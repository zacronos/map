app = require '../../app.coffee'

#
# USAGE:
#
#   property-images(property="propertyScopeVar" imageWidth="400" imageHeight="300")
#

app.directive 'propertyImages', (
  $log,
  $timeout,
  rmapsPropertyFormatterService,
  rmapsResultsFormatterService,
) ->
  restrict: 'EA'
  templateUrl: './includes/directives/property/_propertyImagesDirective.jade'
  scope:
    propertyParent: '=property'
    imageWidth: '@imageWidth'
    imageHeight: '@imageHeight'

  controller: ($scope) ->
    $log = $log.spawn 'propertyImagesDirective'
    $log.debug $scope.propertyParent

    $scope.formatters = {
      results: new rmapsResultsFormatterService  scope: $scope
      property: new rmapsPropertyFormatterService()
    }

    if $scope.propertyParent
      $scope.property = angular.copy($scope.propertyParent)
    else
      $log.error("Property Images Directive was not passed a Property")

    imageLoaded = (event, img) ->
      $timeout ->
        $scope.imageLoaded = true
        $scope.$evalAsync()
      , 50

    photos = []
    if $scope.property.cdn_photo && $scope.property.photo_count
      resizeUrl = $scope.property.cdn_photo
      if resizeUrl.slice(0,4) != "http"
        resizeUrl = "http://#{resizeUrl}"

      # uncomment to load photos locally
      resizeUrl = $scope.property.cdn_photo.replace($scope.property.cdn_photo.split('/')[0], '')

      if $scope.imageWidth
        resizeUrl += "&width=#{$scope.imageWidth}"
      if $scope.imageHeight
        resizeUrl += "&height=#{scope.imageHeight}"

      # Skip the first image, it is expected to be a duplicate
      for i in [1..$scope.property.photo_count]
        photos.push
          key: i
          url: "#{resizeUrl}&image_id=#{i}"
    else
      imageLoaded()

    $scope.property.photos = photos
    $log.debug $scope.property.photos

    $scope.$on 'imageLoaded', imageLoaded