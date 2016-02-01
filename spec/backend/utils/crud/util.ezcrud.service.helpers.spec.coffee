_ = require 'lodash'
basePath = require '../../basePath'
sinon = require 'sinon'
SqlMock = require '../../../specUtils/sqlMock'
ServiceCrud = require "#{basePath}/utils/crud/util.ezcrud.service.helpers"
{expect} = require 'chai'
require('chai').should()

describe 'util.ezcrud.service.helpers', ->

  describe 'ServiceCrud', ->
    beforeEach ->
      @sqlMock = new SqlMock 'config', 'dataSourceFields'
      dbFn = () =>
        @sqlMock

      @serviceCrud = new ServiceCrud(dbFn, {debugNS:'ezcrud:service'})
      @query =
        id: 1
        lorem: "ipsum's"

    it 'passes sanity check', ->
      ServiceCrud.should.be.ok
      @serviceCrud.should.be.ok

    it 'fails instantiation without dbFn', ->
      (-> new ServiceCrud()).should.throw()

    it 'returns correct upsert query string', ->
      expectedSql = "INSERT INTO  temp_table  (id,lorem) VALUES  ( 1 , 'ipsum''s' ) ON CONFLICT  (id) DO UPDATE SET  (lorem) = ( 'ipsum''s' ) RETURNING id"
      ids =
        id: 1
      entity =
        lorem: "ipsum's"
      tableName = 'temp_table'
      qstr = ServiceCrud.getUpsertQueryString ids, entity, tableName
      console.log "\n\n\n\n"
      console.log "qstr:\n#{qstr}"
      console.log "expected:\n#{expectedSql}"
      console.log "\n\n\n\n"
      expect(qstr.trim()).to.equal expectedSql

    it 'gets id obj', ->
      idObj = @serviceCrud._getIdObj(@query)
      expect(idObj).to.deep.equal {'id':1}

    it 'scrutinizes id keys', ->
      expect(@serviceCrud._hasIdKeys(@query)).to.be.true
      expect(@serviceCrud._hasIdKeys({})).to.be.false

    it 'returns sqlQuery (knex) object', ->
      sqlQuery = @serviceCrud.exposeKnex().getAll(@query).knex
      expect(sqlQuery).to.deep.equal @sqlMock

    it 'passes getAll', (done) ->
      @serviceCrud.getAll(@query).then (result) =>
        @sqlMock.whereSpy.calledOnce.should.be.true
        done()

    it 'passes create', (done) ->
      @serviceCrud.create(@query).then (result) =>
        @sqlMock.insertSpy.calledOnce.should.be.true
        done()

    it 'passes getById', (done) ->
      @serviceCrud.getById(@query).then (result) =>
        @sqlMock.whereSpy.calledOnce.should.be.true
        done()

    it 'passes update', (done) ->
      @serviceCrud.update(@query).then (result) =>
        @sqlMock.whereSpy.calledOnce.should.be.true
        @sqlMock.updateSpy.calledOnce.should.be.true
        done()

    it 'passes upsert', (done) ->
      @serviceCrud.upsert(@query).then (result) =>
        @sqlMock.rawSpy.calledOnce.should.be.true
        done()

    it 'passes delete', (done) ->
      @serviceCrud.delete(@query).then (result) =>
        @sqlMock.whereSpy.calledOnce.should.be.true
        @sqlMock.deleteSpy.calledOnce.should.be.true
        done()
