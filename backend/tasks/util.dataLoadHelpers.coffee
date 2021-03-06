tables = require '../config/tables'
Promise = require 'bluebird'
validation = require '../utils/util.validation'
validatorBuilder = require '../../common/utils/util.validatorBuilder'
memoize = require 'memoizee'
vm = require 'vm'
_ = require 'lodash'
logger = require('../config/logger').spawn('dataLoadHelpers')
sqlHelpers = require '../utils/util.sql.helpers'
dbs = require '../config/dbs'
{HardFail} = require '../utils/errors/util.error.jobQueue'
copyStream = require 'pg-copy-streams'
utilStreams = require '../utils/util.streams'
through2 = require 'through2'
rets = require 'rets-client'
parcelUtils = require '../utils/util.parcel'
keystore = require '../services/service.keystore'
analyzeValue = require '../../common/utils/util.analyzeValue'
util = require 'util'
moment = require 'moment'
jobQueue = require '../services/service.jobQueue'
mlsConfigService = require '../services/service.mls_config'
tz = require '../config/tz'

DELETE =
  UNTOUCHED: 'untouched'
  INDICATED: 'indicated'
  NONE: 'none'


buildUniqueSubtaskName = (subtask, overrideBatchId) ->
  parts = [overrideBatchId||subtask.batch_id, subtask.task_name]
  if subtask.data.dataType && !subtask.task_name.endsWith(subtask.data.dataType)
    parts.push(subtask.data.dataType)
  if subtask.data.rawTableSuffix
    parts.push(subtask.data.rawTableSuffix)
  parts.join('_')


_countInvalidRows = (subid, assignedFalse) ->
  query = tables.temp(subid: subid)
  .count('* AS count')
  if assignedFalse
    query.where(rm_valid: false)
  else
    query.whereNull('rm_valid')
  query
  .then (results) ->
    results?[0].count ? 0


_updateDataLoadHistory = (deletedCount, invalidCount, unvalidatedCount, insertedCount, updatedCount, subid, subtask) ->
  logger.spawn(subtask.task_name).debug () -> JSON.stringify({deletedCount, invalidCount, unvalidatedCount, insertedCount, updatedCount, subid})
  tables.history.dataLoad()
  .where(raw_table_name: tables.temp.buildTableName(subid))
  .update
    invalid_rows: invalidCount ? 0
    unvalidated_rows: unvalidatedCount ? 0
    inserted_rows: insertedCount[0]?.count ? 0
    updated_rows: updatedCount[0]?.count ? 0
    deleted_rows: deletedCount[0]?.count ? 0
    touched_rows: null  # query was too expensive to run


