Promise = require 'bluebird'
_ = require 'lodash'
moment = require 'moment'
path = require 'path'
# cartoDbSvc = require '../services/service.cartodb'
jobQueue = require '../services/service.jobQueue'
tables = require '../config/tables'
dataLoadHelpers = require './util.dataLoadHelpers'
externalAccounts = require '../services/service.externalAccounts'
parcelsFetch = require '../services/service.parcels.fetcher.digimaps'
parcelHelpers = require './util.parcelHelpers'
TaskImplementation = require './util.taskImplementation'
logger = require('../config/logger.coffee').spawn('task:digimaps')
importsLogger = require('../config/logger.coffee').spawn('task:digimaps:imports')
errorHandlingUtils = require '../utils/errors/util.error.partiallyHandledError'
{SoftFail, HardFail} = require '../utils/errors/util.error.jobQueue'
analyzeValue = require '../../common/utils/util.analyzeValue'
{PartiallyHandledError, isUnhandled} = require '../utils/errors/util.error.partiallyHandledError'
{NoShapeFilesError, UnzipError} = require('shp2jsonx').errors
util = require 'util'
keystore = require '../services/service.keystore'
dbs = require '../config/dbs'


NUM_ROWS_TO_PAGINATE = 1000
DELAY_MILLISECONDS = 250

LAST_PROCESS_DATE = 'last process date'
NO_NEW_DATA_FOUND = 'no new data found'
QUEUED_FILES = 'queued files'
DIGIMAPS_PROCESS_INFO = 'digimaps process info'


_getFileDate = (filename) ->
  return filename.split('/')[2].split('_')[2]

_getFileFips = (filename) ->
  return filename.split('/')[4].slice(8,13)

_filterImports = (subtask, imports, refreshThreshold) ->
  importsLogger.debug () -> imports

  folderObjs = imports.map (l) ->
    name: l
    date: _getFileDate(l)

  if refreshThreshold? && !subtask.data.skipRefreshThreshold
    logger.debug '@@@ refreshThreshold @@@'
    logger.debug refreshThreshold

    folderObjs = _.filter folderObjs, (o) ->
      o.date > refreshThreshold

    if subtask.data.fipsCodeLimit?
      logger.debug () -> "@@@@@@@@@@@@@ fipsCodeLimit: #{subtask.data.fipsCodeLimit}"
      folderObjs = _.take folderObjs, subtask.data.fipsCodeLimit

    fileNames = folderObjs.map (f) -> f.name
    fileNames.sort()
    fipsCodes = fileNames.map (name) -> _getFileFips(name)

    logger.debug "@@@@@@@@@@@@@@@@@@@@@@@@@ fipsCodes Available from digimaps @@@@@@@@@@@@@@@@@@@@@@@@@@@@@"
    logger.debug fipsCodes

    if subtask.data.fipsCodes? && _.isArray subtask.data.fipsCodes
      fileNames = _.filter fileNames, (name) ->
        _.any subtask.data.fipsCodes, (code) ->
          name.endsWith("_#{code}.zip")

      fipsCodes = fileNames.map (name) -> _getFileFips(name)

    logger.debug "@@@@@@@@@@@@@@@@@@@@@@@@@ filtered fipsCodes  @@@@@@@@@@@@@@@@@@@@@@@@@@@@@"
    logger.debug fipsCodes

    return fileNames

_getLoadFile = (subtask, processInfo) -> Promise.try () ->
  now = Date.now()

  if processInfo[QUEUED_FILES].length > 0
    return {
      load:
        fileName: processInfo[QUEUED_FILES][0]
        startTime: now
      processInfo
    }
  else
    externalAccounts.getAccountInfo(subtask.task_name)
    .then (creds) ->
      parcelsFetch.defineImports({creds})
    .then (imports) ->
      _filterImports(subtask, imports, processInfo[LAST_PROCESS_DATE])
    .then (filteredImports) ->
      if filteredImports.length == 0
        processInfo[NO_NEW_DATA_FOUND] = moment.utc().format('YYYYMMDD')
        return {
          load: null
          processInfo
        }
      else
        processInfo[QUEUED_FILES] = filteredImports
        nextFile = filteredImports[0]
        processInfo[LAST_PROCESS_DATE] = _getFileDate(nextFile)
        return {
          load:
            fileName: nextFile
            startTime: now
          processInfo
        }

