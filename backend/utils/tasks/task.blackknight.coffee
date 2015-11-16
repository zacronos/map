Promise = require "bluebird"
dataLoadHelpers = require './util.dataLoadHelpers'
jobQueue = require '../util.jobQueue'
tables = require '../../config/tables'
logger = require '../../config/logger'
sqlHelpers = require '../util.sql.helpers'
countyHelpers = require './util.countyHelpers'
externalAccounts = require '../../services/service.externalAccounts'
PromiseSftp = require 'promise-sftp'
_ = require 'lodash'
keystore = require '../../services/service.keystore'
TaskImplementation = require './util.taskImplementation'
dbs = require '../../config/dbs'
path = require 'path'
moment = require 'moment'
constants = require './task.blackknight.constants'




_findNewFolders = (ftp, action, processDates, newFolders={}) -> Promise.try () ->
  ftp.list("/Managed_#{action}")
  .then (rootListing) ->
    for dir in rootListing when dir.type == 'd'
      date = dir.name.slice(-8)
      type = dir.name.slice(0, -8)
      if !processDates[action]?
        logger.warn("Unexpected directory found in blackknight FTP drop: /Managed_#{action}/#{dir.name}")
        continue
      if processDates[action] >= date
        continue
      newFolders["#{date}_#{action}"] ?= {date, action}
      newFolders["#{date}_#{action}"][type] = {path: "/Managed_#{action}/#{dir.name}", type: type, date: date, action: action}
    newFolders

_checkFolder = (ftp, folderInfo, processLists) -> Promise.try () ->
  logger.debug "Processing blackknight folder: #{folderInfo.path}"
  ftp.list(folderInfo.path)
  .then (folderListing) ->
    for file in folderListing
      if file.name.endsWith('.txt')
        if file.name.startsWith('metadata_')
          continue
        if file.name.indexOf('_Delete_') == -1
          logger.warn("Unexpected file found in blackknight FTP drop: /#{folderInfo.path}/#{file.name}")
          continue
        if file.size == 0
          continue
        fileType = constants.DELETE
      else if !file.name.endsWith('.gz')
        logger.warn("Unexpected file found in blackknight FTP drop: /#{folderInfo.path}/#{file.name}")
        continue
      else
        fileType = folderInfo.action
      fileInfo = _.clone(folderInfo)
      fileInfo.name = file.name
      processLists[fileType].push(fileInfo)
      
_checkDropChain = (ftp, processInfo, newFolders, drops, i) -> Promise.try () ->
  if i >= drops.length
    # we've iterated over the whole list
    processInfo.dates[constants.LAST_COMPLETE_CHECK] = moment.utc().format('YYYYMMDD')
    return processInfo
  drop = newFolders[drops[i]]
  if !drop[constants.TAX] || !drop[constants.DEED] || !drop[constants.MORTGAGE]
    return Promise.reject(new Error("Partial #{drop.action} drop for #{drop.date}: #{Object.keys(drop).join(', ')}"))

  logger.debug "Processing blackknight drops for #{drop.date}"
  processInfo.dates[drop.action] = drop.date
  _checkFolder(ftp, drop[constants.TAX], processInfo)
  .then () ->
    _checkFolder(ftp, drop[constants.DEED], processInfo)
  .then () ->
    _checkFolder(ftp, drop[constants.MORTGAGE], processInfo)
  .then () ->
    if processInfo[constants.REFRESH].length + processInfo[constants.UPDATE].length + processInfo[constants.DELETE].length == 0
      # nothing in this folder, move on to the next thing in the drop
      return _checkDropChain(ftp, processInfo, newFolders, drops, i+1)
    # we found files!  resolve the results
    processInfo.hasFiles = true
    processInfo