recordChangeCounts = (subtask, opts={}) -> Promise.try () ->
  logger.spawn(subtask.task_name).debug () -> subtask

  subid = buildUniqueSubtaskName(subtask)
  subset = subtask.data.subset ? {}

  dbs.transaction 'normalized', (transaction) ->

    deletedPromise = Promise.try () ->
      if subtask.data.deletes == DELETE.UNTOUCHED
        # check if any rows will be left active after delete, and error if not; for efficiency, just grab the id of the
        # first such row rather than return all or count them all
        q = tables.normalized[subtask.data.dataType](subid: opts.normalSubid, transaction: transaction)
        .select('rm_raw_id')
        .where(batch_id: subtask.batch_id)
        .where(subset)
        .whereNull('deleted')
        .limit(1)
        q.then (row) ->
          if !row?.length
            throw new HardFail("operation would delete all active rows for #{subtask.task_name}: #{subid}")
        .then () ->
          # mark any rows not updated by this task (and not already marked) as deleted -- we only do this when doing a full
          # refresh of all data, because this would be overzealous if we're just doing an incremental update; the update
          # will resolve to a count of affected rows
          tables.normalized[subtask.data.dataType](subid: opts.normalSubid, transaction: transaction)
          .whereNot(batch_id: subtask.batch_id)
          .where(subset)
          .whereNull('deleted')
          .update(deleted: subtask.batch_id)
          .then (count) ->
            [count: count]
      else if subtask.data.deletes == DELETE.INDICATED
        tables.normalized[subtask.data.dataType](subid: opts.normalSubid, transaction: transaction)
        .count('*')
        .where(subset)
        .where(deleted: subtask.batch_id)
      else if subtask.data.deletes == DELETE.NONE
        [count: 0]
    # get a count of raw rows from all raw tables from this batch with rm_valid == false
    invalidPromise = if subtask.data.skipRawTable then 0 else _countInvalidRows(subid, true)
    # get a count of raw rows from all raw tables from this batch with rm_valid == NULL
    unvalidatedPromise = if subtask.data.skipRawTable then 0 else _countInvalidRows(subid, false)
    # get a count of rows from this batch with null change history, i.e. newly-inserted rows
    insertedPromise = tables.normalized[subtask.data.dataType](subid: opts.normalSubid, transaction: transaction)
    .where(inserted: subtask.batch_id)
    .where(subset)
    .count('*')
    # get a count of rows from this batch without a null change history, i.e. newly-updated rows
    updatedPromise = tables.normalized[subtask.data.dataType](subid: opts.normalSubid, transaction: transaction)
    .where(updated: subtask.batch_id)
    .where(subset)
    .count('*')
    ### too expensive to run
    touchedPromise = tables.normalized[subtask.data.dataType](subid: subtask.data.normalSubid)
    .where(batch_id: subtask.batch_id)
    .where(subset)
    .orWhere(deleted: subtask.batch_id)
    .where(subset)
    .count('*')
    ###

    Promise.join(deletedPromise, invalidPromise, unvalidatedPromise, insertedPromise, updatedPromise, subid, Promise.resolve(subtask), _updateDataLoadHistory)
    .then () ->
      if !opts.indicateDeletes
        return

      tables.normalized[subtask.data.dataType](subid: opts.normalSubid, transaction: transaction)
      .select('rm_property_id')
      .where(subset)
      .where(deleted: subtask.batch_id)
      .then (results) ->
        # even though it takes place on another db, we want to wait to commit the earlier transaction until the below
        # successfully commits for data safety
        dbs.transaction (mainDbTransaction) ->
          Promise.each results, (r) ->
            markForDelete r.rm_property_id, opts.data_source_id, subtask.batch_id,
              deletesTable: opts.deletesTable
              transaction: mainDbTransaction


# this function deletes extraneous rows
activateNewData = (subtask, {tableProp, transaction, deletes, skipIndicatedDeletes, data_source_id} = {}) -> Promise.try () ->
  logger.spawn(subtask.task_name).debug subtask

  tableProp ?= 'combined'
  subset = {data_source_id}
  _.extend(subset, subtask.data.subset)

  dbs.ensureTransaction transaction, 'main', (transaction) ->
    Promise.try () ->
      if deletes == DELETE.UNTOUCHED
        # in this mode, we delete all rows on this subset that don't have the current batch_id, because we assume this is
        # a full data sync, and if we didn't touch it that means it should be deleted
        tables.finalized[tableProp](transaction: transaction)
        .where(subset)
        .whereNot(batch_id: subtask.batch_id)
        .delete()
      else
        # in this mode, we're doing an incremental update, so every row has been handled individually, either with an
        # upsert, or with an indicated delete below
        tables.finalized[tableProp](transaction: transaction, as: 'deleter')
        .where(data_source_id: data_source_id)
        .whereExists () ->
          tables.deletes[tableProp](transaction: this)
          .select(1)
          .where
            data_source_id: data_source_id
            batch_id: subtask.batch_id
            rm_property_id: dbs.get('main').raw("deleter.rm_property_id")
        .delete()
        .then () ->
          # clean up after itself in the deletes table
          tables.deletes[tableProp](transaction: transaction)
          .where
            data_source_id: data_source_id
            batch_id: subtask.batch_id
          .delete()
    .then () ->
      setLastUpdateTimestamp(subtask)
    .then () ->
      if subtask.data.setRefreshTimestamp
        setLastRefreshTimestamp(subtask)


_getUsedInputFields = (validationDefinition) ->
  if validationDefinition.input?
    if _.isObject validationDefinition.input
      return _.values(validationDefinition.input)
    else
      return validationDefinition.input
  else
    return [validationDefinition.output]


