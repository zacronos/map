Promise = require "bluebird"
logger = require('../config/logger').spawn('map:filterSummary:combined')
validation = require "../utils/util.validation"
sqlHelpers = require "./../utils/util.sql.helpers"
filterStatuses = require "../enums/filterStatuses"
filterPropertyType = require "../enums/filterPropertyType"
_ = require "lodash"
tables = require "../config/tables"
cluster = require '../utils/util.sql.manual.cluster.combined'


dbFn = tables.finalized.combined

validators = validation.validators

statuses = filterStatuses.keys

propertyTypes = filterPropertyType.keys

minMaxFilterValidations =
  price: [validators.string(replace: [/[$,]/g, ""]), validators.integer()]
  listedDays: validators.integer()
  beds: validators.integer()
  baths: validators.float()
  acres: validators.float()
  sqft: [ validators.string(replace: [/,/g, ""]), validators.integer() ]
  closeDate: validators.datetime()

transforms = do ->
  makeMinMaxes = (result, validators, name) ->
    result["#{name}Min"] = validators
    result["#{name}Max"] = validators

  minMaxFilterValidations = _.transform(minMaxFilterValidations, makeMinMaxes)
  state: validators.object
    subValidateSeparate:
      filters: [
        validators.object
          subValidateSeparate: _.extend minMaxFilterValidations,
            ownerName: [validators.string(trim: true), validators.defaults(defaultValue: "")]
            hasOwner: validators.boolean()
            status: [
              validators.array
                subValidateEach: [
                  validators.string(forceLowerCase: true)
                  validators.choice(choices: statuses)
                ]
              validators.defaults(defaultValue: [])
            ]
            address: [
              validators.object()
              validators.defaults(defaultValue: {})
            ]
            propertyType: [
              validators.string()
              validators.choice(choices: propertyTypes)
            ]
            hasImages: validators.boolean(truthy: true, falsy: false)
            soldRange: validators.string()
          validators.defaults(defaultValue: {})
      ]
  bounds:
    transform: [
      validators.string(minLength: 1)
      validators.geohash
      validators.array(minLength: 2)
    ]
    required: true
  returnType: validators.string()

getDefaultQuery = ->
  sqlHelpers.select(dbFn(), "filter", true)
  .where(active: true)

getResultCount = ({queryParams, permissions}) ->
  # obtain a count(*)-style select query
  query = sqlHelpers.selectCountDistinct(dbFn())
  # apply the queryParams (mostly "where" clause stuff)
  query = getFilterSummaryAsQuery({queryParams, query, permissions})

getPermissions = (profile) -> Promise.try ->
  tables.auth.user()
  .select(['id', 'is_superuser', 'fips_codes', 'mlses_verified'])
  .where(id: profile.auth_user_id)
  .then ([user]) ->
    if !user
      return {}

    # Skip permissions for superusers
    if user.is_superuser
      return superuser: true
    else
      permissions =
        fips: []
        mls: []

      # Limit to FIPS codes and verified MLS for this user
      permissions.fips.push(user.fips_codes...)
      permissions.mls.push(user.mlses_verified...)

      # Include by proxy MLS available to project owner
      if profile.parent_auth_user_id? && profile.parent_auth_user_id != user.id
        return tables.auth.user()
          .select('mlses_verified')
          .where('id', profile.parent_auth_user_id).then ([owner]) ->
            permissions.mls_proxy = owner.mlses_verified # NOTE: spelling/capitalization mismatches may exist
            permissions
      logger.debug "@@@@ permissions @@@@"
      logger.debug permissions
      return permissions

queryPermissions = (query, permissions = {}) ->
  mls = _.union(permissions.mls, permissions.mls_proxy)
  query.where ->
    if permissions.fips?.length && mls?.length
      @where ->
        @where("data_source_type", "county")
        sqlHelpers.whereIn(@, "fips_code", permissions.fips)
      @orWhere ->
        @where("data_source_type", "mls")
        sqlHelpers.whereIn(@, "data_source_id", mls)
    else if mls?.length
      @where("data_source_type", "mls")
      sqlHelpers.whereIn(@, "data_source_id", mls)
    else if permissions.fips?.length
      @where("data_source_type", "county")
      sqlHelpers.whereIn(@, "fips_code", permissions.fips)
    else if !permissions.superuser
      @whereRaw("FALSE")

