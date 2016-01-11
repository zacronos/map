app = require '../app.coffee'

module.exports = app

app.controller 'rmapsProjectsCtrl', ($rootScope, $scope, $http, $state, $log, $modal, rmapsprincipal, rmapsProjectsService, rmapsevents) ->
  $scope.activeView = 'projects'
  $log = $log.spawn("frontend:map:projects")
  $log.debug 'projectsCtrl'

  $scope.projects = []
  $scope.newProject = {}

  $scope.archiveProject = (project, evt) ->
    evt.stopPropagation()
    rmapsProjectsService.archive project

  $scope.addProject = () ->
    $scope.newProject = {}

    modalInstance = $modal.open
      animation: true
      scope: $scope
      template: require('../../html/views/templates/modals/addProjects.jade')()

    $scope.cancelModal = () ->
      modalInstance.dismiss('cancel')

    $scope.saveProject = () ->
      modalInstance.dismiss('save')
      rmapsProjectsService.createProject $scope.newProject

  $scope.loadMap = (project) ->
    $state.go 'map', project_id: project.id, {reload: true}

  $scope.loadProjects = () ->
    rmapsProjectsService.getProjects()
    .then (projects) ->
      $scope.projects = projects
    .catch (error) ->
      $log.error error

  $rootScope.registerScopeData () ->
    $scope.loadProjects()

  # When a project is added elsewhere, this event will fire
  $rootScope.$onRootScope rmapsevents.principal.profile.add, (event, identity) ->
    $scope.loadProjects()

