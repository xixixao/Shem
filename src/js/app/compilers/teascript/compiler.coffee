tokenize = (input) ->
  currentPos = 0
  while input.length > 0
    match = input.match ///
      ^ # must be at the start
      (
        \x20+\n? # spaces possibly at end of line
      | \n # newline
      | [#{controls}] # delims
      | /([^\\x20]|\\/)([^/]|\\/)*?/ # regex
      | "[^"]*?" # strings
      | '\\?[^']' # char
      | [^#{controls}"'\s]+ # normal tokens
      )///
    if not match
      throw new Error "Could not recognize a token starting with `#{input[0..10]}`"
    [token] = match
    input = input[token.length...]
    pos = currentPos
    currentPos += token.length
    constantLabeling {token, pos}

controls = '\\(\\)\\[\\]\\{\\}'

noWS = (tokens) ->
  tokens.filter (token) -> token.label isnt 'whitespace'

astize = (tokens) ->
  tree = []
  current = []
  stack = [[]]
  for token in tokens
    if token.token in leftDelims
      stack.push [token]
    else if token.token in rightDelims
      closed = stack.pop()
      if token.token isnt delims[closed[0].token]
        throw "Wrong closing delimiter #{token.token} for opening delimiter #{closed[0].token}"
      closed.push token
      if not stack[stack.length - 1]
        throw "Missing opening delimeter matching #{token.token}"
      stack[stack.length - 1].push closed
    else
      stack[stack.length - 1].push token
  ast = stack[0][0]
  if not ast
    throw "Missing closing delimeter matching #{stack[stack.length - 1][0].token}"
  else
    ast

leftDelims = ['(', '[', '{']
rightDelims = [')', ']', '}']
delims = '(': ')', '[': ']', '{': '}'

