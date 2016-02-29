app = require '../../app.coffee'
_ = require 'lodash'
confirmModalTemplate = require('../../../html/views/templates/modals/confirm.jade')()
previewModalTemplate = require('../../../html/views/templates/modal-mailPreview.tpl.jade')()

module.exports = app

app.controller 'rmapsSelectTemplateCtrl', ($rootScope, $scope, $log, $modal, rmapsMailTemplateTypeService) ->
  $log = $log.spawn 'mail:rmapsSelectTemplateCtrl'
  $log.debug 'rmapsSelectTemplateCtrl'

  $scope.displayCategory = 'all'

  $scope.categories = rmapsMailTemplateTypeService.getCategories()
  $scope.categoryLists = rmapsMailTemplateTypeService.getCategoryLists()
  $scope.oldTemplateType = ""
  

  $scope.isEmptyCategory = () ->
    return $scope.displayCategory not of $scope.categoryLists or $scope.categoryLists[$scope.displayCategory].length == 0

  $scope.setCategory = (category) ->
    if !category?
      category = 'all'
    $scope.displayCategory = category

  $scope.selectTemplate = (idx) ->
    templateType = $scope.categoryLists[$scope.displayCategory][idx].type
    $log.debug "Selected template type: #{templateType}"
    $log.debug "Old template type: #{$scope.oldTemplateType}"
    $log.debug "Current campaign template type: #{$scope.wizard.mail.campaign.template_type}"

    if $scope.oldTemplateType != "" and $scope.oldTemplateType != templateType
      modalInstance = $modal.open
        animation: true
        template: confirmModalTemplate
        controller: 'rmapsConfirmCtrl'
        resolve:
          modalTitle: () ->
            return "Confirm template change"
          modalBody: () ->
            return "Selecting a different template will reset your letter content. Are you sure you wish to continue?"

      modalInstance.result.then (result) ->
        $log.debug "Confirmation result: #{result}"
        if result
          $scope.wizard.mail.setTemplateType(templateType)
          $scope.oldTemplateType = $scope.wizard.mail.campaign.templateType

    else
      $scope.wizard.mail.setTemplateType(templateType)

  $scope.previewTemplate = (template) ->
    modalInstance = $modal.open
      template: previewModalTemplate
      controller: 'rmapsMailTemplateIFramePreviewCtrl'
      openedClass: 'preview-mail-opened'
      windowClass: 'preview-mail-window'
      windowTopClass: 'preview-mail-windowTop'
      resolve:
        template: () ->
          content: rmapsMailTemplateTypeService.getHtml(template.type)
          category: template.category
          title: template.name

  $rootScope.registerScopeData () ->
    $scope.ready()
    .then () ->
      $scope.oldTemplateType = $scope.wizard.mail.campaign.template_type


app.controller 'rmapsConfirmCtrl',
  ($scope, modalBody, modalTitle) ->
    $scope.modalBody = modalBody
    $scope.modalTitle = modalTitle
    $scope.showCancelButton = true
    $scope.modalCancel = ->
      $scope.$close(false)
    $scope.modalOk = ->
      $scope.$close(true)

