_ = require 'lodash'
through = require 'through'
through2 = require 'through2'
logger = require '../config/logger'
{toGeoFeature} = require './util.geomToGeoJson'
{Readable} = require 'stream'
split = require 'split'


class StringStream extends Readable
  constructor: (@str) ->
    super()

  _read: (size) ->
    @push @str
    @push null


pgStreamEscape = (str) ->
  str
  .replace(/\\/g, '\\\\')
  .replace(/\n/g, '\\n')
  .replace(/\r/g, '\\r')


geoJsonFormatter = (toMove, deletes) ->
  prefixWritten = false
  rm_property_ids = {}
  lastBuffStr = null

  write = (row) ->
    if !prefixWritten
      @queue new Buffer('{"type": "FeatureCollection", "features": [')
      prefixWritten = true

    return if rm_property_ids[row.rm_property_id] #GTFO
    rm_property_ids[row.rm_property_id] = true
    row = toGeoFeature row,
      toMove: toMove
      deletes: deletes

    #hold off on adding to buffer so we know it has a next item to add ','
    if lastBuffStr
      @queue new Buffer lastBuffStr + ','

    lastBuffStr = JSON.stringify(row)

  end = () ->
    if lastBuffStr
      @queue new Buffer lastBuffStr
    @queue new Buffer(']}')
    @queue null#tell through we're done

  through(write, end)


delimitedTextToObjectStream = (inputStream, delimiter, columnsHandler) ->
  count = 0
  splitStream = split()
  doPreamble = true

  if !columnsHandler
    columnsHandler = (headers) -> headers.split(delimiter)  # generic handler

  onError = (err) ->
    outputStream.write(type: 'error', payload: err)
  lineHandler = (line, encoding, callback) ->
    if !line
      # hide empty lines
      return callback()
    if doPreamble
      doPreamble = false
      this.push(type: 'delimiter', payload: delimiter)
      if !_.isArray(columnsHandler)
        columns = columnsHandler(line)
        this.push(type: 'columns', payload: columns)
        return callback()
      this.push(type: 'columns', payload: columnsHandler)
    count++
    this.push(type: 'data', payload: line)
    callback()

  inputStream.on('error', onError)
  splitStream.on('error', onError)
  outputStream = through2.obj lineHandler, (callback) ->
    this.push(type: 'done', payload: count)
    callback()
  inputStream.pipe(splitStream).pipe(outputStream)


module.exports =
  pgStreamEscape: pgStreamEscape
  geoJsonFormatter: geoJsonFormatter
  StringStream: StringStream
  delimitedTextToObjectStream: delimitedTextToObjectStream