loadRawDataPrep = (subtask) -> Promise.try () ->
  logger.debug util.inspect(subtask, depth: null)

  defaults = {}
  defaults[LAST_PROCESS_DATE] = '19700101'
  defaults[NO_NEW_DATA_FOUND] = '19700101'
  defaults[QUEUED_FILES] = []
  keystore.getValuesMap(DIGIMAPS_PROCESS_INFO, defaultValues: defaults)
  .then (processInfo) ->
    console.log('@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@ BEFORE '+JSON.stringify(processInfo,null,2))
    _getLoadFile(subtask, processInfo)
  .then (loadInfo) ->
    console.log('~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ AFTER '+JSON.stringify(loadInfo,null,2))
    dbs.transaction (transaction) ->
      keystore.setValuesMap(loadInfo.processInfo, {namespace: DIGIMAPS_PROCESS_INFO, transaction})
      .then () ->
        if loadInfo.load?
          jobQueue.queueSubsequentSubtask {
            subtask
            manualData: loadInfo.load
            laterSubtaskName: 'loadRawData'
            transaction
          }
          .then () ->
            jobQueue.queueSubsequentSubtask {
              subtask
              laterSubtaskName: "waitForExclusiveAccess"
              transaction
            }
          .then () ->
            jobQueue.queueSubsequentSubtask {
              subtask
              laterSubtaskName: "activateNewData"
              manualData: {deletes: dataLoadHelpers.DELETE.INDICATED}
              replace: true
              transaction
            }
          .then () ->
            jobQueue.queueSubsequentSubtask {
              subtask
              laterSubtaskName: "cleanup"
              transaction
            }

loadRawData = (subtask) -> Promise.try () ->
  logger.debug util.inspect(subtask, depth: null)

  {fileName} = subtask.data
  fipsCode = _getFileFips(fileName)
  numRowsToPageNormalize = subtask.data?.numRowsToPageNormalize || NUM_ROWS_TO_PAGINATE

  subtask.data.rawTableSuffix = fipsCode

  rawTableName = tables.temp.buildTableName(dataLoadHelpers.buildUniqueSubtaskName(subtask))

  dataLoadHistory =
    data_source_id: "#{subtask.task_name}_#{fipsCode}"
    data_source_type: 'parcel'
    data_type: 'parcel'
    batch_id: subtask.batch_id
    raw_table_name: rawTableName

  externalAccounts.getAccountInfo(subtask.task_name)
  .then (creds) ->
    parcelsFetch.getParcelJsonStream(fileName, {creds})
    .then (jsonStream) ->

      dataLoadHelpers.manageRawJSONStream({
        tableName: rawTableName
        dataLoadHistory
        jsonStream
        column: parcelHelpers.column
      })
      .catch isUnhandled, (error) ->
        throw new PartiallyHandledError(error, "failed to stream raw data to temp table: #{rawTableName}")
      .catch (error) ->
        throw new SoftFail error.message
    .catch NoShapeFilesError, (error) ->
      parcelHelpers.handleOveralNormalizeError {error, dataLoadHistory, numRawRows: 0, fileName}
    .catch UnzipError, (error) ->
      parcelHelpers.handleOveralNormalizeError {error, dataLoadHistory, numRawRows: 0, fileName}
    .catch errorHandlingUtils.isUnhandled, (error) ->
      throw new errorHandlingUtils.PartiallyHandledError(error, 'failed to load parcels data for update')
    .catch (error) ->
      throw new SoftFail(analyzeValue.getSimpleMessage(error))
    .then (numRawRows) ->
      if numRawRows == 0
        return 0
      # now that we know we have data, queue up the rest of the subtasks
      logger.debug("num rows to normalize: #{numRawRows}")
      normalizeDataPromise = jobQueue.queueSubsequentPaginatedSubtask {
        subtask
        totalOrList: numRawRows
        maxPage: numRowsToPageNormalize
        laterSubtaskName: "normalizeData"
        mergeData: {
          fipsCode
          dataType: 'parcel'
          rawTableSuffix: fipsCode
          startTime: subtask.data.startTime
        }
      }
      recordChangeCountsPromise = jobQueue.queueSubsequentSubtask {
        subtask
        laterSubtaskName: "recordChangeCounts"
        manualData:
          deletes: dataLoadHelpers.DELETE.UNTOUCHED
          dataType: "parcel"
          rawTableSuffix: fipsCode
          indicateDeletes: true
          subset:
            fips_code: fipsCode
        replace: true
      }
      Promise.join normalizeDataPromise, recordChangeCountsPromise, () ->  # no-op

normalizeData = (subtask) ->
  logger.debug util.inspect(subtask, depth: null)

  {fipsCode,  delay} = subtask.data

  dataLoadHelpers.getRawRows subtask
  .then (rows) ->
    if !rows?.length
      logger.debug () -> "no raw rows found for rm_raw_id #{subtask.data.offset+1} to #{subtask.data.offset+subtask.data.count}"
      return
    logger.debug () -> "got #{rows.length} raw rows"

    parcelHelpers.saveToNormalDb {
      subtask
      rows
      fipsCode
      delay: delay ? DELAY_MILLISECONDS
    }

