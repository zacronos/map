logger = require('../config/logger').spawn('util.mls.photos')
# retsHelpers = require './util.retsHelpers'
_ = require 'lodash'
Archiver = require 'archiver'
through = require 'through2'

_hasNoStar = (photoIds) ->
  JSON.stringify(photoIds).indexOf('*') == -1

isSingleImage = (photoIds) ->
  if _.isString(photoIds)
    return true
  if _.keys(photoIds).length == 1 and _hasNoStar(photoIds)
    return true
  false

###
  using through2 to return a stream now which eventually has data pushed to it
  via event.dataStream
###
imageStream = (object) ->
  error = null

  #immediate returnable stream
  retStream = through (chunk, enc, callback) ->
    if !chunk && !everSentData
      return callback new Error 'No object events'

    if error?
      return callback(error)

    @push chunk
    callback()

  everSentData = false
  #as data MAYBE comes in push it to the returned stream
  object.objectStream.on 'data', (event) ->
    if event.error
      return error = event.error

    everSentData = true
    event.dataStream.pipe(retStream)

  retStream

imagesHandle = (object, cb) ->
  everSentData = false

  object.objectStream.on 'data', (event) ->
    if !event.error
      logger.debug event.headerInfo

      imageId = event.headerInfo.objectId
      listingId = event.headerInfo.contentId
      fileExt = event.headerInfo.contentType.replace('image/','')
      size = event.headerInfo.objectData.size
      contentType = event.headerInfo.contentType
      uploadDate = event.headerInfo.objectData.uploadDate
      description = event.headerInfo.objectData.description

      everSentData = true
      fileName = "#{listingId}_#{imageId}.#{fileExt}"
      logger.debug "fileName: #{fileName}"
      cb(null, {data: event.dataStream, name: fileName, imageId, size, contentType, uploadDate, description})

  object.objectStream.on 'end', () ->
    if !everSentData
      cb(new Error 'No object events')
    cb(null, null, true)

imagesStream = (object, archive = Archiver('zip')) ->

  archive.on 'error', (err)  ->
    throw err

  imagesHandle object, (err, payload, isEnd) ->
    if(err)
      throw err

    if(isEnd)
      archive.finalize()
      logger.debug("Archive wrote #{archive.pointer()} bytes")
      return

    archive.append(payload.data, name: payload.name)


  archive


hasSameUploadDate = (uploadDate1, uploadDate2, allowNull = false) ->
  if allowNull && !uploadDate1? && !uploadDate2?
    return true

  uploadDate1? && uploadDate2? &&
    (new Date(uploadDate1)).getTime() == (new Date(uploadDate2)).getTime()

module.exports = {
  isSingleImage
  imagesHandle
  imagesStream
  imageStream
  hasSameUploadDate
}
