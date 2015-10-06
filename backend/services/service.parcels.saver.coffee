parcelSvc = require './service.properties.parcels'
Promise = require 'bluebird'
logger = require '../config/logger'
JSONStream = require 'JSONStream'
{geoJsonFormatter} = require '../utils/util.streams'
parcelFetcher = require './service.parcels.fetcher.digimaps'
parcelFetcher = parcelFetcher.getParcelZipFileStream
{WGS84, UTM, crsFactory} = require '../../common/utils/enums/util.enums.map.coord_system'
shp2json = require 'shp2jsonx'
_ = require 'lodash'
through = require 'through'
{expectedSingleRow} =  require '../utils/util.sql.helpers'
tables = require '../config/tables'
dbs = require '../config/dbs'

_parcelsTblName = 'parcels'
_toReplace = 'REPLACE_ME'


_formatParcel = (feature) ->
  #match the db attributes
  obj = _.mapKeys feature.properties, (val, key) ->
    key.toLowerCase()
  obj.rm_property_id = obj.parcelapn + obj.fips + '_001'
  obj.geometry = feature.geometry
  obj.geometry.crs = crsFactory()
  obj

_getParcelJSON = (fullPath, digimapsSetings) ->
  parcelFetcher(fullPath, digimapsSetings)
  .then (stream) ->
    shp2json(stream)
    .pipe(JSONStream.parse('*.features.*'))

_getFormatedParcelJSON = (fullPath, digimapsSetings) ->
  _getParcelJSON(fullPath, digimapsSetings)
  .then (stream) ->
    write = (obj) ->
      @queue _formatParcel(obj)
    end = ->
      @queue null
    stream.pipe through(write, end)

_fixGeometrySql = (val, method = 'insert') ->
  # logger.debug val.geometry
  toReplaceWith = "st_geomfromgeojson( '#{JSON.stringify(val.geometry)}')"
  toReplaceWith = "ST_Multi(#{toReplaceWith})" if val.geometry.type == 'Polygon'
  key = if val.geometry.type == 'Point' then 'geom_point' else 'geom_polys'
  delete val.geometry
  val[key] = _toReplace
  q = tables.property.rootParcel()[method](val)
  .where(rm_property_id: val.rm_property_id) if method == 'update'
  raw = q.toString()
  raw.replace("'#{_toReplace}'", toReplaceWith)


_execRawQuery = (val, method = 'insert') ->
  raw = _fixGeometrySql(val, method)
  # logger.debug raw
  dbs.get('main').transaction (trx) ->
    q = trx.raw(raw)
    # if method == 'update'
    # logger.debug "\n\n"
    # logger.debug q.toString()
    # logger.debug "\n\n"
    q

_uploadToParcelsDb = (fullPath, digimapsSetings) -> Promise.try ->
  _getParcelJSON(fullPath, digimapsSetings)
  .then (stream) ->
    inserts = {}
    updates = {}

    new Promise (resolve, reject) ->
      stream.on 'error', reject
      stream.on 'end', ->
        invalidCtr = insertsCtr = updatesCtr = 0
        pointsInserted = (_.filter _.values(inserts) , (v) -> v == 'Point').length
        polysUpdated = (_.filter _.values(updates) , (v) -> v == 'Polygon').length
        #verify Points inserted matches what the DB has
        #should we reject?
        expectedSingleRow(tables.property.rootParcel().count()
        .where(fips: fipsCode)
        .whereNotNull('geom_point'))
        .then (row) ->
          logger.debug "Point Count: #{row.count}"
          if row.count != pointsInserted
            logger.warn "Point Count MisMatch: Db Count #{row.count} vs pointsInserted: #{pointsInserted}"
        #verify Polys updated matches what the DB has
        #should we reject?
        expectedSingleRow(tables.property.rootParcel().count()
        .where(fips: fipsCode)
        .whereNotNull('geom_point')
        .whereNotNull('geom_polys'))
        .then (row) ->
          logger.debug "Poly Count: #{row.count}"
          if row.count != polysUpdated
            logger.warn "Poly Count MisMatch: Db Count #{row.count} vs polysUpdated: #{polysUpdated}"

        logger.debug "done kicking off insert/updates for parcels fipsCode: #{fipsCode}"
        dbs.get('main').raw("SELECT dirty_materialized_view('parcels', FALSE);")
        .catch reject
        .then ->
          resolve
            invalidCtr: invalidCtr
            insertsCtr: insertsCtr
            updatesCtr: updatesCtr

      stream.on 'data', (feature) ->
        #logger.debug feature
        #Upload each object to the parcels DB
        #some objects are points and others a polygons
        #one will be an insert and the next will be an update
        feature = _formatParcel feature
        geomType = feature.geometry.type
      #   logger.debug feature.geometry.type

        val = feature
        return unless val?.parcelapn#GTFO we cant make a valid rm_property_id with no apn
        insert = ->
          return if inserts?[val.rm_property_id]
          inserts[val.rm_property_id] = geomType
          _execRawQuery(val)
          .then ->
            insertsCtr += 1
          .catch ->
            invalidCtr += 1
        update = (old) ->
          return if updates?[val.rm_property_id]
          updates[val.rm_property_id] = geomType
          updateObj = _.merge({},old, val)
          # logger.debug "\n\n"
          # logger.debug updateObj
          # logger.debug "\n\n"
          _execRawQuery(updateObj, 'update')
          .then ->
            updatesCtr += 1
          .catch ->
            invalidCtr += 1

        parcelSvc.upsert val, insert, update

module.exports =
  getParcelJSON: _getParcelJSON
  getFormatedParcelJSON: _getFormatedParcelJSON
  uploadToParcelsDb: _uploadToParcelsDb
