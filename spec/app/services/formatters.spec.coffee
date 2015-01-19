testScope = 'FormattersService'

describe testScope, ->
  beforeEach ->
    angular.mock.module 'app'.ourNs()
    angular.mock.module 'uiGmapgoogle-maps.mocks'
    angular.mock.module 'uiGmapgoogle-maps'

    angular.mock.inject ['GoogleApiMock', (GoogleApiMock) =>
      @apiMock = new GoogleApiMock()
      @apiMock.mockAPI()
      @apiMock.mockLatLng()
      @apiMock.mockMarker()
      @apiMock.mockEvent()
    ]

    inject ['$rootScope', testScope.ourNs(),
      ($rootScope, Formatters) =>
        @$rootScope = $rootScope
        @subject = Formatters
    ]

  it 'subject can be created', ->
    @subject.should.be.ok

  describe 'Common', ->
    beforeEach ->
      @tempSubject = @subject
      @subject = @subject.Common
    afterEach ->
      @subject = @tempSubject

    describe 'intervals', ->
      it '2 units result', ->
        @subject.humanizeDays(600).should.equal "about 1 year, 8 months"
        @subject.humanizeDays(61).should.equal "2 months, 1 day"
        @subject.humanizeDays(59).should.equal "1 month, 29 days"
        @subject.humanizeDays(332).should.equal "11 months, 2 days"
        @subject.humanizeDays(0).should.equal "less than 1 day"
      it '1 unit result', ->
        @subject.humanizeDays(732).should.equal "about 2 years"
