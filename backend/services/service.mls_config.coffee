_ = require 'lodash'
Promise = require "bluebird"
logger = require '../config/logger'
dbs = require '../config/dbs'
config = require '../config/config'
Encryptor = require '../utils/util.encryptor'
{PartiallyHandledError, isUnhandled} = require '../utils/util.partiallyHandledError'
tables = require '../config/tables'
encryptor = new Encryptor(cipherKey: config.ENCRYPTION_AT_REST)
{ThenableCrud} = require '../utils/crud/util.crud.service.helpers'
mainDb = tables.config.mls

class MlsConfigCrud extends ThenableCrud
  update: (id, entity) ->
    super(id, entity, ['name', 'notes', 'active', 'main_property_data'])

  updatePropertyData: (id, propertyData) ->
    base('getById', id)
    .update
      main_property_data: JSON.stringify(propertyData)
    .then (result) ->
      result == 1
    .catch isUnhandled, (error) ->
      throw new PartiallyHandledError(error)

  # Privileged
  updateServerInfo: (id, serverInfo) ->
    if serverInfo.password
      serverInfo.password = encryptor.encrypt(serverInfo.password)
    base('getById', id)
    .update _.pick(serverInfo, ['url', 'username', 'password'])
    .then (result) ->
      result == 1
    .catch isUnhandled, (error) ->
      throw new PartiallyHandledError(error)

  # Privileged
  create: (entity, id) ->
    if entity.password
      mlsConfig.password = encryptor.encrypt(mlsConfig.password)
    super(entity,id)

instance = new MlsConfigCrud(mainDb)
module.exports = instance
