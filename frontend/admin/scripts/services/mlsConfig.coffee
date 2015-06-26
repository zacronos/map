app = require '../app.coffee'
backendRoutes = require '../../../../common/config/routes.backend.coffee'

app.service 'rmapsMlsService', ['Restangular', (Restangular) ->

  mlsAPI = backendRoutes.mls.apiBaseMls
  mlsConfigAPI = backendRoutes.mls_config.apiBaseMlsConfig

  getConfigs = () ->
    console.log "getList()"
    Restangular.all(mlsConfigAPI).getList()

  postConfig = (configObj, collection) ->
    newMls = Restangular.one(mlsConfigAPI)
    _.merge newMls, configObj
    newMls.post().then (res) ->
      # add to our collection (by reference, for adding to existing dropdowns, etc)
      if collection
        collection.push(newMls)
      newMls

  getDatabaseList = (configId) ->
    Restangular.all(mlsAPI).one(configId).all('databases').getList()

  getTableList = (configId, databaseId) ->
    Restangular.all(mlsAPI).one(configId).all('databases').one(databaseId).all('tables').getList()

  getColumnList = (configId, databaseId, tableId) ->
    Restangular.all(mlsAPI).one(configId).all('databases').one(databaseId).all('tables').one(tableId).all('columns').getList()

  getLookupTypes = (configId, databaseId, lookupId) ->
    Restangular.all(mlsAPI).one(configId).all('databases').one(databaseId).all('lookups').one(lookupId).all('types').getList()

  getDataDumpUrl = (configId, limit) ->
    # bypass XHR / $http file-dl drama, and Restangular req/res complication.
    backendRoutes.mls.getDataDump.replace(":mlsId", configId) + "?limit=#{limit}"

  service =
    getConfigs: getConfigs,
    postConfig: postConfig,
    getDatabaseList: getDatabaseList,
    getTableList: getTableList,
    getColumnList: getColumnList,
    getLookupTypes: getLookupTypes
    getDataDumpUrl: getDataDumpUrl

  service
]
