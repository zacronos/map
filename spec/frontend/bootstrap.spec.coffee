###global angular:true###
_ = require 'lodash'
config = require '../../backend/config/config.coffee'
backendRoutes = require '../../common/config/routes.backend.coffee'


beforeEach ->
  window.isTest = true
  angular.module('rmapsCommon')
  .config (nemDebugProvider) ->
    debug = nemDebugProvider.debug
    debug.enable(config.LOGGING.ENABLE)

  .config ($provide, nemSimpleLoggerProvider) ->
    $provide.value('$log', console)
    $provide.decorator nemSimpleLoggerProvider.decorator...

    $provide.decorator '$timeout', ($delegate, $browser) ->
      $delegate.hasPendingTasks = ->
        $browser.deferredFns.length > 0

      $delegate
    $provide.decorator '$httpBackend', ($delegate) ->

      $delegate.hasPendingRequests = ->
        pending = false
        try
          $delegate.verifyNoOutstandingRequest()
        catch
          pending = true
        pending
      $delegate

  .service 'digestor', ($rootScope, $timeout, $log, $httpBackend) ->
    digest: (scope = $rootScope, fn = ->) ->
      if _.isFunction scope
        fn = scope
        scope = $rootScope

      while $timeout.hasPendingTasks()
        # $log.debug 'FLUSHING!'
        $timeout.flush()

      fn() if fn?
      scope.$digest() unless scope.$$phase

      if $httpBackend.hasPendingRequests()
        # $log.debug "FLUSHING $httpBackend"
        $httpBackend.flush()

  .run ($httpBackend) ->
    $httpBackend.when( 'GET', backendRoutes.config.mapboxKey).respond(500)
    $httpBackend.when( 'GET', backendRoutes.config.cartodb).respond(500)
    $httpBackend.when( 'GET', backendRoutes.config.google).respond(500)
    $httpBackend.when( 'GET', backendRoutes.config.asyncAPIs).respond([])
    $httpBackend.when( 'GET', backendRoutes.config.us_states).respond([])

  .run ($log) ->
    $log.currentLevel = $log.LEVELS.log


  angular.module('rmapsMapApp')
  .run ($log) ->
    $log.currentLevel = $log.LEVELS.log

afterEach ->
  #window.moduleName = null
