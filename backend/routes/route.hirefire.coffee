Promise = require 'bluebird'
logger = require '../config/logger'
jobQueue = require '../utils/util.jobQueue'
ExpressResponse = require '../utils/util.expressResponse'

info = (req, res, next) -> Promise.try () ->
  jobQueue.doMaintenance()
  .then () ->
    jobQueue.updateTaskCounts()
  .then () ->
    jobQueue.withSchedulingLock jobQueue.queueReadyTasks
  .then () ->
    jobQueue.getQueueNeeds()
  .then (needs) ->
    next new ExpressResponse(needs)

module.exports =
  info: info
