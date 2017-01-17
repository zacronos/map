Promise = require 'bluebird'
_ = require 'lodash'
logger = require('../config/logger').spawn('util:user')
config = require '../config/config'
subscriptionSvc = require '../services/service.user_subscription'
profileSvc = require '../services/service.profiles'
permissionsService = require '../services/service.permissions'
# errors = require './errors/util.error.profile'


safeUserFields = [
  'cell_phone'
  'email'
  'first_name'
  'id'
  'last_name'
  'work_phone'
  'account_image_id'
  'address_1'
  'address_2'
  'us_state_id'
  'zip'
  'city'
  'website_url'
  'account_use_type_id'
  'company_id'
  'parent_id'
  'stripe_plan_id'
  'mlses_verified'
  'fips_codes'
]

# tests subscription status of the (if active) req.session
# This is leveraged in middleware, but can be used in route code for business logic needs
isSubscriber = (req) ->
  l = logger.spawn("isSubscriber")
  l.debug -> "req.session.subscriptionStatus: #{req?.session?.subscriptionStatus}"
  l.debug -> "req.user.stripe_plan_id: #{req.user?.stripe_plan_id}"

  isActive = req?.session?.subscriptionStatus in config.SUBSCR.STATUS.ACTIVE_LIST
  isPaid = req.user?.stripe_plan_id in config.SUBSCR.PLAN.PAID_LIST

  l.debug -> "isActive: #{isActive}, isPaid: #{isPaid}"

  return isActive && isPaid


# caches permission and group membership values on the user session; we could
# get into unexpected states if those values change during a session, so we
# cache them instead of refreshing.  This means for certain kinds of changes
# to a user account, we will either need to explicitly refresh these values,
# or we'll need to log out the user and let them get refreshed when they log
# back in.
cacheUserValues = (req, reload = {}) ->
  # ensure permissions
  if !req.session.permissions or reload?.permissions
    logger.debug 'req.session.permissions'
    permissionsPromise = permissionsService.getPermissionsForUserId(req.user.id)
    .then (permissionsHash) ->
      logger.debug 'req.session.permissions.then'
      req.session.permissions = permissionsHash

  # ensure groups
  if !req.session.groups or reload?.groups
    logger.debug 'req.session.groups'
    groupsPromise = permissionsService.getGroupsForUserId(req.user.id)
    .then (groupsHash) ->
      logger.debug 'req.session.groups.then'
      req.session.groups = groupsHash

  # ensure subscription
  if !req.session.subscriptionStatus or reload?.subscriptionStatus
    # subscription service discovers if user was manually given a plan permission (bypassed stripe), hence the assignment for `stripe_plan_id` below
    logger.debug -> "PRIOR user.stripe_plan_id: #{req.user.stripe_plan_id}"
    subscriptionPromise = subscriptionSvc.getStatus(req.user)
    .then ({subscriptionPlan, subscriptionStatus}) ->
      logger.debug -> "User #{req.user.id} subscription plan is #{subscriptionPlan}"
      logger.debug -> "User #{req.user.id} subscription status is #{subscriptionStatus}"
      req.user.stripe_plan_id = subscriptionPlan
      req.session.subscriptionStatus = subscriptionStatus
  else
    subscriptionPromise = Promise.resolve()

  # ensure profiles (which depends on subscription, hence adding to the subscription promise chain)
  if !req.session.profiles or reload?.profiles
    subscriptionPromise = subscriptionPromise
    .then () ->

      # if user is subscriber, use service endpoint that includes sandbox creation and display
      if isSubscriber(req)
        logger.debug -> 'user is subscriber'
        profilesPromise = profileSvc.getProfiles(req.user.id)
      # user is a client, and unallowed to deal with sandboxes
      else
        logger.debug -> 'user should have client profiles'
        profilesPromise = profileSvc.getClientProfiles(req.user.id)
        .then (profiles) ->
          if !Object.keys(profiles).length
            logger.warn("No Profile Found!")
            #TODO: throw new errors.NoProfileFoundError()
            # if this blows up we need ot make sure the existing session is logged out
          profiles

      profilesPromise = profilesPromise
      .then (profiles) ->
        logger.debug 'profileSvc.getProfiles.then'
        req.session.profiles = profiles


  Promise.all([permissionsPromise, groupsPromise, subscriptionPromise])
  .catch (err) ->
    logger.error "error caching user values for user: #{req.user.email}"
    Promise.reject(err)

getIdentityFromRequest = (req) ->
  if req.user
    # here we should probaby return some things from the user's profile as well, such as name
    user: _.pick req.user, safeUserFields
    subscriptionStatus: req.session.subscriptionStatus
    permissions: req.session.permissions
    groups: req.session.groups
    environment: config.ENV
    profiles: req.session.profiles
    currentProfileId: req.session.current_profile_id
  else
    null


module.exports = {
  cacheUserValues
  isSubscriber
  getIdentityFromRequest
  safeUserFields
}
