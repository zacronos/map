logger = require('../config/logger').spawn('map:filterSummary:drawnShapes')
combined = require './service.properties.combined.filterSummary'
_ = require 'lodash'
tables = require '../config/tables'
{distance} = require '../../common/utils/enums/util.enums.map.coord_system.coffee'
drawnShapesTransforms = require('../utils/transforms/transforms.properties.coffee').drawnShapes
internals = require './service.properties.combined.filterSummary.internals'

###
override:
- getFilterSummaryAsQuery
- getDefaultQuery
- (optionally) validateAndTransform
- tested non knex query that works
###

detailsName = tables.finalized.combined.tableName
drawnShapesName = tables.user.drawnShapes.tableName

throwOnUndefined = (thing, name) ->
  unless thing
    throw new Error("#{name} is undefined")

throwOnUndefined(detailsName,"detailsName")
throwOnUndefined(drawnShapesName,"drawnShapesName")

getDefaultQuery = (query = combined.getDefaultQuery()) ->
  #http://stackoverflow.com/questions/12204834/get-distance-in-meters-instead-of-degrees-in-spatialite
  #earth meters per degree 111195
  query.joinRaw tables.finalized.combined().raw """
    inner join #{drawnShapesName} on ST_Within(#{detailsName}.geometry_center_raw, #{drawnShapesName}.geometry_raw)
     or
     ST_DWithin(
     #{detailsName}.geometry_center_raw,
     #{drawnShapesName}.geometry_center_raw,
     text(#{drawnShapesName}.shape_extras->'radius')::float/#{distance.METERS_PER_EARTH_RADIUS})
    """

getFilterSummaryAsQuery = ({queryParams, limit, query, permissions}) ->
  # If a query was passed in, it is a cluster query. The drawn shapes table still needs to be joined
  if query
    getDefaultQuery(query)
  else
    query = getDefaultQuery()
    query.select(query.raw("#{drawnShapesName}.id as area_id"))

  query.where("#{drawnShapesName}.project_id", queryParams.project_id)

  if queryParams.isArea
    query.whereNotNull("#{drawnShapesName}.area_name", queryParams.project_id)

  if queryParams.areaId
    query.where("#{drawnShapesName}.id", queryParams.areaId)

  combined.getFilterSummaryAsQuery({queryParams, limit, query, permissions})

getPropertyIdsInArea = ({queryParams, profile}) ->
  # Calculate permissions for the current user
  combined.getPermissions(profile)

  .then (permissions) ->
    logger.debug permissions

    if !queryParams.areaId
      throw new Error('areaId is required')

    query = getDefaultQuery(tables.finalized.combined().distinct("rm_property_id"))
    .where("#{drawnShapesName}.id", queryParams.areaId)

    # If there are filters set, we can use the standard combined query logic, otherwise it will return empty
    if queryParams?.state?.filters?.status?.length
      query = combined.getFilterSummaryAsQuery({queryParams, query, permissions})

    logger.debug -> query.toString()

    query.then (properties) ->
      _.map(properties, 'rm_property_id')

module.exports = {
  getFilterSummaryAsQuery
  getPropertyIdsInArea
  transforms: drawnShapesTransforms
  cluster: internals
}
