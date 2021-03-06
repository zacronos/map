Promise = require 'bluebird'
logger = require('../config/logger').spawn('session:userSession:route')
httpStatus = require '../../common/utils/httpStatus'
sessionSecurityService = require '../services/service.sessionSecurity'
userSessionService = require '../services/service.userSession'
profileService = require '../services/service.profiles'
userSvc = require('../services/services.user').user
projectSvc = require('../services/services.user').project
userUtils = require '../utils/util.user'
ExpressResponse = require '../utils/util.expressResponse'
{methodExec} = require '../utils/util.route.helpers'
_ = require 'lodash'
auth = require '../utils/util.auth.coffee'
moment = require 'moment'
validation = require '../utils/util.validation'
safeColumns = (require '../utils/util.sql.helpers').columns
tables = require '../config/tables'
transforms = require '../utils/transforms/transforms.userSession'
internals = require './route.userSession.internals'
userInternals = require './route.user.internals'
errorHandlingUtils = require '../utils/errors/util.error.partiallyHandledError'
backendRoutes = require '../../common/config/routes.backend.coffee'
{PartiallyHandledError} = require '../utils/errors/util.error.partiallyHandledError'
DataValidationError = require '../utils/errors/util.error.dataValidation'
userSessionErrors = require '../utils/errors/util.errors.userSession'
userFeedbackSvc = require('../services/service.userFeedback').instance


# handle login authentication, and do all the things needed for a new login session
login = (req, res, next) -> Promise.try () ->
  l = logger.spawn("login")
  if req.user
    # someone is logging in over an existing session...  shouldn't normally happen, but we'll deal
    l.debug () -> "attempting to log user out (someone is logging in): #{req.user.email} (#{req.sessionID})"
    promise = sessionSecurityService.deleteSecurities(session_id: req.sessionID)
    .then () ->
      req.user = null
      req.session.regenerateAsync()
  else
    promise = Promise.resolve()

  promise.then () ->
    if req.body.password
      userSessionService.verifyPassword(req.body.email, req.body.password)
    else if req.body.loginToken
      userSessionService.verifyLoginToken({
        email: req.body.email
        loginToken: req.body.loginToken
      })
    else
      return false
  .then (user) -> Promise.try ->
    if !user || !user.is_active
      throw new userSessionErrors.LoginError('Email and/or password does not match our records.')
    req.session.userid = user.id
    l.debug -> _.omit(user, 'password')
    sessionSecurityService.sessionLoginProcess(req, res, user, rememberMe: req.body.remember_me)
  .then () ->
    internals.getIdentity(req, res, next)
  .catch (err) ->
    err.returnStatus = httpStatus.UNAUTHORIZED
    throw err

logout = (req, res, next) -> Promise.try () ->
  auth.logout(req).finally ->
    res.json identity: null

setCurrentProfile = (req, res, next) -> Promise.try () ->
  if !req.body.currentProfileId
    throw new DataValidationError('currentProfileId undefined')

  req.session.current_profile_id = req.body.currentProfileId
  logger.debug () -> "set req.session.current_profile_id: #{req.session.current_profile_id}"

  rm_modified_time = moment()

  userUtils.cacheUserValues(req)
  .then () ->
    # Update the timestamp on a profile whenever it is selected
    profileService.updateCurrent(req.session, {rm_modified_time})
  .then () ->
    identity = userUtils.getIdentityFromRequest(req)
    identity.profiles[req.session.current_profile_id].rm_modified_time = rm_modified_time
    res.json {identity}

updateState = (req, res, next) ->
  profileService.updateCurrent(req.session, req.body)
  .then () ->
    res.send()
  .catch (err) ->
    logger.error "error updating user state via API: #{err}"
    next(err)

profiles = (req, res, next) ->
  methodExec req,
    GET: () ->
      # if user is subscriber, use service endpoint that includes sandbox creation and display
      if userUtils.isSubscriber(req)
        promise = profileService.getProfiles({auth_user_id: req.user.id})

      # user is a client, and unallowed to deal with sandboxes
      else
        promise = profileService.getClientProfiles(req.user.id)

      promise.then (result) ->
        res.json result

    PUT: () ->
      validation.validateAndTransformRequest(req.body, transforms.profiles.PUT)
      .then (validBody) ->
        profileService.update(validBody, req.user.id)
        .then () ->
          delete req.session.profiles  # to force profiles refresh in cache
          internals.updateCache(req, res, next)