getValidationStrings = (dataSourceType, dataSourceId, dataType, listName, fieldName) ->
  if dataSourceType == 'mls'
    dataSourcePromise = Promise.try () ->
      mlsConfigService.getByIdCached(dataSourceId)
      .then (mlsConfig) ->
        mlsConfig.data_rules
  else if dataSourceType == 'county'
    dataSourcePromise = Promise.try () ->
      Promise.resolve {} # no global rules, so far

  dataSourcePromise
  .then (global_rules) ->
    whereClause =
      data_source_id: dataSourceId
      data_type: dataType
    if listName
      whereClause.list = listName
    if fieldName
      whereClause.output = fieldName
    tables.config.dataNormalization()
    .where(whereClause)
    .orderBy('list')
    .orderBy('ordering')
    .then (validations=[]) ->
      validationMap = {}
      for validationDef in validations
        validationMap[validationDef.list] ?= []

        if _.isEmpty validationDef.transform
          if validationDef.list == 'base'
            rule = validatorBuilder.buildBaseRule(dataSourceType, dataType) validationDef
          else
            rule = validatorBuilder.buildDataRule validationDef

          validationDef.transform = rule.getTransformString global_rules

        validationMap[validationDef.list].push(validationDef)
      return {validationMap: validationMap}


getValidationInfo = (dataSourceType, dataSourceId, dataType, listName, fieldName) ->
  if dataSourceType == 'mls'
    dataSourcePromise = Promise.try () ->
      mlsConfigService.getByIdCached(dataSourceId)
      .then (mlsConfig) ->
        mlsConfig.data_rules
  else if dataSourceType == 'county'
    dataSourcePromise = Promise.try () ->
      Promise.resolve {} # no global rules, so far

  dataSourcePromise
  .then (global_rules) ->
    whereClause =
      data_source_id: dataSourceId
      data_type: dataType
    if listName
      whereClause.list = listName
    if fieldName
      whereClause.output = fieldName
    tables.config.dataNormalization()
    .where(whereClause)
    .orderBy('list')
    .orderBy('ordering')
    .then (validations=[]) ->
      validationMap = {}
      for validationDef in validations
        validationMap[validationDef.list] ?= []

        # If transform was overridden, use it directly
        if !_.isEmpty validationDef.transform
          if !context
            context = vm.createContext(validators: validation.validators)
          validationDef.transform = vm.runInContext(validationDef.transform, context)

        # Most common case, generate the transform from the rule configuration
        else
          if validationDef.list == 'base'
            rule = validatorBuilder.buildBaseRule(dataSourceType, dataType) validationDef
          else
            rule = validatorBuilder.buildDataRule validationDef

          transforms = rule.getTransform global_rules
          if !_.isArray transforms
            transforms = [ transforms ]

          validationDef.transform = _.map transforms, (transform) ->
            validation.validators[transform.name](transform.options)

        validationMap[validationDef.list].push(validationDef)
      # pre-calculate the keys that are grouped for later use
      usedKeys = ['rm_raw_id', 'rm_valid', 'rm_error_msg'] # exclude these internal-only fields from showing up as "unused"
      diffExcludeKeys = ['rm_raw_id']
      if dataSourceType == 'mls'
        # coffeelint: disable=check_scope
        for groupName, validationList of validationMap
        # coffeelint: enable=check_scope
          for validationDefinition in validationList
            # generally, don't count the 'base' fields as being used, but we do for 'address' and 'status', as the source
            # fields for those don't have to be explicitly reused
            if validationDefinition.list != 'base' || validationDefinition.output in ['address', 'status_display']
              usedKeys = usedKeys.concat(_getUsedInputFields(validationDefinition))
            else if validationDefinition.output == 'days_on_market'
              # explicitly exclude these keys from diff, because they are derived values based on date
              diffExcludeKeys.concat(_getUsedInputFields(validationDefinition))
      else if dataSourceType == 'county'
        # coffeelint: disable=check_scope
        for groupName, validationList of validationMap
        # coffeelint: enable=check_scope
          for validationDefinition in validationList
            # generally, don't count the 'base' fields as being used, but we do for 'address', as the source
            # fields for those don't have to be explicitly reused
            if validationDefinition.list != 'base' || validationDefinition.output in ['address', 'owner_address', 'owner_name', 'owner_name_2']
              usedKeys = usedKeys.concat(_getUsedInputFields(validationDefinition))
      return {validationMap: validationMap, usedKeys: usedKeys, diffExcludeKeys: diffExcludeKeys}
# memoize it to cache js evals, but only for up to ~24 hours at a time
getValidationInfo = memoize.promise(getValidationInfo, primitive: true, maxAge: 24*60*60*1000)

