frontendRoutes = require '../../../common/config/routes.frontend.coffee'
app = require '../app.coffee'
qs = require 'qs'
httpStatus = require '../../../common/utils/httpStatus.coffee'
commonConfig = require '../../../common/config/commonConfig.coffee'
escapeHtml = require 'escape-html'

app.factory 'RedirectInterceptor'.ourNs(), [ '$location', '$rootScope',
  ($location, $rootScope) ->
    'response': (response) ->
      if response.data?.doLogin and $location.path() != '/'+frontendRoutes.login
        $rootScope.principal?.unsetIdentity()
        $location.url frontendRoutes.login+'?'+qs.stringify(next: $location.path()+'?'+qs.stringify($location.search()))
      response
]
.config ['$httpProvider', ($httpProvider) ->
  $httpProvider.interceptors.push 'RedirectInterceptor'.ourNs()
]

app.factory 'AlertInterceptor'.ourNs(), [ '$rootScope', '$q', 'events'.ourNs(),
  ($rootScope, $q, Events) ->
    defineNull = (value) ->
      return if typeof value == 'undefined' then null else value
    handle = (response, error=false) ->
      if response.config?.alerts == false
        # we're explicitly not supposed to show an alert for this request according to the frontend
        return response
      if response.data?.alert?
        if !response.data?.alert
          # alert is a falsy value, that means we're explicitly not supposed to show an alert according to the backend
          return response
        # yay!  the backend wants us to show an alert!
        $rootScope.$emit Events.alert.spawn, response.data?.alert
      else if error && response.status != 0  # status==0 is weird conditions that we probably don't want the user to see
        alert =
          id: "#{response.status}-#{response.config?.url?.split('?')[0].split('#')[0]}"
          msg: commonConfig.UNEXPECTED_MESSAGE escapeHtml(JSON.stringify(status: defineNull(response.status), data:defineNull(response.data)))
        $rootScope.$emit Events.alert.spawn, alert
      return response
    'response': handle
    'responseError': (response) -> $q.reject(handle(response, true))
    'requestError': (request) ->
      if request.alerts == false
        # we're explicitly not supposed to show an alert for this request according to the frontend
        return $q.reject(request)
      alert =
        id: "request-#{request.url?.split('?')[0].split('#')[0]}"
        msg: commonConfig.UNEXPECTED_MESSAGE escapeHtml(JSON.stringify(url:defineNull(request.status)))
      $rootScope.$emit Events.alert.spawn, alert
      $q.reject(request)
]
.config ['$httpProvider', ($httpProvider) ->
  $httpProvider.interceptors.push 'AlertInterceptor'.ourNs()
]

app.factory 'LoadingIconInterceptor'.ourNs(), [ '$q', 'Spinner'.ourNs(),
  ($q, Spinner) ->
    'request': (request) ->
      Spinner.incrementLoadingCount(request.url)
      request
    'requestError': (rejection) ->
      Spinner.decrementLoadingCount(rejection.url)
      $q.reject(rejection)
    'response': (response) ->
      Spinner.decrementLoadingCount(response.config?.url)
      response
    'responseError': (rejection) ->
      Spinner.decrementLoadingCount(rejection.config?.url)
      $q.reject(rejection)
]
.config ['$httpProvider', ($httpProvider) ->
  $httpProvider.interceptors.push 'LoadingIconInterceptor'.ourNs()
]
