require('chai').should()
rewire = require 'rewire'
svc = rewire '../../../backend/services/service.properties.filterSummary'
gjv = require 'geojson-validation'

mocks =
  map:
    state: require('../../fixtures/backend/mapState')
    filter: require('../../fixtures/backend/mapFilterFilterSummary')()

describe 'service.properties.filterSummary', ->

  beforeEach ->
    @subject = svc

  it 'geojsonPolys returns valid geojson', (done) ->
    @subject.getFilterSummary { state: mocks.map.state, req: mocks.map.filter }
    .then (data) ->
      gjv.valid(data).should.be.ok
      done()
