Promise = require "bluebird"
dataLoadHelpers = require './util.dataLoadHelpers'
jobQueue = require '../services/service.jobQueue'
{SoftFail} = require '../utils/errors/util.error.jobQueue'
tables = require '../config/tables'
logger = require('../config/logger').spawn('task:blackknight')
countyHelpers = require './util.countyHelpers'
externalAccounts = require '../services/service.externalAccounts'
PromiseSftp = require 'promise-sftp'
_ = require 'lodash'
keystore = require '../services/service.keystore'
TaskImplementation = require './util.taskImplementation'
dbs = require '../config/dbs'
moment = require 'moment'
internals = require './task.blackknight.internals'
validation = require '../utils/util.validation'
awsService = require '../services/service.aws'


copyFtpDrop = (subtask) ->
  console.log "copyFtpDrop()"
  ftp = new PromiseSftp()
  now = Date.now()

  # path containers that are populated below
  defaults = {}
  defaults[internals.REFRESH] = '19700101'
  defaults[internals.UPDATE] = '19700101'
  defaults[internals.NO_NEW_DATA_FOUND] = '19700101'

  # dates for which we've processed blackknight files are tracked in keystore
  keystore.getValuesMap(internals.BLACKKNIGHT_COPY_DATES, defaultValues: defaults)
  .then (copyDates) ->
    # establish ftp connection to blackknight
    externalAccounts.getAccountInfo('blackknight')
    .then (accountInfo) ->
      ftp.connect
        host: accountInfo.url
        user: accountInfo.username
        password: accountInfo.password
        autoReconnect: true
      .catch (err) ->
        if err.level == 'client-authentication'
          throw new SoftFail('FTP authentication error')
        else
          throw err

    .then () ->

      # REFRESH paths/files for tax, deed, and mortgage
      refreshPromise = internals.findNewFolders(ftp, internals.REFRESH, copyDates)
      .then (newFolders) ->
        # sort to help us get oldest date...
        drops = Object.keys(newFolders).sort()
        refresh = newFolders[drops[0]]
        # track the dates we got here and send out the tax/deed/mortgage paths
        copyDates[internals.REFRESH] = refresh.date
        return [refresh.tax.path, refresh.deed.path, refresh.mortgage.path]

      # UPDATE paths/files for tax, deed, and mortgage
      updatePromise = internals.findNewFolders(ftp, internals.UPDATE, copyDates)
      .then (newFolders) ->
        # sort to help us get oldest date...
        drops = Object.keys(newFolders).sort()
        update = newFolders[drops[0]]
        # track the dates we got here and send out the tax/deed/mortgage paths
        copyDates[internals.UPDATE] = update.date
        return [update.tax.path, update.deed.path, update.mortgage.path]


      # concat the paths from both sources
      Promise.join(refreshPromise, updatePromise)
      .then ([refreshPaths, updatePaths]) ->
        return refreshPaths.concat updatePaths

    # expect a list of 6 paths here, for one date of processing
    .then (paths) ->

      console.log "paths:\n#{JSON.stringify(paths,null,2)}"

      # traverse each path...
      Promise.each paths, (path) ->
        console.log "path:\n#{path}"
        ftp.list(path)
        .then (files) ->
          console.log "files:\n#{JSON.stringify(files,null,2)}"

          # traverse each file....
          Promise.each files, (file) ->
            console.log "file:\n#{JSON.stringify(file,null,2)}"
            fullpath = "#{path}/#{file.name}"
            #fullpath = "/Managed_Refresh/ASMT20160404/metadata_asmt.txt"
            if !file.size
              return

            console.log "fullpath: #{fullpath}"
            # setup input ftp stream
            logger.debug () -> "copying blackknight file #{fullpath}"
            ftp.get(fullpath)
            .then (ftpStream) -> new Promise (resolve, reject) ->

              ftpStream.on 'error', (ftperr) ->
                console.log "ftp err: #{ftperr}"
                reject(err)

              # ftpStream.on 'data', (d) ->
              #   console.log "got data... #{d}"

              ftpStream.on 'end', (end) ->
                console.log "ftpStream ended"



              # procure writable aws stream
              config =
                extAcctName: awsService.buckets.BlackknightData
                Key: fullpath.substring(1) # omit leading slash
                ContentType: 'text/plain'
              awsService.upload(config)
              .then (upload) ->
                console.log "got upload service"
                upload.on 'error', (err) ->
                  console.log "err: #{err}"
                  reject(err)

                # upload.on 'data', (d) ->
                #   console.log "upload got data"

                upload.on 'uploaded', resolve

                ftpStream.pipe(upload)
            .catch (err) -> # catches ftp errors
              throw new SoftFail("SFTP error while copying #{fullpath}: #{err}")

    .then () ->
      # save off dates
      keystore.setValuesMap(copyDates, namespace: internals.BLACKKNIGHT_COPY_DATES)
    .then () ->
      ftp.logout()


