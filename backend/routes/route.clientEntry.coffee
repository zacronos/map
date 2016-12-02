logger = require('../config/logger').spawn('route:clientEntry')
backendRoutes = require '../../common/config/routes.backend'
clientEntrySvc = require '../services/service.clientEntry'
userSessionRte = require './route.userSession'
{createPasswordHash} =  require '../services/service.userSession'
{mergeHandles, wrapHandleRoutes} = require '../utils/util.route.helpers'

handles = wrapHandleRoutes handles:

  getClientEntry: (req) ->
    clientEntrySvc.getClientEntry req.query.key

  setPasswordAndBounce: (req, res, next) ->
    clientEntrySvc.setPasswordAndBounce req.body
    .then (client) ->
      req.body = client

      # redirect to our login page, preserving the POST method of the request with code 307
      # NOTE: our api calls are handled through structure that automatically sends data through
      #   `res.json`, so non-api web endpoints (such as login) need to be redirected to instead of directly called.
      res.redirect(307, backendRoutes.userSession.login)


module.exports = mergeHandles handles,
  getClientEntry:
    method: 'get'

  setPasswordAndBounce:
    method: 'post'
