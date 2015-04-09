tokenize = (input, initPos = 0) ->
  currentPos = initPos
  while input.length > 0
    match = input.match ///
      ^ # must be at the start
      (
        \x20 # space
      | \n # newline
      | [#{controls}] # delims
      | /([^\s]|\\/)([^/]|\\/)*?/ # regex
      | "(?:[^"\\]|\\.)*" # strings
      | \\[^\s][^\s#{controls}]* # char
      | [^#{controls}\\"'\s]+ # normal tokens
      )///
    if not match
      throw new Error "Could not recognize a token starting with `#{input[0..10]}`"
    [symbol] = match
    input = input[symbol.length...]
    start = currentPos
    currentPos += symbol.length
    end = currentPos
    constantLabeling {symbol, start, end}

controls = '\\(\\)\\[\\]\\{\\}'

astize = (tokens, initialDepth = 0) ->
  tree = []
  current = []
  stack = [[]]
  indentAccumulator = []
  for token in tokens
    if token.symbol is ' ' and indentAccumulator?.length < 2 * (initialDepth + stack.length - 1)
      indentAccumulator.push token
    else
      if indentAccumulator?.length > 0
        stack[stack.length - 1].push createIndent indentAccumulator
      indentAccumulator = undefined
      if token.symbol is '\n'
        indentAccumulator = []
      if token.symbol in leftDelims
        form = [token]
        form.start = token.start
        stack.push form
      else if token.symbol in rightDelims
        closed = stack.pop()
        if not stack[stack.length - 1]
          throw new Error "Missing opening delimeter matching #{token.symbol}"
        if token.symbol isnt closeDelimFor[closed[0].symbol]
          throw new Error "Wrong closing delimiter #{token.symbol} for opening delimiter #{closed[0].symbol}"
        closed.push token
        closed.end = token.end
        markFake closed
        stack[stack.length - 1].push closed
      else
        stack[stack.length - 1].push token
  ast = stack[0][0]
  if not ast
    throw new Error "Missing closing delimeter matching #{stack[stack.length - 1][0].symbol}"
  else
    ast

leftDelims = ['(', '[', '{']
rightDelims = [')', ']', '}']
allDelims = [].concat leftDelims, rightDelims
closeDelimFor = '(': ')', '[': ']', '{': '}'

createIndent = (accumulator) ->
  symbol: (new Array accumulator.length + 1).join ' '
  start: accumulator[0].start
  end: accumulator[accumulator.length - 1].end
  label: 'indent'

markFake = (form) ->
  [prev, rest...] = form
  for node in rest
    if (prev.label in ['whitespace', 'indent'] or prev.symbol in leftDelims) and
        (node.label is 'whitespace' or node.symbol in rightDelims)
      node.fake = yes
    prev = node
  return

constantLabeling = (atom) ->
  {symbol} = atom
  labelMapping atom, [
    ['numerical', -> /^~?\d+/.test symbol]
    ['label', -> isLabel atom]
    ['string', -> /^"/.test symbol]
    ['char', -> /^\\/.test symbol]
    ['regex', -> /^\/[^\s\/]/.test symbol]
    ['const', -> /^[A-Z][^\s\.]*$/.test symbol] # TODO: instead label based on context
    ['paren', -> symbol in ['(', ')']]
    ['bracket', -> symbol in ['[', ']']]
    ['brace', -> symbol in ['{', '}']]
    ['whitespace', -> /^\s+$/.test symbol]
  ]

labelMapping = (word, rules) ->
  for [label, cond] in rules when cond()
    word.label = label
    return word
  word

labelOperator = (expression) ->
  if isForm expression
    [open, _..., close] = expression
    open.label = close.label = 'operator'
  else if not isFake expression
    expression.label = 'operator'

crawl = (ast, cb, parent) ->
  if Array.isArray ast
    for node in ast
      crawl node, cb, ast
  else
    cb ast, ast.symbol, parent

visitExpressions = (expression, cb) ->
  cb expression
  if isForm expression
    for term in _terms expression
      visitExpressions term, cb

teas = (fn, string) ->
  ast = astize tokenize string
  compiled = fn (ctx = new Context), ast
  syntax: collapse toHtml ast
  types: values mapMap (__ highlightType, _type), subtractMaps ctx._scope(), builtInDefinitions()
  translation: '\n' + compiled

mapCompile = (fn, string) ->
  fn (new Context), astize tokenize string

mapTyping = (fn, string) ->
  ast = astize tokenize string
  fn (ctx = new Context), ast
  expressions = []
  visitExpressions ast, (expression) ->
    expressions.push "#{collapse toHtml expression} :: #{highlightType expression.tea}" if expression.tea
  types: values mapMap (__ highlightType, _type), subtractMaps ctx._scope(), builtInDefinitions()
  subs: printSubstitution ctx.substitution
  fails: ctx.substitution.fails
  ast: expressions
  deferred: ctx.deferredBindings()

printSubstitution = (sub) ->
  subToObject mapSub highlightType, sub

mapTypingBare = (fn, string) ->
  ast = astize tokenize string
  fn (ctx = new Context), ast
  expressions = []
  visitExpressions ast, (expression) ->
    expressions.push [(collapse toHtml expression), expression.tea] if expression.tea
  types: values mapMap _type, subtractMaps ctx._scope(), builtInDefinitions()
  subs: ctx.substitution
  ast: expressions
  deferred: ctx.deferredBindings()

highlightType = (type) ->
  if type
    typeAst = astize tokenize printType type
    syntaxType typeAst
    collapse toHtml typeAst
  else
    "undefined"

subToObject = (sub) ->
  ob = {}
  for s, i in sub.vars when s
    ob["#{i + sub.start}"] = s
  ob


_type = (declaration) ->
  declaration.type

mapSyntax = (fn, string) ->
  ast = astize tokenize string
  fn (new Context), ast
  collapse toHtml ast

class Context
  constructor: ->
    @_macros = builtInMacros()
    @expand = {}
    @definitions = []
    @_isOperator = []
    @variableIndex = 0
    @typeVariabeIndex = 0
    @nameIndex = 1
    @substitution = emptySubstitution()
    @statement = []
    @cacheScopes = [[]]
    @_assignTos = []
    topScope = @_augmentScope builtInDefinitions(), @scopeIndex = 0
    topScope.typeNames = builtInTypeNames()
    topScope.topLevel = yes
    @scopes = [topScope]
    @savedScopes = []
    @classParams = newMap()
    @isMalformed = no

  macros: ->
    @_macros

  addMacro: (name, macro) ->
    @_macros[name.symbol] = macro
    name.id = macro.id = @freshId()

  markMalformed: ->
    @isMalformed = yes

  # Creates a deferrable definition to be associated with given pattern
  definePattern: (pattern) ->
    if @isDefining()
      throw new Error "already defining, forgot to leaveDefinition?"
    @_scope().definition =
      name: pattern?.symbol
      pattern: pattern
      inside: 0
      late: no
      deferredBindings: []
      definedNames: []
      deferrable: yes
      _defer: undefined

  bareDefine: ->
    @definePattern()

  defineNonDeferrablePattern: (pattern) ->
    definition = @definePattern pattern
    definition.deferrable = no

  leaveDefinition: ->
    @_scope().definition = undefined

  downInsideDefinition: ->
    @_definition()?.inside++

  upInsideDefinition: ->
    @_definition()?.inside--

  # If the current definition's pattern is a name, returns it
  definitionName: ->
    @_definition().name

  definitionPattern: ->
    @_definition().pattern

  _currentDefinition: ->
    @_scope().definition

  _definition: ->
    @_definitionAtScope @scopes.length - 1

  _definitionAtScope: (i) ->
    @scopes[i].definition or i > 0 and (@_definitionAtScope i - 1) or undefined

  _deferrableDefinition: ->
    @_deferrableDefinitionAtScope @scopes.length - 1

  _deferrableDefinitionAtScope: (i) ->
    (def = @scopes[i].definition) and def.deferrable and def or
      i > 0 and (@_deferrableDefinitionAtScope i - 1) or undefined

  isDefining: ->
    !!@_scope().definition

  isAtDefinition: ->
    (definition = @_currentDefinition()) and definition.pattern and definition.inside is 0

  isAtBareDefinition: ->
    (definition = @_currentDefinition()) and definition.inside is 0

  isAtSimpleDefinition: ->
    @isAtDefinition() and @definitionName()

  # isAtDeferrableDefinition: ->
  #   @isAtDefinition() and @_currentDefinition().deferrable

  # isInsideSimpleDefinition: ->
  #   (definition = @_currentDefinition())

  isOperator: ->
    @_isOperator[@_isOperator.length - 1]

  setIsOperator: (isOperator) ->
    @_isOperator.push isOperator

  resetIsOperator: ->
    @_isOperator.pop()

  # Assignment translation works as follows:
  #   1. parent sets assign to
  #   2. patterns look at the assign to value
  #   3. patterns can request caching of the rhs, which will replace the value
  #      with cache name and remember the cache
  #   4. parent resets assign to and obtains the translation cache, if it
  #      expects there could be one
  setAssignTo: (compiled) ->
    @_assignTos.push value: compiled

  assignTo: ->
    @_assignTos[@_assignTos.length - 1]?.value

  cacheAssignTo: ->
    assignTo = @_assignTos[@_assignTos.length - 1]
    if assignTo?.value and not assignTo.cache
      # Replace assignTo with cache name
      cacheName = @newJsVariable()
      cache = [cacheName, @assignTo()]
      @_assignTos[@_assignTos.length - 1] =
        value: cacheName
        cache: cache

  resetAssignTo: ->
    if cache = @_assignTos.pop().cache
      [cache]
    else
      []

  _scope: ->
    @scopes[@scopes.length - 1]

  _parentScope: ->
    @scopes[@scopes.length - 2]

  newScope: ->
    @scopes.push @_augmentScope newMap(), ++@scopeIndex

  _augmentScope: (scope, index) ->
    scope.index = index
    scope.deferred = []
    scope.deferredBindings = []
    scope.boundTypeVariables = newSet()
    scope.classes = newMap()
    scope.typeNames = newMap()
    scope.typeAliases = newMap()
    scope

  newLateScope: ->
    @newScope()
    @_deferrableDefinition()?.late = yes

  closeScope: ->
    closedScope = @scopes.pop()
    @savedScopes[closedScope.index] =
      parent: @scopes[@scopes.length - 1].index
      definitions: cloneMap closedScope

  currentScopeIndex: ->
    @_scope().index

  isInsideLateScope: ->
    @_deferrableDefinition()?.late

  isInTopScope: ->
    @_scope().topLevel

  addTypeName: (dataType) ->
    if dataType instanceof TypeApp
      {name, kind} = dataType.op
    else
      {name, kind} = dataType
    if (lookupInMap @_scope().typeNames, name) instanceof TempKind
      removeFromMap @_scope().typeNames, name
    addToMap @_scope().typeNames, name, kind

  kindOfTypeName: (name) ->
    for scope in (reverse @scopes)
      if kind = lookupInMap scope.typeNames, name
        return kind

  addTypeAlias: (name, type) ->
    addToMap @_scope().typeAliases, name, type

  resolveTypeAliases: (name) ->
    if alias = lookupInMap @_scope().typeAliases, name
      alias
    else
      name

  bindTypeVariables: (vars) ->
    addAllToSet @_scope().boundTypeVariables, vars

  allBoundTypeVariables: ->
    concatSets (for scope in @scopes
      scope.boundTypeVariables)...

  isClassDefined: (name) ->
    !!@_classNamed name

  addClass: (name, classConstraint, superClasses, declarations) ->
    addToMap @_scope().classes, name,
      supers: superClasses
      constraint: classConstraint
      instances: []
      declarations: declarations

  classNamed: (name) ->
    (@_classNamed name) or throw new Error "Class #{name} is not defined"

  _classNamed: (name) ->
    for scope in (reverse @scopes)
      if classDeclaration = lookupInMap scope.classes, name
        return classDeclaration

  addInstance: (name, type) ->
    (@classNamed type.type.type.className).instances.push {name, type}

  isMethod: (name, type) ->
    any (for {className} in type.constraints
      lookupInMap (@classNamed className).declarations, name)

  isDeclared: (name) ->
    !!(@_declaration name)

  isTyped: (name) ->
    !!@type name

  isActuallyTyped: (name) ->
    !!@actualType name

  _declaration: (name) ->
    @_declarationInScope @scopes.length - 1, name

  _declarationInScope: (i, name) ->
    (lookupInMap @scopes[i], name) or
      i > 0 and (@_declarationInScope i - 1, name) or
      undefined # throw "Could not find declaration for #{name}"

  isCurrentlyDeclared: (name) ->
    !!(lookupInMap @_scope(), name)

  assignType: (name, type) ->
    # log "TYPE OF #{name}", printType type
    if declaration = (lookupInMap @_scope(), name)
      if declaration.type and declaration.type not instanceof TempType
        throw new Error "assignType: #{name} already has a type"
      declaration.type = type
    else
      throw new Error "assignType: #{name} is not declared"

  currentDeclarations: ->
    cloneMap @_scope()

  addToDeferredNames: (binding) ->
    @_definition().deferredBindings.push binding

  addToDeferred: (binding) ->
    @_scope().deferredBindings.push binding

  addToDefinedNames: (binding) ->
    @_currentDefinition()?.definedNames?.push binding

  definedNames: ->
    @_currentDefinition()?.definedNames ? []

  deferredNames: ->
    @_definition().deferredBindings

  deferredBindings: ->
    @_scope().deferredBindings

  declareArity: (name, arity) ->
    @declare name, arity: arity

  # Returns whether the declaration was successful (not redundant)
  declare: (name, declaration = {}) ->
    if lookupInMap @_scope(), name
      false
    else
      declaration.id ?= @freshId()
      addToMap @_scope(), name, declaration
      true

  freshId: ->
    @nameIndex++

  declareTypes: (names, types) ->
    for name, i in names
      @declare name, type: types[i]

  type: (name) ->
    (@_declaration name)?.type

  actualType: (name) ->
    (type = @type name) and (type not instanceof TempType) and type

  declarationId: (name) ->
    (@_declaration name)?.id

  arity: (name) ->
    (@_declaration name)?.arity

  freshTypeVariable: (kind) ->
    if not kind
      throw new Error "Provide kind in freshTypeVariable"
    name = (freshName @typeVariabeIndex++)
    new TypeVariable name, kind

  extendSubstitution: (substitution) ->
    @substitution = joinSubs substitution, @substitution

  newJsVariable: ->
    "i#{@variableIndex++}"

  doDefer: (expression, dependencyName) ->
    @_setDeferIn @_deferrableDefinition(), expression, dependencyName

  _setDeferIn: (definition, expression, dependencyName) ->
    definition._defer =
      (@_deferReasonOf definition) or [expression, dependencyName]

  deferReason: ->
    @_deferReasonOf @_deferrableDefinition()

  shouldDefer: ->
    !!(@_deferReasonOf @_deferrableDefinition())

  _deferReasonOf: (definition) ->
    definition?._defer

  addDeferredDefinition: ([expression, dependencyName, lhs, rhs]) ->
    @_scope().deferred.push [expression, dependencyName, lhs, rhs]

  deferred: ->
    @_scope().deferred

  addClassParams: (params) ->
    @classParams = concatMaps @classParams, params

  classParamNameFor: (constraint) ->
    typeMap = @classParamsForType constraint
    if typeMap then lookupInMap typeMap, constraint.className

  classParamsForType: (constraint) ->
    nestedLookupInMap @classParams, typeNamesOfNormalized constraint

  updateClassParams: ->
    @classParams = substituteVarNames this, @classParams

expressionCompile = (ctx, expression) ->
  throw new Error "invalid expressionCompile args" unless ctx instanceof Context and expression?
  compileFn =
    if isFake expression
      fakeCompile
    else if isAtom expression
      atomCompile
    else if isTuple expression
      tupleCompile
    else if isSeq expression
      seqOrMapCompile
    else if isCall expression
      callCompile
  if not compileFn
    malformed ctx, expression, 'not a valid expression'
  else
    compileFn ctx, expression

# -- This was used to use compiled results from some parent macro while
#    compiling as something else
# rememberCompiled = (expression, result) ->
#   expression.compiled = result

# _compiled = (expression) ->
#   expression.compiled

callCompile = (ctx, call) ->
  operator = _operator call
  operatorName = _symbol operator
  if isName operator
    (if operatorName of ctx.macros() and not ctx.arity operatorName
      callMacroCompile
    else if (isFake operator) or (ctx.isDeclared operatorName) and not ctx.arity operatorName
      callUnknownCompile
    else
      callKnownCompile) ctx, call
  else
    expandedOp = termCompile ctx, operator
    if isTranslated expandedOp
      callUnknownTranslate ctx, expandedOp, call
    else
      expressionCompile ctx, replicate call,
        (call_ (join [expandedOp], (_arguments call)))

callMacroCompile = (ctx, call) ->
  op = _operator call
  op.label = 'keyword'
  macro = ctx.macros()[op.symbol]
  op.id = macro.id
  expanded = macro ctx, call
  if isTranslated expanded
    expanded
  else
    expressionCompile ctx, expanded

isTranslated = (result) ->
  (isSimpleTranslated result) or (Array.isArray result) and (isSimpleTranslated result[0])

isSimpleTranslated = (result) ->
  result.js or result.ir

callUnknownCompile = (ctx, call) ->
  callUnknownTranslate ctx, (operatorCompile ctx, call), call

# Also supports functional macros - macros with defined arity
callKnownCompile = (ctx, call) ->
  operator = _operator call
  args = _labeled _arguments call
  labeledArgs = labeledToMap args

  if tagFreeLabels args
    return malformed ctx, call, 'labels without values inside call'

  paramNames = ctx.arity operator.symbol
  if not paramNames
    # log "deferring in known call #{operator.symbol}"
    ctx.doDefer operator, operator.symbol
    return assignCompile ctx, call, deferredExpression()
  positionalParams = filter ((param) -> not (lookupInMap labeledArgs, param)), paramNames
  nonLabeledArgs = map _snd, filter (([label, value]) -> not label), args

  if nonLabeledArgs.length > positionalParams.length
    malformed ctx, call, 'Too many arguments'
  else
    extraParamNames = positionalParams[nonLabeledArgs.length..]
    extraParams = map token_, ("_#{n}" for n in extraParamNames)
    positionalArgs = map id, nonLabeledArgs # copy
    extraArgs = map id, extraParams
    argsInOrder = (for param in paramNames
      (lookupInMap labeledArgs, param) or
        positionalArgs.shift() or
        extraArgs.shift())
    sortedCall = (call_ operator,  argsInOrder)

    if ctx.assignTo()
      if isCapital operator
        if args.length < paramNames.length and nonLabeledArgs.length > 0
          malformed ctx, call, "curried constructor pattern"
        else
          compiled = callConstructorPattern ctx, sortedCall, extraParamNames
          retrieve call, sortedCall
          compiled
      else
        malformed ctx, call, "function patterns not supported"
    else
      if nonLabeledArgs.length < positionalParams.length
        # log "currying known call"
        lambda = (fn_ extraParams, sortedCall)
        compiled = callMacroCompile ctx, lambda
        retrieve call, lambda
        # TODO: massive hack, erase inserted scope, will have to figure out how to fix this better
        ctx.savedScopes[ctx.savedScopes.length - 1].definitions = newMap()
        compiled
      else
        compiled =
          if operator.symbol of ctx.macros()
            callMacroCompile ctx, sortedCall
          else
            callSaturatedKnownCompile ctx, sortedCall
        retrieve call, sortedCall
        compiled

callConstructorPattern = (ctx, call, extraParamNames) ->
  operator = _operator call
  args = _arguments call
  isExtra = (arg) -> (isAtom arg) && (_symbol arg) in extraParamNames
  paramNames = ctx.arity operator.symbol

  if args.length - extraParamNames.length > 1
    ctx.cacheAssignTo()

  compiledArgs = (for arg, i in args when not isExtra arg
    # ctx.setAssignTo "#{ctx.assignTo()}#{jsObjectAccess paramNames[i]}"
    ctx.setAssignTo (jsAccess ctx.assignTo(), paramNames[i])
    elemCompiled = expressionCompile ctx, arg
    ctx.resetAssignTo()
    elemCompiled)

  precsForData = operatorCompile ctx, call

  # Typing operator like inside a known call
  for arg in args when isExtra arg
    arg.tea = toConstrained ctx.freshTypeVariable star

  # Gets the general type as if the extra arguments were supplied
  callTyping ctx, call

  combinePatterns join [precsForData], compiledArgs

callSaturatedKnownCompile = (ctx, call) ->
  operator = _operator call
  args = _arguments call

  compiledOperator = operatorCompile ctx, call

  compiledArgs = termsCompile ctx, args

  callTyping ctx, call

  # "#{compiledOperator}(#{listOf compiledArgs})"
  assignCompile ctx, call, (irCall operator.tea, compiledOperator, compiledArgs)

labeledToMap = (pairs) ->
  labelNaming = ([label, value]) -> [(_labelName label), value]
  newMapKeysVals (unzip map labelNaming, filter all, pairs)...

tagFreeLabels = (pairs) ->
  freeLabels = filter (([label, value]) -> not value), pairs
  # Free labels not supported now inside calls
  freeLabels.map (label) -> label.label = 'malformed'
  return freeLabels.length > 0

operatorCompile = (ctx, call) ->
  ctx.setIsOperator yes
  ctx.downInsideDefinition()
  compiledOperator = expressionCompile ctx, _operator call
  ctx.upInsideDefinition()
  ctx.resetIsOperator()
  compiledOperator

callUnknownTranslate = (ctx, translatedOperator, call) ->
  args = _arguments call


  argList = if ctx.shouldDefer()
    deferredExpression()
  else
    termsCompile ctx, args

  callTyping ctx, call
  # "_#{args.length}(#{translatedOperator}, #{argList})"
  assignCompile ctx, call,
    (jsCall "_#{args.length}", (join [translatedOperator], argList))

callTyping = (ctx, call) ->
  return if ctx.shouldDefer()
  terms = _terms call
  if terms.length is 1
    malformed ctx, call, 'Missing an argument (for now)'
    terms = join terms, [tea: toConstrained ctx.freshTypeVariable star]
  call.tea = callInfer ctx, terms

callInfer = (ctx, terms) ->
  # Curry the call
  if terms.length > 2
    [subTerms..., lastArg] = terms
    callInferSingle ctx, (callInfer ctx, subTerms), lastArg.tea
  else
    [op, arg] = terms
    callInferSingle ctx, op.tea, arg.tea

callInferSingle = (ctx, operatorTea, argTea) ->
  returnType = ctx.freshTypeVariable star
  unify ctx, operatorTea.type, (typeFn argTea.type, returnType)
  new Constrained (join operatorTea.constraints, argTea.constraints), returnType

termsCompile = (ctx, list) ->
  termCompile ctx, term for term in list

termCompile = (ctx, term) ->
  ctx.downInsideDefinition()
  ctx.setIsOperator no
  compiled = expressionCompile ctx, term
  ctx.resetIsOperator()
  ctx.upInsideDefinition()
  compiled

expressionsCompile = (ctx, list) ->
  expressionCompile ctx, expression for expression in list

tupleCompile = (ctx, form) ->
  elems = _terms form
  arity = elems.length
  if arity > 1
    ctx.cacheAssignTo()

  compiledElems =
    if ctx.assignTo()
      for elem, i in elems
        # "#{ctx.assignTo()}[#{i}]"
        ctx.setAssignTo (jsAccess ctx.assignTo(), "#{i}")
        elemCompiled = expressionCompile ctx, elem
        cache = ctx.resetAssignTo()
        precs: elemCompiled.precs
        assigns: cache.concat elemCompiled.assigns or []
    else
      termsCompile ctx, elems
  # TODO: could support partial tuple application via bare labels
  #   map [0: "hello" 1:] {"world", "le mond", "svete"}
  # TODO: should we support bare records?
  #   [a: 2 b: 3]
  if not ctx.shouldDefer()
    form.tea = tupleOfTypes map _tea, elems

  if ctx.assignTo()
    combinePatterns compiledElems
  else
    (labelOperator form)
    # "[#{listOf compiledElems}]"
    assignCompile ctx, form, (jsArray compiledElems)

seqOrMapCompile = (ctx, form) ->
  elems = _terms form
  (if (_notEmpty elems) and isLabel elems[0]
    hashmapCompile
  else
    seqCompile) ctx, form

seqCompile = (ctx, form) ->
  elems = _validTerms form
  size = elems.length
  if size > 1
    ctx.cacheAssignTo()

  if sequence = ctx.assignTo()
    hasSplat = no
    requiredElems = 0
    for elem in elems
      if isSplat elem
        hasSplat = yes
      else
        requiredElems++

    if hasSplat and requiredElems is 0
      return malformed ctx, form, 'Matching with splat requires at least one element name'

    compiledArgs = (for elem, i in elems
      [lhs, rhs] =
        if isSplat elem
          elem.label = 'name'
          [(splatToName elem), (jsCall "seq_splat", [i, elems.length - i - 1, sequence])]
        else
          [elem, (jsCall "seq_at", [i, sequence])]
      ctx.setAssignTo rhs
      lhsCompiled = expressionCompile ctx, lhs
      retrieve elem, lhs
      ctx.resetAssignTo()
      lhsCompiled)
    elemType = ctx.freshTypeVariable star
    # TODO use (Seq c e) instead of (Array e)
    form.tea = new Constrained (concatMap _constraints, (map _tea, elems)),
      new TypeApp arrayType, elemType

    for elem in elems
      unify ctx, elem.tea.type,
        if isSplat elem
          form.tea.type
        else
          elemType

    cond = (jsBinary (if hasSplat then '>=' else '=='),
      (jsCall "seq_size", [sequence]), requiredElems)
    combinePatterns join [(precs: [(cond_ cond)])], compiledArgs
  else
    # The below worked, but not for patterns
    # Compile as calls for type checking
    # {a b c} to (& a (& b (& c)))
    # expressionCompile ctx, arrayToConses elems
    # result =>         "[#{listOf map _compiled, elems}]"

    compiledItems = uniformCollectionCompile ctx, form, elems, arrayType
    assignCompile ctx, form, (irArray compiledItems)

isSplat = (expression) ->
  (isAtom expression) and (_symbol expression)[...2] is '..'

splatToName = (splat) ->
  replicate splat,
    (token_ (_symbol splat)[2...])

hashmapCompile = (ctx, form) ->
  if hashmap = ctx.assignTo()
    # TODO:
    throw new Error "matching on hash maps not supported yet"
  else
    [labels, items] = unzip pairs _terms form
    keyType = new TypeApp hashmapType, stringType
    compiledItems = uniformCollectionCompile ctx, form, items, keyType
    keys = (map (__ string_, _labelName), labels)
    assignCompile ctx, form, (irMap keys, compiledItems)


uniformCollectionCompile = (ctx, form, items, collectionType, moreConstraints = []) ->
  {constraints, itemType, compiled} = uniformCollectionItemsCompile ctx, items
  (labelOperator form) if not isCall form
  form.tea = new Constrained (join moreConstraints, constraints),
      new TypeApp collectionType, itemType
  compiled

uniformCollectionItemsCompile = (ctx, items) ->
  itemType = ctx.freshTypeVariable star
  compiledItems = termsCompile ctx, items
  for item in items when item.tea
    unify ctx, itemType, item.tea.type
  constraints: (concatMap _constraints, (tea for {tea} in items when tea))
  itemType: itemType
  compiled: compiledItems

# arrayToConses = (elems) ->
#   if elems.length is 0
#     token_ 'empty-array'
#   else
#     [x, xs...] = elems
#     (call_ (token_ 'cons-array'), [x, (arrayToConses xs)])

typeConstrainedCompile = (ctx, call) ->
  [type, constraints...] = _arguments call
  new Constrained (typeConstraintsCompile ctx, constraints), (typeCompile ctx, type)

typeCompile = (ctx, expression, expectedKind) ->
  throw new Error "invalid typeCompile args" unless expression
  (if isAtom expression
    typeNameCompile
  else if isTuple expression
    typeTupleCompile
  else if isCall expression
    typeConstructorCompile
  else
    malformed ctx, expression, 'not a valid type'
  )? ctx, expression, expectedKind

typesCompile = (ctx, expressions, expectedKinds = []) ->
  typeCompile ctx, e, expectedKinds[i] for e, i in expressions

typeNameCompile = (ctx, atom, expectedKind) ->
  expanded = ctx.resolveTypeAliases atom.symbol
  type =
    if expanded is atom.symbol
      kindOfType =
        if isCapital atom
          ctx.kindOfTypeName atom.symbol
        else
          expectedKind or star
      if kindOfType instanceof TempKind
        kindOfType = expectedKind
      if not kindOfType
        # throw new Error "type name #{atom.symbol} was not defined" unless kind
        malformed ctx, atom, "This type name has not been defined"
        kindOfType = star
      atomicType atom.symbol, kindOfType
    else
      expanded
  finalKind = kind type
  if expectedKind instanceof KindFn
    labelOperator atom
  else
    atom.label = 'typename' unless isFake atom
  # if expectedKind and (not kindsEq expectedKind, finalKind)
  #   log expectedKind, finalKind
  #   malformed ctx, atom, "The kind of the type operator doesn't match the
  #                 supplied number of arguments"
  # log type
  type

typeTupleCompile = (ctx, form) ->
  (labelOperator form)
  elemTypes = _terms form
  applyKindFn (tupleType elemTypes.length), (typesCompile ctx, elemTypes)...

typeConstructorCompile = (ctx, call) ->
  op = _operator call
  args = _arguments call

  if isAtom op
    name = op.symbol
    compiledArgs = typesCompile ctx, args
    if name is 'Fn'
      (labelOperator op)
      typeFn compiledArgs...
    else
      arity = args.length
      operatorType = typeNameCompile ctx, op, (kindFn arity)
      applyKindFn operatorType, compiledArgs...
  else
    malformed ctx, op, 'Expected a type constructor instead'

# Will have to defer if class doesn't exist yet
typeConstraintCompile = (ctx, expression) ->
  op = _operator expression
  args = _arguments expression
  if isCall expression
    if isAtom op
      (labelOperator op)
      className = op.symbol
      {constraint} = ctx.classNamed className
      paramKinds = (map kind, constraint.types.types)
      new ClassConstraint op.symbol, new Types (typesCompile ctx, args, paramKinds)
    else
      malformed ctx, expression, 'Class name required in a constraint'
  else
    malformed ctx, expression, 'Class constraint expected'

typeConstraintsCompile = (ctx, expressions) ->
  filter ((t) -> t instanceof ClassConstraint),
    (typeConstraintCompile ctx, e for e in expressions when not isFake e)

# Inside definition, we call assignCompile with its RHS
#   whether to call it and with what expression is left to the RHS expression
#   essentially assignable macros should call it
# This then compiles the LHS
# Possibly defers if RHS or LHS had to defer
# We then unify LHS with RHS, which will populate context substitution
#   with the right subs for type vars on the left
# For each defined name in the LHS, we declare it
assignCompile = (ctx, expression, translatedExpression) ->
  assignCompileAs ctx, expression, translatedExpression, no

assignCompileAs = (ctx, expression, translatedExpression, polymorphic) ->
  # if not translatedExpression # TODO: throw here?
  if ctx.isAtDefinition()
    to = ctx.definitionPattern()
    ctx.setAssignTo (irDefinition expression.tea, translatedExpression)
    {precs, assigns} = patternCompile ctx, to, expression, polymorphic
    translationCache = ctx.resetAssignTo()

    #log "ASSIGN #{ctx.definitionName()}", ctx.shouldDefer()
    if ctx.shouldDefer()
      return deferCurrentDefinition ctx, expression

    if assigns.length is 0
      return malformed ctx, to, 'Not an assignable pattern'
    map compileVariableAssignment, (join translationCache, assigns)
  else
    if ctx.isAtBareDefinition()
      # Force context reduction
      inferredType = (substitute ctx.substitution, expression.tea)
      deferConstraints ctx,
        ctx.allBoundTypeVariables(),
        (findFree inferredType),
        inferredType.constraints
    translatedExpression

# Pushes the deferring to the parent scope
deferCurrentDefinition = (ctx, expression) ->
  ctx.addDeferredDefinition ctx.deferReason().concat [ctx.definitionPattern(), expression]
  deferredExpression()

polymorphicAssignCompile = (ctx, expression, translatedExpression) ->
  assignCompileAs ctx, expression, translatedExpression, yes

patternCompile = (ctx, pattern, matched, polymorphic) ->
  # caching can occur while compiling the pattern
  # precs are {cond}s and {cache}s, sorted in order they need to be executed
  {precs, assigns} = expressionCompile ctx, pattern

  definedNames = ctx.definedNames()

  # log "is deferriing", pattern, ctx.shouldDefer()
  # Make sure deferred names are added to scope so they are compiled within functions
  if ctx.shouldDefer()
    for {name} in definedNames
      if not ctx.arity name
        ctx.declare name
    #log "exiting pattern early", pattern, "for", ctx.shouldDefer()
    return {}


  # Properly bind types according to the pattern
  if pattern.tea
    # log "pattern", matched.tea, pattern.tea
    unify ctx, matched.tea.type, pattern.tea.type

  # log "pattern compiel", definedNames, pattern
  for {name, id, type} in definedNames
    currentType = substitute ctx.substitution, type
    deps = ctx.deferredNames()

    # TODO: this is because functions might declare arity before being declared
    if not ctx.isCurrentlyDeclared name
      ctx.declare name, id: id
    if deps.length > 0
      # log "adding top level lhs to deferred #{name}", deps
      ctx.addToDeferred {name, type, deps: (map (({name}) -> name), deps)}
      for dep in deps
        ctx.addToDeferred {name: dep.name, type: dep.type, deps: [name]}
      ctx.assignType name, (new TempType type)
    else
      # For explicitly typed bindings, we need to check that the inferred type
      #   corresponds to the annotated
      if ctx.isTyped name
        # TODO: check class constraints
        unify ctx, currentType.type, (freshInstance ctx, ctx.type name).type
      else
        [deferredConstraints, retainedConstraints] = deferConstraints ctx,
          ctx.allBoundTypeVariables(),
          (findFree currentType),
          (substituteList ctx.substitution, matched.tea.constraints)
        # log "assign type", name, (printType currentType), retainedConstraints
        # Finalizing type again after possibly added substitution when defer constraints
        currentType = substitute ctx.substitution, type
        ctx.assignType name,
          if polymorphic
            quantifyUnbound ctx, (addConstraints currentType, retainedConstraints)
          else
            toForAll currentType
  # here I will create type schemes for all definitions
  # The problem is I don't know which are impricise, because the names are done inside the
  # pattern. I can use the context to know which types where added in the current assignment.

  # TODO: malformed ctx, "LHS\'s type doesn\'t match the RHS in assignment", pattern

  precs: precs ? []
  assigns: assigns ? []

topLevelExpression = (ctx, expression) ->
  ctx.bareDefine()
  compiled = expressionCompile ctx, expression
  deferred = ctx.deferReason()
  ctx.leaveDefinition()
  if deferred
    [expression, dependencyName] = deferred
    malformed ctx, expression, "#{dependencyName} is not defined"
    undefined
  else
    (irDefinition expression.tea, compiled)

topLevel = (ctx, form) ->
  if (terms = _validTerms form).length % 2 == 0
    definitionList ctx, pairs terms
  else
    throw new Error "Missing definition at top level"

definitionList = (ctx, pairs) ->
  compiledPairs = (for [lhs, rhs] in pairs
    if rhs
      definitionPairCompile ctx, lhs, rhs
    else
      malformed ctx, lhs, 'missing value in definition'
      undefined)

  compiledPairs = join compiledPairs, compileDeferred ctx
  resolveDeferredTypes ctx
  compiledPairs = join compiledPairs, compileDeferred ctx
  deferDeferred ctx


  # log "yay"
  concat filter _is, compiledPairs

# This function resolves the types of mutually recursive functions
resolveDeferredTypes = (ctx) ->
  if _notEmpty ctx.deferredBindings()
    # TODO: proper dependency analysis to get the smallest circular deps
    #       now we are just compiling as if they were all mutually recursive
    names = concatConcatMaps map (({name, type}) -> newMapWith name, type), ctx.deferredBindings()
    # First get rid of instances of already resolved types
    unresolvedNames = newMap()
    for name, types of values names
      if canonicalType = ctx.actualType name
        for type in types
          unify ctx, type.type, (freshInstance ctx, canonicalType).type
      else
        addToMap unresolvedNames, name, types

    # Now assign the same type to all occurences of the given type and unify
    for name, types of values unresolvedNames
      canonicalType = toConstrained ctx.freshTypeVariable star
      for type in types
        #log type.constructor
        unify ctx, canonicalType.type, type.type
        # log "done unifying one"
      ctx.assignType name, quantifyAll substitute ctx.substitution, canonicalType

compileDeferred = (ctx) ->
  compiledPairs = []
  if _notEmpty ctx.deferred()
    deferredCount = 0
    while (_notEmpty ctx.deferred()) and deferredCount < ctx.deferred().length
      prevSize = ctx.deferred().length
      [expression, dependencyName, lhs, rhs] = deferred = ctx.deferred().shift()
      if ctx.isActuallyTyped dependencyName
        compiledPairs.push definitionPairCompile ctx, lhs, rhs
        deferredCount = 0
      else
        # If can't compile, defer further
        ctx.addDeferredDefinition deferred
        deferredCount++
  concat compiledPairs

deferDeferred = (ctx) ->
  # defer completely current scope
  if _notEmpty ctx.deferred()
    for [expression, dependencyName, lhs, rhs] in ctx.deferred()
      if ctx.isInTopScope()
        malformed ctx, expression, "#{dependencyName} is not defined"
      else
        ctx.doDefer expression, dependencyName

definitionPairCompile = (ctx, pattern, value) ->
  # log "COMPILING", pattern
  ctx.definePattern pattern
  # log "deferrement before assign !!!", ctx.shouldDefer()
  compiled = expressionCompile ctx, value
  wasDeferred = ctx.shouldDefer()
  ctx.leaveDefinition()
  if wasDeferred
    # log "RESETTING DEFER"
    undefined
  else
    compiled

ms = {}
ms.fn = ms_fn = (ctx, call) ->
    # For now expect the curried constructor call
    args = _arguments call
    [paramList, defs...] = args
    params = paramTupleIn ctx, call, paramList
    defs ?= []
    if defs.length is 0
      malformed ctx, call, 'Missing function result'
    else
      [docs, defs] = partition isComment, defs
      map labelComments, docs
      if isTypeAnnotation defs[0]
        [type, body, wheres...] = defs
      else
        [body, wheres...] = defs
      paramNames = _names params

      # Arity - before deferring instead? put to assignCompile, because this makes the naming of functions special
      if name = ctx.isAtSimpleDefinition()
        #log "adding arity for #{ctx.definitionName()}", paramNames
        ctx.declareArity name, paramNames
        # Explicit typing
        if type
          explicitType = assignExplicitType ctx, typeConstrainedCompile ctx, type

      paramTypeVars = map (-> ctx.freshTypeVariable star), params
      paramTypes = map (__ toForAll, toConstrained), paramTypeVars
      ctx.newLateScope()
      ctx.bindTypeVariables (map (({name}) -> name), paramTypeVars)
      # log "adding types", (map _symbol, params), paramTypes
      ctx.declareTypes paramNames, paramTypes
      for param in params
        param.id = ctx.declarationId _symbol param

      #log "compiling wheres", pairs wheres
      compiledWheres = definitionList ctx, pairs wheres

      # log "types added"
      # log "compiling", body
      if body
        compiledBody = termCompile ctx, body
      # log "compiled", body.tea
      ctx.closeScope()

      # Syntax - used params in function body
      # !! TODO: possibly add to nameCompile instead, or defer to IDE
      isUsedParam = (expression) ->
        (isName expression) and (_symbol expression) in paramNames
      labelUsedParams = (expression) ->
        map (syntaxNameAs ctx, '', 'param'), filterAst isUsedParam, expression
      map labelUsedParams, join docs, (if body then join [body], wheres else wheres)

      polymorphicAssignCompile ctx, call,
        if ctx.shouldDefer()
          deferredExpression()
        else
          # Typing
          if body and not body.tea
            malformed ctx, body, 'Expression failed to type check'
            #throw new Error "Body not typed"
          call.tea =
            if body
              new Constrained body.tea.constraints,
                typeFn paramTypeVars..., body.tea?.type
            else
              freshInstance ctx, explicitType
          # """λ#{paramNames.length}(function (#{listOf paramNames}) {
          #   #{compiledWheres}
          #   return #{compiledBody};
          # })"""
          (irFunction
            name: (ctx.definitionName() if ctx.isAtSimpleDefinition())
            params: paramNames
            body: (join compiledWheres, [(jsReturn compiledBody)]))
            # (jsCall "λ#{paramNames.length}", [
            #   (jsFunction
            #     name: (ctx.definitionName() if ctx.isAtSimpleDefinition())
            #     params: paramNames
            #     body: (join compiledWheres, [(jsReturn compiledBody)]))])

# Assumes definition name
assignExplicitType = (ctx, type) ->
  explicitType = quantifyUnbound ctx, type
  name = ctx.definitionName()
  if ctx.isTyped name
    malformed ctx, ctx.definitionPattern(), 'This name is already taken'
  else
    ctx.assignType name, explicitType
  explicitType

ms.type = ms_type = (ctx, call) ->
  hasName = requireName ctx, 'Name required to declare new type alias'
  alias = ctx.definitionName()
  if not (isCapital symbol: alias)
    malformed ctx, ctx.definitionPattern(), 'Type aliases must start with a capital letter'
  [type] = _arguments call
  ctx.addTypeAlias alias, typeCompile ctx, type
  jsNoop()

  # data
  #   listing or
  #     pair
  #       constructor-name
  #       record
  #         type
  #     constant-name
ms.data = ms_data = (ctx, call) ->
    hasName = requireName ctx, 'Name required to declare new algebraic data'
    args = _arguments call
    if isTuple args[0]
      [typeParamTuple, args...] = args
      typeParams = paramTupleIn ctx, call, typeParamTuple
    typeParams ?= []
    defs = pairsLeft isAtom, args
    # Syntax
    [names, typeArgLists] = unzip defs
    map (syntaxNewName ctx, 'Type constructor name required'), names
    if not hasName
      return 'malformed'

    dataName = ctx.definitionName()

    # Types, Arity
    {fieldTypes, dataType} = findDataType ctx, typeArgLists, typeParams, dataName
    for [constr, params], i in defs
      paramTypes = fieldTypes[i]
      constrType = if params
        typeFn (join paramTypes, [dataType])...
      else
        dataType
      paramLabels = (_labeled _terms params or []).map(_fst).map(_labelName)
      # log "Adding constructor #{constr.symbol}", constrType
      ctx.declare constr.symbol,
        type: quantifyUnbound ctx, toConstrained constrType
        arity: (paramLabels if params)
      constr.tea = constrType

      # Declare getters
      for label, i in paramLabels
        ctx.declare "#{constr.symbol}.#{label}",
          arity: ["#{constr.symbol[0].toLowerCase()}#{constr.symbol[1...]}"]
          type: quantifyUnbound ctx, toConstrained typeFn dataType, paramTypes[i]

    ctx.addTypeName dataType

    # Translate
    concat (for [constr, params] in defs
      identifier = validIdentifier constr.symbol
      paramLabels = (_labeled _terms params or []).map(_fst).map(_labelName)
      paramNames = paramLabels.map(validIdentifier)

      constrValue = (jsAssignStatement "#{identifier}._value",
        if params
          (jsCall "λ#{paramNames.length}",
            [(jsFunction
              params: paramNames
              body: [(jsReturn (jsNew identifier, paramNames))])])
        else
          (jsNew identifier, []))
      (join (translateDict identifier, paramNames), [constrValue]))

findDataType = (ctx, typeArgLists, typeParams, dataName) ->
  varNames = map _symbol, typeParams
  varNameSet = arrayToSet varNames
  kinds = newMap()

  # Fake kind for recursive use
  ctx.addTypeName new TypeConstr dataName, new TempKind

  # TODO: I need to figure out the error handling, we should bail out
  #       if an undeclared type var is used
  fieldTypes = for typeArgs in typeArgLists
    if typeArgs
      if isRecord typeArgs
        for type in _snd unzip _labeled _terms typeArgs
          type = typeCompile ctx, type
          for name, kind of values findFree type
            if not inSet varNameSet, name
              malformed ctx, type, "Type variable #{name} not declared"
              throw new Error "Type variable #{name} not declared"
            else
              if foundKind = lookupInMap kinds, name
                if not kindsEq foundKind, kind
                  malformed ctx, type, "Type variable #{name} must have the same kind"
              else
                addToMap kinds, name, kind
          type
      else
        malformed ctx, typeArgs, 'Required a record of types'
        null
    else
      null

  for typeParam in typeParams
    if not lookupInMap kinds, (_symbol typeParam)
      malformed ctx, typeParam, 'Data type parameter not used'
      throw new Error 'Data type parameter not used'

  freshingSub = mapMap ((kind) -> ctx.freshTypeVariable kind), kinds

  dataKind = kindFnOfArgs (map ((name) -> lookupInMap kinds, name), varNames)...
  typeVars = map ((name) -> new TypeVariable name, (lookupInMap kinds, name)), varNames
  dataType: (substitute freshingSub,
    (applyKindFn (new TypeConstr dataName, dataKind), typeVars...))
  fieldTypes: (map ((types) -> if types then substituteList freshingSub, types), fieldTypes)

ms.record = ms_record = (ctx, call) ->
    args = _arguments call
    hasName = requireName ctx, 'Name required to declare new record'
    if isTuple args[0]
      [typeParamTuple, args...] = args
    else
      typeParamTuple = (tuple_ [])
    for [name, type] in _labeled args
      if not name
        malformed ctx, type, 'Label is required'
      if not type
        malformed ctx, name, 'Missing type'
    if args.length is 0
      malformed ctx, call, 'Missing field declarations'
    # TS: (data #{ctx.definitionName()} [#{_arguments form}])
    if not hasName
      return 'malformed'
    replicate call,
      (call_ (token_ 'data'),
        [typeParamTuple, (token_ ctx.definitionName()), (tuple_ args)])

  # Type an expression
ms[':'] = ms_typed = (ctx, call) ->
    hasName = requireName ctx, 'Name required to declare typed values for now'
    [type, constraintSeq, rest...] = _arguments call
    compiledType =
      if isSeq constraintSeq
        constraints = typeConstraintsCompile ctx, _terms constraintSeq
        if type
          new Constrained constraints, typeCompile ctx, type
      else
        typeConstrainedCompile ctx, call
    if hasName
      ctx.declare ctx.definitionName()
      assignExplicitType ctx, compiledType
    # TODO: support typing of expressions,
    #watch out of definition patterns without a name
    jsNoop()


# Adds a class to the scope or defers if superclass doesn't exist
ms.class = ms_class = (ctx, call) ->
    hasName = requireName ctx, 'Name required to declare a new class'
    [paramList, defs...] = _validArguments call
    params = paramTupleIn ctx, call, paramList
    paramNames = _names params
    [docs, defs] = partition isComment, defs

    [constraintSeq, wheres...] = defs
    if not isSeq constraintSeq
      wheres = defs
      constraints = []
    else
      constraints = typeConstraintsCompile ctx, _terms constraintSeq

    superClasses = map (quantifyConstraintFor paramNames), constraints
    superClassNames = map (({className}) -> className), constraints

    # TODO: defer if not all declared to prevent cycles in classes
    #   allDeclared = (ctx.isClass c for c in superClasses)

    methodDefinitions = pairs wheres
    ctx.newScope()
    ctx.bindTypeVariables paramNames
    definitionList ctx, methodDefinitions
    declarations = ctx.currentDeclarations()
    ctx.closeScope()

    for [name, def] in methodDefinitions
      (lookupInMap declarations, name.symbol)?.def = def

    if hasName
      name = ctx.definitionName()
      if ctx.isClassDefined name
        malformed ctx, 'class already defined', ctx.definitionPattern()
      else
        {classConstraint, freshedDeclarations} = findClassType ctx, params,
          name, paramNames, declarations
        if classConstraint
          ctx.addClass name, classConstraint, superClasses, freshedDeclarations
          declareMethods ctx, classConstraint, freshedDeclarations

          translateDict name, (keysOfMap freshedDeclarations), superClassNames
        else
          jsNoop()
    else
      jsNoop()

quantifyConstraintFor = (names) -> (constraint) ->
  new ClassConstraint constraint.className,
    new Types (for type in constraint.types.types
      if type.TypeVariable
        index = names.indexOf type.name
        # TODO: attach to the syntax
        # if index is -1
        #   malformed ctx, param, 'Superclass param must occur in class\'s params'
        new QuantifiedVar index
      else
        type)

findClassType = (ctx, params, className, paramNames, methods) ->
  kinds = mapMap (-> undefined), (arrayToSet paramNames)
  for name, {arity, type, def} of values methods
    vars = findFree type.type
    for param in paramNames
      kindSoFar = lookupInMap kinds, param
      foundKind = lookupInMap vars, param
      # if not foundKind
        # TODO: attach error to the type expression
        # malformed ctx, def, 'Method must include class parameter in its type'
      if kindSoFar and foundKind and not kindsEq foundKind, kindSoFar
        # TODO: attach error to the type expression instead
        # TODO: better error message
        malformed ctx, def, 'All methods must use the class paramater of the same kind'
      if foundKind
        replaceInMap kinds, param, foundKind
  if not all (for param in params when not lookupInMap kinds, _symbol param
      malformed ctx, param, 'A class paramater must occur in at least one method\'s type'
      false)
    return {}
  freshingSub = mapMap ((kind) -> ctx.freshTypeVariable kind), kinds
  classParam = (param) ->
    substitute freshingSub, new TypeVariable param, (lookupInMap kinds, param)
  method = ({arity, type, def}) ->
    {arity, def, type: (substitute freshingSub, type)}
  classConstraint: (new ClassConstraint className, new Types (map classParam, paramNames))
  freshedDeclarations: (mapMap method, methods)

declareMethods = (ctx, classConstraint, methodDeclarations) ->
  for name, {arity, type} of values methodDeclarations
    type = quantifyUnbound ctx,
      (addConstraints (freshInstance ctx, type), [classConstraint])
    ctx.declare name, {arity, type}
  return

ms.instance = ms_instance = (ctx, call) ->
    hasName = requireName ctx, 'Name required to declare a new instance'

    [instanceConstraint, defs...] = _validArguments call
    if not isCall instanceConstraint
      return malformed ctx, call, 'Instance requires a class constraint'
    else
      instanceType = typeConstraintCompile ctx, instanceConstraint
    [constraintSeq, wheres...] = defs
    if not isSeq constraintSeq
      wheres = defs
      constraints = []
    else
      constraints = typeConstraintsCompile ctx, _terms constraintSeq

    # TODO: defer if class does not exist
    className = instanceType.className
    classDefinition = ctx.classNamed className
    if not classDefinition
      return malformed ctx, (_operator instanceConstraint), 'Class doesn\'t exist'

    # TODO: defer if super class instances don't exist yet
    superClassInstances = findSuperClassInstances ctx, instanceType.types, classDefinition

    if not hasName
      return malformed ctx, call, "An instance requires a name"
    instanceName = ctx.definitionName()

    ctx.newScope()
    freshInstanceType = assignMethodTypes ctx, instanceConstraint, instanceName,
      classDefinition, instanceType, constraints
    definitions = pairs wheres
    methodsDeclarations = definitionList ctx,
      (prefixWithInstanceName ctx, definitions, instanceName)
    ctx.closeScope()
    if ctx.shouldDefer()
      return deferCurrentDefinition ctx, call

    methods = map (({rhs}) -> rhs), methodsDeclarations
    # log "methods", methods
    methodTypes = (rhs.tea for [lhs, rhs] in definitions)
    if not all methodTypes
      return (jsMalformed "missing type of a method")

    # TODO: defer for class declaration if not defined
    ## if not ctx.isClassDefined className    ...
    if not freshInstanceType
      jsNoop()
    else
      freshConstraints = freshInstanceType.constraints
      instance = quantifyAll (new Constrained freshConstraints,
        (new ClassConstraint instanceType.className, freshInstanceType.type))
      ## if overlaps ctx, instance
      ##   malformed ctx, 'instance overlaps with another', instance
      ## else
      ctx.addInstance instanceName, instance

      # """var #{instanceName} = new #{className}(#{listOf methods});"""
      (jsVarDeclaration (validIdentifier instanceName),
        (irDefinition (new Constrained freshConstraints, (tupleOfTypes methodTypes).type),
          (jsNew className, (join superClassInstances, methods))))

# Makes sure methods are typed explicitly and returns the instance constraint
# with renamed type variables to avoid clashes
assignMethodTypes = (ctx, typeExpression, instanceName, classDeclaration, instanceType, instanceConstraints) ->
  # First we must freshen the instance type, to avoid name clashes of type vars
  freshInstanceType = freshInstance ctx,
    (quantifyUnbound ctx,
      (new Constrained instanceConstraints, instanceType.types))

  # log "mguing", classDeclaration.constraint.types, freshInstanceType.type
  sub = mostGeneralUnifier classDeclaration.constraint.types, freshInstanceType.type
  if isFailed sub
    malformed ctx, typeExpression, 'Type doesn\'t match class type'
    return null

  ctx.bindTypeVariables setToArray (findFree freshInstanceType)
  for name, {arity, type} of values classDeclaration.declarations
    freshType = freshInstance ctx, type
    instanceSpecificType = substitute sub, freshType
    quantifiedType = quantifyUnbound ctx, instanceSpecificType
    prefixedName = instancePrefix instanceName, name
    ctx.declareArity prefixedName, arity
    ctx.assignType prefixedName, quantifiedType
  freshInstanceType

prefixWithInstanceName = (ctx, definitionPairs, instanceName) ->
  for [lhs, rhs] in definitionPairs
    if (syntaxNewName ctx, 'Method name required', lhs) is true
      [(token_ instancePrefix instanceName, lhs.symbol), rhs]
    else
      [lhs, rhs]

instancePrefix = (instanceName, methodName) ->
  "#{instanceName}_#{methodName}"

findSuperClassInstances = (ctx, instanceTypes, classDefinition) ->
  superConstraints = substituteList instanceTypes.types, classDefinition.supers
  instanceDictFor ctx, constraint for constraint in superConstraints


  # TODO:
  # For now support the simplest function macros, just compiling down to source
  # strings
  # macro: (ctx, call) ->
  #   args = _arguments call
  #   [paramList, body] = args
  #   paramTupleIn ctx, paramList
  #   if not body
  #     malformed ctx, call, 'Missing macro definition'

  #   ctx.
  #   # then in assign compile:
  #   ctx.macros[ctx.definitionName()]


  # match
  #   subject
  #   listing of
  #     pair
  #       pattern
  #       result
ms.match = ms_match = (ctx, call) ->
    [subject, cases...] = _arguments call
    if not subject
      return malformed ctx, call, 'match `subject` missing'
    if cases.length % 2 != 0
      return malformed ctx, call, 'match missing result for last pattern'
    subjectCompiled = termCompile ctx, subject

    # To make sure all results have the same type
    resultType = ctx.freshTypeVariable star

    # ctx.setGroupTranslation()
    ctx.setAssignTo subjectCompiled
    varNames = []
    constraints = []
    errorMessage =
      if ctx.definitionName()?
        " in #{ctx.definitionName()}"
      else
        ""
    compiledCases = conditional (for [pattern, result] in pairs cases

      ctx.newScope() # for variables defined inside pattern
      ctx.defineNonDeferrablePattern pattern
      {precs, assigns} = patternCompile ctx, pattern, subject, no

      # Compile the result, given current scope
      ctx.setAssignTo undefined
      compiledResult = termCompile ctx, result #compileImpl result, furtherHoistable
      ctx.resetAssignTo()
      ctx.leaveDefinition()
      ctx.closeScope()

      if ctx.shouldDefer()
        continue

      # TODO: we need to check that
      # log "unifying in match", result, resultType, result.tea
      unify ctx, resultType, result.tea.type
      constraints.push result.tea.constraints...
      varNames.push (findDeclarables precs)...

      matchBranchTranslate precs, assigns, compiledResult
    ), "throw new Error('match failed to match#{errorMessage}');" #TODO: what subject?
    translationCache = ctx.resetAssignTo()
    call.tea = new Constrained constraints, resultType
    assignCompile ctx, call, iife concat (filter _is, [
      (map compileVariableAssignment, translationCache)
      varList varNames
      compiledCases])

ms.format = ms_format = (ctx, call) ->
  typeTable =
    n: numType
    i: numType
    s: stringType
    c: charType
  [formatStringToken, args...] = _arguments call
  compiledArgs = termsCompile ctx, args
  call.tea = new Constrained (concatMap (__ _constraints, _tea), args), stringType
  if not all map _tea, args
    return malformed ctx, call, "Argument not typed"
  types = []
  formatString = _stringValue formatStringToken
  while formatString.length > 0
    match = formatString.match /^(.*?(?:^|[^\\]|\\\\))\%(.)/
    break unless match
    [matched, prefix, symbol] = match
    if symbol of typeTable
      types.push
        type: typeTable[symbol]
        symbol: symbol
        prefix: prefix
    else
      malformed ctx, formatString, "Found an unsupported control character #{symbol}"
    formatString = formatString[matched.length...]
  if args.length > types.length
    malformed ctx, call, "Too many arguments to format"
  # TODO: curry
  formattedArgs = for {type, symbol, prefix}, i in types when args[i]
    compiled = compiledArgs[i]
    unify ctx, type, args[i].tea.type
    [(string_ prefix), switch symbol
      when 's' then compiled
      when 'c' then compiled
      when 'n' then compiled
      when 'i' then (jsUnary "~", (jsUnary "~", compiled))]
  assignCompile ctx, call,
    (jsBinaryMulti "+", join (concat formattedArgs), [string_ formatString])

ms.syntax = ms_syntax = (ctx, call) ->
  hasName = requireName ctx, 'Name required to declare new algebraic data'
  [paramTuple, rest...] = _arguments call
  [body] = rest

  # ctx.addMacro ctx.definitionName(), (ctx) ->
  #   expressionCompile ctx, body

  if hasName
    macroName = ctx.definitionName()

    # params = (map (__ token_, _symbol), _terms paramTuple) # freshen

    compiledMacro = translateToJs translateIr ctx,
        (termCompile ctx, call_ (token_ 'fn'), (join [paramTuple], rest))
    macroFn = eval compiledMacro
    ctx.addMacro ctx.definitionPattern(), (ctx, call) ->
      # operatorCompile ctx, call
      # args = termsCompile ctx, (_arguments call)[0..macroFn.length]
      #callTyping ctx, call
      constantToSource macroFn (_arguments call)...

    # ctx.addMacro macroName, (ctx, call) ->
    #   compiled = termCompile ctx, (fn_ params, body)
    #   assignCompile ctx, body, compiled

    jsNoop()


ms['`'] = ms_quote = (ctx, call) ->
  [res] = _arguments call
  # call.tea = toConstrained typeConstant 'Exp'
  # assignCompile ctx, call, res
  call.tea = toConstrained typeConstant 'Expression'

  serializeAst = (ast) ->
    if isForm ast
      if (_operator ast)?.symbol is ','
        termCompile ctx, ast
      else
        (jsArray (map serializeAst, ast))
    else
      (jsValue (JSON.stringify ast))
  serializeAst res

ms[','] = ms_comma = (ctx, call) ->
  (jsCall 'constantToSource', [expressionCompile ctx, (_arguments call)[0]])

constantToSource = (value) ->
  switch typeof value
    when 'boolean' then (tokenize (if value then 'True' else 'False'))[0]
    when 'number' then (tokenize (if value < 0 then "~#{Math.abs value}" else "#{value}"))[0]
    when 'string' then (tokenize JSON.stringify value)[0]
    when 'object'
      kind = Object.prototype.toString.call(value).slice(8, -1)
      switch kind
        # when 'Date' then (jsNew 'Date', [+value])
        when 'RegExp' then (tokenize "#{value.source}")[0]
        else
          # TODO: rest of immutable
          if Immutable.Iterable.isIterable value
            concat [(tokenize "{")[0], (map constantToSource, value.toJS()), (tokenize "}")[0]]
          else
            value

ms.macro = ms_macro = (ctx, call) ->
  hasName = requireName ctx, 'Name required to declare a new instance'
  [paramTuple, type, rest...] = _arguments call

  if hasName
    macroName = ctx.definitionName()
    redefining = ctx.macros()[macroName]

    # Register type
    params = _terms paramTuple
    paramNames = map _symbol, params
    if not type or not isTypeAnnotation type
      malformed ctx, call, "Type annotation required"
      rest = join [type], rest
    else if not redefining
      ctx.declare macroName,
        arity: paramNames
        type: type = quantifyUnbound ctx, typeConstrainedCompile ctx, type
      call.tea = type

    if not rest.length > 0
      return malformed ctx, call, "Macro body missing"

    #macroFn = transform call
    compiledMacro = translateToJs translateIr ctx,
      (termCompile ctx, call_ (token_ 'fn'), (join [paramTuple], rest))
    # log compiledMacro
    params = (map token_, paramNames) # freshen

    if redefining
      malformed ctx, ctx.definitionPattern(), "Macro with this name already defined"
    else
      ctx.addMacro ctx.definitionPattern(), simpleMacro eval compiledMacro
      fn_ params, call_ (token_ macroName), params

simpleMacro = (macroFn) ->
  (ctx, call) ->
    operatorCompile ctx, call
    args = termsCompile ctx, (_arguments call)[0..macroFn.length]
    callTyping ctx, call
    assignCompile ctx, call, macroFn args...

for jsMethod in ['binary', 'ternary', 'unary', 'access', 'call', 'method']
  do (jsMethod) ->
    ms["Js.#{jsMethod}"] = (ctx, call) ->
      call.tea = toConstrained typeConstant "JS"
      terms = _arguments call
      compatibles = (for term, i in terms
        compiled = termCompile ctx, term
        (irJsCompatible term.tea, compiled))
      (jsCall "js#{jsMethod[0].toUpperCase()}#{jsMethod[1...]}", compatibles)

ms['=='] = ms_eq = (ctx, call) ->
    [a, b] = _arguments call
    operatorCompile ctx, call
    compiledA = termCompile ctx, a
    compiledB = termCompile ctx, b

    callTyping ctx, call
    assignCompile ctx, call, (jsBinary "===", compiledA, compiledB)

ms.Set = ms_Set = (ctx, call) ->
  if ctx.assignTo()
    # TODO:
    throw new Error "matching on sets not supported yet"
  else
    items = _arguments call
    compiledItems = uniformCollectionCompile ctx, call, items, hashsetType
    assignCompile ctx, call, (irSet compiledItems)

ms.List = ms_List = (ctx, call) ->
  if ctx.assignTo()
    # TODO:
    throw new Error "matching on lists not supported yet"
  else
    items = _arguments call
    compiledItems = uniformCollectionCompile ctx, call, items, listType
    assignCompile ctx, call, (irList compiledItems)

ms.Map = ms_Map = (ctx, call) ->
  if ctx.assignTo()
    # TODO:
    throw new Error "matching on maps not supported yet"
  else
    args = _arguments call
    if args.length % 2 != 0
      return malformed ctx, args[args.length - 1], 'Missing value for key'
    [labels, items] = unzip pairs args
    compiledLabels = uniformCollectionItemsCompile ctx, labels
    keyType = applyKindFn hashmapType, compiledLabels.itemType
    compiledItems = uniformCollectionCompile ctx, call, items, keyType,
      compiledLabels.constraints
    assignCompile ctx, call, (irMap compiledLabels.compiled, compiledItems)

# Before assign the correct type to plus
# ms['+'] = ms_plus = (ctx, call) ->
#     [open, op, x, y] = call
#     operatorCompile ctx, call
#     compiled_x = termCompile ctx, x
#     compiled_b = termCompile ctx, y

#     callTyping ctx, call
#     assignCompile ctx, call, (jsBinary "+", compiled_x, compiled_b)

builtInMacros = ->
  copy = {}
  for key, val of ms
    copy[key] = val
  copy


# Creates the condition and body of a branch inside match macro
matchBranchTranslate = (precs, assigns, compiledResult) ->
  {conds, preassigns} = constructCond precs
  [hoistedWheres, furtherHoistable] = hoistWheres [], assigns #hoistWheres hoistableWheres, assigns

  [conds, concat [
    (map compileVariableAssignment, (join preassigns, assigns))
    # hoistedWheres.map(compileDef)
    [(jsReturn compiledResult)]]]

iife = (body) ->
  # """(function(){
  #     #{body}}())"""
  (jsCall (jsFunction
    params: []
    body: body), [])

varList = (varNames) ->
  # "var #{listOf varNames};"
  if varNames.length > 0 then (jsVarDeclarations varNames) else null

conditional = (condCasePairs, elseCase) ->
  if condCasePairs.length is 1
    [[cond, branch]] = condCasePairs
    if cond is 'true'
      return branch
  (jsConditional condCasePairs, elseCase)
  # ((for [cond, branch], i in condCasePairs
  #   control = if i is 0 then 'if' else ' else if'
  #   """#{control} (#{cond}) {
  #       #{branch}
  #     }""").join '') + """ else {
  #       #{elseCase}
  #     }"""

paramTupleIn = (ctx, call, expression) ->
  if not expression or not isTuple expression
    malformed ctx, call, 'Missing paramater list'
    params = []
  else
    params = _validTerms expression
    map (syntaxNewName ctx, 'Parameter name expected'), params
  params

quantifyUnbound = (ctx, type) ->
  vars = subtractSets (findFree type), ctx.allBoundTypeVariables()
  quantify vars, type

substituteVarNames = (ctx, varNames) ->
  subbed = (name) =>
    (inSub ctx.substitution, name)?.name or name
  rehashMap subbed, varNames

# Takes a set of fixed type variables, a set of type variables which
# should be quantified and a list of constraints
# returns deferred and retained constraints
deferConstraints = (ctx, fixedVars, quantifiedVars, constraints) ->
  reducedConstraints = reduceConstraints ctx, constraints
  throw new Error "could not reduce constraints in deferConstraints" unless reducedConstraints
  subbedFixedVars = substituteVarNames ctx, fixedVars
  isFixed = (constraint) ->
    # log subbedFixedVars, constraint, (findFree constraint)
    isSubset subbedFixedVars, (findFree constraint)
  [deferred, retained] = partition isFixed, reducedConstraints
  # TODO: handle ambiguity when reducedConstraints include variables not in
  # fixedVars or quantifiedVars
  [deferred, retained]

reduceConstraints = (ctx, constraints) ->
  normalized = normalizeConstraints ctx, constraints
  if normalized
    simplifyConstraints ctx, normalized
  else
    null

normalizeConstraints = (ctx, constraints) ->
  normalized = concat (for constraint in constraints
    normalizeConstraint ctx, constraint)
  if all normalized
    normalized
  else
    null

normalizeConstraint = (ctx, constraint) ->
  if isNormalizedConstraint constraint
    [constraint]
  else
    instanceContraints = constraintsFromInstance ctx, constraint
    if instanceContraints
      normalizeConstraints ctx, instanceContraints
    else
      # TODO: propogate this as standard error
      throw new Error "no instance found to satisfy #{safePrintType constraint}"
      null

simplifyConstraints = (ctx, constraints) ->
  requiredConstraints = []
  for constraint, i in constraints
    if not entail ctx, (join requiredConstraints, constraints[i + 1..]), constraint
      requiredConstraints.push constraint
  requiredConstraints


# Whether constraints entail constraint
entail = (ctx, constraints, constraint) ->
  for c in constraints
    for superClassConstraint in constraintsFromSuperClasses ctx, c
      # if typeEq superClassConstraint, constraint
      if (sub = constraintsEqual superClassConstraint, constraint)
        ctx.extendSubstitution sub
        return yes
  instanceContraints = constraintsFromInstance ctx, constraint
  if instanceContraints
    allMap ((c) -> entail ctx, constraints, c), instanceContraints
  else
    no

constraintsEqual = (c1, c2) ->
  c1.className is c2.className and
    (typeEq c1.types.types[0], c2.types.types[0]) and
      unifyImpliedParams c1.types, c2.types

constraintsFromSuperClasses = (ctx, constraint) ->
  {className, types} = constraint
  join [constraint], concat (for s in (ctx.classNamed className).supers
    constraintsFromSuperClasses ctx, substitute types.types, s)

constraintsFromInstance = (ctx, constraint) ->
  {className, type} = constraint
  for instance in (ctx.classNamed className).instances
    freshed = freshInstance ctx, instance.type
    # log "trying to find the instance", (printType instance.type.type), (printType constraint)
    substitution = toMatchTypes freshed.type.types, constraint.types
    if substitution
      # log substitution
      ctx.extendSubstitution substitution
      return map ((c) -> substitute substitution, c), freshed.constraints
  null

_names = (list) ->
  map _symbol, list

# From precs, find caches and the LHS are declarable variables
findDeclarables = (precs) ->
  map (__ _fst, _cache), (filter _cache, precs)

combinePatterns = (list) ->
  precs: concat map _precs, filter _precs, list
  assigns: concat map _assigns, filter _assigns, list

_precs = ({precs}) ->
  precs

_assigns = ({assigns}) ->
  assigns

_cache = ({cache}) ->
  cache

cache_ = (x) ->
  cache: x

cond_ = (x) ->
  cond: x

malformed = (ctx, expression, message) ->
  # TODO support multiple malformations
  ctx.markMalformed()
  expression.malformed = message
  jsNoop()

translateDict = (dictName, fieldNames, additionalFields = []) ->
  allFieldNames = (join additionalFields, fieldNames)
  paramAssigns = allFieldNames.map (name) ->
    (jsAssignStatement (jsAccess "this", name), (validIdentifier name))
  constrFn = (jsFunction
    name: dictName
    params: (map validIdentifier, allFieldNames)
    body: paramAssigns)
  accessors = fieldNames.map (name) ->
    (jsAssignStatement (jsAccess dictName, name), (jsFunction
      name: (validIdentifier name)
      params: ["dict"]
      body: [(jsReturn (jsAccess "dict", name))]))
  join [constrFn], accessors

requireName = (ctx, message) ->
  if ctx.isAtDefinition()
    syntaxNewName ctx, message, ctx.definitionPattern()
  else
    malformed ctx, call, message
    false

fakeCompile = (ctx, token) ->
  if ctx.assignTo()
    # ???
  else
    token.tea = toConstrained ctx.freshTypeVariable star
    token.scope = ctx.currentScopeIndex()
    ctx.markMalformed()
    jsNoop()

atomCompile = (ctx, atom) ->
  {symbol, label} = atom
  # Typing and Translation
  {type, id, translation, pattern} =
    switch label
      when 'numerical'
        numericalCompile ctx, symbol
      when 'regex'
        regexCompile ctx, symbol
      when 'char'
        charCompile ctx, atom, symbol
      when 'string'
        type: toConstrained stringType
        translation: symbol
        pattern: literalPattern ctx, symbol
      else
        nameCompile ctx, atom, symbol
  atom.tea = type if type
  atom.id = id if id?
  atom.scope = ctx.currentScopeIndex()
  if ctx.isOperator()
    # TODO: maybe don't use label here, it's getting confusing what is its purpose
    (labelOperator atom)
  if ctx.assignTo()
    pattern
  else
    assignCompile ctx, atom, translation

nameCompile = (ctx, atom, symbol) ->
  contextType = ctx.type symbol
  # log "nameCompile", symbol, ctx.isInsideLateScope(), (printType contextType), ctx.isDeclared symbol
  if exp = ctx.assignTo()
    if atom.label is 'const'
      if contextType
        type: freshInstance ctx, ctx.type symbol
        pattern: constPattern ctx, symbol
      else
        # log "deferring in pattern for #{symbol}"
        ctx.doDefer atom, symbol
        pattern: []
    else
      atom.label = 'name'
      id = (ctx.declarationId symbol) ? ctx.freshId()
      type = toConstrained ctx.freshTypeVariable star
      ctx.bindTypeVariables [type.type.name]
      ctx.addToDefinedNames {name: symbol, id: id, type: type}
      type: type
      id: id
      pattern:
        assigns:
          [[(validIdentifier symbol), exp]]
  else
    # Name typed, use a fresh instance
    # log symbol, contextType
    if contextType and contextType not instanceof TempType
      type = freshInstance ctx, contextType
      {
        id: ctx.declarationId symbol
        type: type
        translation: nameTranslate ctx, atom, symbol, type, ctx.arity symbol
      }
    # Inside function only defer compilation if we don't know arity
    else if ctx.isInsideLateScope() and (ctx.isDeclared symbol) or contextType instanceof TempType
      # Typing deferred, use an impricise type var
      type = toConstrained ctx.freshTypeVariable star
      ctx.addToDeferredNames {name: symbol, type: type}
      {
        id: ctx.declarationId symbol
        type: type
        translation: nameTranslate ctx, atom, symbol, type, ctx.arity symbol
      }
    else
      # log "deferring in rhs for #{symbol}"
      ctx.doDefer atom, symbol
      translation: deferredExpression()

constPattern = (ctx, symbol) ->
  exp = ctx.assignTo()
  precs: [(cond_ switch symbol
      when 'True' then exp
      when 'False' then (jsUnary "!", exp)
      else
        (jsBinary "instanceof", exp, (validIdentifier symbol)))]

nameTranslate = (ctx, atom, symbol, type, arity) ->
  if atom.label is 'const'
    switch symbol
      when 'True' then 'true'
      when 'False' then 'false'
      else
        (jsAccess (validIdentifier symbol), "_value")
  else
    (irReference symbol, type, arity)

numericalCompile = (ctx, symbol) ->
  translation = if symbol[0] is '~' then (jsUnary "-", symbol[1...]) else symbol
  type: toConstrained typeConstant 'Num'
  translation: translation
  pattern: literalPattern ctx, translation

regexCompile = (ctx, symbol) ->
  type: toConstrained typeConstant 'Regex'
  translation: symbol
  pattern:
    if ctx.assignTo()
      precs: [cond_ (jsBinary "===",
        (jsAccess ctx.assignTo(), "string"), "#{symbol}.string")]

specialCharacters =  "\\newline \\tab \\formfeed \\backspace \\return".split ' '
charCompile = (ctx, atom, symbol) ->
  translation =
    if symbol.length is 2
      '"' + symbol[1] + '"'
    else if symbol is "\\space"
      ' '
    else if symbol in specialCharacters
      "\"\\#{symbol[1]}\""
    else if /^\\x[a-fA-F0-9]{2}/.test symbol
      '"' + symbol + '"'
    else if /^\\u[a-fA-F0-9]{4}/.test symbol
      '"' + symbol + '"'
    else
      malformed ctx, atom, 'Unrecognized character'
      ''
  type: toConstrained charType
  translation: translation
  pattern: literalPattern ctx, translation

literalPattern = (ctx, translation) ->
  if ctx.assignTo()
    precs: [cond_  (jsBinary "===", ctx.assignTo(), translation)]

deferredExpression = ->
  jsNoop()

# type expressions syntax
# or
#   atom -> or
#     type constant
#     type variable
#     partial type class (but we don't know that in syntax phase - get rid of phases?)
#   form -> or
#     call
#       type constructor
#       types
#     tuple
#       type
#     call (partial type class call)
#       type class
#       types
syntaxType = (expression) ->
  # ignore type classes for now
  if isName expression
    expression.label = if isCapital then 'typename' else 'typevar'
  else if isTuple expression
    map syntaxType, (_terms expression)
  else if isCall expression
    (_operator expression).label = 'typecons'
    map syntaxType, (_arguments expression)

syntaxNewName = (ctx, message, atom) ->
  curried = (atom) ->
    syntaxNameAs ctx, message, 'name', atom
  if atom then curried atom else curried

syntaxNameAs = (ctx, message, label, atom) ->
  curried = (atom) ->
    if isName atom
      atom.label = label
      true
    else
      malformed ctx, atom, message
  if atom then curried atom else curried

call_ = (op, args) ->
  concat [
    tokenize '('
    [op]
    args
    tokenize ')'
  ]

tuple_ = (list) ->
  concat [
    tokenize '['
    list
    tokenize ']'
  ]

fn_ = (params, body) ->
  (call_ (token_ 'fn'), [(tuple_ params), body])

token_ = (string) ->
  (tokenize string)[0]

string_ = (string) ->
  "\"#{string}\""

translateIr = (ctx, irAst) ->
  walkIr irAst, (ast) ->
    if ast.ir
      ast.ir ctx, ast
    else
      walked = {}
      for name, node of ast when name isnt 'js'
        walked[name] = node and translateIr ctx, node
      walked.js = ast.js
      walked

irDefinition = (type, expression) ->
  {ir: irDefinitionTranslate, type, expression}

# TODO: This must always wrap a function, because if the expression
#       is not a function then it can't need type class dictionaries
#       ^.___ not necessarily, we could have a tuple of functions or similar
irDefinitionTranslate = (ctx, {type, expression}) ->
  finalType = substitute ctx.substitution, type
  reducedConstraints = reduceConstraints ctx, finalType.constraints
  ctx.updateClassParams()
  # TODO: what about the class dictionaries order?
  counter = {}
  classParams = newMap()
  classParamNames = for constraint in reducedConstraints when not isAlreadyParametrized ctx, constraint
    {className} = constraint
    names = typeNamesOfNormalized constraint
    typeMap = nestedLookupInMap classParams, names
    if not typeMap
      nestedAddToMap classParams, names, (typeMap = newMap())
    dictName = "_#{className}_#{counter[className] ?= 0; ++counter[className]}"
    addToMap typeMap, className, dictName
    dictName
  ctx.addClassParams classParams
  if _notEmpty classParamNames
    if expression.ir is irFunctionTranslate
      (irFunctionTranslate ctx,
        name: expression.name
        params: join classParamNames, expression.params
        body: expression.body)
    else
      (jsFunction
        params: classParamNames
        body: [(jsReturn translateIr ctx, expression)])
  else
    translateIr ctx, expression

irCall = (type, op, args) ->
  {ir: irCallTranslate, type, op, args}

irCallTranslate = (ctx, {type, op, args}) ->
  finalType = substitute ctx.substitution, type
  # log op, (printType type), printType finalType
  classParams =
    if op.ir is irReferenceTranslate and ctx.isMethod op.name, op.type
      []
    else
      dictsForConstraint ctx, finalType.constraints
  op =
    if op.ir is irReferenceTranslate and not ctx.isMethod op.name, op.type
      validIdentifier op.name
    else
      translateIr ctx, op
  (jsCall op, (join classParams, (translateIr ctx, args)))


irReference = (name, type, arity) ->
  {ir: irReferenceTranslate, name, type, arity}

irReferenceTranslate = (ctx, {name, type, arity}) ->
  if ctx.isMethod name, type
    translateIr ctx, (irMethod type, name)
  else
    finalType = substitute ctx.substitution, type
    classParams = dictsForConstraint ctx, finalType.constraints
    if classParams.length > 0
      (irFunctionTranslate ctx,
        params: arity
        body: [(jsReturn (jsCall (validIdentifier name), (join classParams, arity)))])
    else
      validIdentifier name


irMethod = (type, name) ->
  {ir: irMethodTranslate, type, name}

irMethodTranslate = (ctx, {type, name}) ->
  finalType = substitute ctx.substitution, type
  # log "irmethod", name, finalType.constraints
  resolvedMethod =
    for dict in dictsForConstraint ctx, finalType.constraints
      (jsAccess dict, name)
  if resolvedMethod.length > 1
    throw new Error "expected one constraint on a method"
  else if resolvedMethod.length is 1
    resolvedMethod[0]
  else
    method

dictsForConstraint = (ctx, constraints) ->
  for constraint in constraints
    dictForConstraint ctx, constraint

dictForConstraint = (ctx, constraint) ->
  if isNormalizedConstraint constraint
    (ctx.classParamNameFor constraint) or findSubClassParam ctx, constraint
  else if _notEmpty (constraints = (constraintsFromInstance ctx, constraint) or [])
    (jsCall (instanceDictFor ctx, constraint),
      (dictsForConstraint ctx, constraints))
  else
    (instanceDictFor ctx, constraint)

findSubClassParam = (ctx, constraint) ->
  toClassName = (c) -> c.className
  for className, dict of values ctx.classParamsForType constraint
    if chain = findSuperClassChain ctx, className, constraint.className
      return accessList dict, chain
  throw new Error "Couldn't find dict for #{safePrintType constraint}"

findSuperClassChain = (ctx, className, targetClassName) ->
  for s in (ctx.classNamed className).supers
    name = s.className
    if name is targetClassName
      return [name]
    else if chain = findSuperClassChain ctx, name, targetClassName
      return join [name], chain
  undefined

typeNamesOfNormalized = (constraint) ->
  #map (({name}) -> name), constraint.types.types
  [printType constraint.types.types[0]]

accessList = (what, list) ->
  [first, rest...] = list
  if first
    accessList (jsAccess what, first), rest
  else
    what

isAlreadyParametrized = (ctx, constraint) ->
  !!ctx.classParamNameFor constraint

instanceDictFor = (ctx, constraint) ->
  for {name, type} in (ctx.classNamed constraint.className).instances
    # TODO: support lookup of composite types, by traversing left depth-first
    if toMatchTypes (freshInstance ctx, type).type.types, constraint.types
      return validIdentifier name
  throw new Error "no instance for #{safePrintType constraint}"

irFunction = ({name, params, body}) ->
  {ir: irFunctionTranslate, name, params, body}

irFunctionTranslate = (ctx, {name, params, body}) ->
  (jsCall "λ#{params.length}", [
    (jsFunction
      name: (validIdentifier name if name)
      params: map validIdentifier, params
      body: translateIr ctx, body)])


irArray = (items) ->
  {ir: irArrayTranslate, items}

irArrayTranslate = (ctx, {items}) ->
  (jsCall "Immutable.List.of", (translateIr ctx, items))


irList = (items) ->
  {ir: irListTranslate, items}

irListTranslate = (ctx, {items}) ->
  (jsCall "Immutable.Stack.of", (translateIr ctx, items))


irMap = (keys, elems) ->
  {ir: irMapTranslate, keys, elems}

irMapTranslate = (ctx, {keys, elems}) ->
  (jsCall "Immutable.Map", [(jsArray (map jsArray,
    (zip (translateIr ctx, keys), (translateIr ctx, elems))))])


irSet = (items) ->
  {ir: irSetTranslate, items}

irSetTranslate = (ctx, {items}) ->
  (jsCall "Immutable.Set.of", items)


irJsCompatible = (type, expression) ->
  {ir: irJsCompatibleTranslate, type, expression}

irJsCompatibleTranslate = (ctx, {type, expression}) ->
  finalType = substitute ctx.substitution, type
  translated = translateIr ctx, expression
  if isCustomCollectionType finalType
    (jsCall (jsAccess translated, 'toArray'), [])
  else
    translated

isCustomCollectionType = ({type}) ->
  helpContext = new Context
  newVar = -> helpContext.freshTypeVariable star
  (toMatchTypes (applyKindFn arrayType, newVar()), type) or
    (toMatchTypes (applyKindFn hashmapType, newVar(), newVar()), type) or
    (toMatchTypes (applyKindFn hashsetType, newVar()), type)


isTypeAnnotation = (expression) ->
  (isCall expression) and (':' is _symbol _operator expression)

isComment = (expression) ->
  (isCall expression) and ('#' is _symbol _operator expression)

isCall = (expression) ->
  (isForm expression) and (isEmptyForm expression) and
    expression[0].symbol is '('

isRecord = (expression) ->
  if isTuple expression
    [labels, values] = unzip pairs _terms expression
    labels.length is values.length and (allMap isLabel, labels)

isSeq = (expression) ->
  (isForm expression) and expression[0].symbol is '{'

isTuple = (expression) ->
  (isForm expression) and expression[0].symbol is '['

isEmptyForm = (form) ->
  (_terms form).length > 0

isForm = (expression) ->
  Array.isArray expression

isLabel = (atom) ->
  /[^\\]:$/.test atom.symbol

isCapital = (atom) ->
  /[A-Z]/.test atom.symbol

isName = (expression) ->
  throw new Error "Nothing passed to isName" unless expression
  (isAtom expression) and (expression.symbol in ['~', '/', '//'] or /[^~"'\/].*/.test expression.symbol)

isAtom = (expression) ->
  not (Array.isArray expression)

isExpressionOrFake = (node) ->
  (isFake node) or (isExpression node)

isFake = (node) ->
  node.fake

isExpression = (node) ->
  node.label not in ['whitespace', 'indent'] and
    (not node.symbol or node.symbol not in allDelims)

_labeled = (list) ->
  pairsLeft isLabel, list

pairsLeft = (leftTest, list) ->
  listToPairsWith list, (item, next) ->
    if leftTest item
      [item, (if next and not leftTest next then next else null)]
    else
      if leftTest item
        [item, null]
      else
        [null, item]

pairsRight = (rightTest, list) ->
  pairsLeft ((x) -> not rightTest x), list
  ###listToPairsWith list, (item, next) ->
    if next and rightTest next
      [(if not rightTest item then item else null), next]
    else
      if rightTest item
        [null, item]
      else
        [item, null]###

listToPairsWith = (list, convertBy) ->
  filter _is, (i = 0; while i < list.length
    result = convertBy list[i], list[i + 1]
    if result[0] and result[1]
      i++
    i++
    result)

pairs = (list) ->
  for el, i in list by 2
    [el, list[i + 1]]

tuplize = (n, list) ->
  for e, i in list by n
    list[i...i + n]

unzip = (pairs) ->
  [
    map _fst, pairs
    map _snd, pairs
  ]

zip = (list1, list2) ->
  zipWith ((a, b) -> [a, b]), list1, list2

zipWith = (fn, list1, list2) ->
  for el, i in list1
    fn el, list2[i]

replicate = (expression, newForm) ->
  newForm

retrieve = (expression, newForm) ->
  expression.tea = newForm.tea
  expression.malformed = newForm.malformed

filterAst = (test, expression) ->
  join (filter test, [expression]),
    if isForm expression
      concat (filterAst test, term for term in _terms expression)
    else
      []

translateStatementsToJs = (jsAstList) ->
  listOfLines translateToJs jsAstList

translateToJs = (jsAst) ->
  walkIr jsAst, (ast) ->
    args = {}
    for name, node of ast when name isnt 'js'
      args[name] = node and translateToJs node
    ast.js args

walkIr = (ast, cb) ->
  if Array.isArray ast
    for node in ast
      walkIr node, cb
  else if ast.ir or ast.js
    cb ast
  else
    ast

printIr = (ast) ->
  walkIr ast, (ast) ->
    args = {}
    for name, node of ast
      args[name] =
        if node?
          if name in ['js', 'ir'] then true else printIr node
        else
          undefined
    args

jsCallMethod = (object, methodName, args) ->
  (jsCall (jsAccess object, methodName), args)

jsAccess = (lhs, name) ->
  {js: jsAccessTranslate, lhs, name}

jsAccessTranslate = ({lhs, name}) ->
  if /^\d/.test name
    "#{lhs}[#{name}]"
  else if (validIdentifier name) isnt name
    "#{lhs}['#{name}']"
  else
    "#{lhs}.#{name}"


jsArray = (elems) ->
  {js: jsArrayTranslate, elems}

jsArrayTranslate = ({elems}) ->
  "[#{listOf elems}]"


jsAssign = (lhs, rhs) ->
  {js: jsAssignTranslate, lhs, rhs}

jsAssignTranslate = ({lhs, rhs}) ->
  "(#{lhs} = #{rhs})"


jsAssignStatement = (lhs, rhs) ->
  {js: jsAssignStatementTranslate, lhs, rhs}

jsAssignStatementTranslate = ({lhs, rhs}) ->
  "#{lhs} = #{rhs};"


jsBinary = (op, lhs, rhs) ->
  {js: jsBinaryTranslate, op, lhs, rhs}

jsBinaryTranslate = ({op, lhs, rhs}) ->
  jsBinaryMultiTranslate {op, args: [lhs, rhs]}


jsBinaryMulti = (op, args) ->
  {js: jsBinaryMultiTranslate, op, args}

jsBinaryMultiTranslate = ({op, args}) ->
  """(#{args.join " #{op} "})"""


jsCall = (fun, args) ->
  {js: jsCallTranslate, fun, args}

jsCallTranslate = ({fun, args}) ->
  "#{fun}(#{listOf args})"


jsConditional = (condCasePairs, elseCase) ->
  {js: jsConditionalTranslate, condCasePairs, elseCase}

jsConditionalTranslate = ({condCasePairs, elseCase}) ->
  ((for [cond, branch], i in condCasePairs
    control = if i is 0 then 'if' else ' else if'
    """#{control} (#{cond}) {
        #{listOfLines branch}
      }""").join '') + """ else {
        #{elseCase}
      }"""


jsExprList = (elems) ->
  {js: jsExprListTranslate, elems}

jsExprListTranslate = ({elems}) ->
  "(#{listOf elems})"


jsFunction = ({name, params, body}) ->
  throw new Error "body of jsFunction must be a list" if not Array.isArray body
  {js: jsFunctionTranslate, name, params, body}

jsFunctionTranslate = ({name, params, body}) ->
  "function #{name or ''}(#{listOf params}){#{blockOfLines body}}"


jsMalformed = (message) ->
  {js: jsMalformedTranslate, message}

jsMalformedTranslate = ({message}) ->
  message


jsMethod = (object, method, args) ->
  {js: jsMethodTranslate, object, method, args}

jsMethodTranslate = ({object, method, args}) ->
  translateToJs (jsCall (jsAccess object, method), args)


jsNew = (classFun, args) ->
  {js: jsNewTranslate, classFun, args}

jsNewTranslate = ({classFun, args}) ->
  "new #{classFun}(#{listOf args})"


jsNoop = ->
  {js: jsNoopTranslate}

jsNoopTranslate = ->
  ""


jsReturn = (arg) ->
  {js: jsReturnTranslate, arg}

jsReturnTranslate = ({arg}) ->
  "return #{arg};"


jsTernary = (cond, thenExp, elseExp) ->
  {js: jsTernaryTranslate, cond, thenExp, elseExp}

jsTernaryTranslate = ({cond, thenExp, elseExp}) ->
  "#{cond} ? #{thenExp} : #{elseExp}"


jsUnary = (op, arg) ->
  {js: jsUnaryTranslate, op, arg}

jsUnaryTranslate = ({op, arg}) ->
  "#{op}#{arg}"


jsValue = (value) ->
  {js: jsValueTranslate, value}

jsValueTranslate = ({value}) ->
  value


jsVarDeclaration = (name, rhs) ->
  {js: jsVarDeclarationTranslate, name, rhs}

jsVarDeclarationTranslate = ({name, rhs}) ->
  "var #{name} = #{rhs};"


jsVarDeclarations = (names) ->
  {js: jsVarDeclarationsTranslate, names}

jsVarDeclarationsTranslate = ({names}) ->
  "var #{listOf names};"

blockOfLines = (lines) ->
  if lines.length is 0
    ''
  else
    '\n' + (listOfLines lines) + '\n'

listOfLines = (lines) ->
  lines.join '\n'

indentLines = (indent, lines) ->
  blockOfLines map ((line) -> indent + line), (filter _notEmpty, lines)

listOf = (args) ->
  args.join ', '

theme =
  keyword: 'red'
  numerical: '#FEDF6B'
  const: '#FEDF6B'
  typename: '#FEDF6B'
  typecons: '#67B3DD'
  label: '#9C49B6'
  string: '#FEDF6B'
  char: '#FEDF6B'
  paren: '#444'
  name: '#9EE062'
  recurse: '#67B3DD'
  param: '#FDA947'
  comment: 'grey'
  operator: '#67B3DD'
  malformed: '#880000'
  normal: 'white'

colorize = (color, string) ->
  "<span style=\"color: #{color}\">#{string}</span>"

# TODO: support require
# Ideally shouldnt have to, just doing it to get around the def checking
labelRequires = (ast) ->
  macro 'require', ast, (node, words) ->
    [req, module, list] = words
    module.label = 'symbol'
    for fun in inside list
      fun.label = 'symbol'
    node

# TODO: figure out comments
# typeComments = (ast) ->
#   macro '#', ast, (node) ->
#     node.type = 'comment'
#     node
labelComments = (call) ->
  for term in _validTerms call
    term.label = 'comment'


# Syntax printing to HTML

toHtml = (highlighted) ->
  crawl highlighted, (word, symbol, parent) ->
    (word.ws or '') + colorize(theme[labelOf word, parent], symbol)

labelOf = (word, parent) ->
  word.malformed and 'malformed' or
    parent?.malformed and word.symbol in allDelims and 'malformed' or
      word.label or 'normal'

collapse = (nodes) ->
  collapsed = ""
  for node in nodes
    crawl node, (node) ->
      collapsed += node
  collapsed

parentize = (ast) ->
  walk ast, (node) ->
    for subNode in node
      subNode.parent = node

walk = (ast, cb) ->
  if Array.isArray ast
    cb ast
    for node in ast
      walk node, cb
  ast

# end of Syntax printing

# for including in other files
# TODO: support with arbitrary left patterns, prob via context
exportList = (source) ->
  wheres = whereList inside preCompileDefs source
  names = []
  for [pattern] in wheres
    if pattern.symbol and pattern.symbol isnt '_'
      names.push pattern.symbol
  names

# Valid identifiers

validIdentifier = (name) ->
  (if inSet reservedInJs, name
    "#{name}_"
  else if name is '.'
    "dot_"
  else
    name)
    .replace(/\+/g, 'plus_')
    .replace(/\-/g, '__')
    .replace(/\*/g, 'times_')
    .replace(/\//g, 'over_')
    .replace(/\!/g, 'not_')
    .replace(/\=/g, 'eq_')
    .replace(/\</g, 'lt_')
    .replace(/\>/g, 'gt_')
    .replace(/\~/g, 'neg_')
    .replace(/\^/g, 'pow_')
    # .replace(/\√/g, 'sqrt_')
    # .replace(/\./g, 'dot_')
    .replace(/\&/g, 'and_')
    .replace(/\|/g, 'or_')
    .replace(/\?/g, 'p_')


# graphToWheres = (graph) ->
#   graph.map ({def: [pattern, def], missing}) -> [pattern, def, missing]

# Finding hoistables - keeping for hoisting where definitions to match

# # Returns two new graphs, one which needs hoisting and one which doesnt
# findHoistableWheres = ([graph, lookupTable]) ->
#   reversedDependencies = reverseGraph graph
#   hoistableNames = {}
#   hoistable = []
#   valid = []
#   for {missing, names} in graph
#     # This def needs hoisting
#     if missing.size > 0
#       hoistableNames[n] = yes for n in names
#       # So do all defs depending on it
#       for name in names
#         for dep in (reversedDependencies[name] or [])
#           for n in dep.names
#             hoistableNames[n] = yes
#   for where in graph
#     {names} = where
#     hoisted = no
#     for n in names
#       # if one of the names needs hoisting
#       if hoistableNames[n]
#         hoistable.push where
#         hoisted = yes
#         break
#     if not hoisted
#       valid.push where
#   validLookup = lookupTableForGraph valid
#   # Remove the valid deps from hoistable defs so that the graphs are mutually exclusive
#   for where in hoistable
#     removeFromSet where.set, name for name of validLookup
#   [
#     [hoistable, lookupTableForGraph hoistable]
#     [valid, validLookup]
#   ]

# Topological sort the dependency graph - keeping for simplifying mutually recursive definitions

# sortTopologically = ([graph, dependencies]) ->
#   reversedDependencies = reverseGraph graph
#   independent = []
#   console.log graph, dependencies

#   for node in graph
#     node.origSet = cloneSet node.set

#   moveToIndependent = (node) ->
#     independent.push node
#     delete dependencies[name] for name in node.names

#   for parent in graph when parent.set.size is 0
#     moveToIndependent parent

#   sorted = []
#   while independent.length > 0
#     finishedParent = independent.pop()
#     sorted.push finishedParent
#     for child in reversedDependencies[finishedParent.names[0]] or []
#       removeFromSet child.set, name for name in finishedParent.names
#       moveToIndependent child if child.set.size is 0


#   console.log "done", sorted, dependencies
#   for node in sorted
#     node.set = node.origSet

#   for parent of dependencies
#     throw new Error "Cyclic definitions between #{(name for name of dependencies).join ','}"
#   sorted

# reverseGraph = (nodes) ->
#   reversed = {}
#   for child in nodes
#     for dependencyName of child.set.values
#       (reversed[dependencyName] ?= []).push child
#   reversed

# # Graph:
# #   [{def: [pattern, def], set: [names that depend on this], names: [names in pattern]}]
# # Lookup by name:
# #   Map (name -> GraphElement)
# constructDependencyGraph = (wheres) ->
#   lookupByName = {}
#   deps = newSet()
#   # find all defined names
#   graph = for [pattern, def], i in wheres
#     def: [pattern, def]
#     set: newSet()
#     names: findNames pattern
#     missing: newSet()

#   lookupByName = lookupTableForGraph graph

#   # then construct local graph
#   for [pattern, def], i in wheres

#     child = graph[i]
#     crawlWhile def,
#       (parent) ->
#         not parent.type
#       (node, token) ->
#         definingScope = lookupIdentifier token, node
#         parent = lookupByName[token]
#         if parent
#           addToSet child.set, name for name in parent.names unless child is parent
#           addToSet deps, parent
#         else if isReference(node) and !lookupIdentifier token, node
#           addToSet child.missing, node.symbol
#   [graph, lookupByName]

# lookupTableForGraph = (graph) ->
#   table = {}
#   for where in graph
#     {names} = where
#     for name in names
#       table[name] = where
#   table

# findNames = (pattern) ->
#   names = []
#   crawl pattern, (node) ->
#     if node.label is 'name'
#       names.push node.symbol
#   names


# Pattern matching in assignment (used in Match as well)

# Maps
# (pattern) ->
#   # expect lists from here on
#   if not Array.isArray pattern
#     throw new Error "pattern match expected pattern but saw token #{pattern.symbol}"
#   [constr, elems...] = inside pattern
#   label = "'#{constructorToJsField constr}'" if constr
#   trigger: isMap pattern
#   cache: true
#   cacheMore: (exp) -> if elems.length > 1 then ["#{exp}[#{label}]"] else []
#   cond: (exp) ->
#     ["#{label} in #{exp}"]
#   assignTo: (exp, value) ->
#     value ?= "#{exp}[#{label}]"
#     recurse: (for elem, i in elems
#       [elem, "#{value}[#{i}]"])


# end of Pattern matching

# Keeping around for implementing hoisting of wheres into match
# trueMacros =
#   'match': (hoistableWheres, onwhat, cases...) ->
#     varNames = []
#     if not onwhat
#       throw new Error 'match `onwhat` missing'
#     if cases.length % 2 != 0
#       throw new Error 'match missing result for last pattern'
#     exp = compileImpl onwhat
#     compiledCases = (for [pattern, result], i in pairs cases
#       control = if i is 0 then 'if' else ' else if'
#       {precs, assigns} = patternMatch pattern, exp, mainCache
#       vars = findDeclarables precs
#       if vars.length >= 1
#         mainCache = [precs[0]]
#         varNames.push vars[1...]...
#       else
#         varNames.push vars...
#       {conds, preassigns} = constructCond precs
#       [hoistedWheres, furtherHoistable] = hoistWheres hoistableWheres, assigns
#       """#{control} (#{conds}) {
#           #{preassigns.concat(assigns).map(compileVariableAssignment).join '\n  '}
#           #{hoistedWheres.map(compileDef).join '\n  '}
#           return #{compileImpl result, furtherHoistable};
#         }"""
#       )
#     mainCache ?= []
#     mainCache = mainCache.map ({cache}) -> compileVariableAssignment cache
#     varDecls = if varNames.length > 0 then ["var #{varNames.join ', '};"] else []
#     content = mainCache.concat(varDecls, compiledCases.join '').join '\n'
#     """(function(){
#       #{content} else {throw new Error('match failed to match');}}())"""
#   'require': (from, list) ->
#     args = inside(list).map(compileName).map(toJsString).join ', '
#     "$listize(window.requireModule(#{toJsString from.symbol}, [#{args}]))"
#   'list': (items...) ->
#     "$listize(#{compileList items})"

# findDeclarables = (precs) ->
#   precs.filter((p) -> p.cache).map(({cache}) -> cache[0])

hoistWheres = (hoistable, assigns) ->
  defined = addAllToSet newSet(), (n for [n, _] in assigns)
  hoistedNames = newSet()
  hoisted = []
  notHoisted = []
  for where in hoistable
    {missing, names, def, set} = where
    stillMissingNames = addAllToSet newSet(),
      (name for name in (setToArray missing) when not inSet defined, name)
    stillMissingDeps = removeAllFromSet (cloneSet set), setToArray hoistedNames
    if stillMissingNames.size == 0 and stillMissingDeps.size == 0
      hoisted.push def
      addAllToSet hoistedNames, names
    else
      notHoisted.push
        def: def
        names: names
        missing: stillMissingNames
        set: stillMissingDeps
  [hoisted, notHoisted]

toJsString = (symbol) ->
  "'#{symbol}'"

compileVariableAssignment = ([to, from]) ->
  # "var #{to} = #{from};"
  (jsVarDeclaration to, from)

# Takes precs and constructs the correct condition
# if precs empty, returns true
# preassigns are assignments that are not followed by a condition, so they
# should be after the condition is checked
constructCond = (precs) ->
  return conds: 'true', preassigns: [] if precs.length is 0
  lastCond = no
  cases = []
  singleCase = []

  translateCondPart = ({cond, cache}) ->
    if cond
      cond
    else
      # "(#{cache[0]} = #{cache[1]})"
      (jsAssign cache[0], cache[1])

  # Each case is a (possibly empty) list of caching followed by a condition
  pushCurrentCase = ->
    condParts = map translateCondPart, singleCase
    cases.push if condParts.length is 1
      condParts[0]
    else
      # "(#{listOf condParts})"
      (jsExprList condParts)
    singleCase = []

  for prec, i in precs
    # Don't know if still need to ignore the first cache, probably did
    # because of the global cache
    # if i is 0 and prec.cache
    #   continue
    if lastCond
      pushCurrentCase()
    singleCase.push prec
    lastCond = prec.cond

  preassigns = if lastCond
    pushCurrentCase()
    []
  else
    map _cache, singleCase
  conds: (jsBinaryMulti "&&", cases)# cases.join " && "
  preassigns: preassigns

# end of Match

# Simple macros and builtin functions
# TODO: reimplement the simple macros

macros =
  'if': (cond, zen, elz) ->
    """(function(){if (#{cond}) {
      return #{zen};
    } else {
      return #{elz};
    }}())"""
  'access': (field, obj) ->
    # TODO: use dot notation if method is valid field name
    "(#{obj})[#{field}]"
  'call': (method, obj, args...) ->
    "(#{macros.access method, obj}(#{args.join ', '}))"
  'new': (clazz, args...) ->
    "(new #{clazz}(#{args.join ', '}))"


expandBuiltings = (mapping, cb) ->
  for op, i in mapping.from
    macros[op] = cb mapping.to[i]

unaryFnMapping =
  from: 'sqrt alert! not empty'.split ' '
  to: 'Math.sqrt window.log ! $empty'.split ' '

expandBuiltings unaryFnMapping, (to) ->
  (x) ->
    if x
      "#{to}(#{x})"
    else
      "function(__a){return #{to}(__a);}"

binaryFnMapping =
  from: []
  to: []

expandBuiltings binaryFnMapping, (to) ->
  (x, y) ->
    if x and y
      "#{to}(#{x}, #{y})"
    else if x
      "function(__b){return #{to}(#{a}, __b);}"
    else
      "function(__a, __b){return #{to}(__a, __b);}"

invertedBinaryFnMapping =
  from: '^'.split ' '
  to: 'Math.pow'.split ' '

expandBuiltings invertedBinaryFnMapping, (to) ->
  (x, y) ->
    if x and y
      "#{to}(#{y}, #{x})"
    else if x
      "function(__b){return #{to}(__b, #{a});}"
    else
      "function(__a, __b){return #{to}(__b, __a);}"

binaryOpMapping =
  from: '+ * = != and or'.split ' '
  to: '+ * == != && ||'.split ' '

expandBuiltings binaryOpMapping, (to) ->
  (x, y) ->
    if x and y
      "(#{x} #{to} #{y})"
    else if x
      "function(__b){return #{x} #{to} __b;}"
    else
      "function(__a, __b){return __a #{to} __b;}"

invertedBinaryOpMapping =
  from: '- / rem < > <= >='.split ' '
  to: '- / % < > <= >='.split ' '

expandBuiltings invertedBinaryOpMapping, (to) ->
  (x, y) ->
    if x and y
      "(#{y} #{to} #{x})"
    else if x
      "function(__b){return __b #{to} #{x};}"
    else
      "function(__a, __b){return __b #{to} __a;}"

# end of Simple macros

# Default type context with builtins

binaryMathOpType = '(Fn Num Num Num)'
comparatorOpType = '(Fn a a Bool)'

builtInTypeNames = ->
  arrayToMap map (({name, kind}) -> [name, kind]), [
    arrowType
    arrayType
    listType
    hashmapType
    hashsetType
    stringType
    charType
    boolType
    numType
  ]

builtInDefinitions = ->
  newMapWith 'True', (type: (quantifyAll toConstrained boolType), arity: []),
      'False', (type: (quantifyAll toConstrained boolType), arity: [])
      '==', (
        type: (quantifyAll toConstrained (typeFn (atomicType 'a', star), (atomicType 'a', star), boolType)),
        arity: ['x', 'y'])
  # concatMaps (mapMap desiplifyTypeAndArity, newMapWith '&', '(Fn a b b)', # TODO: replace with actual type
  #   'show-list', '(Fn a b)' # TODO: replace with actual type
  #   'from-nullable', '(Fn a b)' # TODO: replace with actual type JS -> Maybe a

  # TODO match

  # 'if', '(Fn Bool a a a)'
  # TODO JS interop

  # 'sqrt', '(Fn Num Num)'
  # 'not', '(Fn Bool Bool)'

  # '^', binaryMathOpType

  # '~', '(Fn Num Num)'

  # '+', binaryMathOpType
  # '*', binaryMathOpType
  # '==', comparatorOpType
  # '!=', comparatorOpType
  # 'and', '(Fn Bool Bool Bool)'
  # 'or', '(Fn Bool Bool Bool)'

  # '-', binaryMathOpType
  # '/', binaryMathOpType
  # 'rem', binaryMathOpType
  # '<', comparatorOpType
  # '>', comparatorOpType
  # '<=', comparatorOpType
  # '>=', comparatorOpType
  # ),
  # newMapWith 'True', (type: boolType, arity: [])
  #   'False', (type: boolType, arity: [])
  #   'empty-array', (type: (parseUnConstrainedType '(Fn (Array a))'), arity: [])
  #   'cons-array', (type: (parseUnConstrainedType '(Fn a (Array a) (Array a))'), arity: ['what', 'onto'])

desiplifyTypeAndArity = (simple) ->
  type = parseUnConstrainedType simple
  args = collectArgs type.type.type
  arity = if Array.isArray args then args.length else 0
  type: type
  arity: ("a#{i}" for i in  [0...arity - 2])

parseUnConstrainedType = (string) ->
  quantifyAll toConstrained typeCompile astize tokenize string

desiplifyType = (simple) ->
  if Array.isArray simple
    typeFn (map desiplifyType, simple)...
  else if /^[A-Z]/.test simple
    typeConstant simple
  else
    new TypeVariable simple, star


# Set/Map implementation

newSet =
newMap = ->
  size: 0
  values: {}

addToSet = (set, key) ->
  addToMap set, key, true

addToMap = (set, key, value) ->
  return if set.values[key]
  set.size++
  set.values[key] = value
  set

# Precondition: the key is in the Map
replaceInMap = (map, key, value) ->
  map.values[key] = value

replaceOrAddToMap = (map, key, value) ->
  map.size++ unless map.values[key]
  map.values[key] = value
  map

removeFromSet =
removeFromMap = (set, key) ->
  return if !set.values[key]?
  set.size -= 1
  delete set.values[key]

addAllToSet = (set, array) ->
  for v in array
    addToSet set, v
  set

removeAllFromSet = (set, array) ->
  for v in array
    removeFromSet set, v
  set

keysOfMap =
setToArray = (set) ->
  key for key of set.values

mapToArray = (map) ->
  val for key, val of map.values

mapToArrayVia = (fn, map) ->
  (fn key, val) for key, val of map.values

cloneSet =
cloneMap = (set) ->
  clone = newSet()
  for key, val of set.values
    addToMap clone, key, val
  clone

lookupInMap =
inSet = (set, name) ->
  set.values[name]

isSetEmpty =
isMapEmpty = (set) ->
  set.size is 0

mapMap = (fn, set) ->
  initialized = newMap()
  for key, val of set.values
    addToMap initialized, key, fn val
  initialized

mapSet =
rehashMap = (fn, set) ->
  initialized = newMap()
  for key, val of set.values
    addToMap initialized, (fn key), val
  initialized

filterSet =
filterMap = (fn, set) ->
  initialized = newMap()
  for key, val of set.values when fn key, val
    addToMap initialized, key, val
  initialized

partitionMap = (fn, map) ->
  filteredIn = newMap()
  filteredOut = newMap()
  for key, val of map.values
    addToMap (if fn val, key
      filteredIn
    else
      filteredOut), key, val
  [filteredIn, filteredOut]

reduceSet = (fn, def, set) ->
  (setToArray set).reduce (prev, curr) ->
    fn curr, prev
  , def

newSetWith = (args...) ->
  initialized = newSet()
  for k in args
    addToSet initialized, k
  initialized

newMapWith = (args...) ->
  initialized = newMap()
  for k, i in args by 2
    addToMap initialized, k, args[i + 1]
  initialized

newMapKeysVals = (keys, vals) ->
  initialized = newMap()
  for item, i in vals
    addToMap initialized, keys[i], item
  initialized

concatSets =
concatMaps = (maps...) ->
  concated = newMap()
  for m in maps
    for k, v of m.values
      addToMap concated, k, v
  concated

concatConcatMaps = (maps) ->
  concated = newMap()
  for m in maps
    for k, v of m.values
      if list = lookupInMap concated, k
        list.push v
      else
        addToMap concated, k, [v]
  concated

subtractSets =
subtractMaps = (from, what) ->
  subtracted = newMap()
  for k, v of from.values when k not of what.values
    addToMap subtracted, k, v
  subtracted

arrayToSet = (array) ->
  addAllToSet newSet(), array

arrayToMap = (pairs) ->
  created = newMap()
  for [key, value] in pairs
    addToMap created, key, value
  created

objectToMap = (object) ->
  created = newMap()
  for key, value of object
    addToMap created, key, value
  created

values = (map) ->
  map.values

doIntersect = (setA, setB) ->
  (subtractSets setA, setB).size isnt setA.size

isSubset = (superSet, subSet) ->
  (subtractSets subSet, superSet).size is 0

intersectRight = (mapA, mapB) ->
  intersection = newMap()
  for k, v of mapB.values when k of mapA.values
    addToMap intersection, k, v
  intersection

nestedAddToMap = (map, keys, value) ->
  [nestedKeys..., finalKey] = keys
  for key in nestedKeys
    map = lookupInMap map, key
    if not map
      map = addToMap map, key, newMap()
  addToMap map, finalKey, value

nestedLookupInMap = (map, keys) ->
  for key in keys
    return null if not map?.size?
    map = lookupInMap map, key
  map

# end of Set

# Type inference and checker ala Mark Jones

unify = (ctx, t1, t2) ->
  throw new Error "invalid args to unify" unless ctx instanceof Context and t1 and t2
  sub = ctx.substitution
  ctx.extendSubstitution mostGeneralUnifier (substitute sub, t1), (substitute sub, t2)

# Returns a substitution
mostGeneralUnifier = (t1, t2) ->
  if t1.TypeVariable
    bindVariable t1, t2
  else if t2.TypeVariable
    bindVariable t2, t1
  else if t1.TypeConstr and t2.TypeConstr and
    t1.name is t2.name
      emptySubstitution()
  else if t1.TypeApp and t2.TypeApp
    s1 = mostGeneralUnifier t1.op, t2.op
    s2 = mostGeneralUnifier (substitute s1, t1.arg), (substitute s1, t2.arg)
    joinSubs s2, s1
  else if t1.Types and t2.Types
    if t1.types.length isnt t2.types.length
      unifyFail t1, t2
    else if _notEmpty t1.types
      s1 = mostGeneralUnifier t1.types[0], t2.types[0]
      s2 = mostGeneralUnifier (new Types t1.types[1...]), (new Types t2.types[1...])
      joinSubs s2, s1
    else
      emptySubstitution()
  else
    unifyFail t1, t2

unifyFail = (t1, t2) ->
  substituionFail "could not unify #{(safePrintType t1)}, #{(safePrintType t2)}"

bindVariable = (variable, type) ->
  if type.TypeVariable and variable.name is type.name
    emptySubstitution()
  else if inSet (findFree type), variable.name
    substituionFail "occurs check failed for #{variable.name}"
    # newMapWith variable.name, "occurs check failed"
  else if not kindsEq (kind variable), (kind type)
    # newMapWith variable.name, "kinds don't match for #{variable.name} and #{safePrintType type}"
    substituionFail "kinds don't match for #{variable.name} and #{safePrintType type}"
  else
    newSubstitution variable.name, type

# Maybe substitution if the types match
# t1 can be more general than t2
toMatchTypes = (t1, t2) ->
  substitution = matchType t1, t2
  if _notEmpty substitution.fails
    null
  else
    substitution

# Returns a substitution
matchType = (t1, t2) ->
  if t1.TypeVariable and kindsEq (kind t1), (kind t2)
    newSubstitution t1.name, t2
  else if t1.TypeConstr and t2.TypeConstr and
    t1.name is t2.name
      emptySubstitution()
  else if t1.TypeApp and t2.TypeApp
    s1 = matchType t1.op, t2.op
    s2 = matchType t1.arg, t2.arg
    s3 = mergeSubs s1, s2
    s3 or
      # newMapWith "could not unify", [(safePrintType t1), (safePrintType t2)]
      unifyFail t1, t2
  else if t1.Types and t2.Types
    if t1.types.length isnt t2.types.length
      unifyFail t1, t2
    else if _notEmpty t1.types
      # log "matching ", (printType t1.types[0]), (printType t2.types[0])
      s1 = matchType t1.types[0], t2.types[0]
      # log "after matching", s1
      # I will imply functional dependency of the form A a b c | a -> b c
      # s2 = mostGeneralUnifier (new Types (substituteList s1, t1.types[1...])), (new Types t2.types[1...])
      s2 = unifyImpliedParams (substitute s1, t1), t2
      s3 = mergeSubs s1, s2
      s3 or
        unifyFail t1, t2
        # newMapWith "could not unify", [(safePrintType t1), (safePrintType t2)]
    else
      emptySubstitution()
  else
    unifyFail t1, t2
    # newMapWith "could not unify", [(safePrintType t1), (safePrintType t2)]

unifyImpliedParams = (t1, t2) ->
  mostGeneralUnifier (new Types t1.types[1...]), (new Types t2.types[1...])

joinSubs = (s1,s2) ->
  subUnion s1, (mapSub ((type) -> substitute s1, type), s2)

mergeSubs = (s1, s2) ->
  agree = (varName) ->
    variable = new TypeVariable varName, star
    typeEq (substitute s1, variable), (substitute s2, variable)
  if allMap agree, subIntersection s1, s2
    subUnion s1, s2
  else
    null

mapSub = (fn, sub) ->
  mapped = emptySubstitution()
  mapped.start = (subStart sub)
  mapped.fails = sub.fails
  for name in [(subStart sub)...(subLimit sub)] by 1 when v = (inSub sub, name)
    setInSub mapped, name, fn v
  mapped

subIntersection = (subA, subB) ->
  for name in [(subStart subB)...(subLimit subB)] by 1 when (inSub subB, name) and (inSub subA, name)
    name

subUnion = (subA, subB) ->
  union = emptySubstitution()
  start = Math.min (subStart subA), (subStart subB)
  end = Math.max (subLimit subA), (subLimit subB)
  union.start = start
  for name in [start...end] by 1
    type = (inSub subA, name) or (inSub subB, name)
    if type
      setInSub union, name, type
  union.fails = [].concat subA.fails, subB.fails
  union

newSubstitution = (name, type) ->
  sub = emptySubstitution()
  sub.vars[0] = type
  sub.start = name
  sub

isFailed = (sub) ->
  sub.fails.length > 0

substituionFail = (failure) ->
  sub = emptySubstitution()
  sub.fails.push failure
  sub

subLimit = (sub) ->
  if sub.start is Infinity then -Infinity else sub.start + sub.vars.length

subStart = (sub) ->
  sub.start

setInSub = (sub, name, value) ->
  sub.vars[name - sub.start] = value

inSub = (sub, name) ->
  sub.vars[name - sub.start]

emptySubstitution = ->
  start: Infinity
  fails: []
  vars: []

# Unlike in Jones, we simply use substitute for both variables and quantifieds
# - variables are strings, wheres quantifieds are ints
substitute = (substitution, type) ->
  if type.TypeVariable
    substitution.vars and (inSub substitution, type.name) or
      substitution.values and (lookupInMap substitution, type.name) or type
  else if type.QuantifiedVar
    substitution[type.var] or type
  else if type.TypeApp
    new TypeApp (substitute substitution, type.op),
      (substitute substitution, type.arg)
  else if type.ForAll
    new ForAll type.kinds, (substitute substitution, type.type)
  else if type.Constrained
    new Constrained (substituteList substitution, type.constraints),
      (substitute substitution, type.type)
  else if type.ClassConstraint
    new ClassConstraint type.className, substitute substitution, type.types
  else if type.Types
    new Types substituteList substitution, type.types
  else
    type

substituteList = (substitution, list) ->
  map ((t) -> substitute substitution, t), list

findFree = (type) ->
  if type.TypeVariable
    newMapWith type.name, type.kind
  else if type.TypeApp
    concatMaps (findFree type.op), (findFree type.arg)
  else if type.Constrained
    concatMaps (findFreeInList type.constraints), (findFree type.type)
  else if type.ClassConstraint
    findFree type.types
  else if type.Types
    findFreeInList type.types
  else
    newMap()

findFreeInList = (list) ->
  concatMaps (map findFree, list)...

freshInstance = (ctx, type) ->
  throw new Error "not a forall in freshInstance #{safePrintType type}" unless type and type.ForAll
  freshes = map ((kind) -> ctx.freshTypeVariable kind), type.kinds
  (substitute freshes, type).type

freshName = (nameIndex) ->
  nameIndex
  # suffix = if nameIndex >= 25 then freshName (Math.floor nameIndex / 25) - 1 else ''
  # (String.fromCharCode 97 + nameIndex % 25) + suffix

# Normalized constraint has a type which has type variable at its head
#   that is either ordinary type variable or type variable standing for a constructor
#   with arbitrary type arguments
isNormalizedConstraint = (constraint) ->
  isNormalizedConstraintArgument constraint.types.types[0]

isNormalizedConstraintArgument = (type) ->
  if type
    if type.TypeVariable
      yes
    else if type.TypeConstr
      no
    else if type.TypeApp
      isNormalizedConstraintArgument type.op


typeEq = (a, b) ->
  if a.TypeVariable and b.TypeVariable or
      a.TypeConstr and b.TypeConstr
    a.name is b.name
  else if a.QuantifiedVar and b.QuantifiedVar
    a.var is b.var
  else if a.TypeApp and b.TypeApp
    (typeEq a.op, b.op) and (typeEq a.arg, b.arg)
  else if a.ForAll and b.ForAll
    typeEq a.type, b.type
  else if a.Constrained and b.Constrained
    (all zipWith typeEq, a.constraints, b.constraints) and
      (typeEq a.type, b.type)
  else if a.ClassConstraint and b.ClassConstraint
    a.className is b.className and typeEq a.types, b.types
  else if a.Types and b.Types
    all zipWith typeEq, a.types, b.types
  else
    no

# Kind (data
#   Star
#   KindFn [from: Kind to: Kind])
#
# Type (data
#   TypeVariable [var: TypeVariable]
#   KnownType [const: TypeConstr]
#   TypeApplication [op: Type arg: Type]
#   QuantifiedVar [var: Int])
#
# TypeVariable (record name: String kind: Kind)
# TypeConstr (record name: String kind: Kind)

typeConstant = (name) ->
  new TypeConstr name, star

# Either a type variable or type constructor of some kind
atomicType = (name, kind) ->
  if /^[A-Z]/.test name
    new TypeConstr name, kind
  else
    new TypeVariable name, kind

tupleType = (arity) ->
  new TypeConstr "[#{arity}]", kindFn arity

tupleOfTypes = (types) ->
  new Constrained (concatMap _constraints, types),
    (applyKindFn (tupleType types.length), (map _type, types)...)

_constraints = (type) ->
  type.constraints

kindFn = (arity) ->
  if arity is 0
    star
  else
    new KindFn star, kindFn arity - 1

# Return type is always a star, type classes don't use this function
kindFnOfArgs = (arg, args...) ->
  if not arg
    star
  else
    new KindFn arg, kindFnOfArgs args...

typeFn = (from, to, args...) ->
  if args.length is 0
    if not to
      from
    else
      new TypeApp (new TypeApp arrowType, from), to
  else
    typeFn from, (typeFn to, args...)

applyKindFn = (fn, arg, args...) ->
  if not arg
    fn
  else if args.length is 0
    new TypeApp fn, arg
  else
    applyKindFn (applyKindFn fn, arg), args...

isConstructor = (type) ->
  type.TypeApp

kind = (type) ->
  if type.kind
    type.kind
  else if type.TypeApp
    (kind type.op).to
  else
    console.log "invalid", type
    throw new Error "Invalid type in kind"

kindsEq = (k1, k2) ->
  k1 is k2 or
    k1.from and k2.from and
    (kindsEq k1.from, k2.from) and
    (kindsEq k1.to, k2.to)

class KindFn
  constructor: (@from, @to) ->
class TempKind
  constructor: ->

class TypeVariable
  constructor: (@name, @kind) ->
    @TypeVariable = yes
class TypeConstr
  constructor: (@name, @kind) ->
    @TypeConstr = yes
class TypeApp
  constructor: (@op, @arg) ->
    @TypeApp = yes
class QuantifiedVar
  constructor: (@var) ->
    @QuantifiedVar = yes
class ForAll
  constructor: (@kinds, @type) ->
    @ForAll = yes
class TempType
  constructor: (@type) ->
    @TempType = yes

class Types
  constructor: (@types) ->
    @Types = yes

class Constrained
  constructor: (@constraints, @type) ->
    @Constrained = yes
class ClassConstraint
  constructor: (@className, @types) ->
    @ClassConstraint = yes

addConstraints = ({constraints, type}, addedConstraints) ->
  new Constrained (join constraints, addedConstraints), type

toConstrained = (type) ->
  new Constrained [], type

toForAll = (type) ->
  new ForAll [], type

quantifyAll = (type) ->
  quantify (findFree type), type

quantify = (vars, type) ->
  polymorphicVars = filterMap ((name) -> inSet vars, name), findFree type
  kinds = mapToArray polymorphicVars
  varIndex = 0
  quantifiedVars = mapMap (-> new QuantifiedVar varIndex++), polymorphicVars
  new ForAll kinds, (substitute quantifiedVars, type)

star = '*'
arrowType = new TypeConstr 'Fn', kindFn 2
arrayType = new TypeConstr 'Array', kindFn 1
listType = new TypeConstr 'List', kindFn 1
hashmapType = new TypeConstr 'Map', kindFn 2
hashsetType = new TypeConstr 'Set', kindFn 1
stringType = typeConstant 'String'
charType = typeConstant 'Char'
boolType = typeConstant 'Bool'
numType = typeConstant 'Num'

safePrintType = (type) ->
  try
    return printType type
  catch e
    return "#{type}"

prettyPrint = (type) ->
  if type.ForAll
    prettyPrint type.type
  else if type.Constrained
    if _notEmpty type.constraints
      (map printType, join [type.type], type.constraints).join ' '
    else
      printType type.type

printType = (type) ->
  if type.TypeVariable
    "#{type.name}"
  else if type.QuantifiedVar
    "#{type.var}"
  else if type.TypeConstr
    "#{type.name}"
  else if type.TypeApp
    flattenType collectArgs type
  else if type.ForAll
    "(∀ #{printType type.type})"
  else if type.ClassConstraint
    "(#{type.className} #{(map printType, type.types.types).join ' '})"
  else if type.Constrained
    "(: #{(map printType, join [type.type], type.constraints).join ' '})"
  else if type.TempType
    "(. #{printType type.type})"
  else if Array.isArray type
    "\"#{listOf type}\""
  else if type is undefined
    "undefined"
  else
    throw new Error "Unrecognized type in printType"

collectArgs = (type) ->
  if type.TypeApp
    op = collectArgs type.op
    arg = collectArgs type.arg
    if (Array.isArray op) and (Array.isArray arg) and
        op[0] is 'Fn' and arg[0] is 'Fn'
      join op, arg[1..]
    else
      join (if Array.isArray op then op else [op]),
        [if Array.isArray arg then flattenType arg else arg]
  else
    printType type

flattenType = (types) ->
  if types[0].match /^\[\d+\]$/
    "[#{types[1..].join ' '}]"
  else
    "(#{types.join ' '})"

library = """
var $listize = function (list) {
  if (list.length === 0) {
   return {length: 0};
  }
  return and_(list[0], $listize(list.slice(1)));
};

var and_ = function (x, xs) {
  if (typeof xs === "undefined" || xs === null) {
    throw new Error('Second argument to & must be a sequence');
  }
  if (Immutable.List.isList(xs)) {
    return xs.unshift(x);
  }
  if (Immutable.Set.isSet(xs)) {
    return xs.add(x);
  }
  if (typeof xs == 'string' || xs instanceof String) {
    if (xs === '' && !(typeof x == 'string' || x instanceof String)) {
      return [x];
    } else {
      return x + xs;
    }
  }
  if (xs.unshift) {
    return [x].concat(xs);
  }// cases for other sequences
  return {
    head: x,
    tail: xs
  };
};

var seq_size = function (xs) {
  if (typeof xs === "undefined" || xs === null) {
    throw new Error('Pattern matching on size of undefined');
  }
  if (xs.size !== null) {
    return xs.size;
  }
  if (xs.length !== null) {
    return xs.length;
  }
  return 1 + seq_size(xs.tail);
};

var seq_at = function (i, xs) {
  if (typeof xs === "undefined" || xs === null) {
    throw new Error('Pattern matching required sequence got undefined');
  }
  if (Immutable.Iterable.isIterable(xs)) {
    if (i >= xs.size) {
      throw new Error('Pattern matching required a list of size at least ' + (i + 1));
    }
    return xs.get(i);
  }
  if (xs.length !== null) {
    if (i >= xs.length) {
      throw new Error('Pattern matching required a list of size at least ' + (i + 1));
    }
    return xs[i];
  }
  if (i === 0) {
    return xs.head;
  }
  return seq_at(i - 1, xs.tail);
};

var seq_splat = function (from, leave, xs) {
  if (xs.slice) {
    return xs.slice(from, (xs.size || xs.length) - leave);
  }
  return $listSlice(from, seq_size(xs) - leave - from, xs);
};

// temporary, will be replaced by typed 0-argument function
var $empty = function (xs) {
  if (typeof xs === "undefined" || xs === null) {
    throw new Error('Empty needs a sequence');
  }
  if (typeof xs == 'string' || xs instanceof String) {
    return "";
  }
  if (xs.unshift) {
    return [];
  }
  if ('length' in xs) {
    return $listize([]);
  } // cases for other sequences
  return {};
};

var $listSlice = function (from, n, xs) {
  if (n === 0) {
    return $listize([]);
  }
  if (from === 0) {
    return and_(xs.head, $listSlice(from, n - 1, xs.tail));
  }
  return $listSlice(from - 1, n, xs.tail);
};

var show__list = function (x) {
  var t = [];
  while (x.length !== 0) {
    t.push(x.head);
    x = x.tail;
  }
  return t;
};

var from__nullable = function (jsValue) {
  if (typeof jsValue === "undefined" || jsValue === null) {
    return {';none': true};
  } else {
    return {':just': [jsValue]};
  }
};
""" +
(for i in [1..9]
  varNames = "abcdefghi".split ''
  first = (j) -> varNames[0...j].join ', '
  # TODO: handle A9 first branch
  """var _#{i} = function (fn, #{first i}) {
    if (fn._ === #{i} || fn.length === #{i}) {
      return fn(#{first i});
    } else if (fn._ > #{i} || fn.length > #{i}) {
      return function (#{varNames[i]}) {
        return _#{i + 1}(fn, #{first i + 1});
      };
    } else {
      return _1(#{if i is 1 then "fn()" else "_#{i - 1}(fn, #{first i - 1})"}, #{varNames[i - 1]});
    }
  };""").join('\n\n') +
(for i in [0..9]
  """var λ#{i} = function (fn) {
      fn._ = #{i};
      return fn;
    };""").join('\n\n') +
"""
;
"""


# Add library to compile for running macros
eval library

# Immutable.js
immutable = """
/**
 *  Copyright (c) 2014-2015, Facebook, Inc.
 *  All rights reserved.
 *
 *  This source code is licensed under the BSD-style license found in the
 *  LICENSE file in the root directory of this source tree. An additional grant
 *  of patent rights can be found in the PATENTS file in the same directory.
 *
 * I removed the loader code for nodejs and amd because it was clashing with require js for now
 * I also changed context to window, to make sure it registers when evaling
 */
!function(t,e){window.Immutable=e()}(this,function(){"use strict";function t(t,e){e&&(t.prototype=Object.create(e.prototype)),t.prototype.constructor=t}function e(t){return t.value=!1,t}function r(t){t&&(t.value=!0)}function n(){}function i(t,e){e=e||0;for(var r=Math.max(0,t.length-e),n=Array(r),i=0;r>i;i++)n[i]=t[i+e];return n}function o(t){return void 0===t.size&&(t.size=t.__iterate(s)),t.size}function u(t,e){return e>=0?+e:o(t)+ +e}function s(){return!0}function a(t,e,r){return(0===t||void 0!==r&&-r>=t)&&(void 0===e||void 0!==r&&e>=r)}function h(t,e){return c(t,e,0)}function f(t,e){return c(t,e,e)}function c(t,e,r){return void 0===t?r:0>t?Math.max(0,e+t):void 0===e?t:Math.min(e,t)}function _(t){return y(t)?t:O(t)}function p(t){return d(t)?t:x(t)}function v(t){return m(t)?t:k(t)}function l(t){return y(t)&&!g(t)?t:A(t)}function y(t){return!(!t||!t[vr])}function d(t){return!(!t||!t[lr])}function m(t){return!(!t||!t[yr])}function g(t){return d(t)||m(t)}function w(t){return!(!t||!t[dr])}function S(t){this.next=t}function z(t,e,r,n){var i=0===t?e:1===t?r:[e,r];return n?n.value=i:n={value:i,done:!1},n}function I(){return{value:void 0,done:!0}}function b(t){return!!M(t)}function q(t){return t&&"function"==typeof t.next}function D(t){var e=M(t);return e&&e.call(t)}function M(t){var e=t&&(Sr&&t[Sr]||t[zr]);return"function"==typeof e?e:void 0}function E(t){return t&&"number"==typeof t.length}function O(t){return null===t||void 0===t?T():y(t)?t.toSeq():C(t)}function x(t){return null===t||void 0===t?T().toKeyedSeq():y(t)?d(t)?t.toSeq():t.fromEntrySeq():W(t)}function k(t){return null===t||void 0===t?T():y(t)?d(t)?t.entrySeq():t.toIndexedSeq():B(t)}function A(t){return(null===t||void 0===t?T():y(t)?d(t)?t.entrySeq():t:B(t)).toSetSeq()}function j(t){this._array=t,this.size=t.length}function R(t){var e=Object.keys(t);this._object=t,this._keys=e,this.size=e.length}function U(t){this._iterable=t,this.size=t.length||t.size;}function K(t){this._iterator=t,this._iteratorCache=[]}function L(t){return!(!t||!t[br])}function T(){return qr||(qr=new j([]))}function W(t){var e=Array.isArray(t)?new j(t).fromEntrySeq():q(t)?new K(t).fromEntrySeq():b(t)?new U(t).fromEntrySeq():"object"==typeof t?new R(t):void 0;if(!e)throw new TypeError("Expected Array or iterable object of [k, v] entries, or keyed object: "+t);return e}function B(t){var e=J(t);if(!e)throw new TypeError("Expected Array or iterable object of values: "+t);return e}function C(t){var e=J(t)||"object"==typeof t&&new R(t);if(!e)throw new TypeError("Expected Array or iterable object of values, or keyed object: "+t);return e}function J(t){return E(t)?new j(t):q(t)?new K(t):b(t)?new U(t):void 0}function P(t,e,r,n){var i=t._cache;if(i){for(var o=i.length-1,u=0;o>=u;u++){var s=i[r?o-u:u];if(e(s[1],n?s[0]:u,t)===!1)return u+1}return u}return t.__iterateUncached(e,r)}function H(t,e,r,n){var i=t._cache;if(i){var o=i.length-1,u=0;return new S(function(){var t=i[r?o-u:u];return u++>o?I():z(e,n?t[0]:u-1,t[1])})}return t.__iteratorUncached(e,r)}function N(){throw TypeError("Abstract")}function V(){}function Y(){}function Q(){}function X(t,e){if(t===e||t!==t&&e!==e)return!0;if(!t||!e)return!1;if("function"==typeof t.valueOf&&"function"==typeof e.valueOf){if(t=t.valueOf(),e=e.valueOf(),t===e||t!==t&&e!==e)return!0;if(!t||!e)return!1}return"function"==typeof t.equals&&"function"==typeof e.equals&&t.equals(e)?!0:!1}function F(t,e){return e?G(e,t,"",{"":t}):Z(t)}function G(t,e,r,n){return Array.isArray(e)?t.call(n,r,k(e).map(function(r,n){return G(t,r,n,e)})):$(e)?t.call(n,r,x(e).map(function(r,n){return G(t,r,n,e)})):e}function Z(t){return Array.isArray(t)?k(t).map(Z).toList():$(t)?x(t).map(Z).toMap():t}function $(t){return t&&(t.constructor===Object||void 0===t.constructor)}function tt(t){return t>>>1&1073741824|3221225471&t}function et(t){if(t===!1||null===t||void 0===t)return 0;if("function"==typeof t.valueOf&&(t=t.valueOf(),t===!1||null===t||void 0===t))return 0;if(t===!0)return 1;var e=typeof t;if("number"===e){var r=0|t;for(r!==t&&(r^=4294967295*t);t>4294967295;)t/=4294967295,r^=t;return tt(r)}return"string"===e?t.length>jr?rt(t):nt(t):"function"==typeof t.hashCode?t.hashCode():it(t)}function rt(t){var e=Kr[t];return void 0===e&&(e=nt(t),Ur===Rr&&(Ur=0,Kr={}),Ur++,Kr[t]=e),e}function nt(t){for(var e=0,r=0;t.length>r;r++)e=31*e+t.charCodeAt(r)|0;return tt(e)}function it(t){var e;if(xr&&(e=Dr.get(t),void 0!==e))return e;if(e=t[Ar],void 0!==e)return e;if(!Or){if(e=t.propertyIsEnumerable&&t.propertyIsEnumerable[Ar],void 0!==e)return e;if(e=ot(t),void 0!==e)return e}if(e=++kr,1073741824&kr&&(kr=0),xr)Dr.set(t,e);else{if(void 0!==Er&&Er(t)===!1)throw Error("Non-extensible objects are not allowed as keys.");if(Or)Object.defineProperty(t,Ar,{enumerable:!1,configurable:!1,writable:!1,value:e});else if(void 0!==t.propertyIsEnumerable&&t.propertyIsEnumerable===t.constructor.prototype.propertyIsEnumerable)t.propertyIsEnumerable=function(){return this.constructor.prototype.propertyIsEnumerable.apply(this,arguments)},t.propertyIsEnumerable[Ar]=e;else{if(void 0===t.nodeType)throw Error("Unable to set a non-enumerable property on object.");t[Ar]=e}}return e}function ot(t){if(t&&t.nodeType>0)switch(t.nodeType){case 1:return t.uniqueID;case 9:return t.documentElement&&t.documentElement.uniqueID}}function ut(t,e){if(!t)throw Error(e)}function st(t){ut(t!==1/0,"Cannot perform this action with an infinite size.")}function at(t,e){this._iter=t,this._useKeys=e,this.size=t.size}function ht(t){this._iter=t,this.size=t.size}function ft(t){this._iter=t,this.size=t.size}function ct(t){this._iter=t,this.size=t.size}function _t(t){var e=jt(t);return e._iter=t,e.size=t.size,e.flip=function(){return t},e.reverse=function(){var e=t.reverse.apply(this);return e.flip=function(){return t.reverse()},e},e.has=function(e){return t.includes(e)},e.includes=function(e){return t.has(e)},e.cacheResult=Rt,e.__iterateUncached=function(e,r){var n=this;return t.__iterate(function(t,r){return e(r,t,n)!==!1},r)},e.__iteratorUncached=function(e,r){if(e===wr){
var n=t.__iterator(e,r);return new S(function(){var t=n.next();if(!t.done){var e=t.value[0];t.value[0]=t.value[1],t.value[1]=e}return t})}return t.__iterator(e===gr?mr:gr,r)},e}function pt(t,e,r){var n=jt(t);return n.size=t.size,n.has=function(e){return t.has(e)},n.get=function(n,i){var o=t.get(n,cr);return o===cr?i:e.call(r,o,n,t)},n.__iterateUncached=function(n,i){var o=this;return t.__iterate(function(t,i,u){return n(e.call(r,t,i,u),i,o)!==!1},i)},n.__iteratorUncached=function(n,i){var o=t.__iterator(wr,i);return new S(function(){var i=o.next();if(i.done)return i;var u=i.value,s=u[0];return z(n,s,e.call(r,u[1],s,t),i)})},n}function vt(t,e){var r=jt(t);return r._iter=t,r.size=t.size,r.reverse=function(){return t},t.flip&&(r.flip=function(){var e=_t(t);return e.reverse=function(){return t.flip()},e}),r.get=function(r,n){return t.get(e?r:-1-r,n)},r.has=function(r){return t.has(e?r:-1-r)},r.includes=function(e){return t.includes(e)},r.cacheResult=Rt,r.__iterate=function(e,r){var n=this;return t.__iterate(function(t,r){return e(t,r,n)},!r)},r.__iterator=function(e,r){return t.__iterator(e,!r)},r}function lt(t,e,r,n){var i=jt(t);return n&&(i.has=function(n){var i=t.get(n,cr);return i!==cr&&!!e.call(r,i,n,t)},i.get=function(n,i){var o=t.get(n,cr);return o!==cr&&e.call(r,o,n,t)?o:i}),i.__iterateUncached=function(i,o){var u=this,s=0;return t.__iterate(function(t,o,a){return e.call(r,t,o,a)?(s++,i(t,n?o:s-1,u)):void 0},o),s},i.__iteratorUncached=function(i,o){var u=t.__iterator(wr,o),s=0;return new S(function(){for(;;){var o=u.next();if(o.done)return o;var a=o.value,h=a[0],f=a[1];if(e.call(r,f,h,t))return z(i,n?h:s++,f,o)}})},i}function yt(t,e,r){var n=Lt().asMutable();return t.__iterate(function(i,o){n.update(e.call(r,i,o,t),0,function(t){return t+1})}),n.asImmutable()}function dt(t,e,r){var n=d(t),i=(w(t)?Ie():Lt()).asMutable();t.__iterate(function(o,u){i.update(e.call(r,o,u,t),function(t){return t=t||[],t.push(n?[u,o]:o),t})});var o=At(t);return i.map(function(e){return Ot(t,o(e))})}function mt(t,e,r,n){var i=t.size;if(a(e,r,i))return t;var o=h(e,i),s=f(r,i);if(o!==o||s!==s)return mt(t.toSeq().cacheResult(),e,r,n);var c=s-o;0>c&&(c=0);var _=jt(t);return _.size=0===c?c:t.size&&c||void 0,!n&&L(t)&&c>=0&&(_.get=function(e,r){return e=u(this,e),e>=0&&c>e?t.get(e+o,r):r}),_.__iterateUncached=function(e,r){var i=this;if(0===c)return 0;if(r)return this.cacheResult().__iterate(e,r);var u=0,s=!0,a=0;return t.__iterate(function(t,r){return s&&(s=u++<o)?void 0:(a++,e(t,n?r:a-1,i)!==!1&&a!==c)}),a},_.__iteratorUncached=function(e,r){if(c&&r)return this.cacheResult().__iterator(e,r);var i=c&&t.__iterator(e,r),u=0,s=0;return new S(function(){for(;u++<o;)i.next();if(++s>c)return I();var t=i.next();return n||e===gr?t:e===mr?z(e,s-1,void 0,t):z(e,s-1,t.value[1],t)})},_}function gt(t,e,r){var n=jt(t);return n.__iterateUncached=function(n,i){var o=this;if(i)return this.cacheResult().__iterate(n,i);var u=0;return t.__iterate(function(t,i,s){return e.call(r,t,i,s)&&++u&&n(t,i,o)}),u},n.__iteratorUncached=function(n,i){var o=this;if(i)return this.cacheResult().__iterator(n,i);var u=t.__iterator(wr,i),s=!0;return new S(function(){if(!s)return I();var t=u.next();if(t.done)return t;var i=t.value,a=i[0],h=i[1];return e.call(r,h,a,o)?n===wr?t:z(n,a,h,t):(s=!1,I())})},n}function wt(t,e,r,n){var i=jt(t);return i.__iterateUncached=function(i,o){var u=this;if(o)return this.cacheResult().__iterate(i,o);var s=!0,a=0;return t.__iterate(function(t,o,h){return s&&(s=e.call(r,t,o,h))?void 0:(a++,i(t,n?o:a-1,u))}),a},i.__iteratorUncached=function(i,o){var u=this;if(o)return this.cacheResult().__iterator(i,o);var s=t.__iterator(wr,o),a=!0,h=0;return new S(function(){var t,o,f;do{if(t=s.next(),t.done)return n||i===gr?t:i===mr?z(i,h++,void 0,t):z(i,h++,t.value[1],t);var c=t.value;o=c[0],f=c[1],a&&(a=e.call(r,f,o,u))}while(a);return i===wr?t:z(i,o,f,t)})},i}function St(t,e){var r=d(t),n=[t].concat(e).map(function(t){return y(t)?r&&(t=p(t)):t=r?W(t):B(Array.isArray(t)?t:[t]),t}).filter(function(t){return 0!==t.size});if(0===n.length)return t;if(1===n.length){var i=n[0];if(i===t||r&&d(i)||m(t)&&m(i))return i;}var o=new j(n);return r?o=o.toKeyedSeq():m(t)||(o=o.toSetSeq()),o=o.flatten(!0),o.size=n.reduce(function(t,e){if(void 0!==t){var r=e.size;if(void 0!==r)return t+r}},0),o}function zt(t,e,r){var n=jt(t);return n.__iterateUncached=function(n,i){function o(t,a){var h=this;t.__iterate(function(t,i){return(!e||e>a)&&y(t)?o(t,a+1):n(t,r?i:u++,h)===!1&&(s=!0),!s},i)}var u=0,s=!1;return o(t,0),u},n.__iteratorUncached=function(n,i){var o=t.__iterator(n,i),u=[],s=0;return new S(function(){for(;o;){var t=o.next();if(t.done===!1){var a=t.value;if(n===wr&&(a=a[1]),e&&!(e>u.length)||!y(a))return r?t:z(n,s++,a,t);u.push(o),o=a.__iterator(n,i)}else o=u.pop()}return I()})},n}function It(t,e,r){var n=At(t);return t.toSeq().map(function(i,o){return n(e.call(r,i,o,t))}).flatten(!0)}function bt(t,e){var r=jt(t);return r.size=t.size&&2*t.size-1,r.__iterateUncached=function(r,n){var i=this,o=0;return t.__iterate(function(t){return(!o||r(e,o++,i)!==!1)&&r(t,o++,i)!==!1},n),o},r.__iteratorUncached=function(r,n){var i,o=t.__iterator(gr,n),u=0;return new S(function(){return(!i||u%2)&&(i=o.next(),i.done)?i:u%2?z(r,u++,e):z(r,u++,i.value,i)})},r}function qt(t,e,r){e||(e=Ut);var n=d(t),i=0,o=t.toSeq().map(function(e,n){return[n,e,i++,r?r(e,n,t):e]}).toArray();return o.sort(function(t,r){return e(t[3],r[3])||t[2]-r[2]}).forEach(n?function(t,e){o[e].length=2}:function(t,e){o[e]=t[1]}),n?x(o):m(t)?k(o):A(o)}function Dt(t,e,r){if(e||(e=Ut),r){var n=t.toSeq().map(function(e,n){return[e,r(e,n,t)]}).reduce(function(t,r){return Mt(e,t[1],r[1])?r:t});return n&&n[0]}return t.reduce(function(t,r){return Mt(e,t,r)?r:t})}function Mt(t,e,r){var n=t(r,e);return 0===n&&r!==e&&(void 0===r||null===r||r!==r)||n>0}function Et(t,e,r){var n=jt(t);return n.size=new j(r).map(function(t){return t.size}).min(),n.__iterate=function(t,e){for(var r,n=this.__iterator(gr,e),i=0;!(r=n.next()).done&&t(r.value,i++,this)!==!1;);return i},n.__iteratorUncached=function(t,n){var i=r.map(function(t){return t=_(t),D(n?t.reverse():t)}),o=0,u=!1;return new S(function(){var r;return u||(r=i.map(function(t){
return t.next()}),u=r.some(function(t){return t.done})),u?I():z(t,o++,e.apply(null,r.map(function(t){return t.value})))})},n}function Ot(t,e){return L(t)?e:t.constructor(e)}function xt(t){if(t!==Object(t))throw new TypeError("Expected [K, V] tuple: "+t)}function kt(t){return st(t.size),o(t)}function At(t){return d(t)?p:m(t)?v:l}function jt(t){return Object.create((d(t)?x:m(t)?k:A).prototype)}function Rt(){return this._iter.cacheResult?(this._iter.cacheResult(),this.size=this._iter.size,this):O.prototype.cacheResult.call(this)}function Ut(t,e){return t>e?1:e>t?-1:0}function Kt(t){var e=D(t);if(!e){if(!E(t))throw new TypeError("Expected iterable or array-like: "+t);e=D(_(t))}return e}function Lt(t){return null===t||void 0===t?Qt():Tt(t)?t:Qt().withMutations(function(e){var r=p(t);st(r.size),r.forEach(function(t,r){return e.set(r,t)})})}function Tt(t){return!(!t||!t[Lr])}function Wt(t,e){this.ownerID=t,this.entries=e}function Bt(t,e,r){this.ownerID=t,this.bitmap=e,this.nodes=r}function Ct(t,e,r){this.ownerID=t,this.count=e,this.nodes=r}function Jt(t,e,r){this.ownerID=t,this.keyHash=e,this.entries=r}function Pt(t,e,r){this.ownerID=t,this.keyHash=e,this.entry=r}function Ht(t,e,r){this._type=e,this._reverse=r,this._stack=t._root&&Vt(t._root)}function Nt(t,e){return z(t,e[0],e[1])}function Vt(t,e){return{node:t,index:0,__prev:e}}function Yt(t,e,r,n){var i=Object.create(Tr);return i.size=t,i._root=e,i.__ownerID=r,i.__hash=n,i.__altered=!1,i}function Qt(){return Wr||(Wr=Yt(0))}function Xt(t,r,n){var i,o;if(t._root){var u=e(_r),s=e(pr);if(i=Ft(t._root,t.__ownerID,0,void 0,r,n,u,s),!s.value)return t;o=t.size+(u.value?n===cr?-1:1:0)}else{if(n===cr)return t;o=1,i=new Wt(t.__ownerID,[[r,n]])}return t.__ownerID?(t.size=o,t._root=i,t.__hash=void 0,t.__altered=!0,t):i?Yt(o,i):Qt()}function Ft(t,e,n,i,o,u,s,a){return t?t.update(e,n,i,o,u,s,a):u===cr?t:(r(a),r(s),new Pt(e,i,[o,u]))}function Gt(t){return t.constructor===Pt||t.constructor===Jt}function Zt(t,e,r,n,i){if(t.keyHash===n)return new Jt(e,n,[t.entry,i]);var o,u=(0===r?t.keyHash:t.keyHash>>>r)&fr,s=(0===r?n:n>>>r)&fr,a=u===s?[Zt(t,e,r+ar,n,i)]:(o=new Pt(e,n,i),
s>u?[t,o]:[o,t]);return new Bt(e,1<<u|1<<s,a)}function $t(t,e,r,i){t||(t=new n);for(var o=new Pt(t,et(r),[r,i]),u=0;e.length>u;u++){var s=e[u];o=o.update(t,0,void 0,s[0],s[1])}return o}function te(t,e,r,n){for(var i=0,o=0,u=Array(r),s=0,a=1,h=e.length;h>s;s++,a<<=1){var f=e[s];void 0!==f&&s!==n&&(i|=a,u[o++]=f)}return new Bt(t,i,u)}function ee(t,e,r,n,i){for(var o=0,u=Array(hr),s=0;0!==r;s++,r>>>=1)u[s]=1&r?e[o++]:void 0;return u[n]=i,new Ct(t,o+1,u)}function re(t,e,r){for(var n=[],i=0;r.length>i;i++){var o=r[i],u=p(o);y(o)||(u=u.map(function(t){return F(t)})),n.push(u)}return ie(t,e,n)}function ne(t){return function(e,r,n){return e&&e.mergeDeepWith&&y(r)?e.mergeDeepWith(t,r):t?t(e,r,n):r}}function ie(t,e,r){return r=r.filter(function(t){return 0!==t.size}),0===r.length?t:0!==t.size||t.__ownerID||1!==r.length?t.withMutations(function(t){for(var n=e?function(r,n){t.update(n,cr,function(t){return t===cr?r:e(t,r,n)})}:function(e,r){t.set(r,e)},i=0;r.length>i;i++)r[i].forEach(n)}):t.constructor(r[0])}function oe(t,e,r,n){var i=t===cr,o=e.next();if(o.done){var u=i?r:t,s=n(u);return s===u?t:s}ut(i||t&&t.set,"invalid keyPath");var a=o.value,h=i?cr:t.get(a,cr),f=oe(h,e,r,n);return f===h?t:f===cr?t.remove(a):(i?Qt():t).set(a,f)}function ue(t){return t-=t>>1&1431655765,t=(858993459&t)+(t>>2&858993459),t=t+(t>>4)&252645135,t+=t>>8,t+=t>>16,127&t}function se(t,e,r,n){var o=n?t:i(t);return o[e]=r,o}function ae(t,e,r,n){var i=t.length+1;if(n&&e+1===i)return t[e]=r,t;for(var o=Array(i),u=0,s=0;i>s;s++)s===e?(o[s]=r,u=-1):o[s]=t[s+u];return o}function he(t,e,r){var n=t.length-1;if(r&&e===n)return t.pop(),t;for(var i=Array(n),o=0,u=0;n>u;u++)u===e&&(o=1),i[u]=t[u+o];return i}function fe(t){var e=le();if(null===t||void 0===t)return e;if(ce(t))return t;var r=v(t),n=r.size;return 0===n?e:(st(n),n>0&&hr>n?ve(0,n,ar,null,new _e(r.toArray())):e.withMutations(function(t){t.setSize(n),r.forEach(function(e,r){return t.set(r,e)})}))}function ce(t){return!(!t||!t[Pr])}function _e(t,e){this.array=t,this.ownerID=e}function pe(t,e){function r(t,e,r){
return 0===e?n(t,r):i(t,e,r)}function n(t,r){var n=r===s?a&&a.array:t&&t.array,i=r>o?0:o-r,h=u-r;return h>hr&&(h=hr),function(){if(i===h)return Vr;var t=e?--h:i++;return n&&n[t]}}function i(t,n,i){var s,a=t&&t.array,h=i>o?0:o-i>>n,f=(u-i>>n)+1;return f>hr&&(f=hr),function(){for(;;){if(s){var t=s();if(t!==Vr)return t;s=null}if(h===f)return Vr;var o=e?--f:h++;s=r(a&&a[o],n-ar,i+(o<<n))}}}var o=t._origin,u=t._capacity,s=ze(u),a=t._tail;return r(t._root,t._level,0)}function ve(t,e,r,n,i,o,u){var s=Object.create(Hr);return s.size=e-t,s._origin=t,s._capacity=e,s._level=r,s._root=n,s._tail=i,s.__ownerID=o,s.__hash=u,s.__altered=!1,s}function le(){return Nr||(Nr=ve(0,0,ar))}function ye(t,r,n){if(r=u(t,r),r>=t.size||0>r)return t.withMutations(function(t){0>r?we(t,r).set(0,n):we(t,0,r+1).set(r,n)});r+=t._origin;var i=t._tail,o=t._root,s=e(pr);return r>=ze(t._capacity)?i=de(i,t.__ownerID,0,r,n,s):o=de(o,t.__ownerID,t._level,r,n,s),s.value?t.__ownerID?(t._root=o,t._tail=i,t.__hash=void 0,t.__altered=!0,t):ve(t._origin,t._capacity,t._level,o,i):t}function de(t,e,n,i,o,u){var s=i>>>n&fr,a=t&&t.array.length>s;if(!a&&void 0===o)return t;var h;if(n>0){var f=t&&t.array[s],c=de(f,e,n-ar,i,o,u);return c===f?t:(h=me(t,e),h.array[s]=c,h)}return a&&t.array[s]===o?t:(r(u),h=me(t,e),void 0===o&&s===h.array.length-1?h.array.pop():h.array[s]=o,h)}function me(t,e){return e&&t&&e===t.ownerID?t:new _e(t?t.array.slice():[],e)}function ge(t,e){if(e>=ze(t._capacity))return t._tail;if(1<<t._level+ar>e){for(var r=t._root,n=t._level;r&&n>0;)r=r.array[e>>>n&fr],n-=ar;return r}}function we(t,e,r){var i=t.__ownerID||new n,o=t._origin,u=t._capacity,s=o+e,a=void 0===r?u:0>r?u+r:o+r;if(s===o&&a===u)return t;if(s>=a)return t.clear();for(var h=t._level,f=t._root,c=0;0>s+c;)f=new _e(f&&f.array.length?[void 0,f]:[],i),h+=ar,c+=1<<h;c&&(s+=c,o+=c,a+=c,u+=c);for(var _=ze(u),p=ze(a);p>=1<<h+ar;)f=new _e(f&&f.array.length?[f]:[],i),h+=ar;var v=t._tail,l=_>p?ge(t,a-1):p>_?new _e([],i):v;if(v&&p>_&&u>s&&v.array.length){f=me(f,i);for(var y=f,d=h;d>ar;d-=ar){var m=_>>>d&fr;y=y.array[m]=me(y.array[m],i)}y.array[_>>>ar&fr]=v}if(u>a&&(l=l&&l.removeAfter(i,0,a)),s>=p)s-=p,a-=p,h=ar,f=null,l=l&&l.removeBefore(i,0,s);else if(s>o||_>p){for(c=0;f;){var g=s>>>h&fr;if(g!==p>>>h&fr)break;g&&(c+=(1<<h)*g),h-=ar,f=f.array[g]}f&&s>o&&(f=f.removeBefore(i,h,s-c)),f&&_>p&&(f=f.removeAfter(i,h,p-c)),c&&(s-=c,a-=c)}return t.__ownerID?(t.size=a-s,t._origin=s,t._capacity=a,t._level=h,t._root=f,t._tail=l,t.__hash=void 0,t.__altered=!0,t):ve(s,a,h,f,l)}function Se(t,e,r){for(var n=[],i=0,o=0;r.length>o;o++){var u=r[o],s=v(u);s.size>i&&(i=s.size),y(u)||(s=s.map(function(t){return F(t)})),n.push(s)}return i>t.size&&(t=t.setSize(i)),ie(t,e,n)}function ze(t){return hr>t?0:t-1>>>ar<<ar}function Ie(t){return null===t||void 0===t?De():be(t)?t:De().withMutations(function(e){var r=p(t);st(r.size),r.forEach(function(t,r){return e.set(r,t)})})}function be(t){return Tt(t)&&w(t)}function qe(t,e,r,n){var i=Object.create(Ie.prototype);return i.size=t?t.size:0,i._map=t,i._list=e,i.__ownerID=r,i.__hash=n,i}function De(){return Yr||(Yr=qe(Qt(),le()))}function Me(t,e,r){var n,i,o=t._map,u=t._list,s=o.get(e),a=void 0!==s;if(r===cr){if(!a)return t;u.size>=hr&&u.size>=2*o.size?(i=u.filter(function(t,e){return void 0!==t&&s!==e}),n=i.toKeyedSeq().map(function(t){return t[0]}).flip().toMap(),t.__ownerID&&(n.__ownerID=i.__ownerID=t.__ownerID)):(n=o.remove(e),i=s===u.size-1?u.pop():u.set(s,void 0))}else if(a){if(r===u.get(s)[1])return t;n=o,i=u.set(s,[e,r])}else n=o.set(e,u.size),i=u.set(u.size,[e,r]);return t.__ownerID?(t.size=n.size,t._map=n,t._list=i,t.__hash=void 0,t):qe(n,i)}function Ee(t){return null===t||void 0===t?ke():Oe(t)?t:ke().unshiftAll(t)}function Oe(t){return!(!t||!t[Qr])}function xe(t,e,r,n){var i=Object.create(Xr);return i.size=t,i._head=e,i.__ownerID=r,i.__hash=n,i.__altered=!1,i}function ke(){return Fr||(Fr=xe(0))}function Ae(t){return null===t||void 0===t?Ke():je(t)?t:Ke().withMutations(function(e){var r=l(t);st(r.size),r.forEach(function(t){return e.add(t)})})}function je(t){return!(!t||!t[Gr])}function Re(t,e){
return t.__ownerID?(t.size=e.size,t._map=e,t):e===t._map?t:0===e.size?t.__empty():t.__make(e)}function Ue(t,e){var r=Object.create(Zr);return r.size=t?t.size:0,r._map=t,r.__ownerID=e,r}function Ke(){return $r||($r=Ue(Qt()))}function Le(t){return null===t||void 0===t?Be():Te(t)?t:Be().withMutations(function(e){var r=l(t);st(r.size),r.forEach(function(t){return e.add(t)})})}function Te(t){return je(t)&&w(t)}function We(t,e){var r=Object.create(tn);return r.size=t?t.size:0,r._map=t,r.__ownerID=e,r}function Be(){return en||(en=We(De()))}function Ce(t,e){var r,n=function(o){if(o instanceof n)return o;if(!(this instanceof n))return new n(o);if(!r){r=!0;var u=Object.keys(t);He(i,u),i.size=u.length,i._name=e,i._keys=u,i._defaultValues=t}this._map=Lt(o)},i=n.prototype=Object.create(rn);return i.constructor=n,n}function Je(t,e,r){var n=Object.create(Object.getPrototypeOf(t));return n._map=e,n.__ownerID=r,n}function Pe(t){return t._name||t.constructor.name||"Record"}function He(t,e){try{e.forEach(Ne.bind(void 0,t))}catch(r){}}function Ne(t,e){Object.defineProperty(t,e,{get:function(){return this.get(e)},set:function(t){ut(this.__ownerID,"Cannot set on an immutable record."),this.set(e,t)}})}function Ve(t,e){if(t===e)return!0;if(!y(e)||void 0!==t.size&&void 0!==e.size&&t.size!==e.size||void 0!==t.__hash&&void 0!==e.__hash&&t.__hash!==e.__hash||d(t)!==d(e)||m(t)!==m(e)||w(t)!==w(e))return!1;if(0===t.size&&0===e.size)return!0;var r=!g(t);if(w(t)){var n=t.entries();return e.every(function(t,e){var i=n.next().value;return i&&X(i[1],t)&&(r||X(i[0],e))})&&n.next().done}var i=!1;if(void 0===t.size)if(void 0===e.size)"function"==typeof t.cacheResult&&t.cacheResult();else{i=!0;var o=t;t=e,e=o}var u=!0,s=e.__iterate(function(e,n){return(r?t.has(e):i?X(e,t.get(n,cr)):X(t.get(n,cr),e))?void 0:(u=!1,!1)});return u&&t.size===s}function Ye(t,e,r){if(!(this instanceof Ye))return new Ye(t,e,r);if(ut(0!==r,"Cannot step a Range by 0"),t=t||0,void 0===e&&(e=1/0),r=void 0===r?1:Math.abs(r),t>e&&(r=-r),this._start=t,this._end=e,this._step=r,this.size=Math.max(0,Math.ceil((e-t)/r-1)+1),
0===this.size){if(nn)return nn;nn=this}}function Qe(t,e){if(!(this instanceof Qe))return new Qe(t,e);if(this._value=t,this.size=void 0===e?1/0:Math.max(0,e),0===this.size){if(on)return on;on=this}}function Xe(t,e){var r=function(r){t.prototype[r]=e[r]};return Object.keys(e).forEach(r),Object.getOwnPropertySymbols&&Object.getOwnPropertySymbols(e).forEach(r),t}function Fe(t,e){return e}function Ge(t,e){return[e,t]}function Ze(t){return function(){return!t.apply(this,arguments)}}function $e(t){return function(){return-t.apply(this,arguments)}}function tr(t){return"string"==typeof t?JSON.stringify(t):t}function er(){return i(arguments)}function rr(t,e){return e>t?1:t>e?-1:0}function nr(t){if(t.size===1/0)return 0;var e=w(t),r=d(t),n=e?1:0,i=t.__iterate(r?e?function(t,e){n=31*n+or(et(t),et(e))|0}:function(t,e){n=n+or(et(t),et(e))|0}:e?function(t){n=31*n+et(t)|0}:function(t){n=n+et(t)|0});return ir(i,n)}function ir(t,e){return e=Mr(e,3432918353),e=Mr(e<<15|e>>>-15,461845907),e=Mr(e<<13|e>>>-13,5),e=(e+3864292196|0)^t,e=Mr(e^e>>>16,2246822507),e=Mr(e^e>>>13,3266489909),e=tt(e^e>>>16)}function or(t,e){return t^e+2654435769+(t<<6)+(t>>2)|0}var ur=Array.prototype.slice,sr="delete",ar=5,hr=1<<ar,fr=hr-1,cr={},_r={value:!1},pr={value:!1};t(p,_),t(v,_),t(l,_),_.isIterable=y,_.isKeyed=d,_.isIndexed=m,_.isAssociative=g,_.isOrdered=w,_.Keyed=p,_.Indexed=v,_.Set=l;var vr="@@__IMMUTABLE_ITERABLE__@@",lr="@@__IMMUTABLE_KEYED__@@",yr="@@__IMMUTABLE_INDEXED__@@",dr="@@__IMMUTABLE_ORDERED__@@",mr=0,gr=1,wr=2,Sr="function"==typeof Symbol&&Symbol.iterator,zr="@@iterator",Ir=Sr||zr;S.prototype.toString=function(){return"[Iterator]"},S.KEYS=mr,S.VALUES=gr,S.ENTRIES=wr,S.prototype.inspect=S.prototype.toSource=function(){return""+this},S.prototype[Ir]=function(){return this},t(O,_),O.of=function(){return O(arguments)},O.prototype.toSeq=function(){return this},O.prototype.toString=function(){return this.__toString("Seq {","}")},O.prototype.cacheResult=function(){return!this._cache&&this.__iterateUncached&&(this._cache=this.entrySeq().toArray(),
this.size=this._cache.length),this},O.prototype.__iterate=function(t,e){return P(this,t,e,!0)},O.prototype.__iterator=function(t,e){return H(this,t,e,!0)},t(x,O),x.prototype.toKeyedSeq=function(){return this},t(k,O),k.of=function(){return k(arguments)},k.prototype.toIndexedSeq=function(){return this},k.prototype.toString=function(){return this.__toString("Seq [","]")},k.prototype.__iterate=function(t,e){return P(this,t,e,!1)},k.prototype.__iterator=function(t,e){return H(this,t,e,!1)},t(A,O),A.of=function(){return A(arguments)},A.prototype.toSetSeq=function(){return this},O.isSeq=L,O.Keyed=x,O.Set=A,O.Indexed=k;var br="@@__IMMUTABLE_SEQ__@@";O.prototype[br]=!0,t(j,k),j.prototype.get=function(t,e){return this.has(t)?this._array[u(this,t)]:e},j.prototype.__iterate=function(t,e){for(var r=this._array,n=r.length-1,i=0;n>=i;i++)if(t(r[e?n-i:i],i,this)===!1)return i+1;return i},j.prototype.__iterator=function(t,e){var r=this._array,n=r.length-1,i=0;return new S(function(){return i>n?I():z(t,i,r[e?n-i++:i++])})},t(R,x),R.prototype.get=function(t,e){return void 0===e||this.has(t)?this._object[t]:e},R.prototype.has=function(t){return this._object.hasOwnProperty(t)},R.prototype.__iterate=function(t,e){for(var r=this._object,n=this._keys,i=n.length-1,o=0;i>=o;o++){var u=n[e?i-o:o];if(t(r[u],u,this)===!1)return o+1}return o},R.prototype.__iterator=function(t,e){var r=this._object,n=this._keys,i=n.length-1,o=0;return new S(function(){var u=n[e?i-o:o];return o++>i?I():z(t,u,r[u])})},R.prototype[dr]=!0,t(U,k),U.prototype.__iterateUncached=function(t,e){if(e)return this.cacheResult().__iterate(t,e);var r=this._iterable,n=D(r),i=0;if(q(n))for(var o;!(o=n.next()).done&&t(o.value,i++,this)!==!1;);return i},U.prototype.__iteratorUncached=function(t,e){if(e)return this.cacheResult().__iterator(t,e);var r=this._iterable,n=D(r);if(!q(n))return new S(I);var i=0;return new S(function(){var e=n.next();return e.done?e:z(t,i++,e.value)})},t(K,k),K.prototype.__iterateUncached=function(t,e){if(e)return this.cacheResult().__iterate(t,e);for(var r=this._iterator,n=this._iteratorCache,i=0;n.length>i;)if(t(n[i],i++,this)===!1)return i;for(var o;!(o=r.next()).done;){var u=o.value;if(n[i]=u,t(u,i++,this)===!1)break}return i},K.prototype.__iteratorUncached=function(t,e){if(e)return this.cacheResult().__iterator(t,e);var r=this._iterator,n=this._iteratorCache,i=0;return new S(function(){if(i>=n.length){var e=r.next();if(e.done)return e;n[i]=e.value}return z(t,i,n[i++])})};var qr;t(N,_),t(V,N),t(Y,N),t(Q,N),N.Keyed=V,N.Indexed=Y,N.Set=Q;var Dr,Mr="function"==typeof Math.imul&&-2===Math.imul(4294967295,2)?Math.imul:function(t,e){t=0|t,e=0|e;var r=65535&t,n=65535&e;return r*n+((t>>>16)*n+r*(e>>>16)<<16>>>0)|0},Er=Object.isExtensible,Or=function(){try{return Object.defineProperty({},"@",{}),!0}catch(t){return!1}}(),xr="function"==typeof WeakMap;xr&&(Dr=new WeakMap);var kr=0,Ar="__immutablehash__";"function"==typeof Symbol&&(Ar=Symbol(Ar));var jr=16,Rr=255,Ur=0,Kr={};t(at,x),at.prototype.get=function(t,e){return this._iter.get(t,e)},at.prototype.has=function(t){return this._iter.has(t)},at.prototype.valueSeq=function(){return this._iter.valueSeq()},at.prototype.reverse=function(){var t=this,e=vt(this,!0);return this._useKeys||(e.valueSeq=function(){return t._iter.toSeq().reverse()}),e},at.prototype.map=function(t,e){var r=this,n=pt(this,t,e);return this._useKeys||(n.valueSeq=function(){return r._iter.toSeq().map(t,e)}),n},at.prototype.__iterate=function(t,e){var r,n=this;return this._iter.__iterate(this._useKeys?function(e,r){return t(e,r,n)}:(r=e?kt(this):0,function(i){return t(i,e?--r:r++,n)}),e)},at.prototype.__iterator=function(t,e){if(this._useKeys)return this._iter.__iterator(t,e);var r=this._iter.__iterator(gr,e),n=e?kt(this):0;return new S(function(){var i=r.next();return i.done?i:z(t,e?--n:n++,i.value,i)})},at.prototype[dr]=!0,t(ht,k),ht.prototype.includes=function(t){return this._iter.includes(t)},ht.prototype.__iterate=function(t,e){var r=this,n=0;return this._iter.__iterate(function(e){return t(e,n++,r)},e)},ht.prototype.__iterator=function(t,e){var r=this._iter.__iterator(gr,e),n=0;return new S(function(){var e=r.next();return e.done?e:z(t,n++,e.value,e);})},t(ft,A),ft.prototype.has=function(t){return this._iter.includes(t)},ft.prototype.__iterate=function(t,e){var r=this;return this._iter.__iterate(function(e){return t(e,e,r)},e)},ft.prototype.__iterator=function(t,e){var r=this._iter.__iterator(gr,e);return new S(function(){var e=r.next();return e.done?e:z(t,e.value,e.value,e)})},t(ct,x),ct.prototype.entrySeq=function(){return this._iter.toSeq()},ct.prototype.__iterate=function(t,e){var r=this;return this._iter.__iterate(function(e){if(e){xt(e);var n=y(e);return t(n?e.get(1):e[1],n?e.get(0):e[0],r)}},e)},ct.prototype.__iterator=function(t,e){var r=this._iter.__iterator(gr,e);return new S(function(){for(;;){var e=r.next();if(e.done)return e;var n=e.value;if(n){xt(n);var i=y(n);return z(t,i?n.get(0):n[0],i?n.get(1):n[1],e)}}})},ht.prototype.cacheResult=at.prototype.cacheResult=ft.prototype.cacheResult=ct.prototype.cacheResult=Rt,t(Lt,V),Lt.prototype.toString=function(){return this.__toString("Map {","}")},Lt.prototype.get=function(t,e){return this._root?this._root.get(0,void 0,t,e):e},Lt.prototype.set=function(t,e){return Xt(this,t,e)},Lt.prototype.setIn=function(t,e){return this.updateIn(t,cr,function(){return e})},Lt.prototype.remove=function(t){return Xt(this,t,cr)},Lt.prototype.deleteIn=function(t){return this.updateIn(t,function(){return cr})},Lt.prototype.update=function(t,e,r){return 1===arguments.length?t(this):this.updateIn([t],e,r)},Lt.prototype.updateIn=function(t,e,r){r||(r=e,e=void 0);var n=oe(this,Kt(t),e,r);return n===cr?void 0:n},Lt.prototype.clear=function(){return 0===this.size?this:this.__ownerID?(this.size=0,this._root=null,this.__hash=void 0,this.__altered=!0,this):Qt()},Lt.prototype.merge=function(){return re(this,void 0,arguments)},Lt.prototype.mergeWith=function(t){var e=ur.call(arguments,1);return re(this,t,e)},Lt.prototype.mergeIn=function(t){var e=ur.call(arguments,1);return this.updateIn(t,Qt(),function(t){return t.merge.apply(t,e)})},Lt.prototype.mergeDeep=function(){return re(this,ne(void 0),arguments)},Lt.prototype.mergeDeepWith=function(t){
var e=ur.call(arguments,1);return re(this,ne(t),e)},Lt.prototype.mergeDeepIn=function(t){var e=ur.call(arguments,1);return this.updateIn(t,Qt(),function(t){return t.mergeDeep.apply(t,e)})},Lt.prototype.sort=function(t){return Ie(qt(this,t))},Lt.prototype.sortBy=function(t,e){return Ie(qt(this,e,t))},Lt.prototype.withMutations=function(t){var e=this.asMutable();return t(e),e.wasAltered()?e.__ensureOwner(this.__ownerID):this},Lt.prototype.asMutable=function(){return this.__ownerID?this:this.__ensureOwner(new n)},Lt.prototype.asImmutable=function(){return this.__ensureOwner()},Lt.prototype.wasAltered=function(){return this.__altered},Lt.prototype.__iterator=function(t,e){return new Ht(this,t,e)},Lt.prototype.__iterate=function(t,e){var r=this,n=0;return this._root&&this._root.iterate(function(e){return n++,t(e[1],e[0],r)},e),n},Lt.prototype.__ensureOwner=function(t){return t===this.__ownerID?this:t?Yt(this.size,this._root,t,this.__hash):(this.__ownerID=t,this.__altered=!1,this)},Lt.isMap=Tt;var Lr="@@__IMMUTABLE_MAP__@@",Tr=Lt.prototype;Tr[Lr]=!0,Tr[sr]=Tr.remove,Tr.removeIn=Tr.deleteIn,Wt.prototype.get=function(t,e,r,n){for(var i=this.entries,o=0,u=i.length;u>o;o++)if(X(r,i[o][0]))return i[o][1];return n},Wt.prototype.update=function(t,e,n,o,u,s,a){for(var h=u===cr,f=this.entries,c=0,_=f.length;_>c&&!X(o,f[c][0]);c++);var p=_>c;if(p?f[c][1]===u:h)return this;if(r(a),(h||!p)&&r(s),!h||1!==f.length){if(!p&&!h&&f.length>=Br)return $t(t,f,o,u);var v=t&&t===this.ownerID,l=v?f:i(f);return p?h?c===_-1?l.pop():l[c]=l.pop():l[c]=[o,u]:l.push([o,u]),v?(this.entries=l,this):new Wt(t,l)}},Bt.prototype.get=function(t,e,r,n){void 0===e&&(e=et(r));var i=1<<((0===t?e:e>>>t)&fr),o=this.bitmap;return 0===(o&i)?n:this.nodes[ue(o&i-1)].get(t+ar,e,r,n)},Bt.prototype.update=function(t,e,r,n,i,o,u){void 0===r&&(r=et(n));var s=(0===e?r:r>>>e)&fr,a=1<<s,h=this.bitmap,f=0!==(h&a);if(!f&&i===cr)return this;var c=ue(h&a-1),_=this.nodes,p=f?_[c]:void 0,v=Ft(p,t,e+ar,r,n,i,o,u);if(v===p)return this;if(!f&&v&&_.length>=Cr)return ee(t,_,h,s,v);if(f&&!v&&2===_.length&&Gt(_[1^c]))return _[1^c];if(f&&v&&1===_.length&&Gt(v))return v;var l=t&&t===this.ownerID,y=f?v?h:h^a:h|a,d=f?v?se(_,c,v,l):he(_,c,l):ae(_,c,v,l);return l?(this.bitmap=y,this.nodes=d,this):new Bt(t,y,d)},Ct.prototype.get=function(t,e,r,n){void 0===e&&(e=et(r));var i=(0===t?e:e>>>t)&fr,o=this.nodes[i];return o?o.get(t+ar,e,r,n):n},Ct.prototype.update=function(t,e,r,n,i,o,u){void 0===r&&(r=et(n));var s=(0===e?r:r>>>e)&fr,a=i===cr,h=this.nodes,f=h[s];if(a&&!f)return this;var c=Ft(f,t,e+ar,r,n,i,o,u);if(c===f)return this;var _=this.count;if(f){if(!c&&(_--,Jr>_))return te(t,h,_,s)}else _++;var p=t&&t===this.ownerID,v=se(h,s,c,p);return p?(this.count=_,this.nodes=v,this):new Ct(t,_,v)},Jt.prototype.get=function(t,e,r,n){for(var i=this.entries,o=0,u=i.length;u>o;o++)if(X(r,i[o][0]))return i[o][1];return n},Jt.prototype.update=function(t,e,n,o,u,s,a){void 0===n&&(n=et(o));var h=u===cr;if(n!==this.keyHash)return h?this:(r(a),r(s),Zt(this,t,e,n,[o,u]));for(var f=this.entries,c=0,_=f.length;_>c&&!X(o,f[c][0]);c++);var p=_>c;if(p?f[c][1]===u:h)return this;if(r(a),(h||!p)&&r(s),h&&2===_)return new Pt(t,this.keyHash,f[1^c]);var v=t&&t===this.ownerID,l=v?f:i(f);return p?h?c===_-1?l.pop():l[c]=l.pop():l[c]=[o,u]:l.push([o,u]),v?(this.entries=l,this):new Jt(t,this.keyHash,l)},Pt.prototype.get=function(t,e,r,n){return X(r,this.entry[0])?this.entry[1]:n},Pt.prototype.update=function(t,e,n,i,o,u,s){var a=o===cr,h=X(i,this.entry[0]);return(h?o===this.entry[1]:a)?this:(r(s),a?void r(u):h?t&&t===this.ownerID?(this.entry[1]=o,this):new Pt(t,this.keyHash,[i,o]):(r(u),Zt(this,t,e,et(i),[i,o])))},Wt.prototype.iterate=Jt.prototype.iterate=function(t,e){for(var r=this.entries,n=0,i=r.length-1;i>=n;n++)if(t(r[e?i-n:n])===!1)return!1},Bt.prototype.iterate=Ct.prototype.iterate=function(t,e){for(var r=this.nodes,n=0,i=r.length-1;i>=n;n++){var o=r[e?i-n:n];if(o&&o.iterate(t,e)===!1)return!1}},Pt.prototype.iterate=function(t){return t(this.entry)},t(Ht,S),Ht.prototype.next=function(){for(var t=this._type,e=this._stack;e;){var r,n=e.node,i=e.index++;if(n.entry){if(0===i)return Nt(t,n.entry);}else if(n.entries){if(r=n.entries.length-1,r>=i)return Nt(t,n.entries[this._reverse?r-i:i])}else if(r=n.nodes.length-1,r>=i){var o=n.nodes[this._reverse?r-i:i];if(o){if(o.entry)return Nt(t,o.entry);e=this._stack=Vt(o,e)}continue}e=this._stack=this._stack.__prev}return I()};var Wr,Br=hr/4,Cr=hr/2,Jr=hr/4;t(fe,Y),fe.of=function(){return this(arguments)},fe.prototype.toString=function(){return this.__toString("List [","]")},fe.prototype.get=function(t,e){if(t=u(this,t),0>t||t>=this.size)return e;t+=this._origin;var r=ge(this,t);return r&&r.array[t&fr]},fe.prototype.set=function(t,e){return ye(this,t,e)},fe.prototype.remove=function(t){return this.has(t)?0===t?this.shift():t===this.size-1?this.pop():this.splice(t,1):this},fe.prototype.clear=function(){return 0===this.size?this:this.__ownerID?(this.size=this._origin=this._capacity=0,this._level=ar,this._root=this._tail=null,this.__hash=void 0,this.__altered=!0,this):le()},fe.prototype.push=function(){var t=arguments,e=this.size;return this.withMutations(function(r){we(r,0,e+t.length);for(var n=0;t.length>n;n++)r.set(e+n,t[n])})},fe.prototype.pop=function(){return we(this,0,-1)},fe.prototype.unshift=function(){var t=arguments;return this.withMutations(function(e){we(e,-t.length);for(var r=0;t.length>r;r++)e.set(r,t[r])})},fe.prototype.shift=function(){return we(this,1)},fe.prototype.merge=function(){return Se(this,void 0,arguments)},fe.prototype.mergeWith=function(t){var e=ur.call(arguments,1);return Se(this,t,e)},fe.prototype.mergeDeep=function(){return Se(this,ne(void 0),arguments)},fe.prototype.mergeDeepWith=function(t){var e=ur.call(arguments,1);return Se(this,ne(t),e)},fe.prototype.setSize=function(t){return we(this,0,t)},fe.prototype.slice=function(t,e){var r=this.size;return a(t,e,r)?this:we(this,h(t,r),f(e,r))},fe.prototype.__iterator=function(t,e){var r=0,n=pe(this,e);return new S(function(){var e=n();return e===Vr?I():z(t,r++,e)})},fe.prototype.__iterate=function(t,e){for(var r,n=0,i=pe(this,e);(r=i())!==Vr&&t(r,n++,this)!==!1;);return n},fe.prototype.__ensureOwner=function(t){
return t===this.__ownerID?this:t?ve(this._origin,this._capacity,this._level,this._root,this._tail,t,this.__hash):(this.__ownerID=t,this)},fe.isList=ce;var Pr="@@__IMMUTABLE_LIST__@@",Hr=fe.prototype;Hr[Pr]=!0,Hr[sr]=Hr.remove,Hr.setIn=Tr.setIn,Hr.deleteIn=Hr.removeIn=Tr.removeIn,Hr.update=Tr.update,Hr.updateIn=Tr.updateIn,Hr.mergeIn=Tr.mergeIn,Hr.mergeDeepIn=Tr.mergeDeepIn,Hr.withMutations=Tr.withMutations,Hr.asMutable=Tr.asMutable,Hr.asImmutable=Tr.asImmutable,Hr.wasAltered=Tr.wasAltered,_e.prototype.removeBefore=function(t,e,r){if(r===e?1<<e:0||0===this.array.length)return this;var n=r>>>e&fr;if(n>=this.array.length)return new _e([],t);var i,o=0===n;if(e>0){var u=this.array[n];if(i=u&&u.removeBefore(t,e-ar,r),i===u&&o)return this}if(o&&!i)return this;var s=me(this,t);if(!o)for(var a=0;n>a;a++)s.array[a]=void 0;return i&&(s.array[n]=i),s},_e.prototype.removeAfter=function(t,e,r){if(r===e?1<<e:0||0===this.array.length)return this;var n=r-1>>>e&fr;if(n>=this.array.length)return this;var i,o=n===this.array.length-1;if(e>0){var u=this.array[n];if(i=u&&u.removeAfter(t,e-ar,r),i===u&&o)return this}if(o&&!i)return this;var s=me(this,t);return o||s.array.pop(),i&&(s.array[n]=i),s};var Nr,Vr={};t(Ie,Lt),Ie.of=function(){return this(arguments)},Ie.prototype.toString=function(){return this.__toString("OrderedMap {","}")},Ie.prototype.get=function(t,e){var r=this._map.get(t);return void 0!==r?this._list.get(r)[1]:e},Ie.prototype.clear=function(){return 0===this.size?this:this.__ownerID?(this.size=0,this._map.clear(),this._list.clear(),this):De()},Ie.prototype.set=function(t,e){return Me(this,t,e)},Ie.prototype.remove=function(t){return Me(this,t,cr)},Ie.prototype.wasAltered=function(){return this._map.wasAltered()||this._list.wasAltered()},Ie.prototype.__iterate=function(t,e){var r=this;return this._list.__iterate(function(e){return e&&t(e[1],e[0],r)},e)},Ie.prototype.__iterator=function(t,e){return this._list.fromEntrySeq().__iterator(t,e)},Ie.prototype.__ensureOwner=function(t){if(t===this.__ownerID)return this;var e=this._map.__ensureOwner(t),r=this._list.__ensureOwner(t);return t?qe(e,r,t,this.__hash):(this.__ownerID=t,this._map=e,this._list=r,this)},Ie.isOrderedMap=be,Ie.prototype[dr]=!0,Ie.prototype[sr]=Ie.prototype.remove;var Yr;t(Ee,Y),Ee.of=function(){return this(arguments)},Ee.prototype.toString=function(){return this.__toString("Stack [","]")},Ee.prototype.get=function(t,e){var r=this._head;for(t=u(this,t);r&&t--;)r=r.next;return r?r.value:e},Ee.prototype.peek=function(){return this._head&&this._head.value},Ee.prototype.push=function(){if(0===arguments.length)return this;for(var t=this.size+arguments.length,e=this._head,r=arguments.length-1;r>=0;r--)e={value:arguments[r],next:e};return this.__ownerID?(this.size=t,this._head=e,this.__hash=void 0,this.__altered=!0,this):xe(t,e)},Ee.prototype.pushAll=function(t){if(t=v(t),0===t.size)return this;st(t.size);var e=this.size,r=this._head;return t.reverse().forEach(function(t){e++,r={value:t,next:r}}),this.__ownerID?(this.size=e,this._head=r,this.__hash=void 0,this.__altered=!0,this):xe(e,r)},Ee.prototype.pop=function(){return this.slice(1)},Ee.prototype.unshift=function(){return this.push.apply(this,arguments)},Ee.prototype.unshiftAll=function(t){return this.pushAll(t)},Ee.prototype.shift=function(){return this.pop.apply(this,arguments)},Ee.prototype.clear=function(){return 0===this.size?this:this.__ownerID?(this.size=0,this._head=void 0,this.__hash=void 0,this.__altered=!0,this):ke()},Ee.prototype.slice=function(t,e){if(a(t,e,this.size))return this;var r=h(t,this.size),n=f(e,this.size);if(n!==this.size)return Y.prototype.slice.call(this,t,e);for(var i=this.size-r,o=this._head;r--;)o=o.next;return this.__ownerID?(this.size=i,this._head=o,this.__hash=void 0,this.__altered=!0,this):xe(i,o)},Ee.prototype.__ensureOwner=function(t){return t===this.__ownerID?this:t?xe(this.size,this._head,t,this.__hash):(this.__ownerID=t,this.__altered=!1,this)},Ee.prototype.__iterate=function(t,e){if(e)return this.reverse().__iterate(t);for(var r=0,n=this._head;n&&t(n.value,r++,this)!==!1;)n=n.next;return r},Ee.prototype.__iterator=function(t,e){if(e)return this.reverse().__iterator(t);var r=0,n=this._head;return new S(function(){if(n){var e=n.value;return n=n.next,z(t,r++,e)}return I()})},Ee.isStack=Oe;var Qr="@@__IMMUTABLE_STACK__@@",Xr=Ee.prototype;Xr[Qr]=!0,Xr.withMutations=Tr.withMutations,Xr.asMutable=Tr.asMutable,Xr.asImmutable=Tr.asImmutable,Xr.wasAltered=Tr.wasAltered;var Fr;t(Ae,Q),Ae.of=function(){return this(arguments)},Ae.fromKeys=function(t){return this(p(t).keySeq())},Ae.prototype.toString=function(){return this.__toString("Set {","}")},Ae.prototype.has=function(t){return this._map.has(t)},Ae.prototype.add=function(t){return Re(this,this._map.set(t,!0))},Ae.prototype.remove=function(t){return Re(this,this._map.remove(t))},Ae.prototype.clear=function(){return Re(this,this._map.clear())},Ae.prototype.union=function(){var t=ur.call(arguments,0);return t=t.filter(function(t){return 0!==t.size}),0===t.length?this:0!==this.size||this.__ownerID||1!==t.length?this.withMutations(function(e){for(var r=0;t.length>r;r++)l(t[r]).forEach(function(t){return e.add(t)})}):this.constructor(t[0])},Ae.prototype.intersect=function(){var t=ur.call(arguments,0);if(0===t.length)return this;t=t.map(function(t){return l(t)});var e=this;return this.withMutations(function(r){e.forEach(function(e){t.every(function(t){return t.includes(e)})||r.remove(e)})})},Ae.prototype.subtract=function(){var t=ur.call(arguments,0);if(0===t.length)return this;t=t.map(function(t){return l(t)});var e=this;return this.withMutations(function(r){e.forEach(function(e){t.some(function(t){return t.includes(e)})&&r.remove(e)})})},Ae.prototype.merge=function(){return this.union.apply(this,arguments)},Ae.prototype.mergeWith=function(){var t=ur.call(arguments,1);return this.union.apply(this,t)},Ae.prototype.sort=function(t){return Le(qt(this,t))},Ae.prototype.sortBy=function(t,e){return Le(qt(this,e,t))},Ae.prototype.wasAltered=function(){return this._map.wasAltered()},Ae.prototype.__iterate=function(t,e){var r=this;return this._map.__iterate(function(e,n){return t(n,n,r)},e)},Ae.prototype.__iterator=function(t,e){return this._map.map(function(t,e){
return e}).__iterator(t,e)},Ae.prototype.__ensureOwner=function(t){if(t===this.__ownerID)return this;var e=this._map.__ensureOwner(t);return t?this.__make(e,t):(this.__ownerID=t,this._map=e,this)},Ae.isSet=je;var Gr="@@__IMMUTABLE_SET__@@",Zr=Ae.prototype;Zr[Gr]=!0,Zr[sr]=Zr.remove,Zr.mergeDeep=Zr.merge,Zr.mergeDeepWith=Zr.mergeWith,Zr.withMutations=Tr.withMutations,Zr.asMutable=Tr.asMutable,Zr.asImmutable=Tr.asImmutable,Zr.__empty=Ke,Zr.__make=Ue;var $r;t(Le,Ae),Le.of=function(){return this(arguments)},Le.fromKeys=function(t){return this(p(t).keySeq())},Le.prototype.toString=function(){return this.__toString("OrderedSet {","}")},Le.isOrderedSet=Te;var tn=Le.prototype;tn[dr]=!0,tn.__empty=Be,tn.__make=We;var en;t(Ce,V),Ce.prototype.toString=function(){return this.__toString(Pe(this)+" {","}")},Ce.prototype.has=function(t){return this._defaultValues.hasOwnProperty(t)},Ce.prototype.get=function(t,e){if(!this.has(t))return e;var r=this._defaultValues[t];return this._map?this._map.get(t,r):r},Ce.prototype.clear=function(){if(this.__ownerID)return this._map&&this._map.clear(),this;var t=this.constructor;return t._empty||(t._empty=Je(this,Qt()))},Ce.prototype.set=function(t,e){if(!this.has(t))throw Error('Cannot set unknown key "'+t+'" on '+Pe(this));var r=this._map&&this._map.set(t,e);return this.__ownerID||r===this._map?this:Je(this,r)},Ce.prototype.remove=function(t){if(!this.has(t))return this;var e=this._map&&this._map.remove(t);return this.__ownerID||e===this._map?this:Je(this,e)},Ce.prototype.wasAltered=function(){return this._map.wasAltered()},Ce.prototype.__iterator=function(t,e){var r=this;return p(this._defaultValues).map(function(t,e){return r.get(e)}).__iterator(t,e)},Ce.prototype.__iterate=function(t,e){var r=this;return p(this._defaultValues).map(function(t,e){return r.get(e)}).__iterate(t,e)},Ce.prototype.__ensureOwner=function(t){if(t===this.__ownerID)return this;var e=this._map&&this._map.__ensureOwner(t);return t?Je(this,e,t):(this.__ownerID=t,this._map=e,this)};var rn=Ce.prototype;rn[sr]=rn.remove,rn.deleteIn=rn.removeIn=Tr.removeIn,
rn.merge=Tr.merge,rn.mergeWith=Tr.mergeWith,rn.mergeIn=Tr.mergeIn,rn.mergeDeep=Tr.mergeDeep,rn.mergeDeepWith=Tr.mergeDeepWith,rn.mergeDeepIn=Tr.mergeDeepIn,rn.setIn=Tr.setIn,rn.update=Tr.update,rn.updateIn=Tr.updateIn,rn.withMutations=Tr.withMutations,rn.asMutable=Tr.asMutable,rn.asImmutable=Tr.asImmutable,t(Ye,k),Ye.prototype.toString=function(){return 0===this.size?"Range []":"Range [ "+this._start+"..."+this._end+(this._step>1?" by "+this._step:"")+" ]"},Ye.prototype.get=function(t,e){return this.has(t)?this._start+u(this,t)*this._step:e},Ye.prototype.includes=function(t){var e=(t-this._start)/this._step;return e>=0&&this.size>e&&e===Math.floor(e)},Ye.prototype.slice=function(t,e){return a(t,e,this.size)?this:(t=h(t,this.size),e=f(e,this.size),t>=e?new Ye(0,0):new Ye(this.get(t,this._end),this.get(e,this._end),this._step))},Ye.prototype.indexOf=function(t){var e=t-this._start;if(e%this._step===0){var r=e/this._step;if(r>=0&&this.size>r)return r}return-1},Ye.prototype.lastIndexOf=function(t){return this.indexOf(t)},Ye.prototype.__iterate=function(t,e){for(var r=this.size-1,n=this._step,i=e?this._start+r*n:this._start,o=0;r>=o;o++){if(t(i,o,this)===!1)return o+1;i+=e?-n:n}return o},Ye.prototype.__iterator=function(t,e){var r=this.size-1,n=this._step,i=e?this._start+r*n:this._start,o=0;return new S(function(){var u=i;return i+=e?-n:n,o>r?I():z(t,o++,u)})},Ye.prototype.equals=function(t){return t instanceof Ye?this._start===t._start&&this._end===t._end&&this._step===t._step:Ve(this,t)};var nn;t(Qe,k),Qe.prototype.toString=function(){return 0===this.size?"Repeat []":"Repeat [ "+this._value+" "+this.size+" times ]"},Qe.prototype.get=function(t,e){return this.has(t)?this._value:e},Qe.prototype.includes=function(t){return X(this._value,t)},Qe.prototype.slice=function(t,e){var r=this.size;return a(t,e,r)?this:new Qe(this._value,f(e,r)-h(t,r))},Qe.prototype.reverse=function(){return this},Qe.prototype.indexOf=function(t){return X(this._value,t)?0:-1},Qe.prototype.lastIndexOf=function(t){return X(this._value,t)?this.size:-1;},Qe.prototype.__iterate=function(t){for(var e=0;this.size>e;e++)if(t(this._value,e,this)===!1)return e+1;return e},Qe.prototype.__iterator=function(t){var e=this,r=0;return new S(function(){return e.size>r?z(t,r++,e._value):I()})},Qe.prototype.equals=function(t){return t instanceof Qe?X(this._value,t._value):Ve(t)};var on;_.Iterator=S,Xe(_,{toArray:function(){st(this.size);var t=Array(this.size||0);return this.valueSeq().__iterate(function(e,r){t[r]=e}),t},toIndexedSeq:function(){return new ht(this)},toJS:function(){return this.toSeq().map(function(t){return t&&"function"==typeof t.toJS?t.toJS():t}).__toJS()},toJSON:function(){return this.toSeq().map(function(t){return t&&"function"==typeof t.toJSON?t.toJSON():t}).__toJS()},toKeyedSeq:function(){return new at(this,!0)},toMap:function(){return Lt(this.toKeyedSeq())},toObject:function(){st(this.size);var t={};return this.__iterate(function(e,r){t[r]=e}),t},toOrderedMap:function(){return Ie(this.toKeyedSeq())},toOrderedSet:function(){return Le(d(this)?this.valueSeq():this)},toSet:function(){return Ae(d(this)?this.valueSeq():this)},toSetSeq:function(){return new ft(this)},toSeq:function(){return m(this)?this.toIndexedSeq():d(this)?this.toKeyedSeq():this.toSetSeq()},toStack:function(){return Ee(d(this)?this.valueSeq():this)},toList:function(){return fe(d(this)?this.valueSeq():this)},toString:function(){return"[Iterable]"},__toString:function(t,e){return 0===this.size?t+e:t+" "+this.toSeq().map(this.__toStringMapper).join(", ")+" "+e},concat:function(){var t=ur.call(arguments,0);return Ot(this,St(this,t))},contains:function(t){return this.includes(t)},includes:function(t){return this.some(function(e){return X(e,t)})},entries:function(){return this.__iterator(wr)},every:function(t,e){st(this.size);var r=!0;return this.__iterate(function(n,i,o){return t.call(e,n,i,o)?void 0:(r=!1,!1)}),r},filter:function(t,e){return Ot(this,lt(this,t,e,!0))},find:function(t,e,r){var n=this.findEntry(t,e);return n?n[1]:r},findEntry:function(t,e){var r;return this.__iterate(function(n,i,o){
return t.call(e,n,i,o)?(r=[i,n],!1):void 0}),r},findLastEntry:function(t,e){return this.toSeq().reverse().findEntry(t,e)},forEach:function(t,e){return st(this.size),this.__iterate(e?t.bind(e):t)},join:function(t){st(this.size),t=void 0!==t?""+t:",";var e="",r=!0;return this.__iterate(function(n){r?r=!1:e+=t,e+=null!==n&&void 0!==n?""+n:""}),e},keys:function(){return this.__iterator(mr)},map:function(t,e){return Ot(this,pt(this,t,e))},reduce:function(t,e,r){st(this.size);var n,i;return arguments.length<2?i=!0:n=e,this.__iterate(function(e,o,u){i?(i=!1,n=e):n=t.call(r,n,e,o,u)}),n},reduceRight:function(){var t=this.toKeyedSeq().reverse();return t.reduce.apply(t,arguments)},reverse:function(){return Ot(this,vt(this,!0))},slice:function(t,e){return Ot(this,mt(this,t,e,!0))},some:function(t,e){return!this.every(Ze(t),e)},sort:function(t){return Ot(this,qt(this,t))},values:function(){return this.__iterator(gr)},butLast:function(){return this.slice(0,-1)},isEmpty:function(){return void 0!==this.size?0===this.size:!this.some(function(){return!0})},count:function(t,e){return o(t?this.toSeq().filter(t,e):this)},countBy:function(t,e){return yt(this,t,e)},equals:function(t){return Ve(this,t)},entrySeq:function(){var t=this;if(t._cache)return new j(t._cache);var e=t.toSeq().map(Ge).toIndexedSeq();return e.fromEntrySeq=function(){return t.toSeq()},e},filterNot:function(t,e){return this.filter(Ze(t),e)},findLast:function(t,e,r){return this.toKeyedSeq().reverse().find(t,e,r)},first:function(){return this.find(s)},flatMap:function(t,e){return Ot(this,It(this,t,e))},flatten:function(t){return Ot(this,zt(this,t,!0))},fromEntrySeq:function(){return new ct(this)},get:function(t,e){return this.find(function(e,r){return X(r,t)},void 0,e)},getIn:function(t,e){for(var r,n=this,i=Kt(t);!(r=i.next()).done;){var o=r.value;if(n=n&&n.get?n.get(o,cr):cr,n===cr)return e}return n},groupBy:function(t,e){return dt(this,t,e)},has:function(t){return this.get(t,cr)!==cr},hasIn:function(t){return this.getIn(t,cr)!==cr},isSubset:function(t){return t="function"==typeof t.includes?t:_(t),
this.every(function(e){return t.includes(e)})},isSuperset:function(t){return t.isSubset(this)},keySeq:function(){return this.toSeq().map(Fe).toIndexedSeq()},last:function(){return this.toSeq().reverse().first()},max:function(t){return Dt(this,t)},maxBy:function(t,e){return Dt(this,e,t)},min:function(t){return Dt(this,t?$e(t):rr)},minBy:function(t,e){return Dt(this,e?$e(e):rr,t)},rest:function(){return this.slice(1)},skip:function(t){return this.slice(Math.max(0,t))},skipLast:function(t){return Ot(this,this.toSeq().reverse().skip(t).reverse())},skipWhile:function(t,e){return Ot(this,wt(this,t,e,!0))},skipUntil:function(t,e){return this.skipWhile(Ze(t),e)},sortBy:function(t,e){return Ot(this,qt(this,e,t))},take:function(t){return this.slice(0,Math.max(0,t))},takeLast:function(t){return Ot(this,this.toSeq().reverse().take(t).reverse())},takeWhile:function(t,e){return Ot(this,gt(this,t,e))},takeUntil:function(t,e){return this.takeWhile(Ze(t),e)},valueSeq:function(){return this.toIndexedSeq()},hashCode:function(){return this.__hash||(this.__hash=nr(this))}});var un=_.prototype;un[vr]=!0,un[Ir]=un.values,un.__toJS=un.toArray,un.__toStringMapper=tr,un.inspect=un.toSource=function(){return""+this},un.chain=un.flatMap,function(){try{Object.defineProperty(un,"length",{get:function(){if(!_.noLengthWarning){var t;try{throw Error()}catch(e){t=e.stack}if(-1===t.indexOf("_wrapObject"))return console&&console.warn&&console.warn("iterable.length has been deprecated, use iterable.size or iterable.count(). This warning will become a silent error in a future version. "+t),this.size}}})}catch(t){}}(),Xe(p,{flip:function(){return Ot(this,_t(this))},findKey:function(t,e){var r=this.findEntry(t,e);return r&&r[0]},findLastKey:function(t,e){return this.toSeq().reverse().findKey(t,e)},keyOf:function(t){return this.findKey(function(e){return X(e,t)})},lastKeyOf:function(t){return this.findLastKey(function(e){return X(e,t)})},mapEntries:function(t,e){var r=this,n=0;return Ot(this,this.toSeq().map(function(i,o){return t.call(e,[o,i],n++,r)}).fromEntrySeq());},mapKeys:function(t,e){var r=this;return Ot(this,this.toSeq().flip().map(function(n,i){return t.call(e,n,i,r)}).flip())}});var sn=p.prototype;sn[lr]=!0,sn[Ir]=un.entries,sn.__toJS=un.toObject,sn.__toStringMapper=function(t,e){return JSON.stringify(e)+": "+tr(t)},Xe(v,{toKeyedSeq:function(){return new at(this,!1)},filter:function(t,e){return Ot(this,lt(this,t,e,!1))},findIndex:function(t,e){var r=this.findEntry(t,e);return r?r[0]:-1},indexOf:function(t){var e=this.toKeyedSeq().keyOf(t);return void 0===e?-1:e},lastIndexOf:function(t){return this.toSeq().reverse().indexOf(t)},reverse:function(){return Ot(this,vt(this,!1))},slice:function(t,e){return Ot(this,mt(this,t,e,!1))},splice:function(t,e){var r=arguments.length;if(e=Math.max(0|e,0),0===r||2===r&&!e)return this;t=h(t,this.size);var n=this.slice(0,t);return Ot(this,1===r?n:n.concat(i(arguments,2),this.slice(t+e)))},findLastIndex:function(t,e){var r=this.toKeyedSeq().findLastKey(t,e);return void 0===r?-1:r},first:function(){return this.get(0)},flatten:function(t){return Ot(this,zt(this,t,!1))},get:function(t,e){return t=u(this,t),0>t||this.size===1/0||void 0!==this.size&&t>this.size?e:this.find(function(e,r){return r===t},void 0,e)},has:function(t){return t=u(this,t),t>=0&&(void 0!==this.size?this.size===1/0||this.size>t:-1!==this.indexOf(t))},interpose:function(t){return Ot(this,bt(this,t))},interleave:function(){var t=[this].concat(i(arguments)),e=Et(this.toSeq(),k.of,t),r=e.flatten(!0);return e.size&&(r.size=e.size*t.length),Ot(this,r)},last:function(){return this.get(-1)},skipWhile:function(t,e){return Ot(this,wt(this,t,e,!1))},zip:function(){var t=[this].concat(i(arguments));return Ot(this,Et(this,er,t))},zipWith:function(t){var e=i(arguments);return e[0]=this,Ot(this,Et(this,t,e))}}),v.prototype[yr]=!0,v.prototype[dr]=!0,Xe(l,{get:function(t,e){return this.has(t)?t:e},includes:function(t){return this.has(t)},keySeq:function(){return this.valueSeq()}}),l.prototype.has=un.includes,Xe(x,p.prototype),Xe(k,v.prototype),Xe(A,l.prototype),Xe(V,p.prototype),Xe(Y,v.prototype),
Xe(Q,l.prototype);var an={Iterable:_,Seq:O,Collection:N,Map:Lt,OrderedMap:Ie,List:fe,Stack:Ee,Set:Ae,OrderedSet:Le,Record:Ce,Range:Ye,Repeat:Qe,is:X,fromJS:F};return an});"""

eval immutable

# JS Reserved words

reservedInJs = newSetWith ("abstract arguments boolean break byte case catch char class " +
  "const continue debugger default delete do double else enum eval export " +
  "extends final finally float for function goto if implements import in " +
  "instanceof int interface let long native new null package private protected " +
  "public return short static super switch synchronized this throw throws transient " +
  "try typeof var void volatile while with yield").split(' ')...

# Compilation Server
# Ala Hack keeps track of compiled modules

compiledModules = newMap()
moduleGraph = newMap()

lookupCompiledModule = (name) ->
  lookupInMap compiledModules, name


compileTopLevel = (source, moduleName = '@unnamed') ->
  required = newSetWith 'Prelude' # TODO: Hardcoded prelude dependency
  if (not lookupCompiledModule 'Prelude') and moduleName isnt 'Prelude'
    request: 'Prelude'
  else
    directRequires = subtractSets required, (newSetWith moduleName)
    replaceOrAddToMap moduleGraph, moduleName, requires: directRequires
    toInject = collectRequiresFor moduleName
    ctx = injectedContext toInject
    {js, ast} = compileCtxAstToJs topLevel, ctx, (astFromSource "(#{source})", -1, -1)
    (finalizeTypes ctx, ast)
    replaceOrAddToMap compiledModules, moduleName,
      declared: (subtractContexts ctx, (injectedContext toInject)) # must recompute because ctx is mutated
      js: js
    js: js
    ast: ast
    types: typeEnumaration ctx
    errors: checkTypes ctx

compileExpression = (source, moduleName = '@unnamed') ->
  ast = (astFromSource "(#{source})", -1, -1)
  if _empty _terms ast
    {
      ast: ast
      js: ''
    }
  else
    module = lookupCompiledModule moduleName
    {modules, ctx} = contextWithDependencies moduleName
    [expression] = _terms ast
    {js} = compileCtxAstToJs topLevelExpression, ctx, expression
    (finalizeTypes ctx, expression)
    js: library + immutable + (listOfLines map lookupJs, (reverse modules)) + js
    ast: ast
    errors: checkTypes ctx

contextWithDependencies = (moduleName) ->
  toInject = concatSets (newSetWith moduleName), (collectRequiresFor moduleName)
  ctx: injectedContext toInject
  modules: setToArray toInject

# Primitive type checking for now
checkTypes = (ctx) ->
  # failed = mapToArray filterMap ((name) -> name is 'could not unify'), ctx.substitution
  if isFailed ctx.substitution
    ctx.substitution.fails

lookupJs = (moduleName) ->
  js = (lookupCompiledModule moduleName)?.js
  if not js
    console.error "#{moduleName} not found"
  else
    js

subtractContexts = (ctx, what) ->
  definitions = subtractMaps ctx._scope(), what._scope()
  typeNames = subtractMaps ctx._scope().typeNames, what._scope().typeNames
  classes = subtractMaps ctx._scope().classes, what._scope().classes
  macros = subtractMaps (objectToMap ctx._macros), (objectToMap what._macros)
  savedScopes = ctx.savedScopes
  {definitions, typeNames, classes, macros, savedScopes}

injectedContext = (modulesToInject) ->
  ctx = new Context
  for name of values modulesToInject when compiled = lookupCompiledModule name
    injectContext ctx, compiled.declared
  ctx

injectContext = (ctx, compiledModule) ->
  {definitions, typeNames, classes, macros} = compiledModule
  for name, macro of values macros
    if ctx._macros[name]
      throw new Error "Macro #{name} already defined"
    else
      ctx._macros[name] = macro
  topScope = ctx._scope()
  for name, definition of values definitions
    addToMap topScope, name, definition
  topScope.typeNames = concatMaps topScope.typeNames, typeNames
  topScope.classes = concatMaps topScope.classes, classes
  ctx

collectRequiresFor = (name) ->
  collectRequiresWithAcc name, newSet()

collectRequiresWithAcc = (name, acc) ->
  compiled = lookupInMap moduleGraph, name
  if not compiled
    console.error "#{name} module not found"
    newSet()
  else
    {requires} = compiled
    collected = reduceSet collectRequiresWithAcc,
      (concatSets requires, acc),
      (subtractSets requires, acc)
    concatSets collected, acc


findMatchingDefinitions = (moduleName, reference) ->
  {declared: {savedScopes}} = lookupCompiledModule moduleName
  {ctx} = contextWithDependencies moduleName
  {scope, type} = reference
  return [] unless scope?
  definitions = concatMaps (while scope isnt 0
    found = savedScopes[scope]
    scope = found.parent
    found.definitions)..., ctx._scope()
  removeFromMap definitions, '=='
  findMatchingDefinitionsOnType type, definitions

findMatchingDefinitionsOnType = (type, definitions) ->
  ctx = new Context
  validDefinitions = filterMap ((name, def) -> def.type?), definitions # TODO: filter before
  typesUnify = (def) ->
    not isFailed mostGeneralUnifier (freshInstance ctx, def.type).type, type.type
  [typed, notTyped] = partitionMap typesUnify, validDefinitions
  # allDefs = join (setToArray typed), (setToArray notTyped)
  allDefs = concatMaps typed, notTyped # TODO: don't use object key ordering for ordering
  values mapMap (__ prettyPrint, _type), allDefs

# API


syntaxedExpHtml = (string) ->
  collapse toHtml astize tokenize string

syntaxedType = (type) ->
  collapse toHtml typeCompile new Context, type

compileTopLevelSource = (source) ->
  {js, ast, ctx} = compileToJs topLevel, "(#{source})", -1, -1
  (finalizeTypes ctx, ast)
  {js, ast: ast, types: typeEnumaration ctx}

compileTopLevelAndExpression = (source) ->
  topLevelAndExpression source

topLevelAndExpression = (source) ->
  ast = astize (tokenize "(#{source})", -1), -1
  [terms..., expression] = _validTerms ast
  {ctx} = compiledDefinitions = compileAstToJs definitionList, pairs terms
  compiledExpression = compileCtxAstToJs topLevelExpression, ctx, expression
  (finalizeTypes ctx, expression)
  types: ctx._scope()
  subs: ctx.substitution.fails
  ast: ast
  compiled: library + immutable + compiledDefinitions.js + compiledExpression.js

typeEnumaration = (ctx) ->
  values mapMap _type, ctx._scope()

toJs = (compileFn, source) ->
  (compileToJs compileFn, "(#{source})", -1, -1)?.js

compileToJs = (compileFn, source, posOffset = 0, depthOffset = 0) ->
  compileAstToJs compileFn, (astFromSource source, posOffset, depthOffset)

astFromSource = (source, posOffset = 0, depthOffset = 0) ->
  astize (tokenize source, posOffset), depthOffset

compileAstToJs = (compileFn, ast) ->
  ctx = new Context
  compileCtxAstToJs compileFn, ctx, ast

compileCtxAstToJs = (compileFn, ctx, ast) ->
  ir = compileFn ctx, ast
  if ir
    jsIr = translateIr ctx, ir
    js = (if Array.isArray jsIr
        translateStatementsToJs
      else
        translateToJs) jsIr
  {ctx, ast, js}

astizeList = (source) ->
  parentize astize (tokenize "(#{source})", -1), -1

astizeExpression = (source) ->
  parentize astize tokenize source

astizeExpressionWithWrapper = (source) ->
  parentize astize (tokenize "(#{source})", -1), -1

finalizeTypes = (ctx, ast) ->
  visitExpressions ast, (expression) ->
    if expression.tea
      expression.tea = substitute ctx.substitution, expression.tea
    return
  for scope in ctx.savedScopes when scope?
    for name, def of values scope.definitions when def.type
      def.type = substitute ctx.substitution, def.type
  return

# end of API

# AST accessors

_tea = (expression) ->
  expression.tea

_operator = (call) ->
  (_terms call)[0]

_arguments = (call) ->
  (_terms call)[1..]

_validArguments = (call) ->
  (_validTerms call)[1..]

_terms = (form) ->
  filter isExpressionOrFake, form

_validTerms = (form) ->
  filter isExpression, form

_snd = ([a, b]) -> b

_fst = ([a, b]) -> a

_labelName = (atom) -> (_symbol atom)[0...-1]

_stringValue = ({symbol}) -> symbol[1...-1]

_symbol = ({symbol}) -> symbol

# Utils

join = (seq1, seq2) ->
  seq1.concat seq2

concatMap = (fn, list) ->
  concat map fn, list

concat = (lists) ->
  [].concat lists...

reverse = (list) ->
  (map id, list).reverse()

id = (x) -> x

map = (fn, list) ->
  if list then list.map fn else (list) -> map fn, list

allMap = (fn, list) ->
  all (map fn, list)

all = (list) ->
  (filter _is, list).length is list.length

any = (list) ->
  (filter _is, list).length > 0

filter = (fn, list) ->
  list.filter fn

partition = (fn, list) ->
  [(filter fn, list), (filter ((x) -> not (fn x)), list)]

_notEmpty = (x) -> x.length > 0

_empty = (x) -> x.length is 0

_is = (x) -> !!x

__ = (fna, fnb) ->
  (x) -> fna fnb x

# end of Utils

# Unit tests
test = (testName, teaSource, result) ->
  try
    compiled = (topLevelAndExpression teaSource)
  catch e
    logError "Failed to compile test |#{testName}|\n#{teaSource}\n", e
    return
  try
    log (collapse toHtml compiled.ast)
    if _notEmpty compiled.subs
      log compiled.subs
    if result isnt (got = eval compiled.compiled)
      log "'#{testName}' expected", result, "got", got
  catch e
    logError "Error in test |#{testName}|\n#{teaSource}\n", e

tests = [
  'simple defs'
  """a 2"""
  "a", 2

  'more defs'
  """a 2
    b 3"""
  "a", 2

  'constant data'
  """Color (data Red Blue)
    r Red
    b Blue
    r2 Red"""
  "(== r r2)", true

  'match numbers'
  """positive (fn [n]
      (match n
        0 False
        m True))"""
  "(positive 3)", yes

  'composite data'
  """Person (data
      Baby
      Adult [name: String])

    a (Adult "Adam")

    b Baby

    name (fn [person]
      (match person
        (Adult name) name))"""
  "(name a)", "Adam"

  'records'
  """Person (record name: String id: Num)

    name (fn [person]
      (match person
        (Person name id) name))"""
  """(name ((Person id: 3) "Mike"))""", "Mike"

  'polymorphic records'
  """Person (record [a] name: a id: Num)

    name (fn [person]
      (match person
        (Person name id) name))"""
  """(name ((Person id: 3) "Mike"))""", "Mike"

  'late bound function'
  """f (fn [x] (g x))
    g (fn [x] 2)"""
  "(f 4)", 2

  'late bound def'
  """[x y] z
    z [1 2]"""
  "y", 2

  'tuples'
  """snd (fn [pair]
      (match pair
        [x y] y))"""
  "(snd [1 2])", 2

  # TODO: add test for matching on tuples with multiple branches

  'match data'
  """Person (record name: String id: Num)
    name (fn [person]
      (match person
        (Person "Joe" id) 0
        (Person name id) id))"""
  """(name (Person "Mike" 3))""", 3

  'seqs'
  """{x y z} list
     list {1 2 3}"""
  "z", 3

  'match seq'
  """tail? (fn [list]
      (match list
        {} False
        xx True))
    {x ..xs} {1}"""
  "(tail? xs)", no

  'seq splice in match'
  """
    & (macro [what to]
      (: (Fn a (Array a) (Array a)))
      (Js.call (Js.access to "unshift") {what}))

    map (fn [what to]
      (match to
        {} {}
        {x ..xs} (& (what x) (map what xs))))

    {{x} ..xs} (map (& 42) {{}})"""
  "x", 42

  'typed function'
  """f (fn [x y]
    (: (Fn Bool String Bool))
    x)"""
  """(f True "a")""", yes

  'classes'
  """Show (class [a]
      show (fn [x] (: (Fn a String))))

    show-string (instance (Show String)
      show (fn [x] x))

    aliased-show (fn [something]
      (show something))

    showed-simply (show "Hello")
    showed-via-alias (aliased-show "Hello")"""
  "(== showed-simply showed-via-alias)", yes

  'multiple methods'
  """Util (class [a]
      show (fn [x] (: (Fn a String)))
      read (fn [x] (: (Fn String a))))

    util-string (instance (Util String)
       show (fn [x] x)
       read (fn [x] x))

    test (fn [string]
      (: (Fn String String))
      (read (show string)))"""
  """(test "Hello")""", "Hello"

  'multiple instances'
  """
    Show (class [a]
      show (fn [x] (: (Fn a String))))

    show-string (instance (Show String)
      show (fn [x] x))

    show-bool (instance (Show Bool)
      show (fn [x]
        (match x
          True "True"
          False "False")))"""
  "(show False)", "False"

  'instance constraints'
  """
    Show (class [a]
      show (fn [x] (: (Fn a String))))

    show-string (instance (Show String)
      show (fn [x] x))

    show-snd (instance (Show [a b])
      {(Show a) (Show b)}
      show (fn [x]
        (match x
          [fst snd] (show snd))))"""
  """(show ["Adam" "Michal"])""", "Michal"

  'instance constraints on array' # Tests where clause typing
  """
    Show (class [a]
      show (fn [x] (: (Fn a String))))

    show-string (instance (Show String)
      show (fn [x] x))

    head (fn [array]
      x
      {x ..xs} array)

    show-snd (instance (Show (Array a))
      {(Show a)}
      show (fn [array]
        (show (head array))))"""
  """(show {"Michal" "Adam"})""", "Michal"

  'multiple constraints'
  """
    Show (class [a]
      show (fn [x] (: (Fn a String))))

    Hide (class [a]
      hide (fn [x] (: (Fn a String))))

    show-string (instance (Show String)
      show (fn [x] x))

    hide-string (instance (Hide String)
      hide (fn [x] x))

    f (fn [x]
      (== (show x) (hide x)))
  """
  """(f "Hello")""", yes

  'superclasses'
  """
    Eq (class [a]
      = (fn [x y] (: (Fn a a Bool))))

    Ord (class [a]
      {(Eq a)}
      <= (fn [x y] (: (Fn a a Bool))))

    eq-bool (instance (Eq Bool)
      = (fn [x y]
        (match [x y]
          [True True] True
          [False False] True
          [w z] False)))

    ord-bool (instance (Ord Bool)
      <= (fn [x y]
        (match [x y]
          [True any] True
          [w z] (= w z))))

    test (fn [x]
      (== (<= x x) (= x x)))
    """
  """(test False)""", yes

  'function with constrained result'
  """
    Eq (class [a]
      = (fn [x y] (: (Fn a a Bool))))

    != (fn [x y]
      (not (= x y)))

    not (fn [x]
      (match x
        False True
        True False))

    eq-bool (instance (Eq Bool)
      = (fn [x y]
        (match [x y]
          [True True] True
          [False False] True
          [w z] False)))
  """
  "(!= False True)", yes

  'polymorphic data'
  """
    Maybe (data [a]
      None
      Just [value: a])

    from-just (fn [maybe]
      (match maybe
        (Just x) x))
  """
  "(from-just (Just 42))", 42

  'js unary op'
  """
    ~ (macro [x]
      (: (Fn Num Num))
      (Js.unary "-" x))
    x ~42
  """
  "(~ x)", 42

  'js binary op'
  """
    + (macro [x y]
      (: (Fn Num Num Num))
      (Js.binary "+" x y))
  """
  "(+ 1 2)", 3

  'js cond'
  """
    if (macro [what then else]
      (: (Fn Bool a a a))
      (Js.ternary what then else))
  """
  "(if False 1 2)", 2

  'currying functional macros'
  """
    * (macro [x y]
      (: (Fn Num Num Num))
      (Js.binary "*" x y))

    f (* 2)
  """
  "(f 3)", 6

  'getters'
  """
    Person (record
      first: String last: String)

    jack (Person "Jack" "Jack")
  """
  "(== (Person.first jack) (Person.last jack))", yes

  'macros in instances'
  """
    Show (class [a]
      show (fn [x] (: (Fn a String))))

    num-to-string (macro [n]
      (: (Fn Num String))
      (Js.binary "+" n "\\"\\""))

    show-num (instance (Show Num)
      show (fn [x]
        (num-to-string x)))
  """
  "(show 3)", '3'

  'fib'
  """fibonacci (fn [month] (adults month))

    adults (fn [month]
      (match month
        1 0
        n (+ (adults previous-month) (babies previous-month)))
      previous-month (- 1 month))

    babies (fn [month]
      (match month
        1 1
        n (adults (- 1 month))))

    + (macro [x y]
      (: (Fn Num Num Num))
      (Js.binary "+" x y))

    - (macro [x y]
      (: (Fn Num Num Num))
      (Js.binary "-" y x))"""
    "(fibonacci 7)", 8

  'Map literal'
  """
    data {a: True b: False}

    key? (macro [what in]
      (: (Fn k (Map k i) Bool))
      (Js.call (Js.access in "has") {what}))

    at (macro [key in]
      (: (Fn k (Map k i) i))
      (Js.call (Js.access in "get") {key}))
  """
  """(== (key? "c" data) (at "b" data))""", yes

  'create Set'
  """
    data (Set "Adam" "Vojta" "Michal")

    elem? (macro [what in]
      (: (Fn i (Set i) Bool))
      (Js.call (Js.access in "has") {what}))
  """
  """(elem? "Michal" data)""", yes

  'create Map'
  """
    data (Map 3 "a" 5 "b")

    at (macro [key in]
      (: (Fn k (Map k i) i))
      (Js.call (Js.access in "get") {key}))
  """
  """(at 5 data)""", 'b'

  'type alias'
  """
    Point (type [Num Num])

    x (fn [p]
      (: (Fn Point Num))
      first
      [first second] p)
  """
  "(x [3 4])", 3

  'collections'
  """
    Collection (class [collection]
      elem? (fn [what in]
        (: (Fn item (collection item) Bool))
        (# Whether in contains what .)))

    Bag (class [bag]
      {(Collection bag)}

      fold (fn [with initial over]
        (: (Fn (Fn item b b) b (bag item)))
        (# Fold over with using initial .))

      length (fn [bag]
        (: (Fn (bag item) Num))
        (# The number of items in the bag .))

      empty? (fn [bag]
        (: (Fn (bag item) Bool))
        (# Whether the bag contains no elements.)))

    list-elem? (macro [what in]
      (: (Fn item (Array item) Bool))
      (Js.call (Js.access in "contains") {what}))

    collection-list (instance (Collection Array)
      elem? (fn [what in]
        (list-elem? what in)))
  """
  "(elem? 3 {1 2 3})", yes

  'multiparam classes'
  """
    Collection (class [ce e]
      first (fn [in]
        (: (Fn (ce e) e))))

    list-first (macro [in]
      (: (Fn (Array item) item))
      (Js.call (Js.access in "first") {}))

    list-collection (instance (Collection Array a)
      first (fn [in]
        (list-first in)))
  """
  "(first {42 43 44})", 42

  'functional deps'
  """
    Collection (class [ce e]
      first (fn [in]
        (: (Fn ce e))))

    list-first (macro [in]
      (: (Fn (Array item) item))
      (Js.call (Js.access in "first") {}))

    list-collection (instance (Collection (Array a) a)
      first (fn [in]
        (list-first in)))
  """
  "(first {42 43 44})", 42

  'functional deps on function'
  """
    Map (class [m k v]
      put (fn [key value map]
        (: (Fn k v m m))))

    map-map (instance (Map (Map k v) k v)
      put (macro [key value map]
        (: (Fn k v (Map k v) (Map k v)))
        (Js.call (Js.access map "set") {key value})))

    count (macro [map]
      (: (Fn (Map k v) Num))
      (Js.access map "size"))

    magic (fn [key map]
      (put key 42 map))
  """
  "(count (magic \\C (Map)))", 1

  'super classes with less params'
  """
    Bag (class [b i]
      length (fn [bag]
        (: (Fn b Num)))
      id (fn [item]
        (: (Fn i i))))

    Map (class [m k v]
      {(Bag m v)}
      put (fn [key value map]
        (: (Fn k v m m))))

    map-bag (instance (Bag (Map k v) v)
      length (macro [map]
        (: (Fn (Map k v) Num))
        (Js.access map "size"))
      id (fn [x] x))

    map-map (instance (Map (Map k v) k v)
      put (macro [key value map]
        (: (Fn k v (Map k v) (Map k v)))
        (Js.call (Js.access map "set") {key value})))

    magic (fn [key map]
      (put key 42 map))
  """
  "(length (magic \\C (Map)))", 1

  'functional deps with instance constraints'
  """
    Stack (data [a]
      Nil
      Node [value: a tail: (Stack a)])

    Eq (class [a]
      = (fn [x y] (: (Fn a a Bool))))

    num-eq (instance (Eq Num)
      = (macro [x y]
        (: (Fn Num Num Bool))
        (Js.binary "===" x y)))

    Collection (class [collection item]
      elem? (fn [what in]
        (: (Fn item collection Bool))))

    Bag (class [bag item]
      fold (fn [with initial over]
        (: (Fn (Fn a item a) a bag a))))

    stack-collection (instance (Collection (Stack a) a)
      {(Eq a)}
      elem? (fn [what in]
        (fold found-or-equals False in)
        found-or-equals (fn [found item]
          (= what item))))

    stack-bag (instance (Bag (Stack a) a)
      fold (fn [with initial over]
        (match over
          Nil initial
          (Node x xs) (fold with (with initial x) xs))))
  """
  "(elem? 2 (Node 2 Nil))", yes

  'nested pattern matching'
  """
    f (fn [x]
      y
      [[z y] g] x)
  """
  "(f [[2 42] 3])", 42

  'deferring in tuples'
  """
    g [f {} 3]
    f 4
    [o t r] g
  """
  "o", 4

  'multiple generic constraints'
  """
    Show (class [a]
      show (fn [x] (: (Fn a String))))

    show-string (instance (Show String)
      show (fn [x] x))

    f (fn [pair]
      [(show a) (show b)]
      [a b] pair)

    [x y] (f ["A" "B"])
  """
  """x""", "A"

  'higher-order use of constrained function'
  """
    Show (class [a]
      show (fn [x] (: (Fn a String))))

    show-string (instance (Show String)
      show (fn [x] x))

    f (fn [pair]
      [(show a) (show b)]
      [a b] pair)

    apply (fn [m to]
      (m to))

    [x y] (apply f ["A" "B"])
  """
  """x""", "A"

  'deeply deferred'
  """
    c b
    b a
    a 3
  """
  "c", 3

  'compile before typing due to multiple deferred'
  """
    a (f 3)
    f (fn [x] (h g x))
    g (fn [x] b)
    h (fn [y z] (y z))
    b 4
    c (f 2)
  """
  "a", 4

  'more deferred'
  """
    a (e 3)

    map (fn [l] (l 2))

    e (fn [x]
      (map f)
      k (g 2))

    f (fn [x]
      (h 2))

    g (fn [x]
      2)

    h (fn [x]
      (j 1))

    j (fn [x]
      2)
  """
  "a", 2

  'constants in classes'
  """
  A (class [c e]
    empty (: c)

    first (fn [x] (: (Fn c e))))

  list-a (instance (A (Array a) a)
    empty {}

    first (macro [list]
      (: (Fn (Array a) a))
      (Js.call (Js.access list "first") {})))

  unshift (macro [what to]
    (: (Fn a (Array a) (Array a)))
    (Js.call (Js.access to "unshift") {what}))
  """
  "(first (unshift 3 empty))", 3

  # TODO: this works, but show that we honor the monorphism restriction
  #       in the sense that some is inferred a concrete type
  #       although it should have a polymorphic type or it should error
  #       this is because we compile as if x and some where in the same
  #       implicitly typed group
  'values with constraints'
  """
  A (class [c]
    empty (: c))

  B (class [c e]
    add (fn [what to] (: (Fn e c c))))

  list-a (instance (A (Array a))
    empty {})

  list-b (instance (B (Array a) a)
    add (macro [what to]
      (: (Fn a (Array a) (Array a)))
      (Js.call (Js.access to "unshift") {what})))

  first (macro [list]
    (: (Fn (Array a) a))
    (Js.call (Js.access list "first") {}))

  some (add 2 empty)

  x (first some)
  """
  "x", 2

  'curried type constructor'
  """
  + (macro [x y]
    (: (Fn Num Num Num))
    (Js.binary "+" x y))

  get (macro [key from]
    (: (Fn k (Map k v) v))
    (Js.method from "get" {key}))

  put (macro [key value into]
    (: (Fn k v (Map k v) (Map k v)))
    (Js.method into "set" {key value}))

  Mappable (class [wrapper]
    map (fn [what onto]
      (: (Fn (Fn a b) (wrapper a) (wrapper b)))
      (# Apply what to every value inside onto .)))

  reduce-map (macro [with initial over]
    (: (Fn (Fn a v k a) a (Map k v) a))
    (Js.method over "reduce" {with initial}))

  map-mappable (instance (Mappable (Map k))
    map (fn [what onto]
      (reduce-map helper (Map) onto)
      helper (fn [acc value key]
        (put key (what value) acc))))
  """
  """(get "c" (map (+ 1) {a: 3 b: 2 c: 4}))""", 5

  'reduced call context'
  """
  Bag (class [bag item]
    empty (: bag)

    fold (fn [with initial over]
      (: (Fn (Fn item a a) a bag a)))

    append (fn [what to]
      (: (Fn bag bag bag)))

    first (fn [of]
      (: (Fn bag item))))

  array-bag (instance (Bag (Array a) a)
    empty {}

    fold (macro [with initial list]
      (: (Fn (Fn a b b) b (Array a) b))
      (Js.method list "reduce"
        {(fn [acc x] (with x acc)) initial}))

    append (macro [what to]
      (: (Fn (Array a) (Array a) (Array a)))
      (Js.method to "concat" {what}))

    first (macro [list]
      (: (Fn (Array a) a))
      (Js.method list "first" {})))

  concat (fn [bag-of-bags]
    (fold append empty bag-of-bags))
  """
  "(first (concat {{1} {2} {3}}))", 1

  'mixing constructor classes with fundeps'
  """
  Mappable (class [wrapper]
    map (fn [what onto]
      (: (Fn (Fn a b) (wrapper a) (wrapper b)))
      (# Apply what to every value inside onto .)))

  Bag (class [bag item]
    size (fn [bag]
      (: (Fn bag Num))
      (# The number of items in the bag .))

    empty (: bag)

    fold (fn [with initial over]
      (: (Fn (Fn item a a) a bag a))
      (# Fold over with using initial ...))

    join (fn [what with]
      (: (Fn bag bag bag))
      (# Fold over with using initial ...)))

  array-mappable (instance (Mappable Array)
    map (macro [what over]
      (: (Fn (Fn a b) (Array a) (Array b)))
      (Js.method over "map" {what})))

  array-bag (instance (Bag (Array a) a)
    size (macro [list]
      (: (Fn (List a) Num))
      (Js.access list "size"))

    empty {}

    fold (macro [with initial list]
      (: (Fn (Fn a b b) b (Array a) b))
      (Js.method list "reduce"
        {(fn [acc x] (with x acc)) initial}))

    join (macro [what with]
      (: (Fn (Array a) (Array a) (Array a)))
      (Js.method what "concat" {with})))

  concat (fn [bag-of-bags]
    (fold join empty bag-of-bags))

  concat-map (fn [what over]
    (concat (map what over)))

  """
  "(size (concat-map (fn [x] {}) {1 2 3}))", 0

  # The following doesn't work because the Collection type class specifies
  # that the constructor takes only one argument.
  #
  # 'map as collection'
  # """
  # Collection (class [collection]
  #   elem? (fn [what in]
  #     (: (Fn item (collection item) Bool))
  #     (# Whether in contains what .)))
  #
  # map-elem? (macro [what in]
  #   (: (Fn item (Map key item) Bool))
  #   (Js.call (Js.access in "contains") {what}))
  #
  # collection-map (instance (Collection Map)
  #   elem? (fn [what in]
  #     (map-elem? what in)))
  # """
  # "(elem? 1 {a: 1})", yes


  # bag-list (instance (Bag List)
  #   fold (fn [with initial over]
  #     (fold-list with initial over))

  #   fold (fn [with initial over]
  #     (fold-list with initial over))

  #   fold (fn [with initial over]
  #     (fold-list with initial over)))

  # TODO: support matching with the same name
  #       to implement this we need the iife to take as arguments all variables
  #       with the same names, since JavaScript shadows it too strongly and
  #       replaces the value with undefined
  # test "test", "f (fn [x] (match x x x)) (f 2)", 2
  # so:
  #function f(x) {
  # return (function (x){
  #   var x = x;
  #   return x;
  # })(x);
  #}
  # This is necessary because we might be reusing the name for something else
  # Or we can just mangle the name like PureScript does it
]

testNamed = (givenName) ->
  for [name, source, expression, result] in tuplize 4, tests when name is givenName
    return source + "\n" + "_ " + expression
  throw new Error "Test #{givenName} not found!"

logError = (message, error) ->
  log message, error.message, (error.stack
    .replace(/\n?((\w+)[^>\n]+>[^>\n]+>[^>\n]+:(\d+:\d+)|.*)(?=\n)/g, '\n$2 $3')
    .replace(/\n (?=\n)/g, ''))

debug = (fun) ->
  try
    fun()
  catch e
    logError "debug", e

runTest = (givenName) ->
  for [name, source, expression, result] in tuplize 4, tests when name is givenName
    test name, source + "\n" + expression, result
  "Done"

runTests = (tests) ->
  for [name, source, expression, result] in tuplize 4, tests
    test name, source + "\n" + expression, result
  "Finished"
# end of tests


exports.compileTopLevel = compileTopLevel
exports.compileExpression = compileExpression
exports.findMatchingDefinitions = findMatchingDefinitions
exports.astizeList = astizeList
exports.astizeExpression = astizeExpression
exports.astizeExpressionWithWrapper = astizeExpressionWithWrapper
exports.syntaxedExpHtml = syntaxedExpHtml
exports.syntaxedType = syntaxedType
exports.prettyPrint = prettyPrint

# exports.compileModule = (source) ->
#   """
#   #{library}
#   var exports = {};
#   #{compileDefinitionsInModule source}
#   exports"""

exports.library = library

exports.isForm = isForm
exports.isCall = isCall
exports.isAtom = isAtom


exports.join = join
exports.concatMap = concatMap
exports.concat = concat
exports.id = id
exports.map = map
exports.allMap = allMap
exports.all = all
exports.filter = filter
exports.partition = partition
exports._notEmpty = _notEmpty
exports._is = _is
exports.__ = __

exports._operator = _operator
exports._arguments = _arguments
exports._terms = _terms
exports._snd = _snd
exports._fst = _fst
exports._labelName = _labelName
exports._symbol = _symbol
