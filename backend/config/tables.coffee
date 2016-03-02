logger = require '../config/logger'
dbs = require '../config/dbs'
clone = require 'clone'
knex = require 'knex'
config = require '../config/config'


# setting on module.exports before processing to help with IDE autocomplete
module.exports =
  config:
    dataNormalization: 'config_data_normalization'
    mls: 'config_mls'
    keystore: 'config_keystore'
    externalAccounts: 'config_external_accounts'
    notification: 'config_notification'
    dataSourceFields: 'config_data_source_fields'
    dataSourceLookups: 'config_data_source_lookups'
  lookup:
    usStates: 'lookup_us_states'
    accountUseTypes: 'lookup_account_use_types'
    fipsCodes: 'lookup_fips_codes'
    mls: 'lookup_mls'
    mls_m2m_fips_code_county: 'lookup_mls_m2m_fips_code_county'
  property:
    listing: 'normalized.listing'
    tax: 'normalized.tax'
    deed: 'normalized.deed'
    mortgage: 'normalized.mortgage'
    combined: 'data_combined'
    deletes: 'data_combined_deletes'
    # the following are deprecated, so I'm not bothering to standardize their names
    rootParcel: 'parcels'
    parcel: 'mv_parcels'
    propertyDetails: 'mv_property_details'
  jobQueue:
    dataLoadHistory: 'jq_data_load_history'
    taskConfig: 'jq_task_config'
    subtaskConfig: 'jq_subtask_config'
    queueConfig: 'jq_queue_config'
    taskHistory: 'jq_task_history'
    subtaskErrorHistory: 'jq_subtask_error_history'
    currentSubtasks: 'jq_current_subtasks'
    summary: 'jq_summary'
  auth:
    session: config.SESSION_STORE.tableName  #auth_session
    sessionSecurity: 'auth_session_security'
    user: 'auth_user'
    group: 'auth_group'
    permission: 'auth_permission'
    # the following use _ separators, but are theoretically still camelCased, e.g. auth_m2m_lasers_sharkHeads
    m2m_user_permission: 'auth_m2m_user_permissions'
    m2m_user_group: 'auth_m2m_user_groups'
    m2m_group_permission: 'auth_m2m_group_permissions'
    m2m_user_locations: 'auth_m2m_user_locations'
    m2m_user_mls: 'auth_m2m_user_mls'
  user:
    profile: 'user_profile'
    project: 'user_project'
    company: 'user_company'
    accountImages: 'user_account_images'
    notes: 'user_notes'
    drawnShapes: 'user_drawn_shapes'
    creditCards: 'user_credit_cards'
    shellHistory: 'user_shell_history'
    errors: 'user_errors'
  mail:
    campaign: 'user_mail_campaigns'
    letters: 'user_mail_letters'
    pdfUpload: 'user_pdf_uploads'
  temp: 'raw_temp.raw'





_setup = (baseObject) ->
  for key, value of baseObject
    if typeof(value) == 'object'
      _setup(value)
      continue
    parts = value.split('.')
    if parts.length > 1
      dbName = parts[0]
      tableName = parts[1]
    else
      dbName = 'main'
      tableName = value
    baseObject[key] = do (dbName, tableName) ->
      buildTableName = (subid) -> "#{tableName}_#{subid}"
      query = (opts={}) ->
        db = dbs.get(dbName)
        client = opts.transaction ? db
        if opts.subid
          fullTableName = buildTableName(opts.subid)
        else
          fullTableName = tableName
        if opts.as
          ret = client.from(db.raw("#{fullTableName} AS #{opts.as}"))
        else
          ret = client.from(fullTableName)
        ret.raw = db.raw.bind(db)
        ret
      query.tableName = tableName
      query.buildTableName = buildTableName
      query

_setup(module.exports)
