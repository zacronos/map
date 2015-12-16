app = require '../app.coffee'
backendRoutes = require '../../../../common/config/routes.backend.coffee'

app.config(($provide) ->
  #recommended way of dealing with clean up of angular communication channels
  #http://stackoverflow.com/questions/11252780/whats-the-correct-way-to-communicate-between-controllers-in-angularjs
  $provide.decorator '$rootScope', ($delegate) ->
    Object.defineProperty $delegate.constructor::, '$onRootScope',
      value: (name, listener) ->
        unsubscribe = $delegate.$on(name, listener)
        @$on '$destroy', unsubscribe
        unsubscribe

      enumerable: false

    $delegate
)
.config(($validationProvider, rmapsMainOptions) ->
  {validation} = rmapsMainOptions
  $validationProvider.setErrorHTML (msg) ->
    return "<label class=\"control-label has-error\">#{msg}</label>"
  _.extend $validationProvider,
    # figure out how to do this without jQuery
    validCallback: (element) ->
      #attempt w/o jQuery
      maybeParent = _.first(element.parentsByClass('form-group', true))
      if maybeParent?
        maybeParent.className = maybeParent.className.replace('has-error', '')

      #expected
      #$(element).parents('.form-group:first').removeClass('has-error')
    invalidCallback: (element) ->
      maybeParent = _.first(element.parentsByClass('form-group', true))
      if maybeParent?
        maybeParent.className += ' has-error'
      #parents('.form-group:first').addClass('has-error')
)
.run(($validation, rmapsMainOptions, $http) ->

  {validation} = rmapsMainOptions

  expression =
    password: validation.password
    phone: validation.phone
    optPhone: (value, scope, element, attrs, param) ->
      return true unless value
      #optional URL
      !!value.match(validation.phone)?.length
    address: validation.address
    zipcode: validation.zipcode.US
    optUrl: (value, scope, element, attrs, param) ->
      return true unless value
      #optional URL
      !!value.match(validation.url)?.length
    optNumber: (value, scope, element, attrs, param) ->
      return true unless value
      #optional URL
      !!value.match(validation.number)?.length
    optMinlength: (value, scope, element, attrs, param) ->
      return true unless value
      value.length >= param;
    optMaxlength: (value, scope, element, attrs, param) ->
      return true unless value
      value.length <= param;
    checkUniqueEmail: (value) ->
      $http.post(backendRoutes.userSession.emailIsUnique, email: value)

  defaultMsg =
    password:
      error: 'Password does not meet minimum requirements! 8 min chars, 1 Capital, 1 Lower, 1 Special Char, and no repeating chars more than twice!'
    required:
      error: 'Required!!'
    url:
      error: 'Invlaid Url!'
    optUrl:
      error: 'Invlaid Url!'
    email:
      error: 'Invlaid Email!'
    checkUniqueEmail:
      error: 'Email must be unique!'
    number:
      error: 'Invlaid Number!'
    optNumber:
      error: 'Invlaid Number!'
    minlength:
      error: 'This should be longer'
    optMinlength:
      error: 'This should be longer'
    maxlength:
      error: 'This should be shorter'
    optMaxlength:
      error: 'This should be shorter'
    phone:
      error: 'Invlaid phone number!'
    optPhone:
      error: 'Invlaid phone number!'
    address:
      error: 'Invalid addess.'
    zipcode:
      error: 'Invalid US zipcode.'

  $validation.setExpression(expression).setDefaultMsg(defaultMsg)
)
