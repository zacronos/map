{should, expect}= require('chai')
should()
# sinon = require 'sinon'
logger = require('../../specUtils/logger').spawn('util:parcelHelpers')
rewire = require 'rewire'
countyHelpers = rewire '../../../backend/tasks/util.countyHelpers'
countyHelpersInternals = rewire '../../../backend/tasks/util.countyHelpers.internals'
parcelHelpers = rewire '../../../backend/tasks/util.parcelHelpers'
SqlMock = require '../../specUtils/sqlMock'
sqlHelpers = require '../../../backend/utils/util.sql.helpers'


describe "util.countyHelpers", () ->

  describe "finalizeData", () ->

    propTaxMock = null

    before ->
      subtask =
        data:
          dataType: "parcel"
          fips_code: '1234'
          rawTableSuffix: '1234'
          subset:
            fips_code: '1234'

      propTaxMock = new SqlMock('normalized', 'tax', result: [{rm_property_id: 1}])
      mortgagePropMock = new SqlMock('normalized', 'mortgage', result: [])
      deedPropMock = new SqlMock('normalized', 'deed', result: [])
      parcelPropMock = new SqlMock('normalized', 'parcel', result: [])

      deletesPropMock = new SqlMock('deletes', 'combined', result: [])


      tables =
        normalized:
          tax: propTaxMock.dbFn()
          mortgage: mortgagePropMock.dbFn()
          deed: deedPropMock.dbFn()
          parcel: parcelPropMock.dbFn()
        deletes:
          property: deletesPropMock.dbFn()

      mockSqlHelpers =
        checkTableExists: () ->
          Promise.resolve(true)
        safeJsonArray: sqlHelpers.safeJsonArray

      countyHelpersInternals.__set__ 'tables', tables
      countyHelpersInternals.__set__ 'sqlHelpers', mockSqlHelpers

      countyHelpers.__set__ 'internals', countyHelpersInternals
      parcelHelpers.__set__ 'tables', tables
      countyHelpers.__set__ 'parcelHelpers', parcelHelpers

      countyHelpers.finalizeData({subtask, id:'1', data_source_id: 'sourceName'})


    it 'should query table with subid', () ->
      expect(propTaxMock.toString()).to.include('tax_sourceName_1234')
