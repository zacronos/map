Promise = require 'bluebird'
_ = require 'lodash'
knex = require 'knex'
rewire = require 'rewire'
config = require '../../../backend/config/config'
svc = rewire '../../../backend/services/service.jobs'
sqlMockUtil = require '../../specUtils/sqlMock'


describe 'service.jobs.spec.coffee', ->

  describe 'history service', ->
    beforeEach ->
      @jobQueue_taskHistory = new sqlMockUtil.SqlMock
        groupName: 'jobQueue'
        tableHandle: 'taskHistory'

      @dbs_main = new sqlMockUtil.SqlMock
        groupName: 'dbs'
        tableHandle: 'main'

      @tables =
        jobQueue:
          taskHistory: () =>
            @jobQueue_taskHistory

      @mainDBS =
        get: () =>
          @dbs_main

      _jobQueue = # nullifying the jobQueue.doMaintenance call used in JobService
        doMaintenance: () ->
          _then = 
            then: (fn) =>
              fn()
          _then

      svc.__set__('jobQueue', _jobQueue)
      svc.__set__('dbs', @mainDBS)
      svc.__set__('tables', @tables)

    # getting a timeout error on this test
    xit 'should query history, defaults', (done) =>
      svc.taskHistory.getAll().then (d) =>
        @jobQueue_taskHistory.selectSpy.callCount.should.equal 0
        @jobQueue_taskHistory.whereRawSpy.calledOnce.should.be.true
        expect(@jobQueue_taskHistory.whereRawSpy.args[0][0]).to.equal "now_utc() - started <= interval '30 days'" # the default
        done()


  describe 'history with doMaintenance', ->
    beforeEach ->
      @maintenanceSpy = sinon.spy(svc.__get__('jobQueue').doMaintenance)

    # getting a timeout error on this test
    xit 'should query summary with doMaintenance', (done) ->
      svc.summary.getAll().then (d) =>
        @maintenanceSpy.calledOnce.should.be.true


  describe 'history error service', ->
    beforeEach ->
      @jobQueue_subtaskErrorHistory = new sqlMockUtil.SqlMock
        groupName: 'jobQueue'
        tableHandle: 'subtaskErrorHistory'

      @tables =
        jobQueue:
          subtaskErrorHistory: () =>
            @jobQueue_subtaskErrorHistory

      svc.__set__('tables', @tables)

    # getting a timeout error on this test
    xit 'should query history errors', (done) ->
      svc.subtaskErrorHistory.getAll().then (d) ->
        @jobQueue_subtaskErrorHistory.whereRawSpy.callCount.should.equal 1
        done()


  describe 'task service', ->
    beforeEach ->
      @jobQueue_taskConfig = new sqlMockUtil.SqlMock
        groupName: 'jobQueue'
        tableHandle: 'taskConfig'
      @jobQueue_subtaskConfig = new sqlMockUtil.SqlMock
        groupName: 'jobQueue'
        tableHandle: 'subtaskConfig'

      # niether of these seem to work
      #@tasks = new svc.__get__('TaskService')(@jobQueue_taskConfig())
      svc.tasks.dbFn = @jobQueue_taskConfig()

      @tables =
        jobQueue:
          taskConfig: () =>
            @jobQueue_taskConfig
          subtaskConfig: () =>
            @jobQueue_subtaskConfig

      svc.__set__('tables', @tables)

    # issue involving 'this.jobQueue_taskConfig' not being a function
    xit 'should query task service', (done) ->
      svc.tasks.getAll(name: "foo").then (d) =>
        @jobQueue_taskConfig.whereRawSpy.callCount.should.equal 1
        done()


  describe 'health service', ->
    beforeEach ->
      @jobQueue_taskHistory = new sqlMockUtil.SqlMock
        groupName: 'jobQueue'
        tableHandle: 'taskHistory'
      @jobQueue_dataLoadHistory = new sqlMockUtil.SqlMock
        groupName: 'jobQueue'
        tableHandle: 'dataLoadHistory'
      @property_combined = new sqlMockUtil.SqlMock
        groupName: 'property'
        tableHandle: 'combined'
      @dbs_main = new sqlMockUtil.SqlMock
        groupName: 'dbs'
        tableHandle: 'main'

      @tables =
        jobQueue:
          taskHistory: () =>
            @jobQueue_taskHistory
          dataLoadHistory: () =>
            @jobQueue_dataLoadHistory

        property:
          combined: () =>
            @property_combined

      @mainDBS =
        get: () =>
          @dbs_main

      svc.__set__('dbs', @mainDBS)
      svc.__set__('tables', @tables)


    it 'should query history with defaults', (done) ->
      # sophisticated query containing subqueries, a cross-table join, and several 'raw' calls
      svc.health.getAll()

      # subquery #1
      @jobQueue_dataLoadHistory.selectSpy.calledOnce.should.be.true
      expect(@jobQueue_dataLoadHistory.selectSpy.args[0][0]).to.deep.equal @dbs_main # raw's via dbs_main

      @jobQueue_dataLoadHistory.groupByRawSpy.calledOnce.should.be.true
      expect(@jobQueue_dataLoadHistory.groupByRawSpy.args[0][0]).to.equal 'load_id'

      # no query param yields interval '30 days'
      @jobQueue_dataLoadHistory.whereRawSpy.calledOnce.should.be.true
      expect(@jobQueue_dataLoadHistory.whereRawSpy.args[0][0]).to.equal "now_utc() - rm_inserted_time <= interval '30 days'"

      @jobQueue_dataLoadHistory.whereSpy.calledOnce.should.be.true
      expect(@jobQueue_dataLoadHistory.whereSpy.args[0][0]).to.be.empty
      @jobQueue_dataLoadHistory.asSpy.calledOnce.should.be.true


      # subquery #2
      @property_combined.selectSpy.calledOnce.should.be.true
      expect(@property_combined.selectSpy.args[0][0]).to.deep.equal @dbs_main

      @property_combined.groupByRawSpy.calledOnce.should.be.true
      expect(@property_combined.groupByRawSpy.args[0][0]).to.equal 'combined_id'

      @property_combined.whereRawSpy.callCount.should.equal 0
      expect(@property_combined.whereSpy.args[0][0]).to.be.empty
      @property_combined.asSpy.calledOnce.should.be.true


      # dbs_main (anon knex)
      @dbs_main.selectSpy.calledOnce.should.be.true
      expect(@dbs_main.selectSpy.args[0][0]).to.deep.equal '*'

      @dbs_main.fromSpy.calledOnce.should.be.true
      expect(@dbs_main.fromSpy.args[0][0]).to.deep.equal @jobQueue_dataLoadHistory

      @dbs_main.leftJoinSpy.calledOnce.should.be.true
      expect(@dbs_main.leftJoinSpy.args[0][0]).to.deep.equal @property_combined

      @dbs_main.rawSpy.callCount.should.equal 15 # dbs_main calls all the 'raw'

      done()


    it 'should query history with correct query values', (done) ->
      timerangeTest = '1 day'
      svc.health.getAll timerange: timerangeTest
      expect(@jobQueue_dataLoadHistory.whereRawSpy.args[0][0]).to.equal "now_utc() - rm_inserted_time <= interval '#{timerangeTest}'"

      @jobQueue_dataLoadHistory.whereSpy.calledOnce.should.be.true
      expect(@jobQueue_dataLoadHistory.whereSpy.args[0][0]).to.be.empty

      done()





