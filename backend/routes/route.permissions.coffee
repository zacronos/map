logger = require '../config/logger'
auth = require '../config/auth'
permissionsService = require '../services/service.permissions'


# I'm not sure that we'll actually need this route, but it was convenient for testing

module.exports = (app) ->

  app.get '/user_permissions/:id', auth.requireLogin(), (req, res, next) ->
    logger.debug "getting user permissions for id: #{req.params.id}"
    permissionsService.getPermissionsForUserId(req.params.id)
      .then (userPermissions) ->
        logger.debug "got user permissions for id: #{req.params.id}"
        res.json(userPermissions)
      .catch (err) ->
        message = "error getting user permissions for id: #{req.params.id}"
        logger.error message
        logger.error ''+(err.stack ? err)
        res.status(500).json(message)

  app.get '/group_permissions/:id', (req, res, next) ->
    logger.debug "getting group permissions for id: #{req.params.id}"
    permissionsService.getPermissionsForGroupId(req.params.id)
      .then (groupPermissions) ->
          logger.debug "got group permissions for id: #{req.params.id}"
          res.json(groupPermissions)
      .catch (err) ->
          message = "error getting group permissions for id: #{req.params.id}"
          logger.error message
          logger.error ''+(err.stack ? err)
          res.status(500).json(message)
