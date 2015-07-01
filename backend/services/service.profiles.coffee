Promise = require "bluebird"
bcrypt = require 'bcrypt'
_ = require 'lodash'

logger = require '../config/logger'
{userData} = require "../config/tables"
{auth_user_profile, project} = userData
{singleRow} = require '../utils/util.sql.helpers'
{currentProfile} = require '../utils/util.session.helpers'

cols =  [
  "#{auth_user_profile.tableName}.id as id", 'auth_user_id',
  'filters', 'properties_selected', 'map_toggles',
  'map_position', 'map_results','parent_auth_user_id',
  "#{auth_user_profile.tableName}.rm_modified_time as rm_modified_time",
  "#{auth_user_profile.tableName}.rm_inserted_time as rm_inserted_time",
  "#{auth_user_profile.tableName}.name as name",
  'project_id',
  "#{project.tableName}.rm_modified_time as #{project.tableName}_rm_modified_time",
  "#{project.tableName}.rm_inserted_time as #{project.tableName}_rm_inserted_time",
  "#{project.tableName}.name as #{project.tableName}_name",
]

omitsOnSave = [
  'id'
  'rm_modified_time'
  'rm_inserted_time'
]

authProfileOnly = (joinedObj) ->
  clone = _.clone joinedObj
  for key, value of clone
    if _.contains(key, project.tableName) && key != 'project_id'
      delete clone[key]
  _.omit clone, omitsOnSave

get = (id, withProject = true) ->
  return auth_user_profile().where(id: id) unless withProject

getProfiles = (auth_user_id, withProject = true) -> Promise.try () ->
  return auth_user_profile().where(auth_user_id: userId) unless withProject

  q = auth_user_profile().select(cols...).innerJoin(project.tableName,
  project.tableName + ".id", auth_user_profile.tableName + '.project_id')
  .where(auth_user_id: auth_user_id)
  # logger.debug q.toString()
  q.then (profiles) ->
    _.indexBy profiles, 'id'

getFirst = (userId) ->
  singleRow(auth_user_profile().where(auth_user_id: userId))
  .then (userState) ->
    if not userState
      userData.auth_user_profile()
      .insert
        auth_user_id: userId
      .then () ->
        return {}
    else
      result = userState
      delete result.id
      return result

updateFirst = (session, partialState) ->
  # need the id for lookup, so we don't want to allow it to be set this way
  delete partialState.id

  #avoid unnecessary saves as there is the possibility for race conditions
  needsSave = false
  profile = currentProfile(session)
  for key,part of partialState
    if !_.isEqual part, profile[key]
      needsSave = true
      break
#  logger.debug "service.user needsSave: #{needsSave}"
  if needsSave
    _.extend(profile, partialState)
    session.saveAsync()  # save immediately to prevent problems from overlapping AJAX calls

  profile.auth_user_id = session.userid

  cropped = authProfileOnly(profile)
  logger.debug cropped

  q = userData.auth_user_profile()
  .where(auth_user_id: session.userid, id: profile.id)
  .update(cropped)

  logger.debug q.toString()

  singleRow(q)
  .then (userState) ->
    if not userState
      return {}
    result = userState
    delete result.id
    return result

module.exports =
  get: get
  getProfiles: getProfiles
  updateFirst: updateFirst
  getFirst: getFirst
  authProfileOnly: authProfileOnly