_queuePerFileSubtasks = (transaction, subtask, files, action) -> Promise.try () ->
  if !files?.length
    return
  loadDataList = []
  deleteDataList = []
  countDataList = []
  for file in files
    rawTableSuffix = "#{file.name.slice(0, -7)}"
    loadData =
      path: "#{file.path}/#{file.name}"
      rawTableSuffix: rawTableSuffix
      dataType: file.type
      action: file.action
    if action == constants.DELETE
      loadData.fileType = constants.DELETE
      deleteDataList.push
        rawTableSuffix: rawTableSuffix
        dataType: file.type
        action: file.action
    else
      loadData.fileType = constants.LOAD
      countDataList.push
        rawTableSuffix: rawTableSuffix
        dataType: file.type
        deletes: dataLoadHelpers.DELETE.INDICATED
        subset:
          fips_code: file.name.slice(0, 5)
    loadDataList.push(loadData)
  loadRawDataPromise = jobQueue.queueSubsequentSubtask(transaction, subtask, "blackknight_loadRawData", loadDataList, true)
  deleteDataPromise = jobQueue.queueSubsequentSubtask(transaction, subtask, "blackknight_deleteData", deleteDataList, true)
  recordChangeCountsPromise = jobQueue.queueSubsequentSubtask(transaction, subtask, "blackknight_recordChangeCounts", countDataList, true)
  Promise.join loadRawDataPromise, deleteDataPromise, recordChangeCountsPromise, () ->  # empty handler


checkFtpDrop = (subtask) ->
  ftp = new PromiseSftp()
  defaults = {}
  defaults[constants.REFRESH] = '19700101'
  defaults[constants.UPDATE] = '19700101'
  defaults[constants.LAST_COMPLETE_CHECK] = '19700101'
  keystore.getValuesMap(constants.BLACKKNIGHT_PROCESS_DATES, defaultValues: defaults)
  .then (processDates) ->
    # ##################################### TODO: debugging, remove this when done coding the blackknight task
    processDates = defaults  ############## TODO: debugging, remove this when done coding the blackknight task
    # ##################################### TODO: debugging, remove this when done coding the blackknight task
    externalAccounts.getAccountInfo('blackknight')
    .then (accountInfo) ->
      ftp.connect
        host: accountInfo.url
        user: accountInfo.username
        password: accountInfo.password
        autoReconnect: true
    .then () ->
      _findNewFolders(ftp, constants.REFRESH, processDates)
    .then (newFolders) ->
      _findNewFolders(ftp, constants.UPDATE, processDates, newFolders)
    .then (newFolders) ->
      drops = Object.keys(newFolders).sort()  # sorts by date, with Refresh before Update
      if drops.length == 0
        logger.debug "No new blackknight directories to process"
      else
        logger.debug "Found #{drops.length} blackknight dates to process"
      processInfo = {dates: processDates}
      # reset last complete check unless this run completes
      processInfo.dates[constants.LAST_COMPLETE_CHECK] = '19700101'
      processInfo[constants.REFRESH] = []
      processInfo[constants.UPDATE] = []
      processInfo[constants.DELETE] = []
      _checkDropChain(ftp, processInfo, newFolders, drops, 0)
  .then (processInfo) ->
    ftpEnd = ftp.end()
    # this transaction is important because we don't want the subtasks enqueued below to start showing up as available
    # on their queue out-of-order; normally, subtasks enqueued by another subtask won't be considered as available
    # until the current subtask finishes, but the checkFtpDrop subtask is on a different queue than those being
    # enqueued, and that messes with it.  We could probably fix that edge case, but it would have a steep performance
    # cost, so instead I left it as a caveat to be handled manually (like this) the few times it arises
    dbs.get('main').transaction (transaction) ->
      if processInfo.hasFiles
        deletes = _queuePerFileSubtasks(transaction, subtask, processInfo[constants.DELETE], constants.DELETE)
        refresh = _queuePerFileSubtasks(transaction, subtask, processInfo[constants.REFRESH], constants.REFRESH)
        update = _queuePerFileSubtasks(transaction, subtask, processInfo[constants.UPDATE], constants.UPDATE)
        finalizePrep = jobQueue.queueSubsequentSubtask(transaction, subtask, "blackknight_finalizeDataPrep", {}, true)
        activate = jobQueue.queueSubsequentSubtask(transaction, subtask, "blackknight_activateNewData", {deletes: dataLoadHelpers.DELETE.INDICATED}, true)
        fileProcessing = Promise.join deletes, refresh, update, finalizePrep, activate, () ->  # empty handler
      else
        fileProcessing = Promise.resolve()
      dates = jobQueue.queueSubsequentSubtask(transaction, subtask, 'blackknight_saveProcessDates', dates: processInfo.dates, true)
      Promise.join ftpEnd, fileProcessing, dates, () ->  # empty handler

  
