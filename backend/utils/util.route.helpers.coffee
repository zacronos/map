_ = require 'lodash'
sessionHelper = require './util.session.helpers'

class CurrentProfileError extends Error

badRequest = (msg) ->
  new ExpressResponse(alert: {msg: msg}, httpStatus.BAD_REQUEST)

methodExec = (req, methods) ->
  do(methods[req.method] or -> next(badRequest("HTTP METHOD: #{req.method} not supported for route.")))

currentProfile = (req) ->
  try
    sessionHelper.currentProfile(req.session)
  catch e
    throw new CurrentProfileError(e.message)

mergeHandles = (handles, config) ->
  for key of config
    _.extend config[key],
      handle: handles[key]
  # console.debug config
  config

module.exports =
  methodExec: methodExec
  currentProfile: currentProfile
  CurrentProfileError: CurrentProfileError
  badRequest: badRequest
  mergeHandles: mergeHandles