getRawRows = (subtask, rawSubid, criteria) ->
  rawSubid ?= buildUniqueSubtaskName(subtask)
  # get rows for this subtask
  rowsPromise = tables.temp(subid: rawSubid)
  .orderBy('rm_raw_id')
  .whereBetween('rm_raw_id', [subtask.data.offset+1, subtask.data.offset+subtask.data.count])
  if criteria
    rowsPromise = rowsPromise.where(criteria)

  logger.spawn(subtask.task_name).debug () -> 'getRawRows: '+rowsPromise.toString()
  rowsPromise

# normalizes data from the raw data table into the permanent data table
normalizeData = (subtask, options) -> Promise.try () ->
  successes = []
  rawSubid = buildUniqueSubtaskName(subtask)

  # get validations rules (does not do the validating)
  validationPromise = getValidationInfo(options.dataSourceType, options.dataSourceId, subtask.data.dataType)

  rawRowsPromise = getRawRows(subtask, rawSubid)

  # applies `validationInfo` (via `validationPromise`) to `rows`
  doNormalization = (rows, validationInfo) ->
    processRow = (row, index, length) ->
      stats =
        batch_id: subtask.batch_id
        rm_raw_id: row.rm_raw_id
        up_to_date: new Date(subtask.data.startTime)

      # applies the validation / transform to the row
      validateSingleField = (definitions) ->
        validation.validateAndTransform(row, definitions)

      Promise.props(_.mapValues(validationInfo.validationMap, validateSingleField))
      .cancellable()
      .then (normalizedData) ->
        # builds record, which includes categorizing non-base fields into `shared_groups` and `subscriber_groups`
        options.buildRecord(stats, validationInfo.usedKeys, row, subtask.data.dataType, normalizedData, subtask.data)
      .then (updateRow) ->
        updateRecord({
          updateRow
          stats
          diffExcludeKeys: validationInfo.diffExcludeKeys
          dataType: subtask.data.dataType
          subid: options.normalSubid
          dataSourceType: options.dataSourceType
          idField: options.idField || 'rm_property_id'
          index
        })
        .then (id) ->
          successes.push(id)
        .catch analyzeValue.isKnexError, (err) ->
          jsonData = util.inspect(updateRow, depth: null)
          tables.temp(subid: rawSubid)
          .where(rm_raw_id: row.rm_raw_id)
          .update(rm_valid: false, rm_error_msg: "#{analyzeValue.getFullDetails(err)}\nData: #{jsonData}")
      .catch validation.DataValidationError, (err) ->
        tables.temp(subid: rawSubid)
        .where(rm_raw_id: row.rm_raw_id)
        .update(rm_valid: false, rm_error_msg: err.toString())
    Promise.each(rows, processRow)
    .then () ->
      rows.length
  Promise.join(rawRowsPromise, validationPromise, doNormalization)
  .then (total) ->
    logger.spawn(subtask.task_name).debug () -> "Finished normalize: #{JSON.stringify(i: subtask.data.i, of: subtask.data.of, rawTableSuffix: subtask.data.rawTableSuffix)} (#{successes.length} successes out of #{total})"
    if successes.length == 0 || options.skipFinalize
      return
    manualData =
      cause: subtask.data.dataType
      i: subtask.data.i
      of: subtask.data.of
      count: successes.length
      values: successes
      fips_code: subtask.data.fips_code
    jobQueue.queueSubsequentSubtask({subtask, laterSubtaskName: "finalizeData", manualData})


