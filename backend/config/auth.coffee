querystring = require 'querystring'
Promise = require 'bluebird'
_ = require 'lodash'

logger = require '../config/logger'
config = require '../config/config'
userService = require '../services/service.user'
permissionsService = require '../services/service.permissions'


getSessionUser = (req) -> Promise.try () ->
  if not req.session.userid
    return Promise.resolve(false)
  return userService.getUser(id: req.session.userid).catch (err) -> return false

    
module.exports = {

  # this function gets used as app-wide middleware, so assume it will have run
  # before any route gets called
  setSessionCredentials: (req, res, next) ->
    getSessionUser(req)
      .then (user) ->
        # set the user on the request
        req.user = user
        if user and not req.session.permissions
          # something bad must have happened while loading permissions, try to recover
          logger.debug "trying to set permissions on session for user: #{user.username}"
          return permissionsService.getPermissionsForUserId(user.id)
            .then (permissionsHash) ->
              logger.debug "permissions loaded on session for user: #{user.username}"
              req.session.permissions = permissionsHash
      .then () ->
        next()
      .catch (err) ->
        logger.debug "error while setting session user on request"
        next(err)

  # route-specific middleware that requires a login, and either responds with
  # a 401 or a login redirect on failure
  requireLogin: (options = {}) ->
    defaultOptions =
      redirectOnFail: false
    options = _.merge(defaultOptions, options)
    return (req, res, next) -> Promise.try () ->
      if not req.user
        if options.redirectOnFail
          return res.redirect("/login?#{querystring.stringify(next: req.originalUrl)}")
        else
          return res.status(401).send("Please login to access this URI.")
      return process.nextTick(next)

}
