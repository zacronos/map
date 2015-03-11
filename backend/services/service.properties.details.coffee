db = require('../config/dbs').properties
PropertyDetails = require '../models/model.propertyDetails.coffee'
Promise = require 'bluebird'
logger = require '../config/logger'
requestUtil = require '../utils/util.http.request'
sqlHelpers = require './../utils/util.sql.helpers'
validators = requestUtil.query.validators
ExpressResponse = require '../utils/util.expressResponse'
httpStatus = require '../../common/utils/httpStatus'

columnSets = ['filter', 'address', 'detail', 'all']

transforms =
  rm_property_id: validators.string(minLength: 1)
  columns: validators.choice(choices: columnSets)

#required with default values
required =
  rm_property_id: undefined

module.exports =

  getDetail: (request) -> Promise.try () ->
    requestUtil.query.validateAndTransform(request, transforms, required)
    .then (parameters) ->

      query = sqlHelpers.select(db.knex, parameters.columns)
      .from(sqlHelpers.tableName(PropertyDetails))
      .where(rm_property_id: parameters.rm_property_id)
      .limit(1)

      #logger.sql query.toString()

      query.then (data) ->
        return data?[0]
