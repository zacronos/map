app = require '../../app.coffee'
module.exports = app

app.controller 'rmapsUserMLSCtrl', ($scope, $log, rmapsMlsService) ->
  $log = $log.spawn("map:userMLS")

  $scope.mlses = []

  rmapsMlsService.getForUser()
  .then (res) ->
    $scope.mlses = res
