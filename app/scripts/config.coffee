app = require './app.coffee'

#Setting HTML5 Location Mode
app.config ['$locationProvider',
($locationProvider) -> $locationProvider.html5Mode(true)
]

module.exports =
  app.config ['$routeProvider',
  ($routeProvider) ->
    $routeProvider
    .when '/users',
      templateUrl: 'views/users.html'
      controller: 'UserCtrl'.ourNs()
    .when '/',
      templateUrl: 'views/main.html'
      controller: 'MainCtrl'.ourNs()
    .when '/500',
      templateUrl: 'views/500.html'
    .when '/404',
      templateUrl: 'views/404.html'
    .otherwise
      redirectTo: '/404'
  ]