# this function mutates the updateRow parameter, and that is by design -- please don't "fix" that without care
updateRecord = (opts) -> Promise.try () ->
  {stats, diffExcludeKeys, diffBooleanKeys, dataType, dataSourceType, subid, updateRow, delay, flattenRows, retried} = opts
  delay ?= 100

  Promise.delay(delay)  #throttle for heroku's sake
  .then () ->
    # check for an existing row
    tables.normalized[dataType](subid: subid)
    .select('*')
    .where(data_source_uuid: updateRow.data_source_uuid)
  .then (result) ->
    if !result?.length
      # no existing row, just insert
      updateRow.inserted = stats.batch_id
      if dataType == 'parcel'
        parcelUtils.prepRowForRawGeom(updateRow)
      sqlHelpers.upsert {
        dbFn: tables.normalized[dataType]
        idObj: {data_source_uuid: updateRow.data_source_uuid}
        entityObj: updateRow
        subid
      }
      .catch analyzeValue.isKnexError, (err) ->
        if err.code == '23505'  # unique constraint
          if retried
            err.rm_query = "Failed to detect existing row"
            throw err
          logger.spawn('uniqueConstraint').debug () -> "Failed to detect existing row"
          delete updateRow.inserted
          newOpts = _.clone(opts)
          newOpts.retried = true
          updateRecord(newOpts)
        else
          throw err
    else
      # found an existing row, so need to update, but include change log
      oldRow = result[0]
      changes = _getRowChanges({updateRow, oldRow, dataSourceType, dataType, diffExcludeKeys, diffBooleanKeys, flattenRows})

      change_history = oldRow.change_history ? []
      if !_.isEmpty(changes)
        updateRow.updated = stats.batch_id
        change_history.push changes
      updateRow.change_history = sqlHelpers.safeJsonArray(change_history)

      if oldRow.deleted && updateRow.deleted
        updateRow.deleted = oldRow.deleted

      if dataType == 'parcel'
        parcelUtils.prepRowForRawGeom(updateRow)

      tables.normalized[dataType](subid: subid)
      .where(data_source_uuid: updateRow.data_source_uuid)
      .update(updateRow)
  .then () ->
    updateRow[opts.idField]


getValues = (list, target) ->
  if !target
    target = {}
  for item in list
    target[item.name] = item.value
  target


# Not all row fields are taken into the result, only those that correspond most directly to the source data,
# excluding those that are expected to be date-related derived values (such as DOM and CDOM for MLS listings)
_flattenRow = (row, dataSourceType, dataType) ->
  flattened = {}

  # first get the [{name: x1, value: y1} ...] lists flattened down as {x1: y1, x2: y2, ...}
  # coffeelint: disable=check_scope
  for groupName, groupList of row.shared_groups
  # coffeelint: enable=check_scope
    getValues(groupList, flattened)

  # coffeelint: disable=check_scope
  for groupName, groupList of row.subscriber_groups
  # coffeelint: enable=check_scope
    getValues(groupList, flattened)

  # then merge in hidden and ungrouped fields
  _.extend(flattened, row.hidden_fields)
  _.extend(flattened, row.ungrouped_fields)

  # retain the configured base/filter fields
  baseRuleKeys = _.keys(validatorBuilder.getBaseRules(dataSourceType, dataType))
  _.extend(flattened, _.pick(row, baseRuleKeys))
  return flattened


_getRowChanges = ({updateRow, oldRow, dataSourceType, dataType, diffExcludeKeys, diffBooleanKeys, flattenRows}) ->
  diffExcludeKeys ?= []
  diffBooleanKeys ?= []
  flattenRows ?= true

  # possibly flatten the rows
  newData = if flattenRows then _flattenRow(updateRow, dataSourceType, dataType) else updateRow
  oldData = if flattenRows then _flattenRow(oldRow, dataSourceType, dataType) else oldRow

  # remove excluded keys
  newData = _.omit(newData, diffExcludeKeys)
  oldData = _.omit(oldData, diffExcludeKeys)

  # do our brand of diff
  changes = _diff(newData, oldData)

  # mask certain changed values with the simple `true` value
  for field in diffBooleanKeys
    if changes.hasOwnProperty(field)
      changes[field] = true

  return changes


# this performs a diff of 2 sets of data, returning only the changed/new/deleted fields as keys, with the value
# taken from row2 (intended to be the older set)
_diff = (row1, row2) ->
  result = {}
  for fieldName, value1 of row1
    value2 = row2[fieldName]
    value1 ?= null
    value2 ?= null
    if _.isEqual(value1, value2)
      continue
    type1 = typeof(value1)
    type2 = typeof(value2)
    if type1 != type2 && (type1 == 'number' || type2 == 'number')
      if parseFloat(value1) == parseFloat(value2)
        # same as numbers, one was just a string coming from a pg NUMERIC column, ignore
        continue
    result[fieldName] = value2

  # then get fields missing from row1
  for fieldName, value2 of row2 when !(fieldName of row1) && value2 != null
    result[fieldName] = value2

  return result


