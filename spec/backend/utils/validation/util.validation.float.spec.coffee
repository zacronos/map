Promise = require 'bluebird'
basePath = require '../../basePath'

requestUtil = require "#{basePath}/utils/util.http.request"
validators = requestUtil.query.validators
ParamValidationError = requestUtil.query.ParamValidationError

promiseUtils = require('../../../specUtils/promiseUtils')
expectResolve = promiseUtils.expectResolve
expectReject = promiseUtils.expectReject
promiseIt = promiseUtils.promiseIt

describe 'utils/http.request.validators.float()'.ourNs().ourNs('Backend'), ->
  param = 'fake'

  promiseIt 'should resolve strings that represent integers or decimals', () ->
    [
      expectResolve(validators.float()(param, '123')).then (value) ->
        value.should.equal(123)
      expectResolve(validators.float()(param, '-123')).then (value) ->
        value.should.equal(-123)
      expectResolve(validators.float()(param, '1.7E3')).then (value) ->
        value.should.equal(1700)
      expectResolve(validators.float()(param, '123.456')).then (value) ->
        value.should.equal(123.456)
      expectResolve(validators.float()(param, '1.777E2')).then (value) ->
        value.should.equal(177.7)
    ]

  promiseIt 'should resolve actual integers or decimals', () ->
    [
      expectResolve(validators.float()(param, 234)).then (value) ->
        value.should.equal(234)
      expectResolve(validators.float()(param, 234.56)).then (value) ->
        value.should.equal(234.56)
      expectResolve(validators.float()(param, 1.789e2)).then (value) ->
        value.should.equal(178.9)
    ]

  promiseIt 'should reject strings that do not represent numbers', () ->
    [
      expectReject(validators.float()(param, ''), ParamValidationError)
      expectReject(validators.float()(param, '12.3abc'), ParamValidationError)
    ]

  promiseIt 'should obey the min and max', () ->
    [
      expectReject(validators.float(min: 4.2)(param, '4.1'), ParamValidationError)
      expectReject(validators.float(max: 6)(param, '6.1'), ParamValidationError)
      expectResolve(validators.float(min: 4.1, max: 4.6)(param, '4.3'))
      expectResolve(validators.float(min: 4.1, max: 4.6)(param, '4.1'))
      expectResolve(validators.float(min: 4.1, max: 4.6)(param, '4.6'))
    ]