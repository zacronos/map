_ = require 'lodash'
logger = require('../config/logger').spawn('service:rets:internals')
keystore = require './service.keystore'
dataSource = require './service.dataSource'
retsService = require '../services/service.rets'
mlsConfigService = require './service.mls_config'
moment = require 'moment'
errorHandlingUtils = require '../utils/errors/util.error.partiallyHandledError'
Promise = require 'bluebird'
UnhandledNamedError = require '../utils/errors/util.error.unhandledNamed'
analyzeValue = require '../../common/utils/util.analyzeValue'

RETS_REFRESHES = 'rets-refreshes'
SEVEN_DAYS_MILLIS = 7*24*60*60*1000


_decideIfRefreshNecessary = (opts) -> Promise.try () ->
  {callName, mlsId, otherIds, forceRefresh} = opts
  if forceRefresh
    logger.debug () -> "_getRetsMetadata(#{mlsId}/#{callName}/#{otherIds.join('/')}): forced refresh"
    return true
  keystore.getValue("#{mlsId}/#{callName}/#{otherIds.join('/')}", namespace: RETS_REFRESHES, defaultValue: 0)
  .then (lastRefresh) ->
    millisSinceLastRefresh = Date.now() - lastRefresh
    if millisSinceLastRefresh > SEVEN_DAYS_MILLIS
      logger.debug () -> "_getRetsMetadata(#{mlsId}/#{callName}/#{otherIds.join('/')}): automatic refresh (last refreshed #{moment.duration(millisSinceLastRefresh).humanize()} ago)"
      return true
    else
      logger.debug () -> "_getRetsMetadata(#{mlsId}/#{callName}/#{otherIds.join('/')}): no refresh needed"
      return false


_cacheCanonicalData = (opts) ->
  {callName, mlsId, otherIds, cacheSpecs, forceRefresh} = opts
  now = Date.now()  # save the timestamp of when we started the request
  mlsConfigService.getById(mlsId)
  .catch (err) ->
    logger.error analyzeValue.getSimpleDetails(err)
    throw new UnhandledNamedError("Can't get MLS config for #{mlsId}: #{err.message || err}")
  .then ([mlsConfig]) ->
    logger.debug () -> "_cacheCanonicalData(#{mlsId}/#{callName}/#{otherIds.join('/')}): attempting to acquire canonical data"
    retsService[callName](mlsConfig, otherIds...)
    .then (list) ->
      if !list?.length
        logger.error "_cacheCanonicalData(#{mlsId}/#{callName}/#{otherIds.join('/')}): no canonical data returned"
        throw new UnhandledNamedError('RetsDataError', "No canonical data returned for #{mlsId}/#{callName}/#{otherIds.join('/')}")
      logger.debug () -> "_cacheCanonicalData(#{mlsId}/#{callName}/#{otherIds.join('/')}): canonical data acquired, caching"
      cacheSpecs.dbFn.transaction (query, transaction) ->
        query
        .where(cacheSpecs.datasetCriteria)
        .delete()
        .then () ->
          Promise.map list, (row) ->
            entity = _.extend(row, cacheSpecs.datasetCriteria, cacheSpecs.extraEntityFields)
            cacheSpecs.dbFn(transaction: transaction)
            .insert(entity)
          .all()
      .then () ->
        keystore.setValue("#{mlsId}/#{callName}/#{otherIds.join('/')}", now, namespace: RETS_REFRESHES)
      .then () ->
        logger.debug () -> "_cacheCanonicalData(#{mlsId}/#{callName}/#{otherIds.join('/')}): data cached successfully"
        return list
  .catch errorHandlingUtils.isCausedBy(retsService.RetsError), (err) ->
    msg = "Problem making call to RETS server for #{mlsId}: #{err.message}"
    if forceRefresh
      # if user requested a refresh, then make sure they know it failed
      throw new UnhandledNamedError('RetsDataError', msg)
    else
      logger.warn(msg)
      return null
  .catch (err) ->
    logger.err "Couldn't refresh data cache for #{mlsId}/#{callName}/#{otherIds.join('/')}"
    throw err


_getCachedData = (opts) -> Promise.try () ->
  {callName, mlsId, otherIds} = opts
  logger.debug () -> "_getRetsMetadata(#{mlsId}/#{callName}/#{otherIds.join('/')}): using cached data"
  dataSource[callName](mlsId, otherIds..., getOverrides: false)
  .then (list) ->
    if !list?.length
      logger.error "_getRetsMetadata(#{mlsId}/#{callName}/#{otherIds.join('/')}): no cached data found"
      throw new UnhandledNamedError('RetsDataError', "No cached data found for #{mlsId}/#{callName}/#{otherIds.join('/')}")
    else
      return list


_applyOverrides = (mainList, opts) ->
  {callName, mlsId, otherIds, overrideKey} = opts
  logger.debug () -> "_getRetsMetadata(#{mlsId}/#{callName}/#{otherIds.join('/')}): applying overrides based on #{overrideKey}"
  dataSource[callName](mlsId, otherIds..., getOverrides: true)
  .then (overrideList) ->
    overrideMap = _.indexBy(overrideList, overrideKey)
    for row in mainList
      for key,value of overrideMap[row[overrideKey]]
        if value?
          row[key] = value
    return mainList


getRetsMetadata = (opts) ->
  {callName, mlsId, otherIds, forceRefresh, overrideKey, cacheSpecs} = opts
  Promise.try () ->
    _decideIfRefreshNecessary(opts)
  .then (doRefresh) ->
    if !doRefresh
      return null
    _cacheCanonicalData(opts)
  .then (canonicalData) ->
    if canonicalData?.length
      return canonicalData
    else
      _getCachedData(opts)
  .then (mainList) ->
    if !overrideKey
      return mainList
    else
      _applyOverrides(mainList, opts)
  .catch (err) ->
    msg = "Error acquiring required RETS data"
    if !(err instanceof UnhandledNamedError)
      msg += ": #{mlsId}/#{callName}/#{otherIds.join('/')}"
    throw new errorHandlingUtils.PartiallyHandledError(err, msg)


module.exports = {
  getRetsMetadata
}
