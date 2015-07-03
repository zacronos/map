{methodExec} = require '../util.route.helpers'
factory = require '../util.factory'
logger = require '../../config/logger'
BaseObject = require '../../../common/utils/util.baseObject'

class Crud extends BaseObject
  constructor: (@svc) ->
    unless @svc?
      throw '@svc must be defined'

    # logger.debug Object.keys @
    # logger.functions @

  root: (req, res, next) =>
    self = @
    methodExec req,
      GET: () ->
        self.svc.getAll()

      POST: () -> #create
        self.svc.create(req.body)

  byId: (req, res, next) =>
    self = @
    methodExec req,
      GET: () ->
        self.svc.getById(req.params.id)
      POST: () ->
        self.svc.create(req.body, req.params.id)
      DELETE: () ->
        self.svc.delete(req.body, req.params.id)
      PUT: () ->
        self.svc.update(req.params.id, req.body)

  methodExec: methodExec

  base: () ->
    super([Crud,@].concat(_.toArray arguments)...)


class StreamCrud extends Crud
  root: (req, res, next) ->
    super(req, res, next).stringify().pipe(res)

  byId: (req, res, next) ->
    super(req, res, next).stringify().pipe(res)

module.exports =
  Crud:Crud
  crud: factory(Crud)
  StreamCrud: StreamCrud
  streamCrud: factory(StreamCrud)
