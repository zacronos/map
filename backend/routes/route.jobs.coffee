_ = require 'lodash'
jobs = require '../services/service.jobs'
RouteCrud = require '../utils/crud/util.ezcrud.route.helpers'
{mergeHandles} = require '../utils/util.route.helpers'
auth = require '../utils/util.auth'
jobQueue = require '../services/service.jobQueue'
ExpressResponse = require '../utils/util.expressResponse'
logger = require('../config/logger').spawn('jobQueue:manual')

#
# routing definitions & config for services that pull data from reporting tables
#
class JobStatGetters extends RouteCrud
  taskHistory: (req, res, next) =>
    @custom @svc.taskHistory(req.query), res

  subtaskErrorHistory: (req, res, next) =>
    @custom @svc.subtaskErrorHistory(req.query), res

  summary: (req, res, next) =>
    @custom @svc.summary(req.query), res

  health: (req, res, next) =>
    @custom @svc.health(req.query), res

  runTask: (req, res, next) ->
    jobQueue.queueManualTask(req.params.name, req.user.email)
    .then () ->
      next new ExpressResponse alert: {msg: "Started #{req.params.name}", type: 'rm-success'}

  cancelTask: (req, res, next) ->
    logger.info("Cancelling task via admin: #{req.params.name} (requested by #{req.user.email})")
    jobQueue.cancelTask(req.params.name)
    .then () ->
      next new ExpressResponse alert: {msg: "Canceled #{req.params.name}", type: 'rm-success'}


getterConfig =
  taskHistory:
    methods: ['get']
    middleware: [
      auth.requirePermissions('access_staff')
    ]
  subtaskErrorHistory:
    methods: ['get']
    middleware: [
      auth.requirePermissions('access_staff')
    ]
  summary:
    methods: ['get']
    middleware: [
      auth.requirePermissions('access_staff')
    ]
  health:
    methods: ['get']
    middleware: [
      auth.requirePermissions('access_staff')
    ]
  runTask:
    methods: ['post']
    middleware: [
      auth.requirePermissions('access_staff')
    ]
  cancelTask:
    methods: ['post']
    middleware: [
      auth.requirePermissions('access_staff')
    ]



#
# routing definitions & config for services that pull or update data from config tables
#
queueCrud = new RouteCrud(jobs.queues)
taskCrud = new RouteCrud(jobs.tasks)
subtaskCrud = new RouteCrud(jobs.subtasks)

jobCruds =
  queues: queueCrud.root
  queuesById: queueCrud.byId

  tasks: taskCrud.root
  tasksById: taskCrud.byId

  subtasks: subtaskCrud.root
  subtasksById: subtaskCrud.byId

crudConfig =
  queues:
    methods: ['get', 'post']
    middleware: [
      auth.requirePermissions('access_staff')
    ]
  queuesById:
    methods: ['get', 'post', 'put', 'delete']
    middleware: [
      auth.requirePermissions('access_staff')
    ]
  tasks:
    methods: ['get', 'post']
    middleware: [
      auth.requirePermissions('access_staff')
    ]
  tasksById:
    methods: ['get', 'post', 'put', 'delete']
    middleware: [
      auth.requirePermissions('access_staff')
    ]
  subtasks:
    methods: ['get', 'post']
    middleware: [
      auth.requirePermissions('access_staff')
    ]
  subtasksById:
    methods: ['get', 'post', 'put', 'delete']
    middleware: [
      auth.requirePermissions('access_staff')
    ]

#
# expose routes
#
crudHandles = mergeHandles(jobCruds, crudConfig, debugNS: 'jobStatCrudMerge')
jobStatGettersRoutes = new JobStatGetters(jobs.jobStatGetters, {debugNS: 'jobStatCrud'})
getterHandles = mergeHandles(jobStatGettersRoutes, getterConfig, debugNS: 'jobStatCrudMerge')

module.exports = _.merge crudHandles, getterHandles
