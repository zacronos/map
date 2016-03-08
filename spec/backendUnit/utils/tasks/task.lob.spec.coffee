{should, expect}= require('chai')
should()
sinon = require 'sinon'
Promise = require 'bluebird'
SqlMock = require '../../../specUtils/sqlMock.coffee'
logger = require('../../../specUtils/logger').spawn('task.lob')
rewire = require 'rewire'
svc = rewire "../../../../backend/utils/tasks/task.lob"
_ = require 'lodash'

mockCampaign = require '../../../fixtures/backend/services/lob/mail.campaign.json'
mockLetter = require '../../../fixtures/backend/services/lob/mail.letter.json'
mockLobLetter = require '../../../fixtures/backend/services/lob/lob.letter.singlePage.json'

describe 'task.lob', ->
  beforeEach ->

    @letters = [mockLetter, mockLetter]

    campaigns = new SqlMock 'mail', 'campaign', result: [mockCampaign]
    letters = new SqlMock 'mail', 'letters', result: @letters

    @tables =
      mail:
        campaign: () -> campaigns
        letters:  () -> letters

    svc.__set__ 'tables', @tables

    @lobSvc = createLetter: sinon.spy (letter) -> Promise.try ->
      mockLobLetter

    svc.__set__ 'lobSvc', @lobSvc

    @jobQueue = queueSubsequentSubtask: sinon.spy (transaction, currentSubtask, laterSubtaskName, manualData, replace) ->
      manualData

    svc.__set__ 'jobQueue', @jobQueue

    svc.__set__ 'dbs', transaction: (name, cb) -> cb()

    @subtasks =
      findLetters:
        name: 'lob_findLetters'
        batch_id: 'ikpzfxu5'
      createLetter:
        name: 'lob_createLetter'
        batch_id: 'ikpzfxu5'
        data: mockLetter

  it 'exists', ->
    expect(svc).to.be.ok

  it 'should find letters and enqueue them as subtasks', ->
    svc.executeSubtask(@subtasks.findLetters)
    .then () =>
      @tables.mail.letters().selectSpy.callCount.should.equal 1
      @tables.mail.letters().whereInSpy.args[0][1].should.deep.equal [ 'ready', 'error-transient' ]
      @jobQueue.queueSubsequentSubtask.callCount.should.equal @letters.length
      expect(@jobQueue.queueSubsequentSubtask.args[0][0]).to.be.null
      @jobQueue.queueSubsequentSubtask.args[0][1].should.equal @subtasks.findLetters
      @jobQueue.queueSubsequentSubtask.args[0][2].should.equal 'lob_createLetter'
      @jobQueue.queueSubsequentSubtask.args[0][3].should.equal mockLetter

  it 'send a letter and capture LOB response', ->
    svc.executeSubtask(@subtasks.createLetter)
    .then () =>
      @lobSvc.createLetter.callCount.should.equal 1
      @lobSvc.createLetter.args[0][0].should.equal mockLetter
      @tables.mail.letters().updateSpy.callCount.should.deep.equal 1
      @tables.mail.letters().updateSpy.args[0][0].should.deep.equal
        lob_response: mockLobLetter
        status: 'sent'
        retries: mockLetter.retries + 1
      @tables.mail.letters().whereSpy.args[0][0].should.deep.equal id: mockLetter.id
