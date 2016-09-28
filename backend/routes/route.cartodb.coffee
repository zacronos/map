logger = require('../config/logger').spawn("route:cartodb")
internals = require './route.cartodb.internals'


module.exports =
    getByFipsCodeAsFile:
      method: 'get'
      handle: (req, res, next) ->
        internals.getByFipsCode req, res, next, (validParams,res) ->
          dispistion = "attachment; filename=#{req.params.fipscode}"
          #if we have options set them to the file name seperated by "-"
          #fipscode-rm_property_id-limit.json
          if validParams.fipscode? #error handled in service
            ['start_rm_property_id', 'limit'].forEach (prop) ->
              if validParams[prop]?
                dispistion += "-#{validParams[prop]}"
            res.setHeader 'Content-disposition', dispistion + '.json'
            res.setHeader 'Content-type', 'application/json'

    getByFipsCodeAsStream:
      method: 'get'
      handle: (req, res, next) ->
        #limiting the size since this endppoint is for testing
        # req.query.limit = 100
        internals.getByFipsCode req, res, next
