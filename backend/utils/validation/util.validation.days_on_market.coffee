Promise = require "bluebird"
moment = require 'moment'
integerValidation = require './util.validation.integer'
datetimeValidation = require './util.validation.datetime'


module.exports = (options = {}) ->
  (param, values) -> Promise.try () ->
    if !values?
      return null

    # cumulative days on market has precedence if exists
    if values.cdom?
      integerValidation()(param,values.cdom)
      .then (cdom) ->
        return cdom

    # days on market
    else if values.dom?
      integerValidation()(param,values.dom)
      .then (dom) ->
        return dom

    else
      if !values.creation_date
        return null

      datetimeValidation()(param,values.creation_date)
      .then (creation_date) ->

        # with no close date, we fall back on a calc of `now - creation_date`, with the
        #   intention to possibly include more time at the time of filtering in the frontend
        if !values.close_date && !values.discontinue_date
          dom = moment.utc().diff(moment(creation_date), 'days')
          return dom

        # With close date, we can use `close_date - creation_date`
        else
          datetimeValidation()(param,values.close_date ? values.discontinue_date)
          .then (close_date) ->
            dom = moment(close_date).diff(moment(creation_date), 'days')
            return dom
