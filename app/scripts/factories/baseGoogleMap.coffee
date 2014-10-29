app = require '../app.coffee'

###
  This base map is primarily to deal with basic functionality of zoom and dragg issues.

  For example if only update markers if dragging has really changed. Also checking for zoom deltas (tooManyZoomChanges)
###
module.exports = app.factory 'BaseGoogleMap'.ourNs(), ['Logger'.ns(),'$http','$timeout', ($log) ->
    class BaseGoogleMapCtrl extends BaseObject
      #all constructor arguments are for an instance (other stuff is singletons)
      constructor: (@scope, options, @zoomThresholdMill, @eventDispatcher) ->
        @map = {}
        @hasRun = false;
        @zoomChangedTimeMilli = new Date().getTime()
        @activeMarker = undefined

        angular.extend @scope,
          pageClass: 'page-map',
          map:
            bounds: {}
            options: options
            center: options.json.center
            zoom: options.json.zoom,
            dragging: false,
            events:   #direct hook to google maps sdk events
              tilesloaded: (map, eventName, originalEventArgs) =>
                if !@hasRun
                  @map = map
                  @hasRun = true
          markers: [],
          active_markers: [],
          onMarkerClicked: (marker) =>
            @onMarkerClicked?(marker)

        unBindWatchBounds = @scope.$watch 'map.bounds', (newValue, oldValue) =>
          return if (newValue == oldValue)
          @updateMarkers?(@map,'ready')
        , true

        @scope.$watch 'zoom', (newValue, oldValue) =>
          return if (newValue == oldValue)
          @eventDispatcher?.on_event(@constructor.name,'zoom')
          @updateMarkers?(@map,'zoom') if !@scope.dragging and !@tooManyZoomChanges()

        $log.info 'BaseGoogleMapCtrl: ' + @

      #check zoom deltas as to not query the backend until a view is solidified
      tooManyZoomChanges: =>
        attemptTimeMilli = new Date().getTime()
        delta = attemptTimeMilli - @zoomChangedTimeMilli
        tooMany = @zoomThreshMilli >= delta
        @zoomChangedTimeMilli = attemptTimeMilli if !tooMany
        tooMany

      isZoomIn:(newValue,oldValue) -> newValue > oldValue

]
