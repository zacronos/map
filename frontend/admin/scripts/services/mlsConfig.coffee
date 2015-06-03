app = require '../app.coffee'
backendRoutes = require '../../../../common/config/routes.backend.coffee'

app.service 'rmapsMlsService', ['Restangular', (Restangular) ->

  mlsRestangular = Restangular.all(backendRoutes.mls.apiBaseMls)
  mlsConfigRestangular = Restangular.all(backendRoutes.mls.apiBaseMlsConfig)

  getConfigs = () ->
    Restangular.all('/api/mls_config').getList()

  postConfig = (configObj) ->
    console.log "#### configObj:"
    console.log configObj
    #mlsConfigRestangular.post("mlsConfig", configObj)
    Restangular.all('/api/mls_config').post(configObj)

  getDatabaseList = (configId) ->
    Restangular.all('/api/mls').one(configId).all('databases').getList()

  getTableList = (configId, databaseName) ->
    Restangular.all('/ap/mls').one(configId).all('tables').getList
      databaseName: databaseName

  getColumnList = (configId, databaseName, tableName) ->
    Restangular.all('/api/mls').one(configId).all('columns').getList
      databaseName: databaseName,
      tableName: tableName

  service =
    getConfigs: getConfigs,
    postConfig: postConfig,
    getDatabaseList: getDatabaseList,
    getTableList: getTableList,
    getColumnList: getColumnList

  service
]
