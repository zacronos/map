_ = require 'lodash'
path = require 'path'
#need *.coffee extensions for frontend files as this config is truely common
common =  require '../../common/config/commonConfig.coffee'
toBool = require '../utils/util.toBool.coffee'

scriptName = path.basename(require?.main?.filename, '.coffee')
if scriptName not in ['server','jobQueueWorker','masterWorker']
  scriptName = '__REPL'  # this makes it easier to use the result as keys in a hash


base =
  SIGNUP_ENABLED: toBool(process.env.SIGNUP_ENABLED, defaultValue: true)
  KARMA:
    LOG_LEVEL: process.env.KARMA_LOG_LEVEL ? 'info'
    BROWSERS: if process.env.KARMA_BROWSERS? then process.env.KARMA_BROWSERS.split(',') ? ['PhantomJS']
  S3_URL: 'https://s3.amazonaws.com'
  EXT_AWS_PHOTO_ACCOUNT: process.env.EXT_AWS_PHOTO_ACCOUNT || 'aws-listing-photos'
  COFFEE_SOURCE_MAP: process.env.COFFEE_SOURCE_MAP ? true
  DYNO: process.env.DYNO || 'local'
  NAMESPACE: 'rmaps'
  JQ_QUEUE_NAME: process.env.JQ_QUEUE_NAME || null
  PROC_COUNT: parseInt(process.env.WEB_CONCURRENCY) || require('os').cpus().length
  ENV: process.env.NODE_ENV || 'development'
  ROOT_PATH: path.join(__dirname, '..')
  FRONTEND_ASSETS:
    PATH: path.join(__dirname, '../../_public')
    MAX_AGE_SEC: 60 * 60 * 24 * 365
  HOST_PORT: if process.env.PORT? then parseInt(process.env.PORT) else 8085
  PORT: process.env.PORT_GOD || (if process.env.NGINX_SOCKET_FILENAME then "./nginx/#{process.env.NGINX_SOCKET_FILENAME}" else false) || parseInt(process.env.PORT) || 4000
  LOGGING:
    PATH: 'rmaps.log'
    LEVEL: process.env.LOG_LEVEL ? 'debug'
    FILE_AND_LINE: false
    ENABLE: process.env.LOG_ENABLE ? ''  # 'frontend:*,backend:*,test:*'
    TIMESTAMP: process.env.LOG_TIMESTAMP == 'true'
    LOG_TO_FILE: process.env.LOG_TO_FILE == 'true'
  DBS:
    MAIN:
      client: 'pg'
      connection: process.env.MAIN_DATABASE_URL
      pool: pingTimeout: 20*60*1000
      acquireConnectionTimeout: 90000
    RAW_TEMP:
      client: 'pg'
      connection: process.env.RAW_TEMP_DATABASE_URL
      pool: pingTimeout: 20*60*1000
      acquireConnectionTimeout: 90000
    NORMALIZED:
      client: 'pg'
      connection: process.env.NORMALIZED_DATABASE_URL
      pool: pingTimeout: 20*60*1000
      acquireConnectionTimeout: 90000
    TEST:
      client: 'pg'
      connection: process.env.TEST_DATABASE_URL
      pool: pingTimeout: 20*60*1000
      acquireConnectionTimeout: 90000
  TRUST_PROXY: 2  # indicates there are 2 trusted hops after SSL termination: Heroku -> nginx -> express (except dev)
  FORCE_HTTPS: true
  SESSION:
    secret: 'thisistheREALTYMAPSsecretforthesession'
    cookie:
      maxAge: null
      secure: true
    proxy: true
    name: 'connect.sid'
    resave: false
    saveUninitialized: true
    unset: 'destroy'
    ttl: 30*24*60*60 # 30 days
  SESSION_SECURITY:
    name: 'anticlone'
    app: 'map'
    rememberMeAge: 30*24*60*60*1000 # 30 days
    cookie:
      httpOnly: true
      signed: true
      secure: true
    proxy: true
  USE_ERROR_HANDLER: false
  MEM_WATCH:
    IS_ON: toBool(process.env.MEM_WATCH_IS_ON, defaultValue: false)
  TEMP_DIR: '/tmp'
  MAP: common.map
  IMAGES: common.images
  VALIDATION: common.validation
  NEW_RELIC:
    LOGLEVEL: 'info'
    API_KEY: process.env.NEW_RELIC_API_KEY
  HIREFIRE:
    API_KEY: process.env.HIREFIRE_TOKEN || 'dummy'
    WARN_THRESHOLD: 300000  # 5 minutes
  ENCRYPTION_AT_REST: process.env.ENCRYPTION_AT_REST
  JOB_QUEUE:
    LOCK_KEY: 0x1693F8A6  # random number
    SCHEDULING_LOCK_ID: 0
    MAINTENANCE_LOCK_ID: 1
    MAINTENANCE_WINDOW: 30000  # 30 seconds
    LOCK_DEBUG: process.env.LOCK_DEBUG
    SUBTASK_ZOMBIE_SLACK: 1.0  # 1 minute
    HEARTBEAT_MINUTES: 1.0  # 1 minute
  CLEANUP:
    RAW_TABLE_DROP_DAYS: 365
    RAW_TABLE_CLEAN_DAYS: 7
    SUBTASK_ERROR_DAYS: 30
    TASK_HISTORY_DAYS: 120
    OLD_DELETE_MARKER_DAYS: 3
    OLD_DELETE_PARCEL_DAYS: 3
    CURRENT_SUBTASKS_DAYS: 1
    REQUEST_ERROR_UNEXPECTED_DAYS: 180
    REQUEST_ERROR_EXPECTED_DAYS: 30
    REQUEST_ERROR_HANDLED_DAYS: 60
  EMAIL_VERIFY:
    HASH_MIN_LENGTH: 20
    RESTRICT_TO_OUR_DOMAIN: toBool(process.env.EMAIL_VERIFY_RESTRICT_TO_OUR_DOMAIN, defaultValue: true)
  PAYMENT_PLATFORM:
    TRIAL_PERIOD_DAYS: 30
    LIVE_MODE: toBool(process.env.PAYMENT_IS_LIVE, defaultValue: false)
    INTERVAL_COUNT: 1
    CURRENCY: 'usd'
  EMAIL_PLATFORM:
    LIVE_MODE: toBool(process.env.EMAIL_IS_LIVE, defaultValue: false)
  MAILING_PLATFORM:
    LIVE_MODE: toBool(process.env.MAILING_IS_LIVE, defaultValue: false)
    CAMPAIGN_BILLING_DELAY_DAYS: 1
    CAMPAIGN_BILLING_CAPTURE_DAYS: 6
    READ_PDF_URL_RETRIES: 6
    LOB_MAX_RETRIES: 5
    S3_UPLOAD: _.merge common.pdfUpload, common.mail.s3_upload
    GET_PRICE: common.mail.getPrice
  NOTIFICATIONS:
    USE_WEBHOOKS: toBool(process.env.NOTIFICATIONS_USE_WEBHOOKS, defaultValue: true)
    DELIVERY_THRESH_MIN: 12
    MAX_ATTEMPTS: 10
    ALLOW_PUSH: toBool(process.env.NOTIFICATIONS_ALLOW_PUSH, defaultValue: true)
  ALLOW_LIVE_APIS: toBool(process.env.ALLOW_LIVE_APIS, defaultValue: false)
  RMAPS_MAP_INSTANCE_NAME: process.env.RMAPS_MAP_INSTANCE_NAME
  SUBSCR: common.subscription

