_ = require 'lodash'
path = require 'path'

#console.info "ENV: !!!!!!!!!!!!!!!!!!! %j", process.env
base =
  PROD_PORT: 80
  ENV: process.env.NODE_ENV || 'development'
  ROOT_PATH: path.join(__dirname, '..')
  FRONTEND_ASSETS_PATH: path.join(__dirname, '../../_public')
  PORT: process.env.PORT || 4000
  LOGGING:
    PATH: "mean.coffee.log"
    LEVEL: 'info'
    FILE_AND_LINE: false
    LONG_STACK_TRACES: false
    FRONT_END: false
  USER_DB:
    client: 'pg'
    connection: process.env.USER_DATABASE_URL
    pool:
      min: 2
      max: 10
  PROPERTY_DB:
    client: 'pg'
    connection: process.env.PROPERTY_DATABASE_URL
    pool:
      min: 2
      max: 10
  SESSION:
    secret: "thisisthesecretforthesession"
    cookie:
      maxAge: null
      secure: true
    unset: "destroy"
  NODETIME: false
  USE_ERROR_HANDLER: false
  TRUST_PROXY: 1
  DEFAULT_LANDING_URL: "/"
  LOGOUT_URL: "/"
  DB_CACHE_TIMES:
    SLOW_REFRESH: 60*1000   # 1 minute
    FAST_REFRESH: 30*1000   # 30 seconds
    PRE_FETCH: .1
  MEM_WATCH:
    IS_ON: false

# this one's separated out so we can re-use the USER_DB.connection value
base.SESSION_STORE =
  conString: base.USER_DB.connection


# use environment-specific configuration as little as possible
environmentConfig =

  development:
    USER_DB:
      debug: true
    PROPERTY_DB:
      debug: true
    SESSION:
      cookie:
        secure: false
    LOGGING:
      LEVEL: 'sql'
      FILE_AND_LINE: true
      LONG_STACK_TRACES: true
      FRONT_END: true
    USE_ERROR_HANDLER: true
    TRUST_PROXY: false

  test:
    USER_DB:
      debug: true
    PROPERTY_DB:
      debug: true
    SESSION:
      cookie:
        secure: false
    LOGGING:
      LEVEL: 'debug'
      FILE_AND_LINE: true
      LONG_STACK_TRACES: true
      FRONT_END: true
    USE_ERROR_HANDLER: true
    TRUST_PROXY: false
    MEM_WATCH:
      IS_ON: true

  staging:
    DB_CACHE_TIMES:
      SLOW_REFRESH: 5*60*1000   # 5 minutes
      FAST_REFRESH: 60*1000     # 1 minute

  production:
    DB_CACHE_TIMES:
      SLOW_REFRESH: 10*60*1000   # 10 minutes
      FAST_REFRESH: 60*1000      # 1 minute
    MEM_WATCH:
      IS_ON: true
    # we probably want this for production, but we need to get it set up with
    # an API key first
    #NODETIME:
    #  accountKey: "ENTER-A-VALID-KEY-HERE"
    #  appName: 'mean.coffee'

config = _.merge(base, environmentConfig[base.ENV])
# console.log "config: "+JSON.stringify(config, null, 2)

module.exports = config
