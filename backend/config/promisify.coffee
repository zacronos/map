Promise = require "bluebird"

# Usually, something like the following will work:
#   Promise.promisifyAll(require 'someLib')
# which makes a promisified version of each exported function, using the
# suffix 'Async' (so someLib.nodeFunc becomes someLib.nodeFuncAsync)


bcrypt = require('bcrypt')
bcrypt.genSaltAsync = Promise.promisify(bcrypt.genSalt)
bcrypt.hashAsync = Promise.promisify(bcrypt.hash)
bcrypt.compareAsync = Promise.promisify(bcrypt.compare)


# we don't have access to promisify the entire session class, so we have to
# export it as middleware and promisify each instance
module.exports = {
  middleware:
    promisifySession: (req, res) -> Promise.try () ->
      Promise.promisifyAll(req.session)
      Promise.resolve()
}


# this is a wrapper to provide the inverse of Promise.promisify via a call to
# nodeify(); it accepts a function that returns a promise, and returns a
# function that has a node-style callback as its final parameter and proxies
# functionality to the original function.  Optionally, you can also pass an
# options hash to the wrapper as a 2nd argument; these options will be passed
# directly to nodeify().  The only relevant option at the time of this writing
# is spread:true, which will cause an array resolution to be passed as a splat
# to the callback rather than as an array.  For details on options available:
# https://github.com/petkaantonov/bluebird/blob/master/API.md#nodeifyfunction-callback--object-options---promise
# 
# TL;DR: Returns a nodeback-style version of the passed function.  If there
# are multiple values to pass to the nodeback, pass {spread: true} to the
# wrapper call.
Promise.nodeifyWrapper = (func, options) ->
  return (args..., callback) ->
    func(args...).nodeify(callback, options)