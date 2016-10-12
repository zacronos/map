app = require '../app.coffee'
color = '#ffa500'

app.controller "rmapsDrawAreaCtrl", (
$scope
$log
$q
$rootScope
rmapsEventConstants
rmapsDrawnUtilsService
rmapsMapDrawHandlesFactory
rmapsDrawCtrlFactory
rmapsMapTogglesFactory
rmapsFeatureGroupUtil
rmapsCurrentMapService
) ->
  $scope.tacked = false

  $log = $log.spawn("map:rmapsDrawAreaCtrl")

  isReadyPromise = $q.defer()

  mapId = rmapsCurrentMapService.mainMapId()
  drawnShapesSvc = rmapsDrawnUtilsService.createDrawnSvc()

  drawnShapesSvc.getDrawnItemsAreas()
  .then (drawnItems) ->

    $scope.drawn.items = drawnItems
    featureGroupUtil = new rmapsFeatureGroupUtil({featureGroup:drawnItems, ownerName: 'rmapsDrawAreaCtrl'})

    $rootScope.$on rmapsEventConstants.areas.mouseOver, (event, model) ->
      $log.debug 'list mouseover'
      featureGroupUtil.onMouseOver(model)

    $rootScope.$on rmapsEventConstants.areas.mouseLeave, (event, model) ->
      $log.debug 'list mouseleave'
      featureGroupUtil.onMouseLeave(model)

    # filter drawItems which are only areas / frontend or backend
    $log.spawn("drawnItems").debug(Object.keys(drawnItems._layers).length)

    if !Object.keys(drawnItems._layers).length
      # There are zero areas, force propertiesInShapes to false
      $scope.Toggles.propertiesInShapes = false
      $rootScope.propertiesInShapes = false

    _handles = rmapsMapDrawHandlesFactory {
      mapId
      drawnShapesSvc
      drawnItems

      createPromise: (layer) ->
        #requires rmapsAreasModalCtrl to be in scope (parent)
        geoJson = layer.toGeoJSON()
        if $scope.Toggles.isStatsDraw
          $scope.quickStats(geoJson)
          $scope.drawn.quickStats = layer
          return $q.resolve()
        else
          $scope.create(geoJson)
          .then (result) ->
            $scope.$emit rmapsEventConstants.areas
            if !$scope.Toggles.isTackedAreasDrawBar
              $scope.Toggles.isAreaDraw = false
            result


      deleteAction: (model) ->
        $scope.remove(model, {skipAreas: true})
        .then () ->
          if !Object.keys(drawnItems._layers).length
            rmapsMapTogglesFactory.currentToggles?.setPropertiesInShapes false

          #force refresh
          $scope.$emit rmapsEventConstants.areas

    }

    _drawCtrlFactory = (handles) ->
      rmapsDrawCtrlFactory {
        mapId
        $scope
        handles
        drawnItems
        name: "area"
        itemsOptions:
          color: color
          fillColor: color
          className: 'rmaps-area'
        drawOptions:
          control: (promisedControl) ->
            promisedControl.then (control) ->
              isReadyPromise.resolve(control)
          draw:
            polyline:
              shapeOptions: {color}
            polygon:
              shapeOptions: {color}
            rectangle:
              shapeOptions: {color}
            circle:
              shapeOptions: {color}
      }

    $scope.$watch 'Toggles.isAreaDraw', (newVal) ->
      featureGroupUtil.onOffPointerEvents({isOn:newVal, className: 'rmaps-area'})
      if newVal
        _drawCtrlFactory(_handles)
        isReadyPromise.promise.then (control) ->
          control.enableHandle(handle: 'rectangle')
      else
        _drawCtrlFactory()

    $rootScope.$onRootScope rmapsEventConstants.areas.removeDrawItem, (event, geojsonModel) ->
      drawnItems.removeLayer featureGroupUtil.getLayer(geojsonModel)
