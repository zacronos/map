_ = require 'lodash'
app = require '../app.coffee'

require '../services/leafletObjectFetcher.coffee'

app.service 'rmapsResultsFormatterService', (
$rootScope, $timeout, $filter, $log, $state, $location,
rmapsParcelEnums,
rmapsGoogleService,
rmapsPropertiesService,
rmapsFormattersService) ->

  $log = $log.spawn("map:rmapsResultsFormatterService")

  class ResultsFormatter

    RESULTS_LIST_DEFAULT_LENGTH: 0
    LOAD_MORE_LENGTH: 10

    _isWithinBounds = (map, prop) ->

      location = prop.geometry or prop.geometry or prop.geometry_center
      return if !location?.type? || !location?.coordinates?

      if location.type == 'Polygon'
        pointBounds = rmapsGoogleService.GeoJsonTo.Polygon.toBounds(location)
      else
        pointBounds = rmapsGoogleService.GeoJsonTo.MultiPolygon.toBounds(location)

      isVisible = map.getBounds().intersects(pointBounds)
      return if !isVisible
      prop

    constructor: (@mapCtrl) ->
      _.extend @, rmapsFormattersService.Common
      _.extend @, google: rmapsGoogleService

      @mapCtrl.scope.isScrolling = false

      onScrolling = _.debounce ->
        if @mapCtrl?.scope?
          @mapCtrl.scope.isScrolling = true

      window.onscroll = onScrolling
      $timeout =>
        @mapCtrl.scope.isScrolling = false if(@mapCtrl.scope.isScrolling)
      , 100

      @reset = _.debounce =>
        $log.debug 'resultsFormatters.reset()'

        @mapCtrl.scope.resultsLimit = @RESULTS_LIST_DEFAULT_LENGTH
        @mapCtrl.scope.results = {}
        @lastSummaryIndex = 0
        @mapCtrl.scope.resultsPotentialLength = undefined
        @filterSummaryInBounds = undefined

        @loadMore()
      , 5

      @mapCtrl.scope.resultsLimit = @RESULTS_LIST_DEFAULT_LENGTH
      @mapCtrl.scope.results = {}
      @mapCtrl.scope.resultsPotentialLength = undefined
      @mapCtrl.scope.resultsDescending = false
      @setOrReverseResultsPredicate('price')
      @lastSummaryIndex = 0
      @origLen = 0
      @postRepeat = null
      @mapCtrl.scope.resultsRepeatPerf =
        init: (postRepeat) =>
          @postRepeat = postRepeat
        doDeleteLastTime: false

      @mapCtrl.scope.$watch 'map.markers.filterSummary', (newVal, oldVal) =>
        return if newVal == oldVal
        $log.debug "resultsFormatter - watch filterSummary. New results"

        @lastSummaryIndex = 0
        #what is special about this case where we do not use reset??
        @mapCtrl.scope.results = {}
        @loadMore()

    getResultsArray: =>
      _.values @mapCtrl.scope.results

    ###
    Disabling animation speeds up scrolling and makes it smoother by around 30~40ms
    ###
    getAdditionalClasses: (result) ->
      classes = ''
      classes += 'result-property-hovered' if result?.isMousedOver
      classes

    setOrReverseResultsPredicate: (predicate) =>
      if @mapCtrl.scope.resultsPredicate != predicate
        @mapCtrl.scope.resultsPredicate = predicate
      else
        # if they hit the same button again, invert the search order
        @mapCtrl.scope.resultsDescending = !@mapCtrl.scope.resultsDescending

    getSortClass: (toMatchSortStr) =>
      if toMatchSortStr != @mapCtrl.scope.resultsPredicate
        return ''
      return 'active-sort'

    loadMore: (cancel = true) =>
      #debugging
      @postRepeat.lastTime = new Date() if @postRepeat
      #end debugging
      if @loader
        if cancel
          $timeout.cancel @loader
        else
          return
      @loader = $timeout =>
        @loader = null
        @throttledLoadMore(@getAmountToLoad())
      , 20

    getAmountToLoad: () ->
      return @LOAD_MORE_LENGTH

    throttledLoadMore: (amountToLoad = 0) =>
      $log.debug "throttledLoadMore(#{amountToLoad})"

      resultsPotentialLength = 0

      if !@filterSummaryInBounds and _.keys(@mapCtrl.scope.map.markers.filterSummary).length
        @filterSummaryInBounds = []
        _.each @mapCtrl.scope.map.markers.filterSummary, (prop) =>
          if prop && _isWithinBounds(@mapCtrl.map, prop)
            @filterSummaryInBounds.push prop
            if prop.grouped?.properties?.length
              resultsPotentialLength += prop.grouped.properties.length
            else
              resultsPotentialLength++

        @mapCtrl.scope.resultsPotentialLength = resultsPotentialLength

      return unless _.keys(@filterSummaryInBounds).length

      if not @mapCtrl.scope.results.length # only do this once (per map bound)
        _.each @filterSummaryInBounds, (summary) =>
          if summary.grouped?.properties?.length
            properties = summary.grouped?.properties
          else
            properties = [summary]
          _.each properties, (property) =>
            if @mapCtrl.layerFormatter.isVisible(@mapCtrl.scope, property)
              # $log.debug property
              @mapCtrl.scope.results[property.rm_property_id] = property

      @mapCtrl.scope.resultsLimit = Math.min @mapCtrl.scope.resultsLimit + amountToLoad, @mapCtrl.scope.resultsPotentialLength

      $log.debug "New results limit > #{@mapCtrl.scope.resultsLimit} / #{@mapCtrl.scope.resultsPotentialLength} <"

    showModel: (model) =>
      @click(@mapCtrl.scope.map?.markers.filterSummary[model.rm_property_id] || model, window.event, 'map')

    click: (result, event, context) ->
      $state.go "property", { id: result.rm_property_id }

    clickSaveResultFromList: (result, event = {}) ->
      if event.stopPropagation then event.stopPropagation() else (event.cancelBubble=true)

      rmapsPropertiesService.pinUnpinProperty(result)

      return false

    clickFavoriteResultFromList: (result, event = {}) ->
      if event.stopPropagation then event.stopPropagation() else (event.cancelBubble=true)

      rmapsPropertiesService.favoriteProperty(result)

      return false
