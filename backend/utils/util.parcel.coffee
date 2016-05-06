_ = require 'lodash'
{crsFactory} = require '../../common/utils/enums/util.enums.map.coord_system'
logger = require('../config/logger').spawn('util.parcel')
tables = require '../config/tables'
sqlHelpers = require '../utils/util.sql.helpers'
validation = require '../utils/util.validation'


formatParcel = (feature) ->
  ###
    parcelapn: '48066001',
    fips: '06009',
    sthsnum: '61',
    stdir: 'S',
    ststname: 'WALLACE LAKE',
    stsuffix: 'DR',
    stquadrant: null,
    stunitprfx: null,
    stunitnum: null,
    stcity: 'VALLEY SPRINGS',
    ststate: 'CA',
    stzip: '95252',
    stzip4: null,
    xcoord: '-120.972668',
    ycoord: '38.196870',
    geosource: 'PARCELS',
    addrscore: '3',
    rm_property_id: '4806600106009_001',
  geometry:
   type: 'Point',
     coordinates: [ -120.97266826902195, 38.196869881471976 ],
     crs: { type: 'name', properties: {}
  ###
  if !feature?
    throw new validation.DataValidationError('required', 'feature', feature)
  if !feature.geometry?
    throw new validation.DataValidationError('required', 'feature.geometry', feature.geometry)

  #match the db attributes
  obj = _.mapKeys feature.properties, (val, key) ->
    key.toLowerCase()

  if !obj?.parcelapn?
    throw new validation.DataValidationError('required', 'feaure.properties.parcelapn', obj?.parcelapn)

  # if obj.parcelapn.match(/row/i)
  #   throw new Error 'feaure.properties.parcelapn contains ROW, ignore'

  obj.data_source_uuid = obj.parcelapn
  obj.rm_property_id = obj.fips + '_' + obj.parcelapn + '_001'
  obj.geometry = feature.geometry
  obj.geometry.crs = crsFactory()
  obj

_trimmedPicks = [
  'fips_code'
  'rm_property_id'
  'street_address_num'
  'street_unit_num'
  'geometry'
  'data_source_uuid'
  'rm_raw_id'
]

formatTrimmedParcel = (feature) ->
  feature = formatParcel(feature)
  feature.street_address_num = feature.sthsnum
  feature.street_unit_num = feature.stunitnum
  feature.fips_code = feature.fips
  _.pick feature, _trimmedPicks


normalize = ({batch_id, rows, fipsCode, data_source_id, startTime}) ->
  stringRows = rows

  for row in stringRows
    do (row) ->
      ret = try
        #feature is a string, make it a JSON obj
        obj = formatTrimmedParcel JSON.parse row.feature
        # logger.debug obj

        if fipsCode
          obj.fips_code = fipsCode

        _.extend obj, {
          data_source_id
          batch_id
          rm_raw_id: row.rm_raw_id
        }
        #return a valid row
        row: obj
      catch error
        #return an error object
        error: error

      # Regardless we extend a row or an error object with stats
      # and .. with rm_raw_id! This allows for less object defined
      # checking where rm_raw_id will always be defined.
      _.extend ret,
        rm_raw_id: row.rm_raw_id# dont forget about me :)
        stats: {
          data_source_id
          batch_id
          rm_raw_id: row.rm_raw_id
          up_to_date: startTime
        }

_toReplace = 'REPLACE_ME'

_fixTableName = (database, tableName) ->
  normStr = ''
  if database == 'norm' || database == 'normalized'
    normStr = 'norm'
    tableName = normStr + tableName.toInitCaps()
  tableName

_prepEntityForGeomReplace = (row) ->
  # logger.debug val.geometry
  toReplaceWith = "st_geomfromgeojson( '#{JSON.stringify(row.geometry)}')"
  toReplaceWith = "ST_Multi(#{toReplaceWith})" if row.geometry.type == 'Polygon'

  key = if row.geometry.type == 'Point' then 'geom_point_raw' else 'geom_polys_raw'

  delete row.geometry

  row[key] = _toReplace

  {row, toReplaceWith}

_insertOrUpdate = (method, {row, tableName, database}) ->
  method ?= 'insert'
  tableName = _fixTableName database, tableName
  {row, toReplaceWith} = _prepEntityForGeomReplace row

  q = tables.property[tableName]()[method](row)

  if method == 'update'
    q = q.where(rm_property_id: row.rm_property_id)

  raw = q.toString()
  raw = raw.replace("'#{_toReplace}'", toReplaceWith)
    .replace(/\\/g,'') #hack to deal with change_history and json knex issues

  logger.debug raw
  raw


insertParcelStr = _insertOrUpdate.bind(null, 'insert')

updateParcelStr = _insertOrUpdate.bind(null, 'update')

upsertParcelSqlString = ({row, tableName, database}) ->

  tableName = _fixTableName database, tableName
  {row, toReplaceWith} = _prepEntityForGeomReplace {row, tableName, database}

  q = sqlHelpers.upsert
    idObj: rm_property_id: row.rm_property_id
    entityObj: _.omit(row, 'rm_property_id'),
    dbFn: tables.property[tableName]

  raw = q.toString()
  raw = raw.replace(new RegExp("'#{_toReplace}'", "g"), toReplaceWith)

  logger.debug raw
  raw

module.exports = {
  formatParcel
  formatTrimmedParcel
  normalize
  upsertParcelSqlString
  insertParcelStr
  updateParcelStr
}
