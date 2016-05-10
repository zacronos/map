Promise = require 'bluebird'
_ = require 'lodash'
diff = require('deep-diff').diff

logger = require('../config/logger').spawn('task:digimaps:parcelHelpers')
parcelUtils = require '../utils/util.parcel'
tables = require '../config/tables'
dbs = require '../config/dbs'
dataLoadHelpers = require './util.dataLoadHelpers'
mlsHelpers = require './util.mlsHelpers'
countyHelpers = require './util.countyHelpers'
sqlHelpers = require '../utils/util.sql.helpers'
jobQueue = require '../services/service.jobQueue'
{SoftFail, HardFail} = require '../utils/errors/util.error.jobQueue'
analyzeValue = require '../../common/utils/util.analyzeValue'
{PartiallyHandledError, isUnhandled} = require '../utils/errors/util.error.partiallyHandledError'
validation = require '../utils/util.validation'

column = 'feature'

diffExcludeKeys = [
  'rm_inserted_time'
  'rm_modified_time'
  'geom_polys_raw'
  'geom_point_raw'
  'change_history'
  # 'deleted'
  # 'inserted'
  # 'updated'
]

getRowChanges = (row1, row2) ->
  diff(_.omit(row1, diffExcludeKeys), _.omit(row2, diffExcludeKeys)).map (c) ->
    _(c).omit(_.isUndefined).omit(_.isNull).value()


saveToNormalDb = ({subtask, rows, fipsCode, delay}) -> Promise.try ->
  tableName = 'parcel'
  rawSubid = dataLoadHelpers.buildUniqueSubtaskName(subtask)
  delay ?= 100

  jobQueue.getLastTaskStartTime(subtask.task_name, false)
  .then (startTime) ->

    normalPayloads = parcelUtils.normalize {
      batch_id: subtask.batch_id
      data_source_id: subtask.task_name
      rows
      fipsCode
      startTime
    }

    logger.debug "got #{normalPayloads.length} normalized rows"

    tablesPropName = 'norm'+tableName.toInitCaps()


    #these promises must happen in order since we might have multiple props of the same rm_property_id
    # due to appartments; and or geom_poly_json or geom_point_json for the same prop (since they come in sep payloads)
    #THIS FIXES insert collisions when they should be updates
    #TODO: Bluebird 3.X use mapSeries
    Promise.each normalPayloads, (payload) ->
      # logger.debug payload

      #NOTE: rm_raw_id is always defined which is why it is destructured here
      # this way we do not need to check for stats or row defined.
      {row, stats, error, rm_raw_id} =  payload

      Promise.try () ->
        if error
          throw error

        dataLoadHelpers.updateRecord {
          stats
          dataType: tablesPropName
          updateRow: row
          delay
          getRowChanges
        }
      #removed for performance
      #.then () ->
      #  tables.temp(subid: rawSubid)
      #  .where({rm_raw_id})
      #  .update(rm_valid: true, rm_error_msg: null)
      .catch analyzeValue.isKnexError, (err) ->
        jsonData = JSON.stringify(row,null,2)
        logger.warn "#{analyzeValue.getSimpleMessage(err)}\nData: #{jsonData}"
        throw HardFail err.message
      .catch validation.DataValidationError, (err) ->
        tables.temp(subid: rawSubid)
        .where({rm_raw_id})
        .update(rm_valid: false, rm_error_msg: err.toString())
    .catch isUnhandled, (error) ->
      throw new PartiallyHandledError(error, 'problem saving normalized data')

finalizeParcelEntry = (entries) ->
  entry = entries.shift()
  entry.active = false
  delete entry.deleted
  delete entry.rm_inserted_time
  delete entry.rm_modified_time
  entry.prior_entries = sqlHelpers.safeJsonArray(entries)
  entry.change_history = sqlHelpers.safeJsonArray(entry.change_history)
  entry.update_source = entry.data_source_id
  entry

_finalizeNewParcel = ({parcels, id, subtask, transaction}) ->
  parcel = finalizeParcelEntry(parcels)

  tables.property.parcel(transaction: transaction)
  .where
    rm_property_id: id
    data_source_id: subtask.task_name
    active: false
  .delete()
  .then () ->
    tables.property.parcel(transaction: transaction)
    .insert(parcel)

_finalizeUpdateListing = ({id, subtask, transaction}) ->
  tables.property.combined(transaction: transaction)
  .where
    rm_property_id: id
    active: true
  .then (rows) ->
    promises = for r in rows
      do (r) ->
        #figure out data_source_id and type
        #execute finalize for that specific MLS (subtask)
        if r.data_source_type == 'mls'
          mlsHelpers.finalizeData({subtask, id, data_source_id: r.data_source_id})
        else
          countyHelpers.finalizeData({subtask, id, data_source_id: r.data_source_id})

    Promise.all promises

finalizeData = (subtask, id, delay) -> Promise.try () ->
  delay ?= 100
  ###
  - MOVE / UPSERT entire normalized.parcel table to main.parcel
  - UPDATE LISTINGS / data_combined geometries
  ###
  Promise.delay delay
  .then () ->
    tables.property.normParcel()
    .select('*')
    .where(rm_property_id: id)
    .whereNull('deleted')
    .orderBy('rm_property_id')
    .orderBy('deleted')
    .then (parcels) ->
      if parcels.length == 0
        # might happen if a singleton listing is deleted during the day
        return tables.deletes.parcel()
        .insert
          rm_property_id: id
          data_source_id: subtask.task_name
          batch_id: subtask.batch_id

      dbs.get('main').transaction (transaction) ->
        finalizeListingPromise = _finalizeUpdateListing({id, subtask, transaction})
        finalizeParcelPromise = _finalizeNewParcel({parcels, id, subtask, transaction})

        Promise.all [finalizeListingPromise, finalizeParcelPromise]


activateNewData = (subtask) ->
  logger.debug subtask

  dataLoadHelpers.activateNewData subtask, {
    propertyPropName: 'parcel',
    deletesPropName: 'parcel'
  }

handleOveralNormalizeError = ({error, dataLoadHistory, numRawRows, fileName}) ->
  errorLogger = logger.spawn('handleOveralNormalizeError')

  errorLogger.debug "handling error"
  errorLogger.debug error
  errorLogger.debug fileName

  updateEntity =
    rm_valid: false
    rm_error_msg: fileName + " : " + error.message
    raw_rows: 0

  tables.jobQueue.dataLoadHistory()
  .where dataLoadHistory
  .then (results) ->
    if results?.length
      tables.jobQueue.dataLoadHistory()
      .where dataLoadHistory
      .update updateEntity
    else
      tables.jobQueue.dataLoadHistory()
      .insert _.extend {}, dataLoadHistory, updateEntity
  .then () ->
    if numRawRows?
      numRawRows


getRecordChangeCountsData = (fipsCode) ->
  {
    deletes: dataLoadHelpers.DELETE.UNTOUCHED
    dataType: "normParcel"
    rawDataType: "parcel"
    rawTableSuffix: fipsCode
    subset:
      fips_code: fipsCode
  }


module.exports = {
  saveToNormalDb
  finalizeData
  finalizeParcelEntry
  activateNewData
  handleOveralNormalizeError
  column
  getRecordChangeCountsData
}
