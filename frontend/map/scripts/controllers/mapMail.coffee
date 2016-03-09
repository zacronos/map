app = require '../app.coffee'
module.exports = app
backendRoutes = require '../../../../common/config/routes.backend.coffee'

app.controller 'rmapsMailModalCtrl', ($scope, $state, $modal, $log, rmapsPropertiesService, rmapsLayerFormattersService) ->
  $log = $log.spawn 'mail:rmapsMailModalCtrl'
  $log.debug 'MailModalCtrl'

  $scope.addMail = (maybeParcel) ->

    savedProperties = rmapsPropertiesService.getSavedProperties()

    if maybeParcel?
      property_ids = [maybeParcel.rm_property_id]
    else
      property_ids = _.keys savedProperties

    $scope.newMail =
      property_ids: property_ids

    $scope.modalTitle = "Create Mail Campaign"

    if $scope.newMail.property_ids.length
      $scope.modalBody = "Do you want to create a campaign for the #{$scope.newMail.property_ids.length} selected properties?"

      $scope.modalOk = () ->
        modalInstance.dismiss('save')
        $log.debug "$state.go 'recipientInfo'..."
        $state.go 'recipientInfo', {property_ids: $scope.newMail.property_ids}, {reload: true}

      $scope.cancelModal = () ->
        modalInstance.dismiss('cancel')

    else
      $scope.modalBody = "Pin some properties first"

      $scope.modalOk = () ->
        modalInstance.dismiss('cancel')

      $scope.showCancelButton = false

    modalInstance = $modal.open
      animation: true
      scope: $scope
      template: require('../../html/views/templates/modals/confirm.jade')()

app.controller 'rmapsMapMailCtrl', ($scope, $log, rmapsLayerFormattersService, rmapsMailCampaignService) ->
  $log = $log.spawn 'mail:rmapsMapMailCtrl'
  $log.debug 'MapMailCtrl'

  getMail = () ->
    rmapsMailCampaignService.getProjectMail()
    .then (mail) ->
      $log.debug "received mail data #{mail.length} " if mail?.length
      $scope.map.markers.mail = rmapsLayerFormattersService.setDataOptions mail, rmapsLayerFormattersService.MLS.setMarkerMailOptions

  $scope.map.getMail = getMail

  $scope.$watch 'Toggles.showMail', (newVal) ->
    $scope.map.layers.overlays.mail.visible = newVal

  getMail()
