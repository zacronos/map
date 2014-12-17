db = require('../config/dbs').properties
Parcel = require "../models/model.parcels"
Promise = require "bluebird"
logger = require '../config/logger'
geohashHelper = require '../utils/validation/util.validation.geohash'
requestUtil = require '../utils/util.http.request'
sqlHelpers = require './sql/sql.helpers.coffee'
coordSys = require '../../common/utils/enums/util.enums.map.coord_system'

validators = requestUtil.query.validators

transforms =
  bounds: [
    validators.string(minLength: 1)
    validators.geohash.decode
    validators.array(minLength: 2)
    validators.geohash.transformToRawSQL(column: 'geom_polys_raw', coordSys: coordSys.UTM)
  ]

required =
  bounds: undefined


module.exports =

  getBaseParcelData: (filters) -> Promise.try () ->
    requestUtil.query.validateAndTransform(filters, transforms, required)
    .then (filters) ->

        query = db.knex.select().from(sqlHelpers.tableName(Parcel))
        query.whereRaw(filters.bounds.sql, filters.bounds.bindings)

        query.then (data) ->
          data = data||[]
          # currently we have multiple records in our DB with the same poly...  this is a temporary fix to avoid the issue
          data = _.uniq data, (row) ->
            row.rm_property_id
          data