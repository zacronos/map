app = require '../app.coffee'

sprintf = require('sprintf-js').sprintf

app.factory 'ResultsFormatter'.ourNs(), [
  '$timeout', '$filter', 'Logger'.ourNs(), 'ParcelEnums'.ourNs(), 'GoogleService'.ourNs(),
  'Properties'.ourNs(), 'FormattersService'.ourNs(),
  ($timeout, $filter, $log, ParcelEnums, GoogleService, Properties, FormattersService) ->
    _orderBy = $filter('orderBy')

    _forSaleClass = {}
    _forSaleClass[ParcelEnums.status.sold] = 'sold'
    _forSaleClass[ParcelEnums.status.pending] = 'pending'
    _forSaleClass[ParcelEnums.status.forSale] = 'forsale'
    _forSaleClass[ParcelEnums.status.notForSale] = 'notsale'
    _forSaleClass['saved'] = 'saved'
    _forSaleClass['default'] = ''

    resultEvents = ['click', 'dblclick', 'mouseover', 'mouseleave']

    #TODO: BaseObject should really come from require not window.. same w/ PropMap
    class ResultsFormatter extends BaseObject
      @include FormattersService.Common
      @include FormattersService.Google
      constructor: (@mapCtrl) ->
        super()
        @mapCtrl.scope.isScrolling = false

        onScrolling = _.debounce ->
          @mapCtrl.scope.isScrolling = true

        window.onscroll = onScrolling
        $timeout =>
          @mapCtrl.scope.isScrolling = false if(@mapCtrl.scope.isScrolling)
        , 100

        @reset = _.debounce =>
          @mapCtrl.scope.resultsLimit = 10
          @mapCtrl.scope.results = []
          @lastSummaryIndex = 0
          @mapCtrl.scope.resultsPotentialLength = undefined
          @filterSummaryInBounds = undefined
          @order()
          @loadMore()
        , 5
        @mapCtrl.scope.resultsLimit = 10
        @mapCtrl.scope.results = []
        @mapCtrl.scope.resultsPotentialLength = undefined
        @mapCtrl.scope.resultsAscending = false
        @setResultsPredicate('price')
        @lastSummaryIndex = 0
        @origLen = 0
        @postRepeat = null
        @mapCtrl.scope.resultsRepeatPerf =
          init: (postRepeat, scope) =>
            @postRepeat = postRepeat
          doDeleteLastTime: false

        @mapCtrl.scope.$watch 'layers.filterSummary', (newVal, oldVal) =>
          return if newVal == oldVal
          @lastSummaryIndex = 0
          @mapCtrl.scope.results = []
          @loadMore()

        @mapCtrl.scope.$watch 'Toggles.showResults', (newVal, oldVal) =>
          return if newVal == oldVal
          @loadMore()

      ###
      Disabling animation speeds up scrolling and makes it smoother by around 30~40ms
      ###
      maybeAnimate: =>
        "animated slide-down" if @mapCtrl.scope.isScrolling

      order: =>
        @filterSummarySorted = _orderBy(
          @mapCtrl.scope.layers.filterSummary, @mapCtrl.scope.resultsPredicate, @mapCtrl.scope.resultsAscending)

      invertSorting: =>
        @mapCtrl.scope.resultsAscending = !@mapCtrl.scope.resultsAscending

      setResultsPredicate: (predicate) =>
        @mapCtrl.scope.resultsPredicate = predicate
        @order()

      getSorting: =>
        if @mapCtrl.scope.resultsAscending
          "fa fa-chevron-circle-down"
        else
          "fa fa-chevron-circle-up"

      getCurrentOwners:(result) ->
        owners = []
        owners.push result.owner_name if result.owner_name?
        owners.push result.owner_name2  if result.owner_name2?

        owners.reduce (prev, next) ->
          return "#{next}" unless prev
          "#{prev}, #{next}"
        , ''

      isSavedResult:(result) ->
        result.savedDetails?.isSaved == true

      getCurrentOwnersTitle: (result) =>
        title = "Current Owner"
        return "#{title}'s" if @hasMultipleOwners(result)
        title
      hasMultipleOwners: (result) ->
        if result.owner_name2? and result.owner_name?
          return true
        return false

      getActiveSort: (toMatchSortStr) =>
        if toMatchSortStr == @mapCtrl.scope.resultsPredicate then 'active-sort' else ''

      getForSaleClass: (result) ->
        return unless result
        #        $log.debug "result: #{JSON.stringify(result)}"
        soldClass = _forSaleClass['saved'] if result.savedDetails?.isSaved
        soldClass or _forSaleClass[result.rm_status] or _forSaleClass['default']

      loadMore: =>
        #debugging
        return unless @mapCtrl.scope.Toggles.showResults
        @postRepeat.lastTime = new Date() if @postRepeat
        #end debugging
        if @loader
          $timeout.cancel @loader
        @loader = $timeout @throttledLoadMore, 20

      getAmountToLoad: _.memoize (totalHeight) ->
        cardHeight = 95 #we really need to somehow combine css constants and js constants
        numberOfCards = Math.round totalHeight / cardHeight
        #min height to keep scrolling
        numberOfCards

      throttledLoadMore: (amountToLoad, loadedCtr = 0) =>
        unless @resultsContainer
          @resultsContainer = document.getElementById(@mapCtrl.scope.resultsListId)
        return if not @resultsContainer or not @resultsContainer.offsetHeight > 0
        amountToLoad = @getAmountToLoad(@resultsContainer.offsetHeight) unless amountToLoad
        return unless amountToLoad
        _isWithinBounds = (prop) =>
          pointBounds = GoogleService.GeoJsonTo.MultiPolygon.toBounds(prop.geom_polys_json)
          isVisible = @mapCtrl.gMap.getBounds().intersects(pointBounds)
          return unless isVisible
          prop

        unless @filterSummaryInBounds
          @filterSummaryInBounds = @mapCtrl.scope.layers.filterSummary.map (prop) =>
            if _isWithinBounds(prop)
              return prop
            return
          @filterSummaryInBounds = @filterSummaryInBounds.filter(Boolean) #remove nulls
          @mapCtrl.scope.resultsPotentialLength = @filterSummaryInBounds.length
        return unless @filterSummaryInBounds

        if not @mapCtrl.scope.results.length # only do this once (per map bound)
          @filterSummaryInBounds.forEach (summary) =>
            @mapCtrl.scope.results.push summary

        @mapCtrl.scope.resultsLimit += amountToLoad
#        @bindResultsListEvents()


      click: (result) =>
        #immediatley show something
        @mapCtrl.scope.selectedResult = result
        #start getting more data
        Properties.getPropertyDetail(@mapCtrl.mapState, result.rm_property_id)
        .then (data) =>
          angular.extend @mapCtrl.scope.selectedResult, data

        @mapCtrl.scope.showDetails = true

      mouseover: (result) =>
        result.isMousedOver = true
        @mapCtrl.updateAllLayersByModel(result)

      mouseleave: (result) =>
        result.isMousedOver = undefined
        @mapCtrl.updateAllLayersByModel(result)

      clickSaveResultFromList: (result, eventOpts) =>
        event = eventOpts.$event
        if event.stopPropagation then event.stopPropagation() else (event.cancelBubble=true)
#        alert("saved #{result.rm_property_id} #{event}")
        @mapCtrl.saveProperty(model: result)
        @reset()
]
