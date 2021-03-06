app = require '../app.coffee'
frontendRoutes = require '../../../../common/config/routes.frontend.coffee'
_ = require 'lodash'


# for documentation, see the following:
#   https://github.com/angular-ui/ui-router/wiki/Nested-States-%26-Nested-Views
#   https://github.com/angular-ui/ui-router/wiki
stateDefaults =
  sticky: false
  loginRequired: true
  persist: false

module.exports = app.config (
  $stateProvider,
  $stickyStateProvider,
  $uiViewScrollProvider,
  $urlRouterProvider,
  rmapsOnboardingOrderServiceProvider,
  rmapsOnboardingProOrderServiceProvider,

  rmapsRouteIdentityResolve,
  rmapsRouteProfileResolve
) ->

  $uiViewScrollProvider.useAnchorScroll()

#  $stickyStateProvider.enableDebug(true)

  baseState = (name, overrides = {}) ->
    state =
      name:         name
      parent:       'main'
      url:          frontendRoutes[name],
      #controller:   "rmaps#{name.toInitCaps()}Ctrl"
      controller:   "rmaps#{name[0].toUpperCase()}#{name.substr(1)}Ctrl" # we can have CamelCase yay!
    _.extend(state, overrides)
    _.defaults(state, stateDefaults)

    # Scroll To param
    state.params ?= {}
    state.params.scrollTo = null

    # Evaluate resolves
    if state.loginRequired
      state.resolve = state.resolve or {}

      # Add a resolve for the current Identity to injectable 'currentIdentity'
      if !state.resolve.currentIdentity
        state.resolve.currentIdentity = rmapsRouteIdentityResolve

      # Add a resolve for the current or requested profile to injectable 'currentProfile'
      if !state.resolve.currentProfile
        state.resolve.currentProfile = rmapsRouteProfileResolve

    return state

  appendTemplateProvider = (name, state) ->
    if !state.template && !state.templateProvider && !state.templateUrl
      state.templateProvider = ($templateCache) ->
        "ngInject"
        templateName = if state.parent == 'main' or state.parent is null then "./views/#{name}.jade" else "./views/#{state.parent}/#{name}.jade"
        $templateCache.get templateName

  createView = (name, state, viewName = name) ->
    state.views = {}
    state.views["#{viewName}@#{state.parent}"] =
      templateProvider: state.templateProvider
      template: state.template
      controller: state.controller
    delete state.template
    delete state.controller

  buildMapState = (overrides = {}) ->
    name = 'map'
    state = baseState name, overrides
    appendTemplateProvider name, state
    createView name, state, 'main-map'

    # Set the page type
    state.pageType = 'map'

    $stateProvider.state(state)
    state

  buildModalState = (name, overrides = {}) ->
    state = baseState name, overrides
    appendTemplateProvider name, state
    createView name, state, 'main-modal'

    # Set the page type
    state.pageType = 'modal'

    $stateProvider.state(state)
    state

  buildState = (name, overrides = {}) ->
    state = baseState name, overrides
    appendTemplateProvider name, state

    if state.parent
      createView name, state, 'main-page'

    # Set the page type
    state.pageType = state.pageType or 'page'#could already be set from overrides

    $stateProvider.state(state)
    state

  buildChildState = (name, parent, overrides = {}) ->
    state = baseState name, overrides
    state.parent = parent

    appendTemplateProvider name, state
    $stateProvider.state(state)
    state

  buildState('main', parent: null, url: frontendRoutes.index, loginRequired: false, permissionsRequired: false)

  buildMapState(
    sticky: true
    reloadOnSearch: false
    projectParam: 'project_id'
    params:
      project_id:
        value: null
        squash: true
      property_id:
        value: null
        squash: true
      area_id:
        value: null
        squash: false
  )

  buildState 'onboarding',
    abstract: true
    url: frontendRoutes.onboarding
    loginRequired: false
    permissionsRequired: false

  buildChildState 'onboardingPlan', 'onboarding',
    loginRequired: false
    permissionsRequired: false
    showSteps: false

  rmapsOnboardingOrderServiceProvider.steps.forEach (boardingName) ->
    buildChildState boardingName, 'onboarding',
      url: '/' + (rmapsOnboardingOrderServiceProvider.getId(boardingName) + 1)
      loginRequired: false
      permissionsRequired: false
      showSteps: true

  rmapsOnboardingProOrderServiceProvider.steps.forEach (boardingName) ->
    buildChildState boardingName + 'Pro', 'onboarding',
      controller: "rmaps#{boardingName[0].toUpperCase()}#{boardingName.substr(1)}Ctrl"
      url: '/pro/' + (rmapsOnboardingProOrderServiceProvider.getId(boardingName) + 1)
      templateProvider: ($templateCache) ->
        "ngInject"
        $templateCache.get "./views/onboarding/#{boardingName}.jade"
      loginRequired: false
      permissionsRequired: false
      showSteps: true

  buildState 'snail'
  buildState 'user'
  buildChildState 'userMLS', 'user', {page: { title: 'MLS' }, permissionsRequired: "isMLS"}
  buildChildState 'userSubscription', 'user', page: { title: 'Subscription' }
  buildChildState 'userNotifications', 'user', page: { title: 'Notifications' }
  buildChildState 'userPaymentHistory', 'user', page: { title: 'Payment History' }

  buildState 'clientEntry',
    #parent: null
    loginRequired: false
    permissionsRequired: false
    sticky: false

  buildState 'passwordReset',
    loginRequired: false
    permissionsRequired: false
    sticky: false

  buildState 'profiles'
  buildState 'history'
  buildState 'properties'
  buildModalState 'property', page: { title: 'Property Detail' }
  buildState 'projects', page: { title: 'Projects' }, mobile: { modal: true }

  #
  # Project Dashboard and child pages
  #

  # Project base layout
  buildState 'projectBase',
    projectParam: 'id',
    abstract: true
    controller: 'rmapsProjectCtrl',
    template: "<div id='project-base-state' ui-view rmaps-require-subscriber-or-viewer='omit,modalNow'></div>"
    page: { title: 'Project', dynamicTitle: true },
    mobile: { modal: true },
    resolve:
      currentProject: ($stateParams, rmapsProjectsService) ->
        "ngInject"
        return rmapsProjectsService.getProject $stateParams.id

  # Project dashboard
  buildChildState 'project', 'projectLayout',
    projectParam: 'id',
    page: { title: 'Project', dynamicTitle: true },
    controller: null,
    templateUrl: './views/project.jade'

  # Project child layout
  buildChildState 'projectLayout', 'projectBase',
    projectParam: 'id',
    abstract: true,
    controller: null,
    templateUrl: './views/project/projectLayout.jade',

  # Project child states
  buildChildState 'projectClients', 'projectLayout', projectParam: 'id', page: { title: 'My Clients' }, templateUrl: './views/project/projectClients.jade'
  buildChildState 'projectNotes', 'projectLayout', controller: 'rmapsProjectNotesCtrl', projectParam: 'id', page: { title: 'Notes' }, templateUrl: './views/project/projectNotes.jade'
  buildChildState 'projectFavorites', 'projectLayout', controller: 'rmapsProjectFavoritesCtrl', projectParam: 'id', page: { title: 'Favorites' }, templateUrl: './views/project/projectFavorites.jade'
  buildChildState 'projectAreas', 'projectLayout', projectParam: 'id', page: { title: 'Areas' }, templateUrl: './views/project/projectAreas.jade'
  buildChildState 'projectPins', 'projectLayout', controller: 'rmapsProjectPinsCtrl', projectParam: 'id', page: { title: 'Pinned Properties' }, templateUrl: './views/project/projectPins.jade'

  buildState 'mail', profileRequired: false
  buildState 'mailWizard',
    abstract: true

  buildChildState 'selectTemplate', 'mailWizard'
  buildChildState 'editTemplate', 'mailWizard'
  buildChildState 'campaignInfo', 'mailWizard'
  buildChildState 'recipientInfo', 'mailWizard', params: {property_ids: null}
  buildChildState 'review', 'mailWizard'

  buildState 'login', template: require('../../../common/html/login.jade'), sticky: false, loginRequired: false
  buildState 'logout', url: null, sticky: false, loginRequired: false
  buildState 'accessDenied', controller: null, sticky: false, loginRequired: false

  # this one has to be last, since it is a catch-all
  buildState 'pageNotFound', controller: null, sticky: false, loginRequired: false

  $urlRouterProvider.when '', frontendRoutes.index

#
# Log errors in Resolves
#
app.run ($rootScope, $log) ->
  $log = $log.spawn "ui-router"
  $rootScope.$on '$stateChangeError', (event, toState, toParams, fromState, fromParams, error) ->
    $log.error "State change error: ", error
