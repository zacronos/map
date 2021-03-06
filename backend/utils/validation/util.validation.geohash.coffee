Promise = require 'bluebird'
geohash64 = require 'geohash64'
DataValidationError = require '../errors/util.error.dataValidation'
logger = require '../../config/logger'

module.exports = (param, boundsStr) ->
  Promise.try () ->
    return null if !boundsStr? or boundsStr == ''
    geohash64.decode(boundsStr)
  .catch (err) ->
    logger.error err, true
    Promise.reject new DataValidationError('error decoding geohash string: ', param, boundsStr)
