{DIGIMAPS} = require '../../../backend/config/config'
rewire = require 'rewire'
svc = rewire '../../../backend/services/service.parcels.fetcher.digimaps'
Promise = require 'bluebird'
{StringStream} = require '../../../backend/utils/util.streams'

describe 'service.digimaps', ->
    beforeEach ->
        @subject = svc
        currentDir = null
        @mockFtpClient =
            cwdAsync: (dirName) ->
                currentDir = dirName
                Promise.resolve dirName
            pwdAsync: ->
                Promise.resolve dirName
            listAsync: sinon.stub().returns Promise.resolve [
                    {name:'DMP_DELIVERY_20141011'}
                    {name:'DMP_DELIVERY_20150108'}
                    {name:'DMP_DELIVERY_20150519'}
                    {name:'DMP_DELIVERY_20150208'}
                ]
            getAsync: (fileName) -> Promise.try ->
                console.log "currentDir: #{currentDir}"
                if currentDir.indexOf('ZIPS') != -1
                    return new StringStream(fileName)
                return new StringStream('Does not exist!')

    it 'getParcelZipFileStream', (done) ->
        @subject.getParcelZipFileStream(123, '/ZIPS',Promise.resolve @mockFtpClient)
        .then (stream) ->
            str = ''
            stream.on 'data', (buf)->
                str += String(buf)
            stream.on 'end', ->
                expect(str).to.be.eql('Parcels_123.zip')
                done()
        .catch (err) ->
            throw err
            done()