checkFtpDrop = (subtask) ->
  console.log "\n\n\n\n##########\ncheckFtpDrop()"
  console.log "subtask:\n#{JSON.stringify(subtask,null,2)}"
  ftp = new PromiseSftp()
  defaults = {}
  defaults[internals.REFRESH] = '19700101'
  defaults[internals.UPDATE] = '19700101'
  defaults[internals.NO_NEW_DATA_FOUND] = '19700101'
  now = Date.now()
  keystore.getValuesMap(internals.BLACKKNIGHT_PROCESS_DATES, defaultValues: defaults)
  .then (processDates) ->
    console.log "processDates:\n#{JSON.stringify(processDates,null,2)}"


####################################
    # processInfo = {dates: processDates}
    # processInfo[internals.REFRESH] = []
    # processInfo[internals.UPDATE] = []
    # processInfo[internals.DELETE] = []

    # tableIds = Object.keys(internals.tableIdMap)
    # console.log "tableIds: #{JSON.stringify(tableIds)}"

    # Promise.each tableIds, (tableId) ->
    #   console.log "\n\n\nprocessing tableId #{tableId}"
    #   configRefresh =
    #     extAcctName: awsService.buckets.BlackknightData
    #     Prefix: "Managed_Refresh/#{tableId}#{processDates.Refresh}"
    #   configUpdate =
    #     extAcctName: awsService.buckets.BlackknightData
    #     Prefix: "Managed_Update/#{tableId}#{processDates.Update}"

    #   console.log "configRefresh:\n#{JSON.stringify(configRefresh,null,2)}"
    #   console.log "configUpdate:\n#{JSON.stringify(configUpdate,null,2)}"

    #   Promise.join(awsService.listObjects(configRefresh), awsService.listObjects(configUpdate))
    #   .then ([refreshPaths, updatePaths]) ->
    #     console.log "refreshPaths.Contents[0..2]:\n#{JSON.stringify(refreshPaths.Contents[0..2],null,2)}"
    #     console.log "updatePaths.Contents[0..2]:\n#{JSON.stringify(updatePaths.Contents[0..2],null,2)}"
    #   .catch (err) ->
    #     console.log "err: #{err}"




    # fileObj =
    #   type: internals.tableIdMap[tableId]
    #   action: 



    # awsService.listObjects(config)
    # .then (data) ->
    #   console.log "data:\n#{JSON.stringify(data,null,2)}"



####################################







    externalAccounts.getAccountInfo('blackknight')
    .then (accountInfo) ->
      ftp.connect
        host: accountInfo.url
        user: accountInfo.username
        password: accountInfo.password
        autoReconnect: true
      .catch (err) ->
        if err.level == 'client-authentication'
          throw new SoftFail('FTP authentication error')
        else
          throw err
    .then () ->
      internals.findNewFolders(ftp, internals.REFRESH, processDates)
    .then (newFolders) ->
      internals.findNewFolders(ftp, internals.UPDATE, processDates, newFolders)
    .then (newFolders) ->
      drops = Object.keys(newFolders).sort()  # sorts by date, with Refresh before Update
      if drops.length == 0
        logger.info "No new blackknight directories to process"
        console.log "No new blackknight directories to process"
      else
        logger.debug "Found #{drops.length} blackknight dates to process"
        console.log "Found #{drops.length} blackknight dates to process"
      processInfo = {dates: processDates}
      processInfo[internals.REFRESH] = []
      processInfo[internals.UPDATE] = []
      processInfo[internals.DELETE] = []
      internals.checkDropChain(ftp, processInfo, newFolders, drops, 0)



