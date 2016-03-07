app = require '../app.coffee'
adminRoutes = require '../../../../common/config/routes.admin.coffee'
frontendRoutes = require '../../../../common/config/routes.frontend.coffee'
backendRoutes = require '../../../../common/config/routes.backend.coffee'

# there are some values we want to save onto the root scope
app.run ($rootScope, $state, $stateParams, $timeout, rmapsPrincipalService, rmapsSpinnerService, rmapsEventConstants, rmapsPageService) ->
  $rootScope.alerts = []
  $rootScope.adminRoutes = adminRoutes
  $rootScope.frontendRoutes = frontendRoutes
  $rootScope.backendRoutes = backendRoutes
  $rootScope.principal = rmapsPrincipalService
  $rootScope.$state = $state
  $rootScope.$stateParams = $stateParams
  $rootScope.Spinner = rmapsSpinnerService
  $rootScope.stateData = []
  $rootScope.page = rmapsPageService
  $rootScope._ = window._

