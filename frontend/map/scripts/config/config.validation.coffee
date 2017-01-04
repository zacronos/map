app = require '../app.coffee'
backendRoutes = require '../../../../common/config/routes.backend.coffee'
_ = require 'lodash'


app.config(($provide, $validationProvider) ->
  _removeError = (element) ->
    element.className = element.className.replace(/has\-error/g, '') if element?

  $validationProvider.setErrorHTML (msg) ->
    return "<label class=\"control-label has-error\">#{msg}</label>"

  $provide.decorator '$validation', ($delegate) ->
    # figure out how to do this without jQuery
    $delegate.validCallback = (element) ->
      #attempt w/o jQuery
      element.parentsByClass('form-group', true).forEach (ele) ->
        _removeError ele

    $delegate.invalidCallback = (element) ->
      element.parentsByClass('form-group', true).forEach (ele) ->
        ele.className += ' has-error' if ele?
    $delegate

)
.run ($validation, rmapsMainOptions, $http) ->
  {validation} = rmapsMainOptions

  expression =
    email: validation.email
    password: validation.password
    phone: validation.phone
    realtymapsEmail: validation.realtymapsEmail
    address: validation.address
    zipcode: validation.zipcode.US

    nullify: (value, scope, element, attrs, param) ->
      if !value
        _.set(scope, attrs.ngModel, null)
      return true

    optPhone: (value, scope, element, attrs, param) ->
      return true unless value
      validation.phone.test(value)

    optUrl: (value, scope, element, attrs, param) ->
      return true unless value
      validation.url.test(value)

    optNumber: (value, scope, element, attrs, param) ->
      return true unless value
      validation.number.test(value)

    optMinlength: (value, scope, element, attrs, param) ->
      return true unless value
      value.length >= param

    optMaxlength: (value, scope, element, attrs, param) ->
      return true unless value
      value.length <= param

    optAddress: (value, scope, element, attrs, param) ->
      return true unless value
      validation.address.test(value)

    optZipcode: (value, scope, element, attrs, param) ->
      return true unless value
      validation.zipcode.US.test(value)

    #NOTE: all your doing here is validating the email regex on the backend
    # You could just use angular validation or validate the email regex above (email: validation.email).
    checkValidEmail: (value, scope, element, attrs, param) ->
      config =
        alerts: param != 'disableAlert'
      $http.post(backendRoutes.email.isValid, email: value, config)

    ###
    Do not be mistaken; this also checks if the email is valid!

    If the calling user is logged in and own the unqiue email address then everything passes.
    However, if the user is not logged in and the email is not unique then the route should fail.
    ###
    checkUniqueEmail: (value, scope, element, attrs, param) ->
      config =
        alerts: param != 'disableAlert'
      $http.post(backendRoutes.email.isValid, {email: value, doUnique: true}, config)

    checkUniqueEmailLoggedIn: (value, scope, element, attrs, param) ->
      config =
        alerts: param != 'disableAlert'
      $http.post(backendRoutes.email.isValidLoggedIn, {email: value, doUnique: true}, config)

    checkValidMlsAgent: (value, scope, element, attrs, param) ->
      $http.post(backendRoutes.mls.activeAgent, scope[param], {alerts: false})


  defaultMsg =
    password:
      error: 'Password does not meet requirements: minimum length 10, at least 1 lowercase, 1 capital, 1 number.'
    required:
      error: 'Required'
    url:
      error: 'Invalid Url'
    optUrl:
      error: 'Invalid Url'
    email:
      error: 'Invalid Email'
    realtymapsEmail:
      error: "Email must be of the '@realtymaps.com' domain"
    checkValidEmail:
      error: 'Invalid Email'
    checkUniqueEmailLoggedIn:
      error: 'Email must be unique'
    checkUniqueEmail:
      error: 'Email must be unique'
    checkValidMlsAgent:
      error: 'MLS ID not found or active.'
    number:
      error: 'Invalid Number'
    optNumber:
      error: 'Invalid Number'
    minlength:
      error: 'This should be longer'
    optMinlength:
      error: 'This should be longer'
    maxlength:
      error: 'This should be shorter'
    optMaxlength:
      error: 'This should be shorter'
    phone:
      error: 'Invalid phone number'
    optPhone:
      error: 'Invalid phone number'
    address:
      error: 'Invalid address'
    optAddress:
      error: 'Invalid address'
    zipcode:
      error: 'Invalid US zipcode'
    optZipcode:
      error: 'Invalid US zipcode'
    nullify:
      error: 'unable to nullify'

  $validation.setExpression(expression).setDefaultMsg(defaultMsg)
