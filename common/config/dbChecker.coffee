# TODO: I'm pretty sure this code can't work in the browser, so why is it in common and written as if it might
# TODO: need to run in the browser?


config = require '../../backend/config/config'
unless  window?
  logger = require '../../backend/config/logger'
else
  logger = console

module.exports = ->
if (not config.DBS.MAIN.connection) and
    !process.env.IS_HEROKU
  logger.error 'Did you use FOREMAN?'
  logger.error 'Database connection strings required! fatal and exiting!'
  require('../../backend/config/dbs').shutdown()
  process.exit 1