loadRawData = (subtask) ->
  countyHelpers.loadRawData subtask,
    dataSourceId: 'blackknight'
    columnsHandler: constants.COLUMNS[subtask.data.fileType][subtask.data.action][subtask.data.dataType]
    delimiter: '\t'
    sftp: true
  .then (numRows) ->
    jobQueue.queueSubsequentPaginatedSubtask null, subtask, numRows, constants.NUM_ROWS_TO_PAGINATE, "blackknight_normalizeData",
      rawTableSuffix: subtask.data.rawTableSuffix
      dataType: subtask.data.dataType

saveProcessedDates = (subtask) ->
  keystore.setValuesMap(subtask.data.dates, namespace: constants.BLACKKNIGHT_PROCESS_DATES)

deleteData = (subtask) ->
  Promise.reject('~~~~~~~~~~~~~~~~~ show stopper ~~~~~~~~~~~~~~~~~')

normalizeData = (subtask) ->
  dataLoadHelpers.normalizeData subtask,
    dataSourceId: 'blackknight'
    dataSourceType: 'county'
    buildRecord: countyHelpers.buildRecord

finalizeDataPrep = (subtask) ->
  Promise.map subtask.data.sources, (source) ->
    tables.property[source]()
    .select('rm_property_id')
    .where(batch_id: subtask.batch_id)
    .then (ids) ->
      _.pluck(ids, 'rm_property_id')
  .then (lists) ->
    jobQueue.queueSubsequentPaginatedSubtask(null, subtask, _.union(lists), constants.NUM_ROWS_TO_PAGINATE, "blackknight_finalizeData")

finalizeData = (subtask) ->
  Promise.map subtask.data.values, countyHelpers.finalizeData.bind(null, subtask)


ready = () ->
  defaults = {}
  defaults[constants.REFRESH] = '19700101'
  defaults[constants.UPDATE] = '19700101'
  defaults[constants.LAST_COMPLETE_CHECK] = '19700101'
  keystore.getValuesMap(constants.BLACKKNIGHT_PROCESS_DATES, defaultValues: defaults)
  .then (processDates) ->
    if processDates[constants.LAST_COMPLETE_CHECK] != moment.utc().format('YYYYMMDD')
      # needs to run using regular logic
      return undefined
    dayOfWeek = moment.utc().isoWeekday()
    if dayOfWeek == 7 || dayOfWeek == 1
      # Sunday or Monday, because drops don't happen at the end of Saturday and Sunday  
      return false
    yesterday = moment.utc().subtract(1, 'day').format('YYYYMMDD')
    if processDates[constants.REFRESH] == yesterday && processDates[constants.UPDATE] == yesterday
      # we've already processed yesterday's data
      return false
    # no overrides, needs to run using regular logic
    return undefined


subtasks =
  checkFtpDrop: checkFtpDrop
  loadRawData: loadRawData
  deleteData: deleteData
  normalizeData: normalizeData
  recordChangeCounts: dataLoadHelpers.recordChangeCounts
  finalizeDataPrep: finalizeDataPrep
  finalizeData: finalizeData
  activateNewData: dataLoadHelpers.activateNewData

module.exports = new TaskImplementation(subtasks, ready)