config = require '../../common/config/commonConfig'
base = require './service.properties.base.filterSummary'
sqlHelpers = require './../utils/util.sql.helpers.coffee'
indexBy = require '../../common/utils/util.indexByWLength'
Point = require('../../common/utils/util.geometries').Point
sqlCluster = require '../utils/util.sql.manual.cluster'
Promise = require "bluebird"
logger = require '../config/logger'
propMerge = require '../utils/util.properties.merge'
db = require('../config/dbs').properties
tables = require '../config/tables'
_ = require 'lodash'

_getZoom = (position) ->
  position.center.zoom

_handleReturnType = (state, queryParams, limit, zoom = 13) ->
  returnAs = queryParams.returnType

  _default = ->
    query = base.getFilterSummaryAsQuery(state, queryParams, 800)
    return Promise.resolve([]) unless query

    # include saved id's in query so no need to touch db later
    propertiesIds = _.keys(state.properties_selected)
    if propertiesIds.length > 0
      sqlHelpers.orWhereIn(query, 'rm_property_id', propertiesIds)

    # remove dupes
    # include "savedDetails" for saved props
    query.then (properties) ->
      propMerge.updateSavedProperties(state, properties)

    # more data arranging
    .then (properties) ->
      _.each properties, (prop) ->
        prop.type = prop.geom_point_json.type
        prop.coordinates = prop.geom_point_json.coordinates
        delete prop.geom_point_json
        delete prop.geometry
      props = indexBy(properties, false)
      props

  _cluster = ->
    base.getFilterSummary(state, queryParams, limit, sqlCluster.clusterQuery(zoom))
    .then (properties) ->
      sqlCluster.fillOutDummyClusterIds(properties)
    .then (properties) ->
      properties

  _geojsonPolys = ->
    query = base.getFilterSummaryAsQuery(state, queryParams, 2000, query)
    return Promise.resolve([]) unless query

    # include saved id's in query so no need to touch db later
    propertiesIds = _.keys(state.properties_selected)
    if propertiesIds.length > 0
      sqlHelpers.orWhereIn(query, 'rm_property_id', propertiesIds)

    # data formatting
    query.then (data) ->
      geojson =
        "type": "FeatureCollection"
        "features": propMerge.updateSavedProperties(state, data).map (d) ->
          d.type = 'Feature'
          d.properties = {}
          d

  _clusterOrDefault = ->
    base.getResultCount(state, queryParams).then (data) ->
      if data[0].count > config.backendClustering.resultThreshold
        return _cluster()
      else
        return _default()

  handles =
    cluster: _cluster
    geojsonPolys: _geojsonPolys
    default: _default
    clusterOrDefault: _clusterOrDefault

  handle = handles[returnAs] or handles.default
  handle()

module.exports =
  getFilterSummary: (state, rawFilters, limit = 2000) ->
    _zoom = null
    Promise.try ->
      base.validateAndTransform(state, rawFilters)
    .then (queryParams) ->
      _handleReturnType(state, queryParams, limit, _getZoom(state.map_position))