scrubPermissions = (data, permissions) ->
  if !permissions.superuser
    for row in data
      if (row.data_source_type == 'county' && permissions.fips.indexOf(row.fips_code) == -1) ||
           (row.data_source_type == 'mls' && permissions.mls.indexOf(row.data_source_id) == -1)
        delete row.subscriber_groups
        delete row.owner_name
        delete row.owner_name_2
        delete row.owner_address

getFilterSummaryAsQuery = ({queryParams, limit, query, permissions}) ->
  query ?= getDefaultQuery()
  {bounds, state} = queryParams
  {filters} = state || {}

  # Add permissions
  queryPermissions(query, permissions)

  query.limit(limit) if limit

  # Remainder of query is grouped so we get SELECT .. WHERE (permissions) AND (filters)
  query.where ->
    if filters?.status?.length

      if bounds?
        sqlHelpers.whereInBounds(@, "#{dbFn.tableName}.geometry_raw", bounds)

      # handle property status filtering
      # 3 possible status options (see parcelEnums.coffee): 'for sale', 'pending', 'sold'
      # only need to do any filtering if not all available statuses are selected or all statuses
      #   are selected and sold date range is provided
      if filters.status.length < statuses.length || filters.soldRange
        @where () ->
          sold = false
          hardStatuses = []
          for status in filters.status
            if status == 'sold'
              sold = true
            else
              hardStatuses.push(status)

          if sold
            @orWhere () ->
              @where("#{dbFn.tableName}.status", 'sold')
              if filters.soldRange
                @whereRaw("#{dbFn.tableName}.close_date >= (now()::DATE - '#{filters.soldRange}'::INTERVAL)")

          if hardStatuses.length > 0
            sqlHelpers.orWhereIn(@, "#{dbFn.tableName}.status", hardStatuses)

      sqlHelpers.between(@, "#{dbFn.tableName}.price", filters.priceMin, filters.priceMax)
      sqlHelpers.between(@, "#{dbFn.tableName}.sqft_finished", filters.sqftMin, filters.sqftMax)
      sqlHelpers.between(@, "#{dbFn.tableName}.acres", filters.acresMin, filters.acresMax)

      if filters.bedsMin
        @where("#{dbFn.tableName}.bedrooms", ">=", filters.bedsMin)

      if filters.bathsMin
        @where("#{dbFn.tableName}.baths_total", ">=", filters.bathsMin)

      if filters.ownerName
        # need to avoid any characters that have special meanings in regexes
        # then split on whitespace and commas to get chunks to search for
        patterns = _.transform filters.ownerName.replace(/[\\|().[\]*+?{}^$]/g, " ").split(/[,\s]/), (result, chunk) ->
          if !chunk
            return
          # make dashes and apostrophes optional, can be missing or replaced with a space in the name text
          # since this is after the split, a space here will be an actual part of the search
          result.push chunk.replace(/(['-])/g, "[$1 ]?")
        sqlHelpers.allPatternsInAnyColumn(@, patterns, ["#{dbFn.tableName}.owner_name", "#{dbFn.tableName}.owner_name_2"])

      if filters.listedDaysMin
        @where("days_on_market", ">=", filters.listedDaysMin)
      if filters.listedDaysMax
        @where("days_on_market", "<=", filters.listedDaysMax)

      if filters.propertyType
        @where("#{dbFn.tableName}.property_type", filters.propertyType)

      sqlHelpers.between(@, "#{dbFn.tableName}.close_date", filters.closeDateMin, filters.closeDateMax)

      if filters.hasImages
        @where("photos", "!=", "{}")

      if queryParams.pins?.length
        sqlHelpers.orWhereIn(query, 'rm_property_id', queryParams.pins)

    else if filters.status?
      sqlHelpers.whereIn(query, 'rm_property_id', queryParams.pins || [])

  query

module.exports = {
  transforms
  getDefaultQuery
  getFilterSummaryAsQuery
  getResultCount
  cluster
  getPermissions
  queryPermissions
  scrubPermissions
}
