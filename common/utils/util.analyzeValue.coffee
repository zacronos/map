util = require('util')
_ = require('lodash')


analysisToString = (includeVerbose) ->
  result =  "AnalyzedValue:\n"
  result += "#{module.exports.INDENT}Type: #{this.type}\n"
  if this.details
    result += "#{module.exports.INDENT}Details: #{this.details}\n"
  if this.stack
    result += module.exports.INDENT+module.exports.INDENT+this.stack.join("\n#{module.exports.INDENT}#{module.exports.INDENT}")+'\n'
  if includeVerbose && this.verbose
    result += "#{module.exports.INDENT}Verbose:\n"
    result += module.exports.INDENT+module.exports.INDENT+this.verbose.join("\n#{module.exports.INDENT}#{module.exports.INDENT}")+'\n'
  if this.json
    result += "#{module.exports.INDENT}Full Object:\n"
    result += module.exports.INDENT+module.exports.INDENT+this.json.split('\n').join("\n#{module.exports.INDENT}#{module.exports.INDENT}")+'\n'
  result


getFunctionName = (funcString) ->
  # based off of http://stackoverflow.com/questions/332422/how-do-i-get-the-name-of-an-objects-type-in-javascript
  if not funcString then return null
  funcNameRegex = /function (.{1,})\(/
  results = (funcNameRegex).exec(funcString.toString())
  if results && results.length > 1 then results[1] else ''


# TODO: this original function might be unused by now
analyzeValue = (value, fullJson=false) ->
  result = {toString: analysisToString}
  result.type = typeof(value)
  if value == null
    result.type = 'null'
  else if result.type == 'function'
    result.verbose = value.toString().split('\n')
    result.details = getFunctionName(result.verbose) || '<anonymous function>'
  else if result.type == 'object'
    if value instanceof Error
      result.type = if isKnexError(value) then 'KnexError' else null
      result.details = value.message
      result.verbose = util.inspect(result, depth: null).split('\n')
      if (value.stack?)
        result.stack = (''+value.stack).split('\n').slice(1)
    else
      result.type = null
    result.type = result.type || value?.constructor?.name || getFunctionName(value?.constructor?.toString()) || 'object'
    result.details = result.details || value.toString()
    if (result.details.substr(0, 7) == '[object' || result.type == 'Array')
      result.details = util.inspect(value, depth: null)
  else if result.type == 'string'
    result.details = util.inspect(value, depth: null)
  else if result.type == 'undefined'
    ### do nothing ###
  else # boolean, number, or symbol
    result.details = ''+value
  if fullJson
    result.json = util.inspect(value, depth: null)

  return result


getType = (value) ->
  type = typeof(value)
  if value == null
    type = 'null'
  else if type == 'object'
    if (value instanceof Error) && isKnexError(value)
      type = 'KnexError'
    else
      type = value?.constructor?.name || getFunctionName(value?.constructor?.toString()) || 'object'
  return type


isKnexError = (err) -> (err.hasOwnProperty('internalQuery') && err.name == 'error')


getSimpleDetails = (err, opts={}) ->
  inspectOpts = _.clone(opts)
  showUndefined = inspectOpts.showUndefined ? false
  delete inspectOpts.showUndefined
  showNull = inspectOpts.showNull ? true
  delete inspectOpts.showNull
  showFunctions = inspectOpts.showFunctions ? true
  delete inspectOpts.showFunctions
  inspectOpts.depth ?= null

  if !err?.hasOwnProperty?
    return JSON.stringify(err)
  inspect = util.inspect(err, inspectOpts)
  if !showUndefined
    inspect = inspect.replace(/,?\n? +\w+: undefined/g, '')
  if !showNull
    inspect = inspect.replace(/,?\n? +\w+: null/g, '')
  if !showFunctions
    inspect = inspect.replace(/,?\n? +\w+: \[Function[^\]]*\]/g, '')
  return inspect + '\n' + (err.stack || "#{err}")


getFullDetails = (err, opts={}) ->
  inspectOpts = _.clone(opts)
  maxErrorHistory = inspectOpts.maxErrorHistory ? null
  delete inspectOpts.maxErrorHistory

  inspect = getSimpleDetails(err, inspectOpts)
  cause = err?.jse_cause
  depth = 0
  while cause? && (!maxErrorHistory? || depth < maxErrorHistory)
    inspect += '\n---------- Caused by previous error: ----------\n'
    inspect += getSimpleDetails(cause, inspectOpts)
    depth++
    cause = cause.jse_cause
  return inspect


getSimpleMessage = (err, opts={}) ->
  inspectOpts = _.clone(opts)
  showUndefined = inspectOpts.showUndefined ? false
  delete inspectOpts.showUndefined
  showNull = inspectOpts.showNull ? true
  delete inspectOpts.showNull
  showFunctions = inspectOpts.showFunctions ? true
  delete inspectOpts.showFunctions
  inspectOpts.depth ?= null

  if !err?
    return JSON.stringify(err)
  if err.message
    return err.message
  if err.toString() == '[object Object]'
    inspect = util.inspect(err, inspectOpts)
    if !showUndefined
      inspect = inspect.replace(/,?\n? +\w+: undefined/g, '')
    if !showNull
      inspect = inspect.replace(/,?\n? +\w+: null/g, '')
    if !showFunctions
      inspect = inspect.replace(/,?\n? +\w+: \[Function[^\]]*\]/g, '')
    return inspect
  else
    return err.toString()


simpleInspect = (obj, {skipOuterBraces=true}={}) ->
  result = util.inspect(obj).replace(/\s*\n\s*/g, ' ')
  if skipOuterBraces
    result = result[2..result.length-3]

module.exports = analyzeValue
module.exports.INDENT = "    "
module.exports.getSimpleDetails = getSimpleDetails
module.exports.getSimpleMessage = getSimpleMessage
module.exports.isKnexError = isKnexError
module.exports.getFullDetails = getFullDetails
module.exports.getType = getType
module.exports.simpleInspect = simpleInspect
