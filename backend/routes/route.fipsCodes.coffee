auth = require '../utils/util.auth'
fipsCodes = require '../services/service.fipsCodes'
{RouteCrud} = require '../utils/crud/util.crud.route.helpers'
{mergeHandles} = require '../utils/util.route.helpers'
{validators} = require '../utils/util.validation'
logger = require '../config/logger'
_ = require 'lodash'

class FipsCodesCrud extends RouteCrud
  init:() ->
    @getAllByStateTransforms =
      params:
        state:
          required: true
          transform: [validators.string(minLength:2, maxLength:2)]

      query: validators.object isEmptyProtect: true
      body: validators.object isEmptyProtect: true

    @getAllByStateCountyTransforms = _.extend {}, @getAllByStateTransforms,
      params:
        county:
          required: true
          transform: [validators.string(minLength:2)]

    super(true, ['state', 'count', 'code'])

  getAllByState: (req, res) =>
    @validRequest req, 'getAllByState'
    .then (validReq) =>
      @handleQuery @svc.getAllByState(validReq.params.state), res

  getAllByStateCounty: (req, res) =>
    @validRequest req, 'getAllByStateCounty'
    .then (validReq) =>
      @handleQuery @svc.getAllByStateCounty(validReq.params.state), res

  getAllByStateLikeCounty: (req, res) =>
    @validRequest req, 'getAllByStateCounty'
    .then (validReq) =>
      @handleQuery @svc.getAllByStateLikeCounty(validReq.params.state), res

module.exports = mergeHandles new FipsCodesCrud(fipsCodes),
  root:
    middleware: [auth.requireLogin(redirectOnFail: true)]
  byId:
    middleware: [auth.requireLogin(redirectOnFail: true)]
  getAllByStateCounty: {}
  getAllByState: {}
  getAllByStateLikeCounty: {}