Promise = require "bluebird"
ParamValidationError = require './util.error.paramValidation'

module.exports = (options = {}) ->
  (param, value) -> Promise.try () ->
    if options.equalsTester?
      choice = _.find(options.choices, options.equalsTester.bind(null, value))
      if choice?
        return choice
    else if value in options.choices
      return value
    return Promise.reject new ParamValidationError("unrecognized value, options are: #{JSON.stringify(options.choices)}", param, value)