constantLabeling = (atom) ->
  {token} = atom
  labelMapping atom,
    ['numerical', /^-?\d+/.test token]
    ['label', isLabel atom]
    ['string', /^["']/.test token]
    ['regex', /^\/[^ \/]/.test token]
    ['paren', token in ['(', ')']]
    ['bracket', token in ['[', ']']]
    ['brace', token in ['{', '}']]
    ['whitespace', /^\s+$/.test token]

_isCollectionDelim = (atom) ->
  atom.label in ['bracket', 'brace']

# TODO: remove
walk = (ast, cb) ->
  if Array.isArray ast
    ast = cb ast
    if Array.isArray ast
      ast = typed ast, (for node in ast
        walk node, cb)
  ast

# TODO: remove
typed = (a, b) ->
  b.type = a.type
  b

crawl = (ast, cb, parent) ->
  if Array.isArray ast
    typed ast, (for node in ast
      crawl node, cb, ast)
  else
    cb ast, ast.token, parent

visitExpressions = (expression, cb) ->
  cb expression
  if isForm expression
    for term in _terms expression
      visitExpressions term, cb

inside = (node) -> node[1...-1]

matchNode = (to, node) ->
  return false unless node.length >= 3
  [paren, {token}] = node
  paren.token is '(' and token is to

matchAnyNode = (tos, node) ->
  for to in tos
    if matchNode to, node
      return true
  return false

macro = (operator, ast, cb) ->
  walk ast, (node) ->
    if matchNode operator, node
      return cb node, inside node
    node

typedMacro = (type, ast, cb) ->
  walk ast, (node) ->
    if node.type is type
      return cb node, inside node
    node

mapTokens = (tokens, ast, cb) ->
  crawl ast, (word, token) ->
    if token in tokens
      cb word

teas = (fn, string) ->
  ast = astize tokenize string
  compiled = fn (ctx = new Context), ast
  syntax: collapse toHtml ast
  types: values mapMap (__ highlightType, _type), subtractMaps ctx._scope(), builtInContext new Context
  translation: '\n' + compiled

mapCompile = (fn, string) ->
  fn (new Context), astize tokenize string

mapTyping = (fn, string) ->
  ast = astize tokenize string
  fn (ctx = new Context), ast
  expressions = []
  visitExpressions ast, (expression) ->
    expressions.push "#{collapse toHtml expression} :: #{highlightType expression.tea}" if expression.tea
  types: values mapMap (__ highlightType, _type), subtractMaps ctx._scope(), builtInContext new Context
  subs: values mapMap highlightType, ctx.substitution
  ast: expressions
  deferred: ctx.deferredBindings()

mapTypingBare = (fn, string) ->
  ast = astize tokenize string
  fn (ctx = new Context), ast
  expressions = []
  visitExpressions ast, (expression) ->
    expressions.push [(collapse toHtml expression), expression.tea] if expression.tea
  types: values mapMap _type, subtractMaps ctx._scope(), builtInContext new Context
  subs: values ctx.substitution
  ast: expressions
  deferred: ctx.deferredBindings()

highlightType = (type) ->
  typeAst = astize tokenize printType type
  syntaxType typeAst
  collapse toHtml typeAst

_type = (declaration) ->
  declaration.type

mapSyntax = (fn, string) ->
  ast = astize tokenize string
  fn (new Context), ast
  collapse toHtml ast

class Context
  constructor: ->
    @_macros = builtInMacros
    @expand = {}
    @names = []
    @_isOperator = []
    @variableIndex = 0
    @typeVariabeIndex = 0
    @substitution = newMap()
    @statement = []
    @cacheScopes = [[]]
    @_assignTos = []
    @scopes = [@_augmentScope builtInContext this] # dangerous passing itself in constructor

  macros: ->
    @_macros

  _name: ->
    if @_onTopName()
       @_currentName().name

  _nameExpression: ->
    if @_onTopName()
      @_currentName().expression

  _currentName: ->
    @names[@names.length - 1]

  setName: (expression) ->
    @names.push
      name: expression?.token
      expression: expression
      deferredBindings: []
      definedNames: []
      subs: []

  subName: ->
    @_currentName().subs.push yes

  resetName: ->
    if @_onTopName()
      @names.pop()
    else
      @_currentName().subs.pop()

  _onTopName: ->
    @_currentName().subs.length is 0

  isOperator: ->
    @_isOperator[@_isOperator.length - 1]

  setIsOperator: (isOperator) ->
    @_isOperator.push isOperator

  resetIsOperator: ->
    @_isOperator.pop()

  setAssignTo: (compiled) ->
    @_assignTos.push compiled

  assignTo: ->
    @_assignTos[@_assignTos.length - 1]

  resetAssignTo: ->
    @_assignTos.pop()

  _scope: ->
    @scopes[@scopes.length - 1]

  _parentScope: ->
    @scopes[@scopes.length - 2]

  newScope: ->
    @scopes.push @_augmentScope newMap()

  _augmentScope: (scope) ->
    scope.deferred = []
    scope.deferredBindings = []
    scope

  newLateScope: ->
    @newScope()
    @_scope().late = yes

  closeScope: ->
    @scopes.pop()

  isInLateScope: ->
    @_scope().late

  declaration: (name) ->
    @_declarationInScope @scopes.length - 1, name

  _declarationInScope: (i, name) ->
    (lookupInMap @scopes[i], name) or
      i > 0 and (@_declarationInScope i - 1, name) or
      undefined # throw "Could not find declaration for #{name}"

  addType: (name, type) ->
    if lookupInMap @_scope(), name
      (lookupInMap @_scope(), name).type = type
    else
      addToMap @_scope(), name, {type}

  addToDeferredNames: (binding) ->
    @_currentName().deferredBindings.push binding

  addToDeferred: (binding) ->
    @_scope().deferredBindings.push binding

  addToDefinedNames: (binding) ->
    @_currentName().definedNames.push binding

  definedNames: ->
    @_currentName().definedNames

  deferredNames: ->
    @_currentName().deferredBindings

  deferredBindings: ->
    @_scope().deferredBindings

  addToScope: (name) ->
    addToMap @_scope(), name, {}

  addArity: (name, arity) ->
    if lookupInMap @_scope(), name
      (lookupInMap @_scope(), name).arity = arity
    else
      addToMap @_scope(), name, {arity}

  addTypes: (names, types) ->
    for name, i in names
      @addType name, types[i]

  type: (name) ->
    (@declaration name)?.type

  arity: (name) ->
    (@declaration name)?.arity

  freshTypeVariable: (kind) ->
    if not kind
      throw new Error "Provide kind in freshTypeVariable"
    new TypeVariable (freshName @typeVariabeIndex++), kind

  extendSubstitution: (substitution) ->
    @substitution = joinSubs substitution, @substitution

  newJsVariable: ->
    "i#{@variableIndex++}"

  setGroupTranslation: ->
    @cacheScopes.push []

  cacheAssignTo: ->
    if @assignTo() and not @_translationCache()
      # Replace assign to with cache name
      cacheName = @newJsVariable()
      cache = [cacheName, @assignTo()]
      @_assignTos[@_assignTos.length - 1] = cacheName
      @cacheScopes[@cacheScopes.length - 1][0] = cache

  _translationCache: ->
    @cacheScopes[@cacheScopes.length - 1][0]

  translationCache: ->
    if cache = @cacheScopes.pop()[0]
      [compileAssign cache]
    else
      []

  setDefer: (dependencyName) ->
    @_setDeferIn @_scope(), dependencyName

  setDeferParent: (dependencyName) ->
    if not @scopes.length >= 2
      throw new "Deferring parent although this is top level scope"
    @_setDeferIn @_parentScope(), dependencyName

  _setDeferIn: (scope, dependencyName) ->
    scope._defer =
      if dependencyName
        (@_shouldDeferIn scope) or dependencyName
      else
        dependencyName

  shouldDefer: ->
    @_shouldDeferIn @_scope()

  _shouldDeferIn: (scope) ->
    scope._defer

  addDeferred: (dependencyName, lhs, rhs) ->
    @_scope().deferred.push [dependencyName, lhs, rhs]

  deferred: ->
    @_scope().deferred


expressionCompile = (ctx, expression) ->
  throw "invalid expressionCompile args" unless ctx instanceof Context and expression
  (if isAtom expression
    atomCompile
  else if isTuple expression
    tupleCompile
  else if isSeq expression
    seqCompile
  else if isCall expression
    callCompile
  else
    log "Not handled", expression
    throw "Not handled expression in expressionCompile"
  ) ctx, expression

# -- This was used to use compiled results from some parent macro while
#    compiling as something else
# rememberCompiled = (expression, result) ->
#   expression.compiled = result

# _compiled = (expression) ->
#   expression.compiled

callCompile = (ctx, call) ->
  operator = _operator call
  operatorName = _token operator
  if isName operator
    (if operatorName of ctx.macros()
      macroCompile
    else if ctx.arity operatorName
      callKnownCompile
    else
      callUnknownCompile) ctx, call
  else
    expandedOp = termCompile ctx, operator
    if isTranslated expandedOp
      callUnknownTranslate ctx, expandedOp, call
    else
      expressionCompile replicate call,
        (call_ (join [expandedOp], (_arguments call)))

macroCompile = (ctx, call) ->
  op = _operator call
  op.label = 'keyword'
  expanded = ctx.macros()[op.token] ctx, call
  if not isWellformed expanded
    'malformed'
  else if isTranslated expanded
    expanded
  else
    expressionCompile ctx, expanded

isTranslated = (result) ->
  typeof result is 'string' or result instanceof String

callUnknownCompile = (ctx, call) ->
  callUnknownTranslate ctx, (operatorCompile ctx, call), call

callKnownCompile = (ctx, call) ->
  operator = _operator call
  args = _labeled _arguments call
  labeledArgs = labeledToMap args

  if tagFreeLabels args
    return malformed 'labels without values inside call', call

  paramNames = ctx.arity operator.token
  if not paramNames
    log "deferring in known call #{operator.token}"
    ctx.setDefer operator.token
    return 'deferred'
  positionalParams = filter ((param) -> not (lookupInMap labeledArgs, param)), paramNames
  nonLabeledArgs = map _snd, filter (([label, value]) -> not label), args

  if nonLabeledArgs.length > positionalParams.length
    malformed call, 'Too many arguments'
  else
    extraParamNames = positionalParams[nonLabeledArgs.length..]
    extraParams = map token_, extraParamNames
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
          malformed call, "curried constructor pattern"
        else
          compiled = callConstructorPattern ctx, sortedCall, extraParamNames
          retrieve call, sortedCall
          compiled
      else
        malformed call, "function patterns not supported"
    else
      if nonLabeledArgs.length < positionalParams.length
        log "currying known call"
        lambda = (fn_ extraParams, sortedCall)
        compiled = macroCompile ctx, lambda
        retrieve call, lambda
        compiled
      else
        compiled = callSaturatedKnownCompile ctx, sortedCall
        retrieve call, sortedCall
        compiled

callConstructorPattern = (ctx, call, extraParamNames) ->
  operator = _operator call
  args = _arguments call
  isExtra = (arg) -> (isAtom arg) && (_token arg) in extraParamNames
  paramNames = ctx.arity operator.token

  if args.length - extraParamNames.length > 1
    ctx.cacheAssignTo()

  compiledArgs = (for arg, i in args when not isExtra arg
    ctx.setAssignTo "#{ctx.assignTo()}#{jsObjectAccess paramNames[i]}"
    elemCompiled = expressionCompile ctx, arg
    ctx.resetAssignTo()
    elemCompiled)

  for arg in args when isExtra arg
    arg.tea = ctx.freshTypeVariable star

  # Typing operator like inside a known call
  precsForData = operatorCompile ctx, call
  log 'op in pattern', precsForData

  # Gets the general type as if the extra arguments were supplied
  callTyping ctx, call

  combinePatterns join [precsForData], compiledArgs

jsObjectAccess = (fieldName) ->
  if (validIdentifier fieldName) is fieldName
    ".#{fieldName}"
  else
    "['#{fieldName}']"

callSaturatedKnownCompile = (ctx, call) ->
  operator = _operator call
  args = _arguments call

  compiledOperator = operatorCompile ctx, call
  log "compiled saturated", operator, call

  compiledArgs = termsCompile ctx, args

  callTyping ctx, call

  assignCompile ctx, call, "#{compiledOperator}(#{listOf compiledArgs})"

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
  ctx.subName()
  compiledOperator = atomCompile ctx, _operator call
  ctx.resetName()
  ctx.resetIsOperator()
  compiledOperator

callUnknownTranslate = (ctx, translatedOperator, call) ->
  args = _arguments call


  argList = if ctx.shouldDefer()
    'deferred'
  else
    listOf termsCompile ctx, args

  callTyping ctx, call

  assignCompile ctx, call, "_#{args.length}(#{translatedOperator}, #{argList})"

callTyping = (ctx, call) ->
  return if ctx.shouldDefer()
  call.tea = callInfer ctx, _terms call

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
  unify ctx, operatorTea, (typeFn argTea, returnType)
  returnType

termsCompile = (ctx, list) ->
  termCompile ctx, term for term in list

termCompile = (ctx, term) ->
  ctx.subName()
  ctx.setIsOperator no
  compiled = expressionCompile ctx, term
  ctx.resetIsOperator()
  ctx.resetName()
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
        ctx.setAssignTo "#{ctx.assignTo()}[#{i}]"
        elemCompiled = expressionCompile ctx, elem
        ctx.resetAssignTo()
        elemCompiled
    else
      termsCompile ctx, elems
  # TODO: could support partial tuple application via bare labels
  #   map [0: "hello" 1:] {"world", "le mond", "svete"}
  # TODO: should we support bare records?
  #   [a: 2 b: 3]
  form.tea = applyKindFn (tupleType arity), (tea for {tea} in elems)...

  if ctx.assignTo()
    combinePatterns compiledElems
  else
    form.label = 'operator'
    assignCompile ctx, form, "[#{listOf compiledElems}]"

seqCompile = (ctx, form) ->
  elems = _terms form
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
      return malformed 'Matching with splat requires at least one element name', form

    compiledArgs = (for elem, i in elems
      [lhs, rhs] =
        if isSplat elem
          elem.label = 'name'
          [(splatToName elem), "seq_splat(#{i}, #{elems.length - i - 1}, #{sequence})"]
        else
          [elem, "seq_at(#{i}, #{sequence})"]
      ctx.setAssignTo rhs
      lhsCompiled = expressionCompile ctx, lhs
      retrieve elem, lhs
      ctx.resetAssignTo()
      lhsCompiled)
    elemType = ctx.freshTypeVariable star
    # TODO use (Seq c e) instead of (Array e)
    form.tea = new TypeApp arrayType, elemType

    for elem in elems
      unify ctx, elem.tea,
        if isSplat elem
          form.tea
        else
          elemType

    cond = "seq_size(#{sequence}) #{if hasSplat then '>=' else '=='} #{requiredElems}"
    combinePatterns join [(precs: [(cond_ cond)])], compiledArgs
  else
    # The below worked, but not for patterns
    # Compile as calls for type checking
    # {a b c} to (& a (& b (& c)))
    # expressionCompile ctx, arrayToConses elems
    # result =>         "[#{listOf map _compiled, elems}]"

    elemType = ctx.freshTypeVariable star
    compiledElems = termsCompile ctx, elems
    for elem in elems
      unify ctx, elemType, elem.tea

    form.label = 'operator'
    form.tea = new TypeApp arrayType, elemType
    assignCompile ctx, form, "[#{listOf compiledElems}]"

isSplat = (expression) ->
  (isAtom expression) and (_token expression)[...2] is '..'

splatToName = (splat) ->
  replicate splat,
    (token_ (_token splat)[2...])

# arrayToConses = (elems) ->
#   if elems.length is 0
#     token_ 'empty-array'
#   else
#     [x, xs...] = elems
#     (call_ (token_ 'cons-array'), [x, (arrayToConses xs)])

assignCompile = (ctx, expression, translatedExpression) ->
  if not translatedExpression
    log expression
  if to = ctx._nameExpression()

    ctx.setGroupTranslation()
    {precs, assigns} = patternCompile ctx, to, expression, translatedExpression

    log "ASSIGN #{ctx._name()}", ctx.shouldDefer()
    if ctx.shouldDefer()
      ctx.addDeferred ctx.shouldDefer(), to, expression
      return 'deferred'

    if assigns.length is 0
      throw new "No assign in assignCompile"
    listOfLines join ctx.translationCache(), map compileAssign, assigns
  else
    translatedExpression

patternCompile = (ctx, pattern, matched, translatedMatched) ->

  ctx.setAssignTo translatedMatched
  # caching can occur while compiling the pattern
  # precs are {cond}s and {cache}s, sorted in order they need to be executed
  {precs, assigns} = expressionCompile ctx, pattern
  ctx.resetAssignTo()

  definedNames = ctx.definedNames()

  # Make sure deferred names are added to scope so they are compiled within functions
  if ctx.shouldDefer()
    for {name} in definedNames
      if not ctx.arity name
        ctx.addToScope name
    log "exiting pattern early", pattern, "for", ctx.shouldDefer()
    return {}

  # Check the types
  if pattern.tea
    unify ctx, matched.tea, pattern.tea

  # And substitute to get correct types TODO: make sure this works for match as well

  # A big map of free typevar names to lists of value names
  tempVars = concatConcatMaps (for {name, type} in ctx.deferredNames()
    # ctx.addToDeferred {name, type}
    # or use the substitution instead of type below:
    mapMap (-> {name, type}), findFree substitute ctx.substitution, type)

  log "pattern compiel", definedNames
  for {name, type} in definedNames
    currentType = substitute ctx.substitution, type
    deps = concat mapToArray intersectRight (findFree currentType), tempVars
    if deps.length > 0
      depsNames =  deps
      log "adding top level lhs to deferred #{name}"
      ctx.addToDeferred {name, type, deps: (map (({name}) -> name), deps)}
      for dep in deps
        ctx.addToDeferred {name: dep.name, type: dep.type, deps: [name]}
      ctx.addType name, new TempType type
    else
      log "adding type for lhs #{name}", currentType
      ctx.addArity name, [] unless ctx.arity name
      ctx.addType name, if ctx._nameExpression()
        quantifyAll currentType
      else
        toForAll currentType
  # here I will create type schemes for all definitions
  # The problem is I don't know which are impricise, because the names are done inside the
  # pattern. I can use the context to know which types where added in the current assignment.

  # TODO: malformed "LHS\'s type doesn\'t match the RHS in assignment", pattern

  precs: precs ? []
  assigns: assigns ? []

topLevel = (ctx, form) ->
  definitionList ctx, pairs _terms form

definitionList = (ctx, pairs) ->
  compiledPairs = filter _is, (for [lhs, rhs] in pairs
    definitionPairCompile ctx, lhs, rhs)

  compiledPairs = join compiledPairs, compileDeferred ctx
  resolveDeferredTypes ctx

  log "yay"

  listOfLines compiledPairs

resolveDeferredTypes = (ctx) ->
  if _notEmpty ctx.deferredBindings()
    # TODO: proper dependency analysis to get the smallest circular deps
    #       now we are just compiling as if they were all mutually recursive
    names = concatConcatMaps map (({name, type}) -> newMapWith name, type), ctx.deferredBindings()
    for name, types of values names
      canonicalType = ctx.freshTypeVariable star
      for type in types
        log type.constructor
        # log "unifying", canonicalType, type
        unify ctx, canonicalType, type
        # log "done unifying one"
    # log "done unifying"
    for name of values names
      # log "done"
      ctx.addType name, substitute ctx.substitution, canonicalType
      # log "added"

compileDeferred = (ctx) ->
  compiledPairs = []
  if _notEmpty ctx.deferred()
    deferredCount = 0
    while (_notEmpty ctx.deferred()) and deferredCount < ctx.deferred().length
      prevSize = ctx.deferred().length
      [dependencyName, lhs, rhs] = deferred = ctx.deferred().shift()
      if ctx.declaration dependencyName
        compiledPairs.push definitionPairCompile ctx, lhs, rhs
      else
        # If can't compile, defer further
        ctx.addDeferred deferred...
      if prevSize is ctx.deferred().length
        deferredCount++

  # defer completely current scope
  if _notEmpty ctx.deferred()
    for [dependencyName, lhs, rhs] in ctx.deferred()
      ctx.setDeferParent dependencyName

  compiledPairs

definitionPairCompile = (ctx, lhs, rhs) ->
  # log "COMPILING", lhs, rhs
  ctx.setName lhs
  # log "deferrement before assign !!!", ctx.shouldDefer()
  compiled = expressionCompile ctx, rhs
  ctx.resetName()
  if ctx.shouldDefer()
    # log "RESETTING DEFER"
    ctx.setDefer false
    undefined
  else
    compiled

builtInMacros =

  fn: (ctx, call) ->
    # For now expect the curried constructor call
    args = _arguments call
    [paramList, defs...] = args
    if not paramList or not isTuple paramList
      malformed call, 'Missing paramater list'
      params = []
    else
      params = _terms paramList
      map (syntaxNewName 'Parameter name expected'), params
    defs ?= []
    if defs.length is 0
      malformed call, 'Missing function result'
    else
      [docs, defs] = partition isComment, defs
      if defs.length % 2 == 0
        [type, body, wheres...] = defs
      else
        [body, wheres...] = defs
      paramNames = map _token, params
      # pattern
      paramTypes = map (-> toForAll ctx.freshTypeVariable star), params
      ctx.newLateScope()
      # log "adding types", (map _token, params), paramTypes
      ctx.addTypes (map _token, params), paramTypes

      log "compiling wheres", pairs wheres
      compiledWheres = definitionList ctx, pairs wheres

      # log "types added"
      log "compiling", body
      compiledBody = termCompile ctx, body
      # log "compiled", body.tea
      ctx.closeScope()

      # Syntax - used params in function body
      # !! TODO: possibly add to nameCompile instead, or defer to IDE
      isUsedParam = (expression) ->
        (isName expression) and (_token expression) in paramNames
      labelUsedParams = (expression) ->
        map (syntaxNameAs '', 'param'), filterAst isUsedParam, expression
      map labelUsedParams, join [body], wheres

      # Arity - before deferring instead go to assignCompile, because this makes the naming of functions special
      if ctx._name()
        log "adding arity for #{ctx._name()}", paramNames
        ctx.addArity ctx._name(), paramNames

      assignCompile ctx, call,
        if ctx.shouldDefer()
          'deferred'
        else
          # Typing
          if not body.tea
            log body
            throw "Body not typed"
          call.tea = typeFn (map _type, paramTypes)..., body.tea

          """λ(function (#{listOf paramNames}) {
            #{compiledWheres}
            return #{compiledBody};
          }"""
  # data
  #   listing or
  #     pair
  #       constructor-name
  #       record
  #         type
  #     constant-name
  data: (ctx, call) ->
    defs = pairsLeft isAtom, _arguments call
    # Syntax
    syntaxNewName 'Name required to declare new algebraic data', ctx._nameExpression()
    [names, typeArgLists] = unzip defs
    map (syntaxNewName 'Type constructor name required'), names
    for typeArgs in typeArgLists
      if isRecord typeArgs
        for type in _snd unzip _labeled _terms typeArgs
          syntaxType type
      else
        typeArgs.label = 'malformed'
    # Types
    for [constr, params] in defs
      constrType = desiplifyType if params
        join (_labeled _terms params).map(_snd).map(_token), [ctx._name()]
      else
        ctx._name()
      # TODO support polymorphic data
      log "Adding constructor #{constr.token}"
      ctx.addType constr.token, toForAll constrType
      constr.tea = constrType
    # TODO: support polymorphic data
    # We don't add binding to types, but maybe need to store elsewhere
    # ctx.addType ctx._name(), typeConstant ctx._name()
    # Arity
    for [constr, params] in defs when params
      ctx.addArity constr.token,
        (_labeled _terms params).map(_fst).map(_labelName)
    # Translate
    listOfLines (for [constr, params] in defs
      identifier = validIdentifier constr.token
      paramNames = (_labeled _terms params or []).map(_fst).map(_labelName)
        .map(validIdentifier)
      paramList = paramNames.join(', ')
      paramAssigns = blockOfLines paramNames.map (name) ->
        "  this.#{name} = name;"
      constrFn = """function #{identifier}(#{paramList}) {#{paramAssigns}};"""
      constrValue = if params
        """
        #{identifier}.value = λ(function(#{paramList}){
          return new #{identifier}(#{paramList});
        });"""
      else
        "#{identifier}.value = new #{identifier}();"
      listOfLines [constrFn, constrValue])

  record: (ctx, call) ->
    args = _arguments call
    for [name, type] in _labeled args
      if not name
        malformed type, 'Label is required'
      if not type
        malformed name, 'Missing type'
      if name and type
        syntaxType type
    if args.length is 0
      malformed call, 'Missing arguments'
    # TS: (data #{ctx._name()} [#{_arguments form}])
    replicate call,
      (call_ (token_ 'data'), [(token_ ctx._name()), (tuple_ args)])

  # match
  #   subject
  #   listing of
  #     pair
  #       pattern
  #       result
  match: (ctx, call) ->
    [subject, cases...] = _arguments call
    varNames = []
    if not subject
      return malformed 'match `subject` missing', call
    if cases.length % 2 != 0
      return malformed 'match missing result for last pattern', call
    subjectCompiled = termCompile ctx, subject

    # To make sure all results have the same type
    call.tea = resultType = ctx.freshTypeVariable star

    ctx.setGroupTranslation()
    compiledCases = conditional (for [pattern, result] in pairs cases

      ctx.newScope() # for variables defined inside pattern
      ctx.setName()

      {precs, assigns} = patternCompile ctx, pattern, subject, subjectCompiled

      ctx.resetName()
      # Compile the result, given current scope
      compiledResult = termCompile ctx, result #compileImpl result, furtherHoistable
      ctx.closeScope()

      if ctx.shouldDefer()
        continue

      log "unifying in match", resultType, result.tea
      unify ctx, resultType, result.tea
      varNames.push (findDeclarables precs)...

      matchBranchTranslate precs, assigns, compiledResult
    ), "throw new Error('match failed to match');" #TODO: what subject?
    assignCompile ctx, call, iife listOfLines concat (filter _is, [
      ctx.translationCache()
      varList varNames
      compiledCases])

# Creates the condition and body of a branch inside match macro
matchBranchTranslate = (precs, assigns, compiledResult) ->
  {conds, preassigns} = constructCond precs
  [hoistedWheres, furtherHoistable] = hoistWheres [], assigns #hoistWheres hoistableWheres, assigns

  [conds, indentLines '  ',
    concat [
      (map compileAssign, (join preassigns, assigns))
      hoistedWheres.map(compileDef)
      ["return #{compiledResult};"]]]

iife = (body) ->
  """(function(){
      #{body}}())"""

varList = (varNames) ->
  if varNames.length > 0 then "var #{listOf varNames};" else null

conditional = (condCasePairs, elseCase) ->
  if condCasePairs.length is 1
    [[cond, branch]] = condCasePairs
    if cond is 'true'
      return branch
  ((for [cond, branch], i in condCasePairs
    control = if i is 0 then 'if' else ' else if'
    """#{control} (#{cond}) {
        #{branch}
      }""").join '') + """ else {
        #{elseCase}
      }"""

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

malformed = (expression, message) ->
  # TODO support multiple malformations
  expression.malformed = message
  message

isWellformed = (expression) ->
  if expression.malformed
    no
  else
    if isForm expression
      for term in _terms expression
        unless isWellformed term
          return no
    yes

atomCompile = (ctx, atom) ->
  {token} = atom
  # Syntax
  atom.label = regexMapping token,
    ['numerical', /^~?\d+/]
    ['const', /^[A-Z][^\s]*$/]
    ['string', /^["]/]
    ['char', /^[']/]
    ['regex', /^\/[^ \/]/]
  {label} = atom
  # Typing and Translation
  {type, translation, pattern} =
    switch label
      when 'numerical'
        numericalCompile ctx, token
      when 'regex'
        regexCompile ctx, token
      when 'char'
        type: typeConstant 'Char'
        translation: token
        pattern: literalPattern ctx, token
      when 'string'
        type: typeConstant 'String'
        translation: token
        pattern: literalPattern ctx, token
      else
        nameCompile ctx, atom, token
  atom.tea = type if type
  if ctx.isOperator()
    # TODO: maybe don't use label here, it's getting confusing what is its purpose
    atom.label = 'operator'
  if ctx.assignTo()
    pattern
  else
    assignCompile ctx, atom, translation

nameCompile = (ctx, atom, token) ->
  contextType = ctx.type token
  if exp = ctx.assignTo()
    if atom.label is 'const'
      if contextType
        type: freshInstance ctx, ctx.type token
        pattern: constPattern ctx, token
      else
        log "deferring in pattern for #{token}"
        ctx.setDefer token
        pattern: []
    else
      atom.label = 'name'
      type = ctx.freshTypeVariable star
      ctx.addToDefinedNames {name: token, type: type}
      type: type
      pattern:
        assigns:
          [[(validIdentifier token), exp]]
  else
    # Name typed, use a fresh instance
    if contextType and contextType not instanceof TempType
      {
        type: freshInstance ctx, contextType
        translation: nameTranslate ctx, atom, token
      }
    # Inside function only defer compilation if we don't know arity
    else if ctx.isInLateScope() and (ctx.declaration token) or contextType instanceof TempType
      # Typing deferred, use an impricise type var
      type = ctx.freshTypeVariable star
      ctx.addToDeferredNames {name: token, type: type}
      {
        type: type
        translation: nameTranslate ctx, atom, token
      }
    else
      log "deferring for #{token}"
      ctx.setDefer token
      translation: 'deferred'

constPattern = (ctx, token) ->
  exp = ctx.assignTo()
  precs: [(cond_ switch token
      when 'True' then "#{exp}"
      when 'False' then "!#{exp}"
      else
        "#{exp} instanceof #{token}")]

nameTranslate = (ctx, atom, token) ->
  if atom.label is 'const'
    switch token
      when 'True' then 'true'
      when 'False' then 'false'
      else
        "#{validIdentifier token}.value"
  else
    validIdentifier token

numericalCompile = (ctx, token) ->
  translation = if token[0] is '~' then "(-#{token})" else token
  type: typeConstant 'Num'
  translation: translation
  pattern: literalPattern ctx, translation

regexCompile = (ctx, token) ->
  type: typeConstant 'Regex'
  translation: token
  pattern:
    if ctx.assignTo()
      precs: [cond_ "#{ctx.assignTo()}.string" + " === #{token}.string"]

literalPattern = (ctx, translation) ->
  if ctx.assignTo()
    precs: [cond_ "#{ctx.assignTo()}" + " === #{translation}"]

regexMapping = (token, regexes...) ->
  for [label, regex] in regexes
    if regex.test token
      return label

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
    syntaxNameAs 'Constructor name required', 'typecons', (_operator expression)
    map syntaxType, (_arguments expression)

syntaxNewName = (message, atom) ->
  curried = (atom) ->
    syntaxNameAs message, 'name', atom
  if atom then curried atom else curried

syntaxNameAs = (message, label, atom) ->
  curried = (atom) ->
    if isName atom
      atom.label = label
    else
      malformed atom, message
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

isComment = (expression) ->
  (isCall expression) and ('#' is _token _operator expression)

isCall = (expression) ->
  (isForm expression) and (isEmptyForm expression) and
    expression[0].label is 'paren'

isRecord = (expression) ->
  if isTuple expression
    [labels, values] = unzip pairs _terms expression
    labels.length is values.length and (allMap isLabel, labels)

isSeq = (expression) ->
  (isForm expression) and expression[0].label is 'brace'

isTuple = (expression) ->
  (isForm expression) and expression[0].label is 'bracket'

isEmptyForm = (form) ->
  (_terms form).length > 0

isForm = (expression) ->
  Array.isArray expression

isLabel = (atom) ->
  /:$/.test atom.token

isCapital = (atom) ->
  /[A-Z]/.test atom.token

isName = (expression) ->
  throw "Nothing passed to isName" unless expression
  (isAtom expression) and /[^~"'\/].*/.test expression.token

isAtom = (expression) ->
  not (Array.isArray expression)

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

unzip = (pairs) ->
  [
    filter _is, map _fst, pairs
    filter _is, map _snd, pairs
  ]

replicate = (expression, newForm) ->
  newForm

retrieve = (expression, newForm) ->
  expression.tea = newForm.tea
  expression.malformed = newForm.malformed

_operator = (call) ->
  (_terms call)[0]

_arguments = (call) ->
  (_terms call)[1..]

_terms = (form) ->
  form[1...-1].filter ({label}) -> label isnt 'whitespace'

_snd = ([a, b]) -> b

_fst = ([a, b]) -> a

_labelName = (atom) -> (_token atom)[0...-1]

_token = ({token}) -> token

filterAst = (test, expression) ->
  join (filter test, [expression]),
    if isForm expression
      concat (filterAst test, term for term in _terms expression)
    else
      []

join = (seq1, seq2) ->
  seq1.concat seq2

concatMap = (fn, list) ->
  concat map fn, list

concat = (lists) ->
  [].concat lists...

id = (x) -> x

map = (fn, list) ->
  if list then list.map fn else (list) -> map fn, list

allMap = (fn, list) ->
  all (map fn, list)

all = (list) ->
  (filter _is, list).length is list.length

filter = (fn, list) ->
  list.filter fn

partition = (fn, list) ->
  [(filter fn, list), (filter ((x) -> not (fn x)), list)]

_notEmpty = (x) -> x.length > 0

_is = (x) -> !!x

__ = (fna, fnb) ->
  (x) -> fna fnb x

theme =
  keyword: 'red'
  numerical: '#FEDF6B'
  const: '#FEDF6B'
  typename: '#FEDF6B'
  typecons: '#67B3DD'
  label: '#9C49B6'
  string: '#FEDF6B'
  paren: '#444'
  name: '#9EE062'
  recurse: '#67B3DD'
  param: '#FDA947'
  comment: 'grey'
  operator: '#67B3DD'
  normal: 'white'

colorize = (color, string) ->
  "<span style=\"color: #{color}\">#{string}</span>"

labelMapping = (word, rules...) ->
  for [label, cond] in rules when cond
    word.label = label
    return word
  word

isDelim = (token) ->
  /[\(\)\[\]\{\}]/.test token.token

# TODO: support classes and instances
# classDefinition = (node) ->
#   words = inside node
#   [keyword, paramList, defs...] = words
#   params = if Array.isArray(paramList) then paramList else undefined
#   defs ?= []
#   if defs.length > 0
#     [first] = defs
#     if Array.isArray first
#       context = first
#       defs = defs[1..]
#   wheres = whereList defs
#   {params, context, wheres}

# instanceDefinition = (node) ->
#   words = inside node
#   [keyword, klass, defs...] = words
#   wheres = whereList defs
#   {klass, wheres}

# labelClasses = (ast) ->
#   macro 'class', ast, (node, args) ->
#     node.type = 'class'
#     {params, context, wheres} = classDefinition node
#     labelContext context
#     labelWhere wheres
#     labelParams node, params if params?
#     node

# labelContext = (node) ->
#   for parent in inside node
#     parent.label = 'operator'

# labelInstances = (ast) ->
#   macro 'instance', ast, (node, args) ->
#     node.type = 'instance'
#     {klass, wheres} = instanceDefinition node
#     klass.label = 'operator'
#     labelWhere wheres
#     node

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
# labelComments = (ast) ->
#   typedMacro 'comment', ast, (node, words) ->
#     for word in words
#       word.label = 'comment' unless word.label in ['param', 'recurse']
# node


# Syntax printing to HTML

toHtml = (highlighted) ->
  crawl highlighted, (word, token, parent) ->
    (word.ws or '') + colorize(theme[labelOf word, parent], token)

labelOf = (word, parent) ->
  if (_isCollectionDelim word) and parent
    parent.label
  else
    word.label or 'normal'

collapse = (nodes) ->
  collapsed = ""
  for node in nodes
    crawl node, (node) ->
      collapsed += node
  collapsed

# TODO need?
# Correct offset by 1 in positions, when we wrap the source in an S-exp
shiftPos = (ast) ->
  crawl ast, (word) ->
    word.pos = word.pos - 1
    word

# TODO: need?
parentize = (highlighted) ->
  walkOnly highlighted, (node) ->
    for subNode in node
      subNode.parent = node
    node

# end of Syntax printing

# for including in other files
# TODO: support with arbitrary left patterns, prob via context
exportList = (source) ->
  wheres = whereList inside preCompileDefs source
  names = []
  for [pattern] in wheres
    if pattern.token and pattern.token isnt '_'
      names.push pattern.token
  names

# Valid identifiers

validIdentifier = (name) ->
  [firstChar] = name
  if firstChar is '-'
    throw new Error "Identifier expected, but got minus #{name}"
  else if firstChar is '/'
    throw new Error "Identifier expected, but found regex #{name}"
  else
    name
      .replace(/\+/g, 'plus_')
      .replace(/\-/g, '__')
      .replace(/\*/g, 'times_')
      .replace(/\//g, 'over_')
      # .replace(/\√/g, 'sqrt_')
      .replace(/\./g, 'dot_')
      .replace(/\&/g, 'and_')
      .replace(/\?/g, 'p_')
      .replace(/^const$/, 'const_')
      .replace(/^default$/, 'default_')
      .replace(/^with$/, 'with_')
      .replace(/^in$/, 'in_')


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
#           addToSet child.missing, node.token
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
#       names.push node.token
#   names


# Pattern matching in assignment (used in Match as well)

# Maps
# (pattern) ->
#   # expect lists from here on
#   if not Array.isArray pattern
#     throw new Error "pattern match expected pattern but saw token #{pattern.token}"
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
#           #{preassigns.concat(assigns).map(compileAssign).join '\n  '}
#           #{hoistedWheres.map(compileDef).join '\n  '}
#           return #{compileImpl result, furtherHoistable};
#         }"""
#       )
#     mainCache ?= []
#     mainCache = mainCache.map ({cache}) -> compileAssign cache
#     varDecls = if varNames.length > 0 then ["var #{varNames.join ', '};"] else []
#     content = mainCache.concat(varDecls, compiledCases.join '').join '\n'
#     """(function(){
#       #{content} else {throw new Error('match failed to match');}}())"""
#   'require': (from, list) ->
#     args = inside(list).map(compileName).map(toJsString).join ', '
#     "$listize(window.requireModule(#{toJsString from.token}, [#{args}]))"
#   'list': (items...) ->
#     "$listize(#{compileList items})"

# findDeclarables = (precs) ->
#   precs.filter((p) -> p.cache).map(({cache}) -> cache[0])

# hoistWheres = (hoistable, assigns) ->
#   defined = addAllToSet newSet(), (n for [n, _] in assigns)
#   hoistedNames = newSet()
#   hoisted = []
#   notHoisted = []
#   for where in hoistable
#     {missing, names, def, set} = where
#     stillMissingNames = addAllToSet newSet(),
#       (name for name in (setToArray missing) when not inSet defined, name)
#     stillMissingDeps = removeAllFromSet (cloneSet set), setToArray hoistedNames
#     if stillMissingNames.size == 0 and stillMissingDeps.size == 0
#       hoisted.push def
#       addAllToSet hoistedNames, names
#     else
#       notHoisted.push
#         def: def
#         names: names
#         missing: stillMissingNames
#         set: stillMissingDeps
#   [hoisted, notHoisted]

toJsString = (token) ->
  "'#{token}'"

compileAssign = ([to, from]) ->
  "var #{to} = #{from};"

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
      "(#{cache[0]} = #{cache[1]})"

  # Each case is a (possibly empty) list of caching followed by a condition
  pushCurrentCase = ->
    condParts = map translateCondPart, singleCase
    cases.push if condParts.length is 1
      condParts[0]
    else
      "(#{listOf condParts})"
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
  conds: cases.join " && "
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

binaryMathOpType = ['Num', 'Num', 'Num']
comparatorOpType = ['a', 'a', 'Bool']

builtInContext = (ctx) ->
  concatMaps (mapMap desiplifyTypeAndArity, newMapWith 'True', 'Bool',
    'False', 'Bool'
    '&', ['a', 'b', 'b'] # TODO: replace with actual type
    'show-list', ['a', 'b'] # TODO: replace with actual type
    'from-nullable', ['a', 'b'] # TODO: replace with actual type JS -> Maybe a

    # TODO match

    'if', ['Bool', 'a', 'a', 'a']
    # TODO JS interop

    'sqrt', ['Num', 'Num']
    'not', ['Bool', 'Bool']

    '^', binaryMathOpType

    '~', ['Num', 'Num']

    '+', binaryMathOpType
    '*', binaryMathOpType
    '=', comparatorOpType
    '!=', comparatorOpType
    'and', ['Bool', 'Bool', 'Bool']
    'or', ['Bool', 'Bool', 'Bool']

    '-', binaryMathOpType
    '/', binaryMathOpType
    'rem', binaryMathOpType
    '<', comparatorOpType
    '>', comparatorOpType
    '<=', comparatorOpType
    '>=', comparatorOpType),
    newMapWith 'empty-array', (type: (new TypeApp arrayType, (ctx.freshTypeVariable star))),
      'cons-array', (
        type:
          (typeFn (elemType = ctx.freshTypeVariable star),
            (new TypeApp arrayType, elemType),
            (new TypeApp arrayType, elemType))
        arity: ['what', 'onto'])

desiplifyTypeAndArity = (simple) ->
  type: quantifyAll desiplifyType simple
  arity: ("a#{i}" for _, i in simple[0...simple.length - 1])

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
  set.size += 1
  set.values[key] = value
  set

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

setToArray = (set) ->
  key for key of set.values

mapToArray = (map) ->
  val for key, val of map.values

cloneSet = (set) ->
  clone = newSet()
  addAllToSet clone, setToArray set

lookupInMap =
inSet = (set, name) ->
  set.values[name]

isSetEmpty = (set) ->
  set.size is 0

mapSet =
mapMap = (fn, set) ->
  initialized = newMap()
  for key, val of set.values
    addToMap initialized, key, fn val
  initialized

filterSet =
filterMap = (fn, set) ->
  initialized = newMap()
  for key, val of set.values when fn key
    addToMap initialized, key, val
  initialized

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
  for map in maps
    for k, v of map.values
      addToMap concated, k, v
  concated

concatConcatMaps = (maps) ->
  concated = newMap()
  for map in maps
    for k, v of map.values
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

values = (map) ->
  map.values

doIntersect = (setA, setB) ->
  (subtractSets setA, setB).size isnt setA.size

intersectRight = (mapA, mapB) ->
  intersection = newMap()
  for k, v of mapB.values when k of mapA.values
    addToMap intersection, k, v
  intersection

# end of Set

# Type inference and checker ala Mark Jones

unify = (ctx, t1, t2) ->
  throw "invalid args to unify" unless ctx instanceof Context and t1 and t2
  sub = ctx.substitution
  ctx.extendSubstitution findSubToMatch (substitute sub, t1), (substitute sub, t2)

findSubToMatch = (t1, t2) ->
  if t1 instanceof TypeVariable
    bindVariable t1, t2
  else if t2 instanceof TypeVariable
    bindVariable t2, t1
  else if t1 instanceof TypeConstr and t2 instanceof TypeConstr and
    t1.name is t2.name
      emptySubstitution()
  else if t1 instanceof TypeApp and t2 instanceof TypeApp
    s1 = findSubToMatch t1.op, t2.op
    s2 = findSubToMatch (substitute s1, t1.arg), (substitute s1, t2.arg)
    joinSubs s1, s2
  else
    newMapWith "could not unify", [(printType t1), (printType t2)]

bindVariable = (variable, type) ->
  if type instanceof TypeVariable and variable.name is type.name
    emptySubstitution()
  else if inSet (findFree type), variable.name
    newSetWith variable.name, "occurs check failed"
  else if not kindsEq (kind variable), (kind type)
    newSetWith variable.name, "kinds don't match for #{variable.name}"
  else
    newMapWith variable.name, type

joinSubs = (s1,s2) ->
  concatSets s1, mapMap ((type) -> substitute s1, type), s2

emptySubstitution = ->
  newMap()

# Unlike in Jones, we simply use substitue for both variables and quantifieds
# variables are strings, wheres quantifieds are ints
substitute = (substitution, type) ->
  if type instanceof TypeVariable and substitution.values
    (lookupInMap substitution, type.name) or type
  else if type instanceof QuantifiedVar
    substitution[type.var] or type
  else if type instanceof TypeApp
    new TypeApp (substitute substitution, type.op),
      (substitute substitution, type.arg)
  else if type instanceof ForAll
    new ForAll type.kinds, (substitute substitution, type.type)
  else
    type

findFree = (type) ->
  if type instanceof TypeVariable
    newMapWith type.name, type.kind
  else if type instanceof TypeApp
    concatMaps (findFree type.op), (findFree type.arg)
  else
    newMap()

findBound = (name, binding) ->
  (lookupInMap binding, name) or 'unbound name #{name}'

freshInstance = (ctx, type) ->
  throw "not a forall in freshInstance" unless type instanceof ForAll
  freshes = map ((kind) -> ctx.freshTypeVariable kind), type.kinds
  (substitute freshes, type).type

freshName = (nameIndex) ->
  suffix = if nameIndex > 25 then Math.floor nameIndex / 25 else ''
  String.fromCharCode 97 + nameIndex % 25

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

tupleType = (arity) ->
  new TypeConstr "[#{arity}]", kindFn arity

kindFn = (arity) ->
  if arity is 1
    new KindFn star, star
  else
    new KindFn star, kindFn arity - 1

typeFn = (from, to, args...) ->
  if args.length is 0
    new TypeApp (new TypeApp arrowType, from), to
  else
    typeFn from, (typeFn to, args...)

applyKindFn = (fn, arg, args...) ->
  if args.length is 0
    new TypeApp fn, arg
  else
    applyKindFn (applyKindFn fn, arg), args...

isConstructor = (type) ->
  type instanceof TypeApp

kind = (type) ->
  if type.kind
    type.kind
  else if type instanceof TypeApp
    (kind type.op).to
  else
    throw "Invalid type in kind"

kindsEq = (k1, k2) ->
  k1 is k2 or
    (kindsEq k1.from, k2.from) and
    (kindsEq k1.to, k2.to)

class KindFn
  constructor: (@from, @to) ->

class TypeVariable
  constructor: (@name, @kind) ->
class TypeConstr
  constructor: (@name, @kind) ->
class TypeApp
  constructor: (@op, @arg) ->
class QuantifiedVar
  constructor: (@var) ->
class ForAll
  constructor: (@kinds, @type) ->
class TempType
  constructor: (@type) ->

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
arrowType = new TypeConstr '->', kindFn 2
arrayType = new TypeConstr 'Array', kindFn 1


printType = (type) ->
  (flattenType type) or
    if type instanceof TypeVariable
      type.name
    else if type instanceof QuantifiedVar
      type.var
    else if type instanceof TypeConstr
      type.name
    else if type instanceof TypeApp
      types = collectArgs type
      if types.length is 1
        types[0]
      else
        "(Fn #{types.join ' '})"
    else if type instanceof ForAll
      "(∀ #{printType type.type})"
    else if type instanceof TempType
      "(. #{printType type.type})"
    else if Array.isArray type
      "\"#{listOf type}\""
    else if type is undefined
      "undefined"

collectArgs = (type) ->
  if type.op?.op?.name is '->'
    join [printType type.op.arg], collectArgs type.arg
  # else if match = type.op?.op?.name?.match /^\[(\d)\]$/
  #   arity = parseInt match[1]
  #   for i in [0...arity]

  else if type.op
    ["(#{printType type.op} #{printType type.arg})"]
  else
    [printType type]

flattenType = (type) ->
  if type instanceof TypeConstr and match = type.name.match /^\[(\d)\]$/
    {
      arity: parseInt match[1]
      types: []
    }
  else if type instanceof TypeApp
    flattenedOp = flattenType type.op
    if flattenedOp?.arity
      if flattenedOp.arity is flattenedOp.types.length + 1
        "[#{(join flattenedOp.types, [printType type.arg]).join ' '}]"
      else
        flattenedOp.types.push printType type.arg
        flattenedOp
    else
      undefined
  else
    undefined

library = """
var $listize = function (list) {
  if (list.length == 0) {
   return {length: 0};
  }
  return and_(list[0], $listize(list.slice(1)));
};

var and_ = function (x, xs) {
  if (typeof xs === "undefined" || xs === null) {
    throw new Error('Second argument to & must be a sequence');
  }
  if (typeof xs == 'string' || xs instanceof String) {
    if (xs == '' && !(typeof x == 'string' || x instanceof String)) {
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

var $sequenceSize = function (xs) {
  if (typeof xs === "undefined" || xs === null) {
    throw new Error('Pattern matching on size of undefined');
  }
  if (xs.length != null) {
    return xs.length;
  }
  return 1 + $sequenceSize(xs.tail);
};

var $sequenceAt = function (i, xs) {
  if (typeof xs === "undefined" || xs === null) {
    throw new Error('Pattern matching required sequence got undefined');
  }
  if (xs.length != null) {
    if (i >= xs.length) {
      throw new Error('Pattern matching required a list of size at least ' + (i + 1));
    }
    return xs[i];
  }
  if (i == 0) {
    return xs.head;
  }
  return $sequenceAt(i - 1, xs.tail);
};

var $sequenceSplat = function (from, leave, xs) {
  if (xs.slice) {
    return xs.slice(from, xs.length - leave);
  }
  return $listSlice(from, $sequenceSize(xs) - leave - from, xs);
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
  if (n == 0) {
    return $listize([]);
  }
  if (from == 0) {
    return and_(xs.head, $listSlice(from, n - 1, xs.tail));
  }
  return $listSlice(from - 1, n, xs.tail);
};

var show__list = function (x) {
  var t = [];
  while (x.length != 0) {
    t.push(x.head);
    x = x.tail;
  }
  return t;
};

var λ = function (n, f) {
  f._ = n;
  return f;
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
  """var _#{i} = function (f, #{first i}) {
    if (f._ === #{i} || f.length === #{i}) {
      return f(#{first i});
    } else if (f._ > #{i} || f.length > #{i}) {
      return function (#{varNames[i]}) {
        return _#{i + 1}(f, #{first i + 1});
      };
    } else {
      return _1(#{if i is 1 then "f()" else "_#{i - 1}(f, #{first i - 1})"}, #{varNames[i - 1]});
    }
  };""").join('\n\n') +
"""
;
"""



exports.compile = (source) ->
  library + compileDefinitions source

exports.compileModule = (source) ->
  """
  #{library}
  var exports = {};
  #{compileDefinitionsInModule source}
  exports"""

exports.compileExp = compiledBottom

exports.tokenize = tokenizeAndTypeInferDefinitions

exports.tokenizeExp = tokenizedExp

exports.syntaxedExpHtml = syntaxedExp

exports.exportList = exportList

exports.library = library

exports.walk = walk