db = require('../config/dbs').properties
parcelSvc = require './service.properties.parcels'
Promise = require "bluebird"
logger = require '../config/logger'
JSONStream = require 'JSONStream'
{geoJsonFormatter} = require '../utils/util.streams'
parcelFetcher = require './service.parcels.fetcher.digimaps'
{WGS84, UTM} = require '../../common/utils/enums/util.enums.map.coord_system'
shp2json = require 'shp2jsonx'
_ = require 'lodash'
through = require 'through'

_toReplace = "REPLACE_ME"

_formatParcel = (feature) ->
    #match the db attributes
    obj = _.mapKeys feature.properties, (val, key) ->
        key.toLowerCase()
    obj.rm_property_id = obj.parcelapn + obj.fips + '_001'
    obj.geometry = feature.geometry
    obj.geometry.crs =
        type: "name"
        properties:
            name: "EPSG:26910"
    obj

_formatParcels = (featureCollection)  ->
    featureCollection.features.map (f) ->
        _formatParcel(f)

_getParcelJSON = (fipsCode) ->
    parcelFetcher(fipsCode)
    .then (stream) ->
        shp2json(stream)
        .pipe(JSONStream.parse('*'))

_getFormatedParcelJSON = (fipsCode) ->
    _getParcelJSON(fipsCode)
    .then (stream) ->
        write = (obj) ->
          @queue _formatParcels(obj)
        end = ->
          @queue null
        stream.pipe through(write, end)

_fixGeometrySql = (geomType, val, method = 'insert') ->
    # logger.debug val.geometry
    toReplaceWith = "st_geomfromgeojson( '#{JSON.stringify(val.geometry)}')"
    toReplaceWith = "ST_Multi(#{toReplaceWith})" if geomType == 'polygon'
    delete val.geometry
    key = if geomType == 'point' then 'geom_point' else 'geom_polys'
    val[key] = _toReplace
    q = parcelSvc.rootDb()[method](val)
    q = q.where(rm_property_id: val.rm_property_id) if method == 'update'
    raw = q.toString()
    raw.replace("'#{_toReplace}'", toReplaceWith)


_execRawQuery = (geomType, val, method = 'insert') ->
    raw = _fixGeometrySql(geomType,val, method)
    # logger.debug raw
    db.knex.transaction (trx) ->
        q = trx.raw(raw)
        if method == 'update'
            logger.debug "\n\n"
            logger.debug q.toString()
            logger.debug "\n\n"
        q

_uploadToParcelsDb = (fipsCode) ->

    _getParcelJSON(fipsCode)
    .then (stream) ->
        stream.on 'data', (featureCollection) ->
            #Upload each object to the parcels DB
            #some objects are points and others a polygons
            #one will be an insert and the next will be an update
            # logger.debug featureCollection.fileName
            geomType = if featureCollection.fileName.indexOf('Points') != -1 then 'point' else 'polygon'
            logger.debug geomType
            coll = _formatParcels featureCollection
            #not bulk upserting so we can check them individually
            # logger.debug JSON.stringify coll[0]
            # updateGraph = {}
            #
            # _createGraphItem = (geomType, updateObj)->
            #     #cleans up itself
            #     updateGraph[updateObj.rm_property_id] = _execRawQuery(geomType, updateObj, 'update')
            #     updateGraph[updateObj.rm_property_id]
            #     .finally ->
            #         logger.debug "delete graph item: #{old.rm_property_id}"
            #         delete updateGraph[updateObj.rm_property_id]
            #
            # _update = (geomType, updateObj) ->
            #     #keep a graph of updates to keep us from updating the same rows at the same time
            #     graphItem = updateGraph[updateObj.rm_property_id]
            #     if !graphItem? #create
            #         _createGraphItem(geomType,updateObj)
            #         return
            #     #queue up existing promise to exec after another
            #     graphItem.finally ->
            #         _createGraphItem(geomType,updateObj)


            coll.forEach (val)  ->
                insert = ->
                    _execRawQuery(geomType, val)
                update = (old) ->
                    updateObj = _.merge({},old, val)
                    # logger.debug "\n\n"
                    # logger.debug updateObj
                    # logger.debug "\n\n"
                    _execRawQuery(geomType, updateObj, 'update')
                    # _update(geomType, updateObj)
                parcelSvc.upsert val, insert, update

module.exports =
    getParcelJSON: _getParcelJSON
    getFormatedParcelJSON: _getFormatedParcelJSON
    uploadToParcelsDb: _uploadToParcelsDb
