_ = require 'lodash'
Promise = require "bluebird"
DataValidationError = require './util.error.dataValidation'
arrayValidation = require './util.validation.array'
doValidationSteps = require './util.impl.doValidationSteps'
logger = require '../../config/logger'

module.exports = (options = {}) ->
  (param, values) ->
    if !values?
      return null
    Promise.try () ->
      arrayValidation()(param,values)
    .then (arrayValues) ->
      if arrayValues == null
        return null
      if !options.criteria
        if arrayValues.length == 0
          throw new DataValidationError("no array elements given", param, values)
        else
          return arrayValues[0]
      Promise.settle(_.map(arrayValues, doValidationSteps.bind(null, options.criteria, param)))
      .then (validatedValues) ->
        for inspection in validatedValues
          if inspection.isFulfilled()
            return inspection.value()
        throw new DataValidationError("no array elements fulfilled validation criteria", param, values)