require('chai').should()
sinon = require 'sinon'
rewire = require 'rewire'
Promise = require 'bluebird'
basePath = require '../basePath'
SqlMock = require '../../specUtils/sqlMock'

onboardingRoute = rewire "#{basePath}/routes/route.onboarding"

subject = null
# onboardingRoute.__set__ 'mergeHandles', ->

describe "route.onboarding", ->

  beforeEach ->
    @res =
      json: sinon.stub()
    @next = sinon.stub()

    onboardingRoute.__set__ 'transaction'
    @createPasswordHashStub = sinon.stub().returns(Promise.resolve('password'))
    @validateAndTransformRequestStub = sinon.stub()

    sqlMocks =
      user: new SqlMock 'auth', 'user'
      m2m_user_group: new SqlMock 'auth', 'm2m_user_group'
      m2m_user_locations: new SqlMock 'auth', 'm2m_user_locations'
      m2m_user_mls: new SqlMock 'auth', 'm2m_user_mls'


    @tablesStubs =
      auth:
        user: sqlMocks.user.dbFn()
        m2m_user_group: sqlMocks.m2m_user_group.dbFn()
        m2m_user_locations: sqlMocks.m2m_user_locations.dbFn()
        m2m_user_mls: sqlMocks.m2m_user_mls.dbFn()

    sqlMocks.user.setResults [
      {id:1, first_name: "first", last_name: "last"}
      [id:1, first_name: "second", last_name: "2Last"]
    ]
    sqlMocks.m2m_user_group.setResult([])
    sqlMocks.m2m_user_locations.setResult([])
    sqlMocks.m2m_user_mls.setResult([])

    @transactionThenStub = sinon.stub()
    @transactionCatchStub = sinon.stub()

    @transaction = (dbName, trxQueryCb) =>
      Promise.try () ->
        # console.log.cyan "trxQueryCb!!!!!!!!!!!!!!!!!!"
        trxQueryCb({})
      .then () =>
        # console.log.magenta "THEN!!!!!!!!!!!!!!!!!!"
        @transactionThenStub()
      .catch (error) =>
        # console.log.yellow error
        # console.log.magenta "CATCH!!!!!!!!!!!!!!!!!!"
        @transactionCatchStub()
    onboardingRoute.__set__ 'wrapHandleRoutes', (handles) ->
      handles
    onboardingRoute.__set__ 'emailServices', {}
    onboardingRoute.__set__ 'paymentServices', {}
    onboardingRoute.__set__ 'transaction', @transaction
    onboardingRoute.__set__ 'createPasswordHash', @createPasswordHashStub
    onboardingRoute.__set__ 'tables', @tablesStubs
    onboardingRoute.__set__ 'getPlanId', () ->
      Promise.resolve(1)

    onboardingRoute.__set__ 'validateAndTransformRequest', (req) => Promise.try =>
      @validateAndTransformRequestStub()
      req

    subject = onboardingRoute.__get__ 'handles'

  describe 'createUser', ->
    beforeEach ->
      @mockReq =
        params: {}
        query:{}
        body:
          first_name: "first"
          last_name: "last"
          plan:
            name: 'pro'
          token: 'token'
          fips_code: 'fips_code'
          mls_code: 'mls_code'

    describe "submitPaymentPlan", ->

      it 'on reject error transaction catches', ->
        onboardingRoute.__set__ 'submitPaymentPlan', () ->
          Promise.reject('PLANNED')

        subject.createUser(@mockReq, @res, @next)
        .then =>
          @transactionCatchStub.called.should.be.true

      it 'on resolve transaction resolves', ->
        onboardingRoute.__set__ 'submitPaymentPlan', () ->
          Promise.resolve(authUser:{}, customer:{})

        onboardingRoute.__set__ 'submitEmail', () ->
          Promise.resolve()

        subject.createUser(@mockReq, @res, @next)
        .then =>
          @transactionThenStub.called.should.be.true

    describe "submitEmail", ->

      it 'on reject error transaction catches', ->

        onboardingRoute.__set__ 'submitPaymentPlan', () ->
          Promise.resolve(authUser:{}, customer:{})

        onboardingRoute.__set__ 'submitEmail', () ->
          Promise.reject()


        subject.createUser(@mockReq, @res, @next)
        .then =>
          @transactionCatchStub.called.should.be.true

      it 'on resolve transaction resolves', ->
        onboardingRoute.__set__ 'submitPaymentPlan', () ->
          Promise.resolve(authUser:{}, customer:{})

        onboardingRoute.__set__ 'submitEmail', () ->
          Promise.resolve()

        subject.createUser(@mockReq, @res, @next)
        .then =>
          @transactionThenStub.called.should.be.true
