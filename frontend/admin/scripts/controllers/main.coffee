app = require '../app.coffee'
adminRoutes = require '../../../../common/config/routes.admin.coffee'

module.exports = app.controller 'rmapsMainCtrl', [ '$scope', '$state', ($scope, $state) ->
  $scope.adminRoutes = adminRoutes
  $scope.$state = $state
  console.log "#### main controller"
#  debugger;
]