newProject = (req, res, next) ->
  validation.validateAndTransformRequest(req.body, transforms.newProject)
  .then (validBody) ->
    profile = profileService.getCurrentSessionProfile req.session
    toSave = _.extend({auth_user_id: req.user.id, can_edit: true}, validBody)


    # COPY
    if validBody.copyCurrent is true
      # If copying while on sandbox, we simply un-sandbox the profile.
      if profile.sandbox is true
        toSave.sandbox = false
        toSave.id = profile.project_id
        return projectSvc.update _.pick(toSave, safeColumns.project)
        .then () ->
          # sandbox was transformed to named project, recreate sandbox
          profileService.createSandbox(req.user.id)
        .then () ->
          profile # leave the current profile selected

      # If copying while not on sandbox, set toSave fields for new project & profile
      else
        _.extend toSave, _.pick(profile, ['filters', 'map_toggles', 'map_position', 'map_results'])


    # SAVE AS / CREATE
    else
      # we need a position to start with on the frontend, so copy the other profile's position
      _.extend toSave, _.pick(profile, ['map_position'])
      toSave = _.omit toSave, ['filters']

    profileService.create toSave

  .then (newProfile) ->
    req.session.current_profile_id = newProfile.id
    logger.debug "set req.session.current_profile_id: #{req.session.current_profile_id}"
    delete req.session.profiles # to force profiles refresh in cache
    internals.updateCache(req, res, next)


image = (req, res, next) ->
  methodExec req,
    GET: () -> userInternals.getImage {req, res, next, entity: req.user}
    PUT: () ->
      userInternals.updateImage {req, next, entity: req.user}
      .then ()->
        internals.updateCache(req, res, next)

companyImage = (req, res, next) ->
  methodExec req,
    GET: () ->
      userInternals.getCompanyImage(req, res, next)

    PUT: () -> Promise.try ->
      userInternals.updateCompanyImage {
        req
        next
        entity: _.omit(req.body, 'blob')
      }
      .then ()->
        internals.updateCache(req, res, next)
    .catch errorHandlingUtils.isUnhandled, (error) ->
      throw new errorHandlingUtils.PartiallyHandledError(error, 'failed to PUT company image')



root = (req, res, next) ->
  methodExec req,
    PUT: () ->
      # WE EXPLICITY NEED NULLS to remove values, not using validateAndTransformRequest
      validation.validateAndTransform(req.body, transforms.root.PUT(req.user.id))
      .then (validBody) ->
        validBody.id =  req.user.id
        userSvc.update(validBody)
      .then () ->
        internals.updateCache(req, res, next)


#only way to add a company for a logged in user (otherwise use admin route /company)
companyRoot = (req, res, next) ->
  methodExec req,
    POST: () ->
      validation.validateAndTransformRequest(req.body, transforms.companyRoot.POST())
      .then (validBody) ->
        tables.user.company.transaction (transaction) ->

          q = if !req.user.company_id? and !validBody.id?
            tables.user.company({transaction}).insert(validBody).returning('id')
            .then ([id]) ->
              id
          else
            id = req.user.company_id || validBody.id
            tables.user.company({transaction})
            .update _.pick validBody, internals.safeRootCompanyFields
            .where {id}
            .then ->
              id

          q.then (company_id) ->
            if !company_id?
              throw new Error('Error creating new company')

            tables.auth.user({transaction})
            .where id: req.user.id
            .update {company_id}
            .then () ->
              internals.updateCache(req, res, next)

updatePassword = (req, res, next) ->
  validation.validateAndTransformRequest(req.body, transforms.updatePassword)
  .then (validBody) ->
    userSessionService.updatePassword(req.user, validBody.password)
    .then ->
      res.json(true)
    .catch (err) ->
      throw new PartiallyHandledError(err)