####################################
# processInfo:
# {
#   "dates": {
#     "no new data found": "20160729",
#     "Refresh": "20160405",
#     "Update": "20160405"
#   },
#   "Refresh": [],
#   "Update": [
#     {
#       "path": "/Managed_Update/ASMT20160405",
#       "type": "tax",
#       "date": "20160405",
#       "action": "Update",
#       "name": "12021_Assessment_Update_20160405.txt.gz"
#     },
#     {
#       "path": "/Managed_Update/Deed20160405",
#       "type": "deed",
#       "date": "20160405",
#       "action": "Update",
#       "name": "12021_Deed_Update_20160405.txt.gz"
#     },
#     {
#       "path": "/Managed_Update/SAM20160405",
#       "type": "mortgage",
#       "date": "20160405",
#       "action": "Update",
#       "name": "12021_SAM_Update_20160405.txt.gz"
#     }
#   ],
#   "Delete": [
#     {
#       "path": "/Managed_Update/ASMT20160405",
#       "type": "tax",
#       "date": "20160405",
#       "action": "Update",
#       "name": "Assessment_Update_Delete_20160405.txt"
#     },
#     {
#       "path": "/Managed_Update/Deed20160405",
#       "type": "deed",
#       "date": "20160405",
#       "action": "Update",
#       "name": "Deed_Update_Delete_20160405.txt"
#     },
#     {
#       "path": "/Managed_Update/SAM20160405",
#       "type": "mortgage",
#       "date": "20160405",
#       "action": "Update",
#       "name": "SAM_Update_Delete_20160405.txt"
#     }
#   ],
#   "hasFiles": true
# }





  .then (processInfo) ->
    console.log "\n####################################################################################################################################"
    console.log "processInfo:\n#{JSON.stringify(processInfo,null,2)}"
    ftpEnd = ftp.end()
    # this transaction is important because we don't want the subtasks enqueued below to start showing up as available
    # on their queue out-of-order; normally, subtasks enqueued by another subtask won't be considered as available
    # until the current subtask finishes, but the checkFtpDrop subtask is on a different queue than those being
    # enqueued, and that messes with it.  We could probably fix that edge case, but it would have a steep performance
    # cost, so instead I left it as a caveat to be handled manually (like this) the few times it arises
    dbs.transaction 'main', (transaction) ->
      if processInfo.hasFiles
        deletes = internals.queuePerFileSubtasks(transaction, subtask, processInfo[internals.DELETE], internals.DELETE)
        refresh = internals.queuePerFileSubtasks(transaction, subtask, processInfo[internals.REFRESH], internals.REFRESH, now)
        update = internals.queuePerFileSubtasks(transaction, subtask, processInfo[internals.UPDATE], internals.UPDATE, now)
        activate = jobQueue.queueSubsequentSubtask({transaction, subtask, laterSubtaskName: "activateNewData", manualData: {deletes: dataLoadHelpers.DELETE.INDICATED, startTime: now}, replace: true})
        fileProcessing = Promise.join refresh, update, deletes, activate, (refreshFips, updateFips) ->
          fipsCodes = _.extend(refreshFips, updateFips)
          console.log "-------fipsCodes-------:\n#{JSON.stringify(fipsCodes)}"
          normalizedTablePromises = []
          for fipsCode of fipsCodes
            # ensure normalized data tables exist -- need all 3 no matter what types we have data for
            normalizedTablePromises.push dataLoadHelpers.ensureNormalizedTable(internals.TAX, fipsCode)
            normalizedTablePromises.push dataLoadHelpers.ensureNormalizedTable(internals.DEED, fipsCode)
            normalizedTablePromises.push dataLoadHelpers.ensureNormalizedTable(internals.MORTGAGE, fipsCode)
          Promise.all(normalizedTablePromises)
      else
        fileProcessing = Promise.resolve()
      dates = jobQueue.queueSubsequentSubtask({transaction, subtask, laterSubtaskName: 'saveProcessDates', manualData: {dates: processInfo.dates}, replace: true})
      Promise.join ftpEnd, fileProcessing, dates, () ->  # empty handler


loadRawData = (subtask) ->
  console.log "\n\nloadRawData()"
  console.log "subtask:\n#{JSON.stringify(subtask,null,2)}"
  internals.getColumns(subtask.data.fileType, subtask.data.action, subtask.data.dataType)
  .then (columns) ->
    countyHelpers.loadRawData subtask,
      dataSourceId: 'blackknight'
      columnsHandler: columns
      delimiter: '\t'
      sftp: true
  .then (numRows) ->
    console.log "numRows: #{numRows}"
    mergeData =
      rawTableSuffix: subtask.data.rawTableSuffix
      dataType: subtask.data.dataType
      action: subtask.data.action
      normalSubid: subtask.data.normalSubid
    if subtask.data.fileType == internals.DELETE
      laterSubtaskName = "deleteData"
      numRowsToPage = subtask.data?.numRowsToPageDelete || internals.NUM_ROWS_TO_PAGINATE
    else
      laterSubtaskName = "normalizeData"
      mergeData.startTime = subtask.data.startTime
      numRowsToPage = subtask.data?.numRowsToPageNormalize || internals.NUM_ROWS_TO_PAGINATE

    jobQueue.queueSubsequentPaginatedSubtask({subtask, totalOrList: numRows, maxPage: numRowsToPage, laterSubtaskName, mergeData})


saveProcessDates = (subtask) ->
  keystore.setValuesMap(subtask.data.dates, namespace: internals.BLACKKNIGHT_PROCESS_DATES)