# this one's separated out so we can re-use the DBS.MAIN.connection value
base.SESSION_STORE =
  conString: base.DBS.MAIN.connection
  tableName: 'auth_session'


# use environment-specific configuration as little as possible
environmentConfig =

  development:
    HOST: APP_NAME: "dev.realtymaps.com:#{base.HOST_PORT}"
    TRUST_PROXY: 1  # indicates there is 1 trusted hop after SSL termination: nginx -> express
    DBS:
      MAIN:
        debug: false # set to true for verbose logging
      RAW_TEMP:
        debug: false # set to true for verbose logging
    LOGGING:
      FILE_AND_LINE: true
    USE_ERROR_HANDLER: true
    NEW_RELIC:
      RUN: toBool(process.env.NEW_RELIC_RUN, defaultValue: false)
      LOGLEVEL: 'info'
      APP_NAME: if process.env.RMAPS_MAP_INSTANCE_NAME then "#{process.env.RMAPS_MAP_INSTANCE_NAME}-dev-realtymaps-map" else null
    CLEANUP:
      RAW_TABLE_CLEAN_DAYS: 1
      SUBTASK_ERROR_DAYS: 7
      OLD_DELETE_MARKER_DAYS: 1

  test: # test inherits from development below
    LOGGING:
      LEVEL: 'info'
    MEM_WATCH:
      IS_ON: true

  staging:
    HOST: if process.env.RMAPS_MAP_INSTANCE_NAME then "#{process.env.RMAPS_MAP_INSTANCE_NAME}.staging.realtymaps.com" else null
    NEW_RELIC:
      RUN: toBool(process.env.NEW_RELIC_RUN, defaultValue: true)
      LOGLEVEL: 'info'
      APP_NAME: if process.env.RMAPS_MAP_INSTANCE_NAME then "#{process.env.RMAPS_MAP_INSTANCE_NAME}-staging-realtymaps-map" else null

  production:
    HOST: "realtymaps.com"
    MEM_WATCH:
      IS_ON: true
    NEW_RELIC:
      RUN: toBool(process.env.NEW_RELIC_RUN, defaultValue: true)
      APP_NAME: 'realtymaps-map'


pools =
  server:
    MAIN:
      pool:
        min: 2
        max: 10
    RAW_TEMP:
      pool:
        min: 0
        max: 10
    NORMALIZED:
      pool:
        min: 0
        max: 10
  jobQueueWorker:
    MAIN:
      pool:
        min: 2
        max: 4
    RAW_TEMP:
      pool:
        min: 2
        max: 4
    NORMALIZED:
      pool:
        min: 2
        max: 4
  queueNeedsWorker:
    MAIN:
      pool:
        min: 1
        max: 2
    RAW_TEMP:
      pool:
        min: 0
        max: 2
    NORMALIZED:
      pool:
        min: 0
        max: 2
  __REPL:
    MAIN:
      pool:
        min: 2
        max: 4
    RAW_TEMP:
      pool:
        min: 2
        max: 4
    NORMALIZED:
      pool:
        min: 2
        max: 4
    TEST:
      pool:
        min: 2
        max: 4


base.DBS = _.merge(base.DBS, pools[scriptName])
environmentConfig.test = _.merge({}, environmentConfig.development, environmentConfig.test)
config = _.merge({}, base, environmentConfig[base.ENV])
if scriptName == '__REPL'
  config.IS_REPL = true


module.exports = config

# have to set a secret backend-only route
backendRoutes = require('../../common/config/routes.backend.coffee')
backendRoutes.hirefire =
  info: "/hirefire/#{config.HIREFIRE.API_KEY}/info"
