_ = require 'lodash'
logger = require('../config/logger').spawn('service:retsCache')
tables = require '../config/tables'
Promise = require 'bluebird'
internals = require './service.retsCache.internals'


###
  As a whole, this service is a layer in front of service.rets to cache the results of metadata requests in the db and
  prevent making unnecessary requests to the RETS server.  That's a big deal since some of them limit concurrent logins.
###


# gets metadata (data type, id for a code-to-readable-values map, etc) about the columns available for a given table in
# a given db of a RETS server
getColumnList = (opts) ->
  {mlsId, databaseId, tableId, forceRefresh} = opts
  logger.debug () -> "getColumnList(), mlsId=#{mlsId}, databaseId=#{databaseId}, tableId=#{tableId}, forceRefresh=#{forceRefresh}"
  cacheSpecs =
    datasetCriteria:
      data_source_id: mlsId
      data_list_type: "#{databaseId}/#{tableId}"
    extraEntityFields:
      data_source_type: 'mls'
    dbFn: tables.config.dataSourceFields
  internals.getRetsMetadata({cacheSpecs, overrideKey: 'SystemName', callName: 'getColumnList', mlsId, otherIds: [databaseId, tableId], forceRefresh})


# gets a list of code-to-readable-values mappings for a given database and mapping/lookup id on a RETS server, as would
# be found in the metadata from getColumnList
getLookupTypes = (opts) ->
  {mlsId, databaseId, lookupId, forceRefresh} = opts
  logger.debug () -> "getLookupTypes(), mlsId=#{mlsId}, databaseId=#{databaseId}, lookupId=#{lookupId}, forceRefresh=#{forceRefresh}"
  cacheSpecs =
    datasetCriteria:
      data_source_id: mlsId
      data_list_type: databaseId
      LookupName: lookupId
    extraEntityFields:
      data_source_type: 'mls'
    dbFn: tables.config.dataSourceLookups
  internals.getRetsMetadata({cacheSpecs, callName: 'getLookupTypes', mlsId, otherIds: [databaseId, lookupId], forceRefresh})


# gets metadata about the databases available on a given RETS server
getDatabaseList = (opts) ->
  {mlsId, forceRefresh} = opts
  logger.debug () -> "getDatabaseList(), mlsId=#{mlsId}, forceRefresh=#{forceRefresh}"
  cacheSpecs =
    datasetCriteria:
      data_source_id: mlsId
    dbFn: tables.config.dataSourceDatabases
  internals.getRetsMetadata({cacheSpecs, callName: 'getDatabaseList', mlsId, otherIds: [], forceRefresh})


# gets a list of the object (image/video) types available on a given RETS server -- an entity (listing, realtor, etc)
# may have objects associated with it, and they must be requested by type
getObjectList = (opts) ->
  {mlsId, forceRefresh} = opts
  logger.debug () -> "getObjectList(), mlsId=#{mlsId}, forceRefresh=#{forceRefresh}"
  cacheSpecs =
    datasetCriteria:
      data_source_id: mlsId
    dbFn: tables.config.dataSourceObjects
  internals.getRetsMetadata({cacheSpecs, callName: 'getObjectList', mlsId, otherIds: [], forceRefresh})


# gets metadata about the tables available in a given database on a given RETS server
getTableList = (opts) ->
  {mlsId, databaseId, forceRefresh} = opts
  logger.debug () -> "getTableList(), mlsId=#{mlsId}, databaseId=#{databaseId}, forceRefresh=#{forceRefresh}"
  cacheSpecs =
    datasetCriteria:
      data_source_id: mlsId
      data_list_type: databaseId
    dbFn: tables.config.dataSourceTables
  internals.getRetsMetadata({cacheSpecs, callName: 'getTableList', mlsId, otherIds: [databaseId], forceRefresh})


module.exports = {
  getColumnList
  getLookupTypes
  getDatabaseList
  getObjectList
  getTableList
}