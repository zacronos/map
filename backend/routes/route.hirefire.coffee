Promise = require 'bluebird'
logger = require('../config/logger').spawn('hirefire')
jobQueue = require '../utils/util.jobQueue'
ExpressResponse = require '../utils/util.expressResponse'
keystore = require '../services/service.keystore'
config = require '../config/config'
memdump = require '../utils/util.memdump'


HIREFIRE_RUN_TIMESTAMP = 'hirefire run timestamp'


_checkIfRun = () ->
  keystore.getValue(HIREFIRE_RUN_TIMESTAMP, defaultValue: 0)
  .then (timestamp) ->
    if Date.now() - timestamp >= config.HIREFIRE.BACKUP.RUN_WINDOW
      logger.warn "Hirefire hasn't run since #{new Date(timestamp)}, manually executing"
      _priorTimestamp = timestamp
      # the 'true' below prevents this from dieing on a missing task
      module.exports.info(true)
    return undefined

_priorTimestamp = null
if config.HIREFIRE.BACKUP.DO_BACKUP
  # stagger initial checks to avoid simultaneous checks from startup
  initial_delay = config.HIREFIRE.BACKUP.RUN_WINDOW + Math.floor(Math.random()*config.HIREFIRE.BACKUP.DELAY_VARIATION)
  _timeout = setTimeout(_checkIfRun, initial_delay)


info = (req, res, next) -> Promise.try () ->
  logger.debug('Route started...')
  if config.HIREFIRE.BACKUP.DO_BACKUP
    clearTimeout(_timeout)
    # continue to slightly stagger checks, just in case the initial stagger was unlucky
    _timeout = setTimeout(_checkIfRun, config.HIREFIRE.BACKUP.RUN_WINDOW + Math.floor(Math.random()*config.HIREFIRE.BACKUP.DELAY_VARIATION))

  now = Date.now()
  keystore.setValue(HIREFIRE_RUN_TIMESTAMP, now)
  .then (currentTimestamp=now) ->
    # if it turns out something else has started running since we determined we should run (race condition),
    # don't bother running if this isn't a real hirefire hit (let the other one handle it)
    if _priorTimestamp? && currentTimestamp != _priorTimestamp && req == null
      logger.debug('Skipping hirefire run (assuming another instance is handling it)')
      return
    logger.debug('Doing maintenance...')
    jobQueue.doMaintenance()
    .then () ->
      logger.debug('Queueing ready tasks...')
      jobQueue.queueReadyTasks(dieOnMissingTask: !req)
    .then () ->
      logger.debug('Determining queue needs...')
      jobQueue.getQueueNeeds()
    .then (needs) ->
      # TODO: remove this line once finished with troubleshooting
      if req?.query.memdump then require('../utils/util.memdump').makeDump()

      logger.debug () -> ('Queue needs: '+JSON.stringify(needs, null, 2))
      if next
        next new ExpressResponse(needs)
      else
        return needs
    .catch (err) ->
      logger.error "unexpected error during hirefire info check: #{err.stack||err}"
      if next
        next(err)
      else
        throw err


module.exports =
  info: info
