app = require '../app.coffee'
_ = require 'lodash'


app.directive 'rmapsMacroEventHelper', ($rootScope, $log, $timeout, textAngularManager) ->
  restrict: 'A'
  require: 'ngModel'
  link: (scope, element, attrs, ngModel) ->
    scope.mousex = 0
    scope.mousey = 0

    element.bind 'dragover', (e) ->
      scope.mousex = e.clientX
      scope.mousey = e.clientY

    element.on 'keyup', (e) ->
      update = () ->
        scope.macroAction.whenTyped e
        ngModel.$commitViewValue()
        ngModel.$render()

      scope.$evalAsync update

    $timeout ->
      scope.editor = textAngularManager.retrieveEditor 'wysiwyg'
      scope.editor.scope.$on 'rmaps-drag-end', (e, opts) ->
        scope.macroAction.whenDropped e

    $rootScope.$on 'rmaps-drag-end', (e) ->
      scope.editor.editorFunctions.focus()
      # percolate drag end event down so the editor hears it
      scope.editor.scope.$broadcast 'rmaps-drag-end'


app.directive 'rmapsMacroHelper', ($log, $rootScope, $timeout, $window, $document) ->
  restrict: 'A'
  require: 'ngModel'
  link: (scope, element, attrs, ngModel) ->
    _doc = $document[0]

    # convert existing macros that aren't already styled
    $timeout ->
      ngModel.$setViewValue scope.convertMacros()
      ngModel.$render()

    # wrap the macro markup within a textnode in a span that can be styled
    scope.convertMacrosInSpan = (textnode, offset, macro, exchange=false) ->
      range = rangy.createRange()
      range.setStart textnode, offset
      if exchange
        range.setEnd textnode, offset+macro.length
        range.deleteContents()
      el = angular.element "<span>#{macro}</span>"
      scope.setMacroClass el[0]
      range.insertNode el[0]

    # determine if the node has been flagged as macro span (whether valid or not), by class
    # this is *not* macro validation
    scope.isMacroNode = (node) ->
      classedNode = if node.nodeType == 3 then node.parentNode else node
      # this regex accounts for classname with/without "-error" flag
      return /macro-display/.test(classedNode.className)

    # macro or not?
    scope.validateMacro = (macro) ->
      return _.contains(_.map(scope.macros), macro)

    # apply correct class to a new or existing macro node
    scope.setMacroClass = (node) ->
      if node.nodeType == 3
        classedNode = node.parentNode
        macro = node.data
      else
        classedNode = node
        macro = node.childNodes[0].data

      if scope.validateMacro macro
        if classedNode.classList.contains 'macro-display-error'
          classedNode.classList.remove 'macro-display-error'
        classedNode.classList.add 'macro-display'
      else
        if classedNode.classList.contains 'macro-display'
          classedNode.classList.remove 'macro-display'
        classedNode.classList.add 'macro-display-error'

    # generic recursive tree walker
    # provide collection, containerName, and a test function with a process function to run on child if test passes
    scope.walk = (collection, containerName, test, process) ->
      for child in collection
        if test(child)
          process(child)
        if containerName of child and child[containerName].length > 0
          scope.walk child[containerName], containerName, test, process

    # convert unwrapped macro-markup into spans
    scope.convertMacros = () ->
      # DOM-ize our letter content for easier traversal/processing
      content = ngModel.$viewValue
      letterDoc = new DOMParser().parseFromString(content, 'text/html')

      # helper func passed to 'walk'
      _test = (n) ->
        return n?.nodeType == 3 && not scope.isMacroNode(n) && /{{.*?}}/.test(n.data)

      # helper func passed to 'walk'
      # pulls macro-markup from data of text node to convert to styled macro
      _process = (n) ->
        re = new RegExp(/{{(.*?)}}/g)
        # js list push/pop acts like lifo queue, useful here to process last child first (from behind)
        # since the element changes as we pass
        conversions = []
        s = n.data
        while m = re.exec(s)
          conversions.push [n, m.index, m[0]]
        while p = conversions.pop()
          scope.convertMacrosInSpan p[0], p[1], p[2], true

      # apply test and processing to DOM-ized letter...
      scope.walk letterDoc.childNodes, 'childNodes', _test, _process

      # return the resulting content
      letterDoc.documentElement.innerHTML


    # filter selected node for macros
    scope.macroFilter = (sel) ->
      # make macro span if it needs
      if /{{.*?}}/.test(sel.focusNode.data)
        if not scope.isMacroNode(sel.focusNode)
          offset = sel.focusNode.data.indexOf('{{')
          macro = sel.focusNode.data.substring offset, sel.focusNode.data.indexOf('}}')+2
          scope.convertMacrosInSpan sel.focusNode, offset, macro, true

        # trim/clean data
        sel.focusNode.data = sel.focusNode.data.trim()

    scope.caretFromPoint = () ->
      # http://stackoverflow.com/questions/2444430/how-to-get-a-word-under-cursor-using-javascript
      if _doc.caretPositionFromPoint
        range = _doc.caretPositionFromPoint scope.mousex, scope.mousey
        textNode = range.offsetNode
        offset = range.offset
      else if _doc.caretRangeFromPoint
        range = _doc.caretRangeFromPoint scope.mousex, scope.mousey
        textNode = range.startContainer
        offset = range.startOffset
      return {range, textNode, offset}

    # act on macros when events occur
    scope.macroAction =
      whenDropped: (e) ->
        scope.editor.editorFunctions.focus() # make sure editor has focus on drop
        sel = $window.getSelection()
        e.targetScope.displayElements.text[0].focus()
        {range, textNode, offset} = scope.caretFromPoint()

        # macro-ize markup
        scope.convertMacrosInSpan textNode, offset, scope.macro

      whenTyped: (e) ->
        sel = rangy.getSelection()
        # while typing, filter for macros and wrap if necessary
        scope.macroFilter(sel)

        # alter macro class depending on validity of macro
        if sel?.focusNode?.data? and scope.isMacroNode sel.focusNode
          scope.setMacroClass sel.focusNode

    # keep templateObj updated with bound htmlcontent
    scope.$watch 'data.htmlcontent', (newC, oldC) ->
      scope.templateObj.mailCampaign.content = scope.data.htmlcontent

    # helper for holding a macro value during drag-and-drop
    scope.setMacro = (macro) ->
      scope.macro = macro


app.directive 'rmapsMailTemplateLayout', ($log, $rootScope, $timeout, $window, $document) ->
  restrict: 'EA'
  transclude: false,
  template: require('../../html/views/templates/mail-sel-tpl-layout.tpl.jade')()
  scope:
    templatesArray: "="
  #require: 'ngModel'
  link: (scope, element, attrs, ngModel) ->
    $log.debug "#### rmapsMailTemplateLayout"
    $log.debug "scope:"
    $log.debug scope
    $log.debug "element:"
    $log.debug element
    $log.debug "attrs:"
    $log.debug attrs
    $log.debug "ngModel:"
    $log.debug ngModel


