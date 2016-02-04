###global _:true###
app = require '../app.coffee'
frontendRoutes = require '../../../../common/config/routes.frontend.coffee'
# for documentation, see the following:
#   https://github.com/angular-ui/ui-router/wiki/Nested-States-%26-Nested-Views
#   https://github.com/angular-ui/ui-router/wiki

stateDefaults =
  sticky: false
  loginRequired: true

module.exports = app.config ($stateProvider, $stickyStateProvider, $urlRouterProvider,
rmapsOnboardingOrderServiceProvider, rmapsOnboardingProOrderServiceProvider) ->

  baseState = (name, overrides = {}) ->
    state =
      name:         name
      parent:       'main'
      url:          frontendRoutes[name],
      #controller:   "rmaps#{name.toInitCaps()}Ctrl"
      controller:   "rmaps#{name[0].toUpperCase()}#{name.substr(1)}Ctrl" # we can have CamelCase yay!
    _.extend(state, overrides)
    _.defaults(state, stateDefaults)

    return state

  appendTemplateProvider = (name, state) ->
    if !state.template && !state.templateProvider
      state.templateProvider = ($templateCache) ->
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
    state.pageType = 'page'

    $stateProvider.state(state)
    state

  buildState 'main', parent: null, url: frontendRoutes.index, loginRequired: false
  buildMapState
    sticky: true,
    reloadOnSearch: false,
    params:
      project_id:
        value: null
        squash: true
      property_id:
        value: null
        squash: true

  buildState 'onboarding',
    abstract: true
    url: frontendRoutes.onboarding
    loginRequired: false
    permissionsRequired: false

  buildState 'onboardingPlan',
    parent: 'onboarding'
    loginRequired: false
    permissionsRequired: false
    showSteps: false

  rmapsOnboardingOrderServiceProvider.steps.forEach (boardingName) ->
    buildState boardingName,
      parent: 'onboarding'
      url: '/' + (rmapsOnboardingOrderServiceProvider.getId(boardingName) + 1)
      loginRequired: false
      permissionsRequired: false
      showSteps: true

  rmapsOnboardingProOrderServiceProvider.steps.forEach (boardingName) ->
    buildState boardingName + 'Pro',
      parent: 'onboarding'
      controller: "rmaps#{boardingName[0].toUpperCase()}#{boardingName.substr(1)}Ctrl"
      url: '/pro/' + (rmapsOnboardingProOrderServiceProvider.getId(boardingName) + 1)
      templateProvider: ($templateCache) ->
        $templateCache.get "./views/onboarding/#{boardingName}.jade"
      loginRequired: false
      permissionsRequired: false
      showSteps: true

  buildState 'snail'
  buildState 'user'
  buildState 'profiles'
  buildModalState 'history'
  buildState 'properties'
  buildModalState 'projects', page: { title: 'Projects' }, mobile: { modal: true }
  buildModalState 'project', page: { title: 'Project', dynamicTitle: true }, mobile: { modal: true }
  buildModalState 'projectClients', parent: 'project', page: { title: 'My Clients' }, mobile: { modal: true }
  buildModalState 'projectNotes', parent: 'project', page: { title: 'Notes' }, mobile: { modal: true }
  buildModalState 'projectFavorites', parent: 'project', page: { title: 'Favorites' }, mobile: { modal: true }
  buildModalState 'projectNeighbourhoods', parent: 'project', page: { title: 'Neighborhoods' }, mobile: { modal: true }
  buildModalState 'projectPins', parent: 'project', page: { title: 'Pinned Properties' }, mobile: { modal: true }
  buildState 'neighbourhoods'
  buildState 'notes'
  buildState 'favorites'
  buildState 'sendEmailModal'
  buildState 'newEmail'

  buildModalState 'mail'
  buildState 'mailWizard',
    sticky: true

  buildState 'selectTemplate', parent: 'mailWizard'
  buildState 'editTemplate', parent: 'mailWizard'
  buildState 'senderInfo', parent: 'mailWizard'
  buildState 'recipientInfo', parent: 'mailWizard'

  buildState 'login', template: require('../../../common/html/login.jade'), sticky: false, loginRequired: false
  buildState 'logout', sticky: false, loginRequired: false
  buildState 'accessDenied', controller: null, sticky: false, loginRequired: false
  buildState 'authenticating', controller: null, sticky: false, loginRequired: false
  # this one has to be last, since it is a catch-all
  buildState 'pageNotFound', controller: null, sticky: false, loginRequired: false

  $urlRouterProvider.when '', frontendRoutes.index