manageRawJSONStream = ({dataLoadHistory, jsonStream, column}) -> Promise.try ->
  #one column to dump the whole json blob to
  isFinished = false
  count = 0

  objectStreamTransform = (json, encoding, callback) ->
    # logger.spawn(dataLoadHistory.raw_table_name).debug json
    if isFinished
      return
    count++

    this.push(type: 'data', payload: [JSON.stringify json])
    callback()

  #format the json to a format compatible for manageRawDataStream
  #format: row of strings
  objectStreamer = through2.obj objectStreamTransform, (callback) ->
    if isFinished
      return
    isFinished = true
    logger.spawn(dataLoadHistory.raw_table_name).debug () -> "FINISHED: #{dataLoadHistory.raw_table_name}"
    objectStreamer.push(type: 'done', payload: count)
    callback()

  objectStreamer.push(type: 'delimiter', payload: '\t')
  objectStreamer.push(type: 'columns', payload: [column])

  jsonStream.once 'error', (err) ->
    if isFinished
      return
    isFinished = true
    objectStreamer.push(type: 'error', payload: err)

  jsonStream.pipe(objectStreamer)

  manageRawDataStream(dataLoadHistory, objectStreamer)


manageRawDataStream = (dataLoadHistory, objectStream, opts={}) ->
  # WOW, super annoying that the line below breaks the build without adding in these comments
  # coffeelint: disable=check_scope
  [batch_id, data_source_id, data_type] = dataLoadHistory.raw_table_name.split('_')
  # coffeelint: enable=check_scope
  commitLogger = logger.spawn('commits').spawn(data_source_id).spawn(data_type)

  dbs.getPlainClient 'raw_temp', (promiseQuery, streamQuery) ->
    startedTransaction = false
    dbStreamer = null
    dbStream = null
    columns = null
    delimiter = null

    doPerValEscape = (val) ->
      utilStreams.pgStreamEscape(val, delimiter)

    commitStreamChunk = ({linesCount}) ->
      dbStreamer.unpipe(dbStream)
      dbStream?.write('\\.\n')
      dbStream?.end()
      dbStream = null
      promiseQuery('COMMIT TRANSACTION')
      .then () ->
        startedTransaction = false
      .then () ->
        tables.history.dataLoad()
        .where(raw_table_name: dataLoadHistory.raw_table_name)
        .update(raw_rows: linesCount + (opts.initialCount ? 0))
      .then () ->
        commitLogger.debug("#{linesCount + (opts.initialCount ? 0)} total rows committed to #{dataLoadHistory.raw_table_name}")

    startStreamChunk = ({createTable}) ->
      promiseQuery('BEGIN TRANSACTION')
      .then () ->
        startedTransaction = true
      .then () ->
        if createTable
          createRawTable = dbs.get('raw_temp').schema.createTable dataLoadHistory.raw_table_name, (table) ->
            table.increments('rm_raw_id').notNullable()
            table.boolean('rm_valid')
            table.text('rm_error_msg')
            for fieldName in columns
              table.text(fieldName)
          promiseQuery(createRawTable.toString())
          .then () ->
            logger.debug () -> "created raw table: #{dataLoadHistory.raw_table_name}"
      .then () ->
        copyStart = "COPY \"#{dataLoadHistory.raw_table_name}\" (\"#{columns.join('", "')}\") FROM STDIN WITH (ENCODING 'UTF8', NULL '', DELIMITER '#{delimiter}')"
        dbStream = streamQuery(copyStream.from(copyStart))
        dbStreamer.pipe(dbStream)

    new Promise (resolve, reject) ->
      # stream the results into a COPY FROM query
      hadError = false
      linesCount = 0
      onError = (err) ->
        reject(err)
        dbStreamer.unpipe(dbStream)
        dbStream?.write('\\.\n')
        dbStream?.end()
        hadError = true
      dbStreamTransform = (event, encoding, callback) ->
        try
          switch event.type
            when 'data'
              if Array.isArray(event.payload)  # escape each value separately
                this.push(_.map(event.payload, doPerValEscape).join(delimiter))
              else  # escape the whole row at once
                this.push(utilStreams.pgStreamEscape(event.payload))
              this.push('\n')
              linesCount++
              Promise.try () ->
                if opts.maxChunkSize? && linesCount%opts.maxChunkSize == 0
                  commitStreamChunk({linesCount})
                  .then () ->
                    startStreamChunk(createTable: false)
              .then () ->
                callback()
            when 'delimiter'
              delimiter = event.payload
              callback()
            when 'columns'
              columns = []
              for fieldName in event.payload
                columns.push fieldName.replace(/\./g, '')
              sqlHelpers.upsert
                dbFn: tables.history.dataLoad
                idObj: {raw_table_name: dataLoadHistory.raw_table_name}
                entityObj: dataLoadHistory
              .then () ->
                commitLogger.debug("Starting chunk streaming to #{dataLoadHistory.raw_table_name} (existing rows: #{opts.initialCount ? 0})")
                startStreamChunk(createTable: !opts.initialCount?)
              .then () ->
                callback()
            when 'error'
              if !(event.payload instanceof rets.RetsReplyError) || event.payload.replyTag != "NO_RECORDS_FOUND"
                # make sure it is a true error, not just no records returned
                onError(event.payload)
              callback()
            else
              callback()
        catch error
          onError(error)
          callback()
      dbStreamer = through2.obj dbStreamTransform, (callback) ->
        totalLines = linesCount + (opts.initialCount ? 0)
        Promise.try () ->
          if startedTransaction
            commitStreamChunk({linesCount})
        .then () ->
          if totalLines > 0
            promiseQuery("CREATE INDEX IF NOT EXISTS \"#{dataLoadHistory.raw_table_name}_rm_valid_idx\" ON \"#{dataLoadHistory.raw_table_name}\" (rm_valid)")
            .catch analyzeValue.isKnexError, (err) ->
              if err.code == '23505'
                # this means we hit an error where the index exists, even though we specified IF NOT EXISTS; we can ignore
                return
              throw err
        .then () ->
          callback()
          if !hadError
            resolve(totalLines)
      objectStream.pipe(dbStreamer)
    .catch (err) ->
      logger.error("problem streaming to #{dataLoadHistory.raw_table_name}: #{err}")
      logger.error analyzeValue.getFullDetails(err)
      Promise.try () ->
        if startedTransaction
          promiseQuery('ROLLBACK TRANSACTION')
      .then () ->
        throw err


