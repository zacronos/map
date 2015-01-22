app = require '../app.coffee'
require '../factories/map.coffee'
frontendRoutes = require '../../../common/config/routes.frontend.coffee'

###
  Our Main Map Controller, logic
  is in a specific factory where Map is a GoogleMap
###
map = undefined

module.exports = app

.config(['uiGmapGoogleMapApiProvider', (GoogleMapApi) ->
  GoogleMapApi.configure
  # key: 'your api key',
    v: '3.17' #note 3.16 is slow and buggy on markers
    libraries: 'visualization,geometry'

])

.controller 'MapCtrl'.ourNs(), [
  '$scope', '$rootScope', 'Map'.ourNs(), 'MainOptions'.ourNs(), 'MapToggles'.ourNs(),
  'principal'.ourNs(), 'events'.ourNs(), 'ParcelEnums'.ourNs(),
  ($scope, $rootScope, Map, MainOptions, Toggles,
  principal, Events, ParcelEnums) ->
    #ng-inits or inits
    #must be defined pronto as they will be skipped if you try to hook them to factories
    $scope.resultsInit = (resultsListId) ->
      $scope.resultsListId = resultsListId

    $scope.init = (pageClass) ->
      $scope.pageClass = pageClass
    #end inits

    restoreState = () ->
      principal.getIdentity()
      .then (identity) ->
        if not identity?.stateRecall
          return MainOptions.map
        if identity.stateRecall.map_center
          MainOptions.map.options.json.center = identity.stateRecall.map_center
        if identity.stateRecall.map_zoom
          MainOptions.map.options.json.zoom = +identity.stateRecall.map_zoom
        if identity.stateRecall.filters
          statusList = identity.stateRecall.filters.status || []
          delete identity.stateRecall.filters.status
          for key,status of ParcelEnums.status
            identity.stateRecall.filters[key] = (statusList.indexOf(status) > -1)
          if not $rootScope.selectedFilters?
            $rootScope.selectedFilters = {}
          _.extend($rootScope.selectedFilters, identity.stateRecall.filters)

          MainOptions.map.toggles = if identity.stateRecall.map_toggles then new Toggles(identity.stateRecall.map_toggles) else new Toggles()
        return MainOptions.map
      .then (mapOptions) ->
        # wait to initialize map until we've merged state values into the initial options
        map = new Map($scope, mapOptions)

    $scope.$onRootScope Events.principal.login.success, () ->
      restoreState()

    if principal.isIdentityResolved() && principal.isAuthenticated()
      restoreState()

    $scope.sendSnail = (property) ->
      $rootScope.$emit Events.snail.initiateSend, property
]