requestResetPassword = (req, res, next) ->
  validation.validateAndTransformRequest(req.body, transforms.requestResetPassword)
  .then (validBody) ->
    userSessionService.requestResetPassword(validBody.email, req.headers.host)
    .then (r) ->
      res.json(true)
    .catch (err) ->
      next new ExpressResponse({message: "Could not send password reset, is email valid?"},
        {status: httpStatus.BAD_REQUEST, quiet: true})

getResetPassword = (req, res, next) ->
  userSessionService.getResetPassword req.query?.key
  .then (result) ->
    res.json(result)
  .catch (err) ->
    next new ExpressResponse({message: "Password reset may have expired."},
     {status: httpStatus.BAD_REQUEST, quiet: true})

doResetPassword = (req, res, next) ->
  validation.validateAndTransformRequest(req.body, transforms.doResetPassword)
  .then (validBody) ->
    userSessionService.doResetPassword validBody
    .then () ->
      # redirect to our login page, preserving the POST method of the request with code 307
      # NOTE: our api calls are handled through structure that automatically sends data through
      #   `res.json`, so non-api web endpoints (such as login) need to be redirected to instead of directly called.
      res.redirect(307, backendRoutes.userSession.login)
    .catch (err) ->
      next new ExpressResponse({message: "Error resetting password."},
        {status: httpStatus.BAD_REQUEST, quiet: true})

requestLoginToken = (req, res, next) ->
  validation.validateAndTransformRequest(req.body, transforms.requestLoginToken)
  .then (validBody) ->
    userSessionService.requestLoginToken({
      superuser: req.user
      email: validBody.email
    })
    .then (result) ->
      res.json(result)
    .catch (err) ->
      next new ExpressResponse({message: "Could not get login token, is email valid?"},
        {status: httpStatus.BAD_REQUEST, quiet: true})

feedback = (req, res, next) ->
  l = logger.spawn('feedback')
  methodExec req,
    GET: () ->
      l.debug -> "req.user"
      l.debug -> req.user
      userFeedbackSvc.getAll({auth_user_id: req.user.id})
    POST: () ->
      l.debug -> "req"
      l.debug -> _.pick(req, ['body', 'params','query'])
      validation.validateAndTransformRequest(req, transforms.feedback.POST)
      .then (validReq) ->
        l.debug -> "validReq"
        l.debug -> validReq
        validReq.body.auth_user_id = req.user.id
        validReq.body.auth_user_email = req.user.email
        if !validReq.body.id?
          validReq.body.id = null
        userFeedbackSvc.upsert(validReq.body)
        .then (result) ->
          res.json(result)

module.exports =
  root:
    method: 'put'
    handle: root
    middleware:
      auth.requireLogin()

  companyRoot:
    method: 'post'
    handle: companyRoot
    middleware:
      auth.requireLogin()

  login:
    method: 'post'
    handle: login
    middleware: auth.sessionSetup

  logout:
    method: 'get'
    handle: logout
    middleware: auth.sessionSetup

  identity:
    method: 'get'
    handle: internals.getIdentity
    middleware: auth.sessionSetup

  updateState:
    method: 'post'
    middleware: auth.requireLogin()
    handle: updateState

  profiles:
    methods: ['get', 'put']
    middleware: auth.requireLogin()
    handle: profiles

  currentProfile:
    method: 'post'
    middleware: auth.requireLogin()
    handle: setCurrentProfile

  newProject:
    method: 'post'
    middleware: auth.requireLogin()
    handle: newProject

  image:
    methods: ['get', 'put']
    middleware: auth.requireLogin()
    handle: image

  companyImage:
    methods: ['get', 'put']
    middleware: auth.requireLogin()
    handle: companyImage

  updatePassword:
    method: 'put'
    middleware: auth.requireLogin()
    handle: updatePassword

  requestResetPassword:
    method: 'post'
    handle: requestResetPassword

  getResetPassword:
    method: 'get'
    handle: getResetPassword

  doResetPassword:
    method: 'post'
    handle: doResetPassword

  requestLoginToken:
    method: 'post'
    middleware: [
     auth.requireLogin()
     auth.requirePermissions('spoof_user')
    ]
    handle: requestLoginToken

  feedback:
    methods: ['get', 'post']
    handle: feedback
    middleware:
      auth.requireLogin()