# not used as a task since it is in normalizeData
# however this makes finalizeData accessible via the subtask script
finalizeDataPrep = (subtask) ->
  numRowsToPageFinalize = subtask.data?.numRowsToPageFinalize || NUM_ROWS_TO_PAGINATE
  fipsCode = subtask.data?.fipsCode

  if !fipsCode?
    throw new HardFail('fipsCode is required for finalizedDataPrep')

  logger.debug util.inspect(subtask, depth: null)

  tables.normalized.parcel()
  .select('rm_property_id')
  .where
    batch_id: subtask.batch_id
    fips_code: fipsCode
  .then (ids) ->
    ids  = _.pluck(ids, 'rm_property_id')
    jobQueue.queueSubsequentPaginatedSubtask {
      subtask
      totalOrList: ids
      maxPage: numRowsToPageFinalize
      laterSubtaskName: "finalizeData"
      mergeData:
        normalSubid: fipsCode #required for countyHelpers.finalizeData
    }

###
This step is an in-between to protect a following step from being run.
In this case we are hoping to protect finalizeData (not prep) and activateData.

This is due to the fact that mls or county could be finalizing and activating data at the same time.
Since parcels can modify both mls and county rows in data_combined weird results could happen.

The opposite is true of county and mls since they only modify their perspective and exclusive rows.
###
waitForExclusiveAccess = (subtask) ->
  keystore.setValue('digimapsExclusiveAccess', true, namespace: 'locks')
  .then () ->
    tables.jobQueue.taskHistory()
    .select('name')
    .where(current: true)
    .whereRaw("blocked_by_locks \\? 'digimapsExclusiveAccess'")
    .whereNull('finished')
    .then (results=[]) ->
      if results.length > 0
        logger.info("Waiting for exclusive data_combined access; #{results.length} tasks remaining: #{_.pluck(results, 'name').join(', ')}")
        # Create a promise that doesn't finish on its own -- it just waits to get timed out and retried.  This is safer
        # than trying to poll internally, because a polling flow can't handle zombies, but a retrying flow can
        return new Promise (resolve, reject) ->  # noop
      else
        logger.info("Exclusive data_combined access obtained")
        # go ahead and resolve, so the subtask will finish and the task will continue
        return null


finalizeData = (subtask) ->
  # logger.debug () -> util.inspect(subtask, depth: null)
  logger.debug () -> 'beginning finalizeData'

  {delay, normalSubid} = subtask.data

  if !normalSubid?
    throw new HardFail "normalSubid must be defined"

  Promise.each subtask.data.values, (id) ->
    parcelHelpers.finalizeData(subtask, id, delay ? DELAY_MILLISECONDS)
  # .then ->
  #   jobQueue.queueSubsequentSubtask {
  #     subtask,
  #     laterSubtaskName: 'syncCartoDb'
  #     manualData: subtask.data
  #     replace: true
  #   }

recordChangeCounts = (subtask) ->
  numRowsToPageFinalize = subtask.data?.numRowsToPageFinalize || NUM_ROWS_TO_PAGINATE

  dataLoadHelpers.recordChangeCounts(subtask, deletesTable: 'parcel')
  .then (deletedIds) ->
    jobQueue.queueSubsequentPaginatedSubtask {
      subtask
      totalOrList: deletedIds
      maxPage: numRowsToPageFinalize
      laterSubtaskName: "finalizeData"
      mergeData:
        normalSubid: subtask.data.subset.fips_code  # required for countyHelpers.finalizeData
        deletedParcel: true
    }

cleanup = (subtask) ->
  keystore.setValue('digimapsExclusiveAccess', false, namespace: 'locks')
  .then () ->
    defaults = {}
    defaults[LAST_PROCESS_DATE] = '19700101'
    defaults[NO_NEW_DATA_FOUND] = '19700101'
    defaults[QUEUED_FILES] = []
    keystore.getValuesMap(DIGIMAPS_PROCESS_INFO, defaultValues: defaults)
    .then (processInfo) ->
      processInfo[QUEUED_FILES].shift()
      keystore.setValuesMap(processInfo, namespace: DIGIMAPS_PROCESS_INFO)


ready = () ->
  # do some special logic for efficiency
  defaults = {}
  defaults[LAST_PROCESS_DATE] = '19700101'
  defaults[NO_NEW_DATA_FOUND] = '19700101'
  defaults[QUEUED_FILES] = []
  keystore.getValuesMap(DIGIMAPS_PROCESS_INFO, defaultValues: defaults)
  .then (processInfo) ->
    # definitely run task if there are queued files
    if processInfo[QUEUED_FILES].length > 0
      return true

    oneWeekAgo = moment.utc().subtract(1, 'week').format('YYYYMMDD')

    if processInfo[NO_NEW_DATA_FOUND] >= oneWeekAgo
      # we've already indicated there's no new data to find within the last week
      return false
    # no overrides, ready to run
    return true


subtasks = {
  loadRawDataPrep
  loadRawData
  normalizeData
  recordChangeCounts
  finalizeDataPrep
  waitForExclusiveAccess
  finalizeData
  activateNewData: parcelHelpers.activateNewData
  cleanup
}
module.exports = new TaskImplementation('digimaps', subtasks, ready)
