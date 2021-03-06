mod = require '../module.coffee'
loadingCount = 0

mod.service 'rmapsSpinnerService', ($log) ->

  incrementLoadingCount: (logMessage, delta=1) ->
    loadingCount += delta
    #$log.debug("incremented loadingCount by #{delta} (#{logMessage}): #{loadingCount}")
  decrementLoadingCount: (logMessage, delta=1) ->
    loadingCount -= delta
    if loadingCount < 0
      loadingCount = 0
    #$log.debug("decremented loadingCount by #{delta} (#{logMessage}): #{loadingCount}")
  getLoadingCount: () ->
    loadingCount
