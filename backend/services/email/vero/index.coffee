veroBootstrap = require('./service.email.impl.vero.bootstrap')

module.exports = veroBootstrap.then (vero) ->
  user: require('./service.email.impl.vero.user')(vero)