deleteData = (subtask) ->
  normalDataTable = tables.normalized[subtask.data.dataType]
  dataLoadHelpers.getRawRows(subtask)
  .then (rows) ->
    Promise.each rows, (row) ->
      if row['FIPS Code'] != '12021'
        Promise.resolve()
      else if subtask.data.action == internals.REFRESH
        # delete the entire FIPS, we're loading a full refresh
        normalDataTable(subid: row['FIPS Code'])
        .where
          data_source_id: 'blackknight'
          fips_code: row['FIPS Code']
        .whereNull('deleted')
        .update(deleted: subtask.batch_id)
      else if subtask.data.dataType == internals.TAX
        # get validation for parcel_id
        dataLoadHelpers.getValidationInfo('county', 'blackknight', subtask.data.dataType, 'base', 'parcel_id')
        .then (validationInfo) ->
          Promise.props(_.mapValues(validationInfo.validationMap, validation.validateAndTransform.bind(null, row)))
        .then (normalizedData) ->
          normalDataTable(subid: row['FIPS Code'])
          .where
            data_source_id: 'blackknight'
            fips_code: row['FIPS Code']
            parcel_id: normalizedData.parcel_id
          .update(deleted: subtask.batch_id)
      else
        # get validation for data_source_uuid
        dataLoadHelpers.getValidationInfo('county', 'blackknight', subtask.data.dataType, 'base', 'data_source_uuid')
        .then (validationInfo) ->
          Promise.props(_.mapValues(validationInfo.validationMap, validation.validateAndTransform.bind(null, row)))
        .then (normalizedData) ->
          normalDataTable(subid: row['FIPS Code'])
          .where
            data_source_id: 'blackknight'
            fips_code: row['FIPS Code']
            data_source_uuid: normalizedData.data_source_uuid
          .update(deleted: subtask.batch_id)


normalizeData = (subtask) ->
  dataLoadHelpers.normalizeData subtask,
    dataSourceId: 'blackknight'
    dataSourceType: 'county'
    buildRecord: countyHelpers.buildRecord


# not used as a task since it is in normalizeData
# however this makes finalizeData accessible via the subtask script
finalizeDataPrep = (subtask) ->
  {normalSubid} = subtask.data
  if !normalSubid?
    throw new SoftFail "normalSubid required"

  tables.normalized.tax(subid: normalSubid)
  .select('rm_property_id')
  .then (results) ->
    jobQueue.queueSubsequentPaginatedSubtask {
      subtask,
      totalOrList: _.pluck(results, 'rm_property_id')
      maxPage: 100
      laterSubtaskName: "finalizeData"
      mergeData:
        normalSubid: normalSubid
    }

finalizeData = (subtask) ->
  Promise.map subtask.data.values, (id) ->
    countyHelpers.finalizeData({subtask, id})


ready = () ->
  # don't automatically run if digimaps is running
  tables.jobQueue.taskHistory()
  .where
    current: true
    name: 'digimaps'
  .whereNull('finished')
  .then (results) ->
    if results?.length
      # found an instance of digimaps, GTFO
      return false

    # if we didn't bail above, do some other special logic for efficiency
    defaults = {}
    defaults[internals.REFRESH] = '19700101'
    defaults[internals.UPDATE] = '19700101'
    defaults[internals.NO_NEW_DATA_FOUND] = '19700101'
    keystore.getValuesMap(internals.BLACKKNIGHT_PROCESS_DATES, defaultValues: defaults)
    .then (processDates) ->
      today = moment.utc().format('YYYYMMDD')
      yesterday = moment.utc().subtract(1, 'day').format('YYYYMMDD')
      dayOfWeek = moment.utc().isoWeekday()
      if processDates[internals.NO_NEW_DATA_FOUND] != today
        # needs to run using regular logic
        return undefined
      else if dayOfWeek == 7 || dayOfWeek == 1
        # Sunday or Monday, because drops don't happen at the end of Saturday and Sunday
        keystore.setValue(internals.NO_NEW_DATA_FOUND, today, namespace: internals.BLACKKNIGHT_PROCESS_DATES)
        .then () ->
          return false
      else if processDates[internals.REFRESH] == yesterday && processDates[internals.UPDATE] == yesterday
        # we've already processed yesterday's data
        keystore.setValue(internals.NO_NEW_DATA_FOUND, today, namespace: internals.BLACKKNIGHT_PROCESS_DATES)
        .then () ->
          return false
      else
        # no overrides, needs to run using regular logic
        return undefined


recordChangeCounts = (subtask) ->
  dataLoadHelpers.recordChangeCounts(subtask, {deletesTable: 'combined'})


subtasks = {
  copyFtpDrop
  checkFtpDrop
  loadRawData
  deleteData
  normalizeData
  recordChangeCounts
  finalizeDataPrep
  finalizeData
  activateNewData: dataLoadHelpers.activateNewData
  saveProcessDates
}
module.exports = new TaskImplementation('blackknight', subtasks, ready)
