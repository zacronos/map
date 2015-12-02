app = require '../app.coffee'

app.factory 'rmapsMapToggles', ($rootScope) ->

  (json) ->
    _locationCb = null
    @showResults = false
    @showDetails = false
    @showFilters = false
    @showSearch = false
    @isFetchingLocation = false
    @hasPreviousLocation = false

    @showAddresses = true
    @showPrices = true
    @showNeighborhoodTap = false
    @showNotes = false
    @propertiesInShapes = false

    @enableNoteTap = () =>
      @showNoteTap = true

    @enableNeighborhoodTap = () =>
      @showNeighborhoodTap = true

    @toggleNotes = () =>
      @showNotes = !@showNotes

    @toggleNoteTap = =>
      @showNoteTap = !@showNoteTap

    @toggleAddresses = =>
      @showAddresses = !@showAddresses

    @togglePrices = =>
      @showPrices = !@showPrices

    @toggleDetails = =>
      @showDetails = !@showDetails

    @toggleResults = =>
      if @showDetails
        @showDetails = false
        @showResults = true
        return
      @showResults =  !@showResults

    @toggleFilters = =>
      @showFilters = !@showFilters

    @togglePropertiesInShapes = =>
      @propertiesInShapes = !@propertiesInShapes

    @toggleSearch = (val) =>
      if val?
        @showSearch = val
      else
        @showSearch = !@showSearch

      if @showSearch
        # let angular have a chance to attach the input box...
        document.getElementById('places-search-input')?.focus()

    @setLocationCb = (cb) ->
      _locationCb = cb

    @toggleLocation = =>
      @isFetchingLocation = true
      navigator.geolocation.getCurrentPosition (location) =>
        @isFetchingLocation = false
        _locationCb(location)

    @togglePreviousLocation = ->
      _locationCb()

    if json?
      _.extend @, _.mapValues json, (val) ->
        return val == 'true'
    @
