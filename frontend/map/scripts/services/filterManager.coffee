_ = require 'lodash'
#TODO This should probably become a controller
app = require '../app.coffee'

app.service 'rmapsFilterManagerService', (
$rootScope, $log,
rmapsParcelEnums, rmapsRenderingService, rmapsEventConstants, rmapsMainOptions) ->

  _promiseObject =
    filterDrawPromise: false

  _cleanFilters = (filters) ->
    #remove all null, zero, and empty string values so we don't send them
    _.each filters, (v,k) ->
      if !v && v != false
        delete filters[k]

  getFilters = () ->
    if $rootScope.selectedFilters
      selectedFilters = _.clone($rootScope.selectedFilters || {})
      _cleanFilters(selectedFilters)
      selectedFilters.status = []
      if (selectedFilters.forSale)
        selectedFilters.status.push(rmapsParcelEnums.status.forSale)
      if (selectedFilters.pending)
        selectedFilters.status.push(rmapsParcelEnums.status.pending)
      if (selectedFilters.sold)
        selectedFilters.status.push(rmapsParcelEnums.status.sold)
      delete selectedFilters.forSale
      delete selectedFilters.pending
      delete selectedFilters.sold
      delete selectedFilters.notForSale

      selectedFilters

  $rootScope.updateFilters = (newFilters, oldFilters) ->

    return if (!newFilters? && !oldFilters?) || newFilters == oldFilters

    rmapsRenderingService.debounce _promiseObject, 'filterDrawPromise', ->
      $rootScope.$broadcast rmapsEventConstants.map.filters.updated, getFilters()
    , rmapsMainOptions.filterDrawDelay

  getFilters: getFilters
