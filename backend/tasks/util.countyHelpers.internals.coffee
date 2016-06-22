_ = require 'lodash'
Promise = require 'bluebird'
dbs = require '../config/dbs'
logger = require('../config/logger').spawn('task:util:countyHelpers:internals')
tables = require '../config/tables'
dataLoadHelpers = require './util.dataLoadHelpers'
{HardFail} = require '../utils/errors/util.error.jobQueue'
moment = require 'moment'


_documentFinalize = (fnName, cbPromise) ->
  logger.spawn('verbose').debug () -> "#{fnName} STARTED"

  cbPromise()
  .then (entries) ->
    logger.spawn('verbose').debug () -> "#{fnName} FINISHED"
    entries

finalizeDataTax = ({subtask, id, data_source_id, forceFinalize}) ->
  _documentFinalize "finalizeDataTax", () ->
    tables.normalized.tax(subid: subtask.data.normalSubid)
    .select('*')
    .where
      rm_property_id: id
      data_source_id: data_source_id || subtask.task_name
    .whereNull('deleted')
    .orderBy('rm_property_id')
    .orderBy('deleted')
    .orderByRaw('close_date DESC NULLS LAST')
    .then (taxEntries=[]) ->
      if taxEntries.length == 0
        return null  # sometimes this might cover up a real error, but there are semi-legitimate cases where this can happen
      if !forceFinalize && subtask.data.cause != 'tax' && taxEntries[0]?.batch_id == subtask.batch_id
        logger.debug "GTFO to allow finalize from tax instead of: #{subtask.data.cause}"
        # since the same rm_property_id might get enqueued for finalization multiple times, we GTFO based on the priority
        # of the given enqueue source, in the following order: tax, deed, mortgage.  So if this instance wasn't enqueued
        # because of tax data, but the tax data appears to have been updated in this same batch, we bail and let tax take
        # care of it.
        return null
      return taxEntries


finalizeDataDeed = ({subtask, id, data_source_id, forceFinalize}) ->
  _documentFinalize "finalizeDataDeed", () ->
    tables.normalized.deed(subid: subtask.data.normalSubid)
    .select('*')
    .where
      rm_property_id: id
      data_source_id: data_source_id || subtask.task_name
    .whereNull('deleted')
    .orderBy('rm_property_id')
    .orderBy('deleted')
    .orderByRaw('close_date ASC NULLS FIRST')
    .then (deedEntries=[]) ->
      if !forceFinalize && subtask.data.cause == 'mortgage' && deedEntries[0]?.batch_id == subtask.batch_id
        logger.debug "GTFO to allow finalize from deed instead of: #{subtask.data.cause}"
        # see above comment about GTFO shortcut logic.  This part lets mortgage give priority to deed.
        return null
      return deedEntries


finalizeDataMortgage = ({subtask, id, data_source_id}) ->
  _documentFinalize "finalizeDataMortgage", () ->
    tables.normalized.mortgage(subid: subtask.data.normalSubid)
    .select('*')
    .where
      rm_property_id: id
      data_source_id: data_source_id || subtask.task_name
    .whereNull('deleted')
    .orderBy('rm_property_id')
    .orderBy('deleted')
    .orderByRaw('close_date ASC NULLS FIRST')


_promoteValues = ({taxEntries, deedEntries, mortgageEntries, parcelEntries, subtask}) ->
  tax = dataLoadHelpers.finalizeEntry({entries: taxEntries, subtask})
  tax.data_source_type = 'county'
  _.extend(tax, parcelEntries[0])

  # all county data gets 'sold' status -- it will be differentiated by the frontend's sold timeframe filter
  tax.status = 'sold'
  tax.substatus = 'sold'
  tax.status_display = 'sold'

  # TODO: consider going through salesHistory to make it essentially a diff, with changed values only for certain
  # TODO: static data fields?

  # now that we have an ordered sales history, overwrite that into the tax record
  saleFields = ['price', 'close_date', 'parcel_id', 'owner_name', 'owner_name_2', 'address', 'owner_address', 'property_type', 'zoning']
  tax.subscriber_groups.mortgageHistory = mortgageEntries
  lastSale = deedEntries[0]
  if lastSale? && moment(lastSale.close_date).isAfter(tax.assessmentDate)
    tax.subscriber_groups.owner = lastSale.subscriber_groups.owner
    tax.subscriber_groups.deed = lastSale.subscriber_groups.deed
    for field in saleFields
      tax[field] = lastSale[field]
    # save the MLS promoted values for easier access
    promotedValues =
      owner_name: lastSale.owner_name
      owner_name_2: lastSale.owner_name_2
      zoning: lastSale.zoning
  else
    # save the MLS promoted values for easier access
    promotedValues =
      owner_name: tax.owner_name
      owner_name_2: tax.owner_name_2
      zoning: tax.zoning
  tax.subscriber_groups.deedHistory = deedEntries
  tax.shared_groups.saleHistory = []
  for deedInfo in deedEntries
    tax.shared_groups.saleHistory.push(price: deedInfo.price, close_date: deedInfo.close_date)

  {promotedValues,tax}

_updateDataCombined = ({subtask, id, data_source_id, transaction, tax}) ->
  tables.finalized.combined(transaction: transaction)
  .where
    rm_property_id: id
    data_source_id: data_source_id || subtask.task_name
    active: false
  .delete()
  .then () ->
    tables.finalized.combined(transaction: transaction)
    .insert(tax)

finalizeJoin = ({subtask, id, data_source_id, delay, transaction, taxEntries, deedEntries, mortgageEntries, parcelEntries}) ->
  delay ?= 100
  _documentFinalize "finalizeJoin", () ->
    # TODO: does this need to be discriminated further?  speculators can resell a property the same day they buy it with
    # TODO: simultaneous closings, how do we properly sort to account for that?
    {promotedValues,tax} = _promoteValues({taxEntries, deedEntries, mortgageEntries, parcelEntries, subtask})

    Promise.delay(delay)  #throttle for heroku's sake
    .then () ->
      if !_.isEqual(promotedValues, tax.promoted_values)
        # need to save back promoted values to the normal table
        tables.normalized.tax(subid: subtask.data.normalSubid)
        .where
          data_source_id: data_source_id || subtask.task_name
          data_source_uuid: tax.data_source_uuid
        .update(promoted_values: promotedValues)
      else
        Promise.resolve()
    .then () ->
      delete tax.promoted_values

      # we must use an existing transaction if there is one
      dbs.ensureTransaction transaction, 'main', (transaction) ->
        _updateDataCombined {subtask, id, data_source_id, transaction: transaction, tax}


module.exports = {
  finalizeDataTax
  finalizeDataDeed
  finalizeDataMortgage
  finalizeJoin
}
