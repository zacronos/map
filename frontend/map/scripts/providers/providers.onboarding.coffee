_ = require 'lodash'
app = require '../app.coffee'

app.provider 'rmapsOnboardingOrderService', (rmapsMainOptions) ->
  class OnBoardingOrder
    constructor: (@steps = [
      'onboardingPayment'
      'onboardingLocation'
      'onboardingFinishYay'
    ], @name = '', @submitStepName = 'onboardingLocation') ->
      @clazz = OnBoardingOrder
      @submitStepName += @name.toInitCaps()

    inBounds: (id) ->
      id >= 0 and id < @steps.length

    getStep: (id) ->
      if @inBounds id
        return @steps[id]

    #appends the name of the OnBordingOrder to the current step
    #useful since state name onboardingPaymentPro -> OnBordingProOrder.onboardingPayment
    getStepName: (id) =>
      @getStep(id) + @name.toInitCaps()

    getId: (name) =>
      name = name.replace(new RegExp(@name,'ig'),'')
      @steps.indexOf name

    getNextStep: (name, direction = 1) ->
      currentId = @getId name
      nextStepId = currentId + direction
      if @inBounds nextStepId
        @getStepName nextStepId

    getPrevStep: (name) ->
      @getNextStep name, -1

    $get: ->
      @

  new OnBoardingOrder()

app.provider 'rmapsOnboardingProOrderService', (rmapsOnboardingOrderServiceProvider, rmapsMainOptions) ->
  new rmapsOnboardingOrderServiceProvider.clazz [
    'onboardingPayment'
    'onboardingLocation'
    'onboardingFinishYay'
  ], rmapsMainOptions.subscription.PLAN.PRO, 'onboardingLocation'

app.provider 'rmapsOnboardingOrderSelectorService', (rmapsOnboardingOrderServiceProvider, rmapsOnboardingProOrderServiceProvider, rmapsMainOptions) ->
  @getPlanFromState = ($state) ->
    return unless $state
    if RegExp(rmapsMainOptions.subscription.PLAN.PRO, "i").test($state.current.name)
      rmapsMainOptions.subscription.PLAN.PRO

  @getOrderSvc = (plan) =>
    if !_.isString plan
      plan = @getPlanFromState(plan)# then plan should be $state
    if plan == rmapsMainOptions.subscription.PLAN.PRO
      return rmapsOnboardingProOrderServiceProvider
    rmapsOnboardingOrderServiceProvider

  @initScope = (plan, $scope) ->
    $scope.orderSvc = @getOrderSvc(plan)
    $scope.view.steps = $scope.orderSvc.steps
    $scope

  @$get = =>
    @
  @
