describe "BaseGoogleMap", ->
  beforeEach ->
    #console.info "beforeEach ->"


    angular.mock.module 'app'.ourNs()
    angular.mock.module "google-maps.mocks"
    angular.mock.module "google-maps".ns()

    #console.info "beforeEach.after modules"
    angular.mock.inject ['GoogleApiMock', (GoogleApiMock) =>
      @apiMock = new GoogleApiMock()
      @apiMock.mockAPI()
      @apiMock.mockLatLng()
      @apiMock.mockMarker()
      @apiMock.mockEvent()
    ]

    #console.info "after GoogleApiMock"
    @mocks =
      options:
        json:
          center:
            latitude: 90.0
            longitude: 89.0
          zoom: 3
      zoomThresholdMilli: 1000

    inject ["$rootScope", 'BaseGoogleMap'.ourNs(),
     ($rootScope, BaseGoogleMap) =>
        #console.log "$rootScope: ", $rootScope
        @$rootScope = $rootScope

        @ctor = BaseGoogleMap
        @subject = new BaseGoogleMap(
          $rootScope.$new(), @mocks.options, @mocks.zoomThresholdMilli
        )
    ]
  it 'ctor exists', ->
    @ctor.should.be.ok

  it 'subject can be created', ->
    @subject.should.beok