getLastUpdateTimestamp = (subtask) ->
  keystore.getValue(subtask.task_name, namespace: 'data update timestamps', defaultValue: 0)

setLastUpdateTimestamp = (subtask, startTime) ->
  keystore.setValue(subtask.task_name, startTime || subtask.data?.startTime, namespace: 'data update timestamps')

getLastRefreshTimestamp = (subtask) ->
  keystore.getValue(subtask.task_name, namespace: 'data refresh timestamps', defaultValue: 0)

setLastRefreshTimestamp = (subtask, startTime) ->
  keystore.setValue(subtask.task_name, startTime || subtask.data?.startTime, namespace: 'data refresh timestamps')

# this is logic that checks to see if the last time something happened was before today, and if it is currently after a
# given time of day (24-hour time).  Note this works based on eastern time zone, including DST
checkReadyForRefresh = (subtask, {targetHour, targetMinute, targetDay, runIfNever}) ->
  targetHour ?= 0
  targetMinute ?= 0
  getLastRefreshTimestamp(subtask)
  .then (refreshTimestamp) ->
    logger.spawn(subtask.task_name).debug () -> refreshTimestamp
    if runIfNever && refreshTimestamp == 0
      return true

    now = Date.now()
    target = moment.utc(now).utcOffset(tz.MOMENT_UTC_OFFSET).startOf('day')
    if target.diff(refreshTimestamp) <= 0  # was today
      return false

    today = target.valueOf()
    if targetDay?
      target.day(targetDay)
      if target.diff(today) != 0
        # not the target day
        return false

    target.hour(targetHour)
    target.minute(targetMinute)
    if target.diff(now) > 0  # not yet past target time
      return false

    return true


markForDelete = (rm_property_id, data_source_id, batch_id, opts={}) ->
  deletesTable = opts.deletesTable ? 'combined'
  transaction = opts.transaction ? undefined

  tables.deletes[deletesTable](transaction: transaction)
  .returning('rm_property_id')
  .insert({rm_property_id, data_source_id, batch_id})


module.exports = {
  buildUniqueSubtaskName
  recordChangeCounts
  activateNewData
  getValidationInfo
  getValidationStrings
  normalizeData
  getRawRows
  getValues
  manageRawDataStream
  manageRawJSONStream
  DELETE
  updateRecord
  getLastUpdateTimestamp
  setLastUpdateTimestamp
  setLastRefreshTimestamp
  getLastRefreshTimestamp
  checkReadyForRefresh
  markForDelete
}
