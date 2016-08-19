{should, expect}= require('chai')
should()
# sinon = require 'sinon'
Promise = require 'bluebird'
logger = require('../../specUtils/logger').spawn('util.mlsHelpers.internals')
rewire = require 'rewire'
subject = rewire "../../../backend/tasks/util.mlsHelpers.internals"
SqlMock = require '../../specUtils/sqlMock.coffee'
mlsPhotoUtil = require '../../../backend/utils/util.mls.photos'

describe 'util.mlsHelpers.internals', ->

  # See SqlMock.coffee for explanation of blockToString
  photo = new SqlMock('finalized', 'photo', blockToString: true)

  tableMocks =
    finalized:
      photo: () -> photo

  subject.__set__ 'tables', tables

  beforeEach ->
    photo.resetSpies()

  describe 'makeInsertPhoto', ->

    it 'cdnPhotoStr defined', (done) ->
      data_source_id = 'data_source_id'
      data_source_uuid = 'uuid'
      listingRow = {data_source_id, data_source_uuid}
      cdnPhotoStr = 'http://cdn.com'
      jsonObjStr = JSON.stringify crap: 'crap'
      imageId = 'imageId'
      photo_id = 'photo_id'

      queryString = subject.makeInsertPhoto {
        listingRow
        cdnPhotoStr
        jsonObjStr
        imageId
        photo_id
        doReturnStr: true
        table: tableMocks.finalized.photo
      }

      tableMocks.finalized.photo().whereSpy.callCount.should.equal 1
      tableMocks.finalized.photo().whereSpy.args[0][0].should.deep.equal listingRow

      tableMocks.finalized.photo().rawSpy.callCount.should.equal 1
      tableMocks.finalized.photo().rawSpy.args[0][0].should.equal("jsonb_set(photos, '{#{imageId}}', ?, true)")
      tableMocks.finalized.photo().rawSpy.args[0][1].should.equal(jsonObjStr)

      tableMocks.finalized.photo().updateSpy.callCount.should.equal 1
      tableMocks.finalized.photo().updateSpy.args[0][0].photos.should.be.ok
      tableMocks.finalized.photo().updateSpy.args[0][0].cdn_photo.should.equal(cdnPhotoStr)

      done()

    it 'cdnPhotoStr undefined', (done) ->
      data_source_id = 'data_source_id'
      data_source_uuid = 'uuid'
      listingRow = {data_source_id, data_source_uuid}
      jsonObjStr = JSON.stringify crap: 'crap'
      imageId = 'imageId'
      photo_id = 'photo_id'

      queryString = subject.makeInsertPhoto {
        listingRow
        jsonObjStr
        imageId
        photo_id
        doReturnStr: true
        table: tableMocks.finalized.photo
      }

      expect(tableMocks.finalized.photo().updateSpy.args[0][0].cdn_photo).to.be.undefined

      done()

    it 'use a real cdnPhotoStr', (done) ->
      data_source_id = 'data_source_id'
      data_source_uuid = 'uuid'
      listingRow = {data_source_id, data_source_uuid}
      jsonObjStr = JSON.stringify crap: 'crap'
      imageId = 'imageId'
      photo_id = 'photo_id'

      cdnPhotoStrPromise = mlsPhotoUtil.getCndPhotoShard {
        newFileName: 'crap.jpg'
        listingRow
        shardsPromise: Promise.resolve
          one:
            id: 0
            url: 'cdn1.com'
          two:
            id: 1
            url: 'cdn2.com'
      }

      cdnPhotoStrPromise
      .then (cdnPhotoStr) ->

        queryString = subject.makeInsertPhoto {
          listingRow
          jsonObjStr
          imageId
          photo_id
          doReturnStr: true
          cdnPhotoStr
          table: tableMocks.finalized.photo
        }

        tableMocks.finalized.photo().whereSpy.callCount.should.equal 1
        tableMocks.finalized.photo().whereSpy.args[0][0].should.deep.equal listingRow

        tableMocks.finalized.photo().rawSpy.callCount.should.equal 1
        tableMocks.finalized.photo().rawSpy.args[0][0].should.equal("jsonb_set(photos, '{#{imageId}}', ?, true)")
        tableMocks.finalized.photo().rawSpy.args[0][1].should.equal(jsonObjStr)

        tableMocks.finalized.photo().updateSpy.callCount.should.equal 1
        tableMocks.finalized.photo().updateSpy.args[0][0].photos.should.be.ok
        tableMocks.finalized.photo().updateSpy.args[0][0].cdn_photo.should.equal(cdnPhotoStr)

        done()
