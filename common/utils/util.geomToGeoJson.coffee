_ = require 'lodash'

toGeoFeature = (row, opts) ->
  opts.deletes?.forEach (prop) ->
    delete row[prop]

  row.properties = {}

  if opts?.geometry?
    geometryStr = _.find opts.geometry, (geomName) ->
      row[geomName]?
    row.geometry = row[geometryStr]

    # console.log row, true

  opts?.toMove?.forEach (prop) ->
    row.properties[prop] = row[prop]
    delete row[prop]

  row.type = 'Feature'


  row

toGeoFeatureCollection = (rows = [], opts = {}) ->
  if opts?.uniqueKey?
    rows = _.uniq rows, (r) ->
      r[opts.uniqueKey]

  rows = for key, row of rows
    toGeoFeature(row, opts)

  type: 'FeatureCollection'
  features: rows

module.exports = {
  toGeoFeature
  toGeoFeatureCollection
}
