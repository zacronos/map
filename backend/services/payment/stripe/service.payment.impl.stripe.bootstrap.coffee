stripeFactory = require 'stripe'
externalAccounts = require '../../service.externalAccounts'
{CriticalError} = require '../../../utils/errors/util.errors.critical'
config = require '../../../config/config'
logger = require('../../../config/logger').spawn('stripe')


module.exports = () ->
  externalAccounts.getAccountInfo('stripe')
  .then ({other}) ->
    throw new CriticalError('Stripe API_KEYS intialization failed.') unless other
    API_KEYS = other
    if config.PAYMENT_PLATFORM.LIVE_MODE
      if config.ENV != 'production' && !config.ALLOW_LIVE_APIS
        throw new Error("Refusing to use stripe live API from #{config.ENV} -- set ALLOW_LIVE_APIS to force")
      apiKeyNameStr = 'live'
    else
      apiKeyNameStr = 'test'

    keyToUse = "secret_#{apiKeyNameStr}_api_key"
    logger.debug -> "using API_KEY prop: #{apiKeyNameStr} for backend stripe"
    secret_api_key = API_KEYS[keyToUse]
    stripeFactory(secret_api_key)
  .then (stripe) ->
    stripe
