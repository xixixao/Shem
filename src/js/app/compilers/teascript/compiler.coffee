tokenize = (input, initPos = 0) ->
  currentPos = initPos
  while input.length > 0
    match = input.match ///
      ^ # must be at the start
      (
        \x20+ # spaces
      | \n # newline
      | [#{controls}] # delims
      | /([^\\x20]|\\/)([^/]|\\/)*?/ # regex
      | "[^"]*?" # strings
      | \\[^\x20] # char
      | [^#{controls}"'\s]+ # normal tokens
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

noWS = (tokens) ->
  tokens.filter (token) -> token.label isnt 'whitespace'

astize = (tokens) ->
  tree = []
  current = []
  stack = [[]]
  for token in tokens
    if token.symbol in leftDelims
      form = [token]
      form.start = token.start
      stack.push form
    else if token.symbol in rightDelims
      closed = stack.pop()
      if not stack[stack.length - 1]
        throw new Error "Missing opening delimeter matching #{token.symbol}"
      if token.symbol isnt delims[closed[0].symbol]
        throw new Error "Wrong closing delimiter #{token.symbol} for opening delimiter #{closed[0].symbol}"
      closed.push token
      closed.end = token.end
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
delims = '(': ')', '[': ']', '{': '}'

constantLabeling = (atom) ->
  {symbol} = atom
  labelMapping atom,
    ['numerical', /^-?\d+/.test symbol]
    ['label', isLabel atom]
    ['string', /^"/.test symbol]
    ['char', /^\\/.test symbol]
    ['regex', /^\/[^ \/]/.test symbol]
    ['const', /^[A-Z][^\s]*$/.test symbol] # TODO: instead label based on context
    ['paren', symbol in ['(', ')']]
    ['bracket', symbol in ['[', ']']]
    ['brace', symbol in ['{', '}']]
    ['whitespace', /^\s+$/.test symbol]

isCollectionDelim = (atom) ->
  atom.label in ['bracket', 'brace']

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
  types: values mapMap (__ highlightType, _type), subtractMaps ctx._scope(), builtInContext()
  translation: '\n' + compiled

mapCompile = (fn, string) ->
  fn (new Context), astize tokenize string

mapTyping = (fn, string) ->
  ast = astize tokenize string
  fn (ctx = new Context), ast
  expressions = []
  visitExpressions ast, (expression) ->
    expressions.push "#{collapse toHtml expression} :: #{highlightType expression.tea}" if expression.tea
  types: values mapMap (__ highlightType, _type), subtractMaps ctx._scope(), builtInContext()
  subs: values mapMap highlightType, ctx.substitution
  ast: expressions
  deferred: ctx.deferredBindings()

mapTypingBare = (fn, string) ->
  ast = astize tokenize string
  fn (ctx = new Context), ast
  expressions = []
  visitExpressions ast, (expression) ->
    expressions.push [(collapse toHtml expression), expression.tea] if expression.tea
  types: values mapMap _type, subtractMaps ctx._scope(), builtInContext()
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
    @definitions = []
    @_isOperator = []
    @variableIndex = 0
    @typeVariabeIndex = 0
    @substitution = newMap()
    @statement = []
    @cacheScopes = [[]]
    @_assignTos = []
    topScope = @_augmentScope builtInContext()
    topScope.topLevel = yes
    @scopes = [topScope]
    @classParams = newMap()

  macros: ->
    @_macros

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
    (definition = @_currentDefinition()) and definition.inside is 0

  isAtSimpleDefinition: ->
    @isAtDefinition() and @definitionName()

  isAtDeferrableDefinition: ->
    @isAtDefinition() and @_currentDefinition().deferrable

  # isInsideDefinition: ->
  #   (definition = @_currentDefinition()) and definition.inside isnt 0

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
      [compileVariableAssignment cache]
    else
      []

  _scope: ->
    @scopes[@scopes.length - 1]

  _parentScope: ->
    @scopes[@scopes.length - 2]

  newScope: ->
    @scopes.push @_augmentScope newMap()

  _augmentScope: (scope) ->
    scope.deferred = []
    scope.deferredBindings = []
    scope.boundTypeVariables = newSet()
    scope.classes = newMap()
    scope

  newLateScope: ->
    @newScope()
    @_deferrableDefinition()?.late = yes

  closeScope: ->
    @scopes.pop()

  isInsideLateScope: ->
    @_deferrableDefinition()?.late

  isInTopScope: ->
    @_scope().topLevel

  bindTypeVariables: (vars) ->
    addAllToSet @_scope().boundTypeVariables, vars

  allBoundTypeVariables: ->
    concatSets (for scope in @scopes
      scope.boundTypeVariables)...

  isClassDefined: (name) ->
    !!@classNamed name

  addClass: (name, classConstraint, superClasses, declarations) ->
    addToMap @_scope().classes, name,
      supers: superClasses
      constraint: classConstraint
      instances: []
      declarations: declarations

  classNamed: (name) ->
    for scope in (reverse @scopes)
      if classDeclaration = lookupInMap scope.classes, name
        return classDeclaration

  addInstance: (name, type) ->
    (@classNamed type.type.className).instances.push {name, type}

  isMethod: (name, type) ->
    any (for {className} in type.constraints
      lookupInMap (@classNamed className).declarations, name)

  isDeclared: (name) ->
    !!(@_declaration name)

  isTyped: (name) ->
    !!(@_declaration name).type

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
      if declaration.type
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
      addToMap @_scope(), name, declaration
      true

  declareTypes: (names, types) ->
    for name, i in names
      @declare name, type: types[i]

  type: (name) ->
    (@_declaration name)?.type

  arity: (name) ->
    (@_declaration name)?.arity

  freshTypeVariable: (kind) ->
    if not kind
      throw new Error "Provide kind in freshTypeVariable"
    new TypeVariable (freshName @typeVariabeIndex++), kind

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

  classParamNameFor: (typeVarName) ->
    lookupInMap @classParams, typeVarName

expressionCompile = (ctx, expression) ->
  throw new Error "invalid expressionCompile args" unless ctx instanceof Context and expression
  compileFn =
    if isAtom expression
      atomCompile
    else if isTuple expression
      tupleCompile
    else if isSeq expression
      seqCompile
    else if isCall expression
      callCompile
  if not compileFn
    malformed expression, 'not a valid expression'
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
    (if operatorName of ctx.macros()
      macroCompile
    else if (ctx.isDeclared operatorName) and not ctx.arity operatorName
      callUnknownCompile
    else
      callKnownCompile) ctx, call
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
  expanded = ctx.macros()[op.symbol] ctx, call
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

callKnownCompile = (ctx, call) ->
  operator = _operator call
  args = _labeled _arguments call
  labeledArgs = labeledToMap args

  if tagFreeLabels args
    return malformed call, 'labels without values inside call'

  paramNames = ctx.arity operator.symbol
  if not paramNames
    # log "deferring in known call #{operator.symbol}"
    ctx.doDefer operator, operator.symbol
    return deferredExpression()
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
        # log "currying known call"
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
  assignCompile ctx, call, (irCall call.tea, compiledOperator, compiledArgs)

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
  compiledOperator = atomCompile ctx, _operator call
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
        ctx.resetAssignTo()
        elemCompiled
    else
      termsCompile ctx, elems
  # TODO: could support partial tuple application via bare labels
  #   map [0: "hello" 1:] {"world", "le mond", "svete"}
  # TODO: should we support bare records?
  #   [a: 2 b: 3]
  form.tea = tupleOfTypes (tea for {tea} in elems)

  if ctx.assignTo()
    combinePatterns compiledElems
  else
    form.label = 'operator'
    # "[#{listOf compiledElems}]"
    assignCompile ctx, form, (jsArray compiledElems)

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
      return malformed form, 'Matching with splat requires at least one element name'

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
    form.tea = new Constrained (concatMap _constraints, elems),
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

    elemType = ctx.freshTypeVariable star
    compiledElems = termsCompile ctx, elems
    for elem in elems
      unify ctx, elemType, elem.tea.type

    form.label = 'operator'
    form.tea = new Constrained (concatMap _constraints, (tea for {tea} in elems)),
      new TypeApp arrayType, elemType
    assignCompile ctx, form, (jsArray compiledElems)

isSplat = (expression) ->
  (isAtom expression) and (_symbol expression)[...2] is '..'

splatToName = (splat) ->
  replicate splat,
    (token_ (_symbol splat)[2...])

# arrayToConses = (elems) ->
#   if elems.length is 0
#     token_ 'empty-array'
#   else
#     [x, xs...] = elems
#     (call_ (token_ 'cons-array'), [x, (arrayToConses xs)])

typeConstrainedCompile = (call) ->
  [type, constraints...] = _arguments call
  new Constrained (typeConstraintsCompile constraints), typeCompile type

typeCompile = (expression) ->
  throw new Error "invalid typeCompile args" unless expression
  (if isAtom expression
    typeConstantCompile
  else if isTuple expression
    typeTupleCompile
  else if isCall expression
    typeConstructorCompile
  else
    malformed expression, 'not a valid type'
  )? expression

typesCompile = (expressions) ->
  map typeCompile, expressions

typeConstructorCompile = (call) ->
  op = _operator call
  args = _arguments call

  if isAtom op
    op.label = 'operator'
    name = op.symbol
    compiledArgs = typesCompile args
    if name is 'Fn'
      typeFn compiledArgs...
    else
      arity = args.length
      applyKindFn (atomicType name, kindFn arity), compiledArgs...
  else
    malformed op, 'Should use a type constructor here'

typeConstraintCompile = (expression) ->
  op = _operator expression
  args = _arguments expression
  if isCall expression
    if isAtom op
      op.label = 'operator'
      new ClassContraint op.symbol, typeCompile args[0] # TODO: support multiparameter type classes
    else
      malformed expression, 'Class name required in a constraint'
  else
    malformed expression, 'Class constraint expected'

typeConstraintsCompile = (expressions) ->
  filter ((t) -> t instanceof ClassContraint),
    (map typeConstraintCompile, expressions)

typeTupleCompile = (form) ->
  form.label = 'operator'
  elemTypes = _terms form
  applyKindFn (tupleType elemTypes.length), (typesCompile elemTypes)...

typeConstantCompile = (atom) ->
  atom.label = 'typename'
  atomicType atom.symbol, star

# Inside definition, we call assignCompile with its RHS
#   whether to call it and with what expression is left to the RHS expression
#   essentially assignable macros should call it
# This then compiles the LHS
# Possibly defers if RHS or LHS had to defer
# We then unify LHS with RHS, which will populate context substitution
#   with the right subs for type vars on the left
# For each defined name in the LHS, we declare it
assignCompile = (ctx, expression, translatedExpression) ->
  # if not translatedExpression # TODO: throw here?
  if ctx.isAtDefinition()
    to = ctx.definitionPattern()

    ctx.setAssignTo (irDefinition expression.tea, translatedExpression)
    {precs, assigns} = patternCompile ctx, to, expression
    translationCache = ctx.resetAssignTo()

    #log "ASSIGN #{ctx.definitionName()}", ctx.shouldDefer()
    if ctx.shouldDefer()
      ctx.addDeferredDefinition ctx.deferReason().concat [to, expression]
      return deferredExpression()

    if assigns.length is 0
      return malformed to, 'Not an assignable pattern'
    join translationCache, map compileVariableAssignment, assigns
  else
    translatedExpression

patternCompile = (ctx, pattern, matched) ->

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
    # log pattern, matched, matched.tea, pattern.tea
    unify ctx, matched.tea.type, pattern.tea.type

  # log "pattern compiel", definedNames, pattern
  for {name, type} in definedNames
    currentType = substitute ctx.substitution, type
    deps = ctx.deferredNames()
    if deps.length > 0
      # log "adding top level lhs to deferred #{name}"
      ctx.addToDeferred {name, type, deps: (map (({name}) -> name), deps)}
      for dep in deps
        ctx.addToDeferred {name: dep.name, type: dep.type, deps: [name]}
      ctx.declare name, type: new TempType type
    else
      # TODO: this is because functions might declare arity before being declared
      if not ctx.isCurrentlyDeclared name
        ctx.declare name
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
        ctx.assignType name,
          if ctx.isAtDeferrableDefinition()
            quantifyAll (addConstraints currentType, retainedConstraints)
          else
            toForAll currentType
  # here I will create type schemes for all definitions
  # The problem is I don't know which are impricise, because the names are done inside the
  # pattern. I can use the context to know which types where added in the current assignment.

  # TODO: malformed "LHS\'s type doesn\'t match the RHS in assignment", pattern

  precs: precs ? []
  assigns: assigns ? []

topLevelExpression = (ctx, expression) ->
  compiled = expressionCompile ctx, expression
  compiled

topLevel = (ctx, form) ->
  definitionList ctx, pairs _terms form

definitionList = (ctx, pairs) ->
  compiledPairs = (for [lhs, rhs] in pairs
    if rhs
      definitionPairCompile ctx, lhs, rhs
    else
      malformed lhs, 'missing value in definition'
      undefined)

  compiledPairs = join compiledPairs, compileDeferred ctx
  resolveDeferredTypes ctx

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
      if canonicalType = ctx.type name
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
    # log "done unifying"
    for name of values unresolvedNames
      # All functions must have been declared already
      ctx.assignType name, quantifyAll substitute ctx.substitution, canonicalType

compileDeferred = (ctx) ->
  compiledPairs = []
  if _notEmpty ctx.deferred()
    deferredCount = 0
    while (_notEmpty ctx.deferred()) and deferredCount < ctx.deferred().length
      prevSize = ctx.deferred().length
      [expression, dependencyName, lhs, rhs] = deferred = ctx.deferred().shift()
      if ctx.isDeclared dependencyName
        compiledPairs.push definitionPairCompile ctx, lhs, rhs
      else
        # If can't compile, defer further
        ctx.addDeferredDefinition deferred
      if prevSize is ctx.deferred().length
        deferredCount++

  # defer completely current scope
  if _notEmpty ctx.deferred()
    for [expression, dependencyName, lhs, rhs] in ctx.deferred()
      if ctx.isInTopScope()
        malformed expression, "#{dependencyName} is not defined"
      else
        ctx.doDefer expression, dependencyName

  concat compiledPairs

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
    params = paramTuple call, paramList
    defs ?= []
    if defs.length is 0
      malformed call, 'Missing function result'
    else
      [docs, defs] = partition isComment, defs
      if isTypeConstraint defs[0]
        [type, body, wheres...] = defs
      else
        [body, wheres...] = defs
      paramNames = _names params

      # Arity - before deferring instead? put to assignCompile, because this makes the naming of functions special
      if ctx.isAtSimpleDefinition()
        #log "adding arity for #{ctx.definitionName()}", paramNames
        ctx.declareArity ctx.definitionName(), paramNames
        # Explicit typing
        if type
          explicitType = quantifyUnbound ctx, typeConstrainedCompile type
          ctx.assignType ctx.definitionName(), explicitType

      paramTypeVars = map (-> ctx.freshTypeVariable star), params
      paramTypes = map (__ toForAll, toConstrained), paramTypeVars
      ctx.newLateScope()
      # log "adding types", (map _symbol, params), paramTypes
      ctx.declareTypes paramNames, paramTypes

      #log "compiling wheres", pairs wheres
      compiledWheres = definitionList ctx, pairs wheres

      # log "types added"
      #log "compiling", body
      if body
        compiledBody = termCompile ctx, body
      # log "compiled", body.tea
      ctx.closeScope()

      # Syntax - used params in function body
      # !! TODO: possibly add to nameCompile instead, or defer to IDE
      isUsedParam = (expression) ->
        (isName expression) and (_symbol expression) in paramNames
      labelUsedParams = (expression) ->
        map (syntaxNameAs '', 'param'), filterAst isUsedParam, expression
      map labelUsedParams, if body then join [body], wheres else wheres

      if body and not isWellformed body
        return 'malformed'

      assignCompile ctx, call,
        if ctx.shouldDefer()
          deferredExpression()
        else
          # Typing
          if body and not body.tea
            throw new Error "Body not typed"
          call.tea =
            if body
              new Constrained body.tea.constraints,
                typeFn paramTypeVars..., body.tea.type
            else
              freshInstance ctx, explicitType
          # """λ#{paramNames.length}(function (#{listOf paramNames}) {
          #   #{compiledWheres}
          #   return #{compiledBody};
          # })"""
          (irFunction
            name: (ctx.definitionName() if ctx.isAtSimpleDefinition())
            type: call.tea
            params: paramNames
            body: (join compiledWheres, [(jsReturn compiledBody)]))
            # (jsCall "λ#{paramNames.length}", [
            #   (jsFunction
            #     name: (ctx.definitionName() if ctx.isAtSimpleDefinition())
            #     params: paramNames
            #     body: (join compiledWheres, [(jsReturn compiledBody)]))])

  # data
  #   listing or
  #     pair
  #       constructor-name
  #       record
  #         type
  #     constant-name
ms.data = ms_data = (ctx, call) ->
    hasName = requireName ctx, 'Name required to declare new algebraic data'
    defs = pairsLeft isAtom, _arguments call
    # Syntax
    [names, typeArgLists] = unzip defs
    map (syntaxNewName 'Type constructor name required'), names
    for typeArgs in typeArgLists
      if isRecord typeArgs
        for type in _snd unzip _labeled _terms typeArgs
          syntaxType type
      else
        typeArgs.label = 'malformed'
    if not hasName
      return 'malformed'

    dataName = ctx.definitionName()

    # Types, Arity
    for [constr, params] in defs
      constrType = desiplifyType if params
        join (_labeled _terms params).map(_snd).map(_symbol), [dataName]
      else
        dataName
      # TODO support polymorphic data
      #log "Adding constructor #{constr.symbol}"
      ctx.declare constr.symbol,
        type: toForAll toConstrained constrType
        arity: ((_labeled _terms params).map(_fst).map(_labelName) if params)
      constr.tea = constrType
    # We don't add binding to kind constructors, but maybe we need to
    # ctx.addType dataName, typeConstant dataName

    # Translate
    concat (for [constr, params] in defs
      identifier = validIdentifier constr.symbol
      paramNames = (_labeled _terms params or []).map(_fst).map(_labelName)
        .map(validIdentifier)
      constrValue = (jsAssignStatement "#{identifier}.value",
        if params
          (jsCall "λ#{paramNames.length}",
            [(jsFunction
              params: paramNames
              body: [(jsReturn (jsNew identifier, paramNames))])])
        else
          (jsNew identifier, []))
      (join (translateDict identifier, paramNames), [constrValue]))

ms.record = ms_record = (ctx, call) ->
    args = _arguments call
    hasName = requireName ctx, 'Name required to declare new record'
    for [name, type] in _labeled args
      if not name
        malformed type, 'Label is required'
      if not type
        malformed name, 'Missing type'
      if name and type
        syntaxType type
    if args.length is 0
      malformed call, 'Missing arguments'
    # TS: (data #{ctx.definitionName()} [#{_arguments form}])
    if not hasName
      return 'malformed'
    replicate call,
      (call_ (token_ 'data'), [(token_ ctx.definitionName()), (tuple_ args)])

  # # Type an expression
  # ':': (ctx, call) ->
  #   [expression, type] = _arguments call
  #   if not type
  #     return malformed 'Missing type', call
  #   ctx.setIsType true
  #   ctx.setIsType false

  # Adds a class to the scope or defers if superclass doesn't exist
ms.class = ms_class = (ctx, call) ->
    hasName = requireName ctx, 'Name required to declare a new class'
    [paramList, defs...] = _arguments call
    params = paramTuple ctx, paramList
    paramNames = _names params
    [docs, defs] = partition isComment, defs

    [constraintSeq, wheres...] = defs
    if not isSeq constraintSeq
      wheres = defs
      constraints = []
    else
      constraints = typeConstraintsCompile _terms constraintSeq

    superClasses = map (({className}) -> className), constraints

    # TODO: defer if not all declared to prevent cycles in classes
    #   allDeclared = (ctx.isClass c for c in superClasses)

    methodDefinitions = pairs wheres
    ctx.newScope()
    ctx.bindTypeVariables paramNames
    definitionList ctx, methodDefinitions
    declarations = ctx.currentDeclarations()
    ctx.closeScope()

    for [name, def] in methodDefinitions
      (lookupInMap declarations, name)?.def = def

    if hasName
      name = ctx.definitionName()
      if ctx.isClassDefined name
        malformed 'class already defined', ctx.definitionPattern()
      else
        classConstraint = findClassType name, paramNames, declarations
        ctx.addClass name, classConstraint, superClasses, declarations
        declareMethods ctx, classConstraint, declarations

        translateDict name, (keysOfMap declarations), superClasses
    else
      'malformed'

findClassType = (className, paramNames, methods) ->
  # TODO: support multi-param classes
  [param] = paramNames
  kind = undefined
  constraint = undefined
  for name, {arity, type, def} of values methods
    vars = findFree type.type
    foundKind = lookupInMap vars, param
    if not foundKind
      # TODO: attach error to the type expression
      malformed def, 'Method must include class parameter in its type'
    if kind and not kindsEq foundKind, kind
      # TODO: attach error to the type expression instead
      # TODO: better error message
      malformed def, 'All methods must use the class paramater of the same kind'
    kind or= foundKind
    constraint or= new ClassContraint className, (new TypeVariable param, kind)
  constraint

declareMethods = (ctx, classConstraint, methodDeclarations) ->
  for name, {arity, type} of values methodDeclarations
    type = quantifyUnbound ctx, addConstraints type.type, [classConstraint]
    ctx.declare name, {arity, type}
  return

ms.instance = ms_instance = (ctx, call) ->
    hasName = requireName ctx, 'Name required to declare a new instance'

    [instanceConstraint, defs...] = _arguments call
    if not isCall instanceConstraint
      return malformed call, 'Instance requires a class constraint'
    else
      instanceType = typeConstraintCompile instanceConstraint
    [constraintSeq, wheres...] = defs
    if not isSeq constraintSeq
      wheres = defs
      constraints = []
    else
      constraints = typeConstraintsCompile _terms constraintSeq

    # TODO: defer if class does not exist
    className = instanceType.className
    classDefinition = ctx.classNamed className

    # TODO: defer if super class instances don't exist yet
    superClassInstances = findSuperClassInstances ctx, instanceType.type, classDefinition

    if hasName
      instanceName = ctx.definitionName()

      ctx.newScope()
      freshConstrains = assignMethodTypes ctx, instanceName,
        classDefinition, instanceType, constraints
      definitions = pairs wheres
      methodsDeclarations = definitionList ctx,
        (prefixWithInstanceName definitions, instanceName)
      ctx.closeScope()

      methods = map (({rhs}) -> rhs), methodsDeclarations
      # log "methods", methods
      methodTypes = (rhs.tea for [lhs, rhs] in definitions)

      # TODO: defer for class declaration if not defined
      ## if not ctx.isClassDefined className    ...

      instance = (new Constrained constraints, instanceType)
      ## if overlaps ctx, instance
      ##   malformed 'instance overlaps with another', instance
      ## else
      ctx.addInstance instanceName, instance

      # """var #{instanceName} = new #{className}(#{listOf methods});"""
      (jsVarDeclaration (validIdentifier instanceName),
        (irDefinition (new Constrained freshConstrains, (tupleOfTypes methodTypes).type),
          (jsNew className, (join superClassInstances, methods))))
    else
      'malformed'

# Makes sure methods are typed explicitly and returns the instance constraint
# with renamed type variables to avoid clashes
assignMethodTypes = (ctx, instanceName, classDeclaration, instanceType, instanceConstraints) ->
  # First we must freshen the instance type, to avoid name clashes of type vars
  freshInstanceType = freshInstance ctx,
    (quantifyUnbound ctx,
      (new Constrained instanceConstraints, instanceType.type))

  # log "mguing", classDeclaration.constraint.type, freshInstanceType.type
  sub = mostGeneralUnifier classDeclaration.constraint.type, freshInstanceType.type
  # log sub

  ctx.bindTypeVariables setToArray (findFree freshInstanceType)
  for name, {arity, type} of values classDeclaration.declarations
    freshType = freshInstance ctx, type
    instanceSpecificType = substitute sub, freshType
    quantifiedType = quantifyUnbound ctx, instanceSpecificType
    prefixedName = instancePrefix instanceName, name
    ctx.declareArity prefixedName, arity
    ctx.assignType prefixedName, quantifiedType
  freshInstanceType.constraints

prefixWithInstanceName = (definitionPairs, instanceName) ->
  for [lhs, rhs] in definitionPairs
    if (syntaxNewName lhs, 'Method name required') is true
      [(token_ instancePrefix instanceName, lhs.symbol), rhs]
    else
      [lhs, rhs]

instancePrefix = (instanceName, methodName) ->
  "#{instanceName}_#{methodName}"

findSuperClassInstances = (ctx, instanceType, classDefinition) ->
  toConstraint = (superName) ->
    new ClassContraint superName, instanceType
  superConstraints = map toConstraint, classDefinition.supers
  instanceDictFor ctx, constraint for constraint in superConstraints


  # TODO:
  # For now support the simplest function macros, just compiling down to source
  # strings
  # macro: (ctx, call) ->
  #   args = _arguments call
  #   [paramList, body] = args
  #   paramTuple paramList
  #   if not body
  #     malformed call, 'Missing macro definition'

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
      return malformed call, 'match `subject` missing'
    if cases.length % 2 != 0
      return malformed call, 'match missing result for last pattern'
    subjectCompiled = termCompile ctx, subject

    # To make sure all results have the same type
    resultType = ctx.freshTypeVariable star

    # ctx.setGroupTranslation()
    ctx.setAssignTo subjectCompiled
    varNames = []
    constraints = []
    compiledCases = conditional (for [pattern, result] in pairs cases

      ctx.newScope() # for variables defined inside pattern
      ctx.defineNonDeferrablePattern pattern
      {precs, assigns} = patternCompile ctx, pattern, subject

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
    ), "throw new Error('match failed to match');" #TODO: what subject?
    translationCache = ctx.resetAssignTo()
    call.tea = new Constrained constraints, resultType
    assignCompile ctx, call, iife concat (filter _is, [
      translationCache
      varList varNames
      compiledCases])

ms['=='] = ms_eq = (ctx, call) ->
    [a, b] = _arguments call
    operatorCompile ctx, call
    compiledA = termCompile ctx, a
    compiledB = termCompile ctx, b

    callTyping ctx, call
    assignCompile ctx, call, (jsBinary "===", compiledA, compiledB)

builtInMacros = ms


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

paramTuple = (call, expression) ->
  if not expression or not isTuple expression
    malformed call, 'Missing paramater list'
    params = []
  else
    params = _terms expression
    map (syntaxNewName 'Parameter name expected'), params
  params

quantifyUnbound = (ctx, type) ->
  vars = subtractSets (findFree type), ctx.allBoundTypeVariables()
  quantify vars, type

# Takes a set of fixed type variables, a set of type variables which
# should be quantified and a list of constraints
# returns deferred and retained constraints
deferConstraints = (ctx, fixedVars, quantifiedVars, constraints) ->
  reducedConstraints = reduceConstraints ctx, constraints
  isFixed = (constraint) ->
    # log fixedVars, constraint, (findFree constraint)
    isSubset fixedVars, (findFree constraint)
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
    for superClassContraint in constraintsFromSuperClasses ctx, c
      if typeEq superClassContraint, constraint
        return yes
  instanceContraints = constraintsFromInstance ctx, constraint
  if instanceContraints
    allMap ((c) -> entail ctx, constraints, c), instanceContraints
  else
    no

constraintsFromSuperClasses = (ctx, constraint) ->
  {className, type} = constraint
  join [constraint], concat (for s in (ctx.classNamed className).supers
    bySuper ctx, new ClassContraint s, type)

constraintsFromInstance = (ctx, constraint) ->
  {className, type} = constraint
  for instance in (ctx.classNamed className).instances
    substitution = matchType instance.type.type.type, constraint.type
    if not lookupInMap substitution, "could not unify"
      return map ((c) -> substitute substitution, c), instance.type.constraints
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

malformed = (expression, message) ->
  # TODO support multiple malformations
  expression.malformed = message
  (jsMalformed message)

isWellformed = (expression) ->
  if expression.malformed
    no
  else
    if isForm expression
      for term in _terms expression
        unless isWellformed term
          return no
    yes

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
    syntaxNewName message, ctx.definitionPattern()
  else
    malformed call, message
    false

atomCompile = (ctx, atom) ->
  {symbol, label} = atom
  # Typing and Translation
  {type, translation, pattern} =
    switch label
      when 'numerical'
        numericalCompile ctx, symbol
      when 'regex'
        regexCompile ctx, symbol
      when 'char'
        type: toConstrained typeConstant 'Char'
        translation: symbol
        pattern: literalPattern ctx, symbol
      when 'string'
        type: toConstrained typeConstant 'String'
        translation: symbol
        pattern: literalPattern ctx, symbol
      else
        nameCompile ctx, atom, symbol
  atom.tea = type if type
  if ctx.isOperator()
    # TODO: maybe don't use label here, it's getting confusing what is its purpose
    atom.label = 'operator'
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
      type = toConstrained ctx.freshTypeVariable star
      ctx.addToDefinedNames {name: symbol, type: type}
      type: type
      pattern:
        assigns:
          [[(validIdentifier symbol), exp]]
  else
    # Name typed, use a fresh instance
    if contextType and contextType not instanceof TempType
      type = freshInstance ctx, contextType
      {
        type: type
        translation: nameTranslate ctx, atom, symbol, type
      }
    # Inside function only defer compilation if we don't know arity
    else if ctx.isInsideLateScope() and (ctx.isDeclared symbol) or contextType instanceof TempType
      # Typing deferred, use an impricise type var
      type = toConstrained ctx.freshTypeVariable star
      ctx.addToDeferredNames {name: symbol, type: type}
      {
        type: type
        translation: nameTranslate ctx, atom, symbol, type
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

nameTranslate = (ctx, atom, symbol, type) ->
  if atom.label is 'const'
    switch symbol
      when 'True' then 'true'
      when 'False' then 'false'
      else
        (jsAccess (validIdentifier symbol), "value")
  else if ctx.isMethod symbol, type
    (irMethod type, symbol)
  else
    validIdentifier symbol

numericalCompile = (ctx, symbol) ->
  translation = if symbol[0] is '~' then (jsUnary "-", symbol) else symbol
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

literalPattern = (ctx, translation) ->
  if ctx.assignTo()
    precs: [cond_  (jsBinary "===", ctx.assignTo(), translation)]

deferredExpression = ->
  {js: 'deferred'}

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
      true
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
  # TODO: what about the class dictionaries order?
  counter = {}
  classParams = newMap()
  for {className, type} in reducedConstraints when not isAlreadyParametrized ctx, type
    addToMap classParams, type.name,
      "_#{className}_#{counter[className] ?= 0; ++counter[className]}"
  ctx.addClassParams classParams
  classParamNames = mapToArray classParams
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
  classParams =
    if op.ir is irMethodTranslate
      []
    else
      dictsForConstraint ctx, finalType.constraints
  (jsCall (translateIr ctx, op), (join classParams, (translateIr ctx, args)))

irMethod = (type, name) ->
  {ir: irMethodTranslate, type, name}

irMethodTranslate = (ctx, {type, name}) ->
  finalType = substitute ctx.substitution, type
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
  if constraint.type instanceof TypeVariable
    ctx.classParamNameFor constraint.type.name
  else if _notEmpty (constraints = constraintsFromInstance ctx, constraint)
    (jsCall (instanceDictFor ctx, constraint),
      (dictsForConstraint ctx, constraints))
  else
    (instanceDictFor ctx, constraint)

isAlreadyParametrized = (ctx, type) ->
  !!ctx.classParamNameFor type.name

instanceDictFor = (ctx, constraint) ->
  for {name, type} in (ctx.classNamed constraint.className).instances
    # TODO: support lookup of composite types, by traversing left depth-first
    if type.type.type.name is constraint.type.name
      return validIdentifier name
  throw new Error "no instance for #{printType constraint}"

irFunction = ({name, params, body}) ->
  {ir: irFunctionTranslate, name, params, body}

irFunctionTranslate = (ctx, {name, params, body}) ->
  (jsCall "λ#{params.length}", [
    (jsFunction
      name: (validIdentifier name if name)
      params: params
      body: translateIr ctx, body)])

isTypeConstraint = (expression) ->
  (isCall expression) and (':' is _symbol _operator expression)

isComment = (expression) ->
  (isCall expression) and ('#' is _symbol _operator expression)

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
  /:$/.test atom.symbol

isCapital = (atom) ->
  /[A-Z]/.test atom.symbol

isName = (expression) ->
  throw new Error "Nothing passed to isName" unless expression
  (isAtom expression) and /[^~"'\/].*/.test expression.symbol

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

tuplize = (n, list) ->
  for e, i in list by n
    list[i...i + n]

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
  {js: jsMalformedTranslate, message: message}

jsMalformedTranslate = ({message}) ->
  message

jsNew = (classFun, args) ->
  {js: jsNewTranslate, classFun, args}

jsNewTranslate = ({classFun, args}) ->
  "new #{classFun}(#{listOf args})"


jsReturn = (arg) ->
  {js: jsReturnTranslate, arg}

jsReturnTranslate = ({arg}) ->
  "return #{arg};"


jsUnary = (op, arg) ->
  {js: jsUnaryTranslate, op, arg}

jsUnaryTranslate = ({op, arg}) ->
  "#{op}#{arg}"


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
  crawl highlighted, (word, symbol, parent) ->
    (word.ws or '') + colorize(theme[labelOf word, parent], symbol)

labelOf = (word, parent) ->
  if (isCollectionDelim word) and parent
    parent.label
  else
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
  [firstChar] = name
  if firstChar is '/'
    throw new Error "Identifier expected, but found regex #{name}"
  else
    name
      .replace(/\+/g, 'plus_')
      .replace(/\-/g, '__')
      .replace(/\*/g, 'times_')
      .replace(/\//g, 'over_')
      .replace(/\=/g, 'eq_')
      .replace(/\</g, 'lt_')
      .replace(/\>/g, 'gt_')
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

builtInContext = ->
  concatMaps (mapMap desiplifyTypeAndArity, newMapWith 'True', 'Bool',
    'False', 'Bool'
    '&', '(Fn a b b)' # TODO: replace with actual type
    'show-list', '(Fn a b)' # TODO: replace with actual type
    'from-nullable', '(Fn a b)' # TODO: replace with actual type JS -> Maybe a

    # TODO match

    # 'if', '(Fn Bool a a a)'
    # TODO JS interop

    # 'sqrt', '(Fn Num Num)'
    # 'not', '(Fn Bool Bool)'

    # '^', binaryMathOpType

    # '~', '(Fn Num Num)'

    # '+', binaryMathOpType
    # '*', binaryMathOpType
    '==', comparatorOpType
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
    ),
    newMapWith 'empty-array', (type: (parseUnConstrainedType '(Fn (Array a))'), arity: [])
      'cons-array', (type: (parseUnConstrainedType '(Fn a (Array a) (Array a))'), arity: ['what', 'onto'])

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

keysOfMap =
setToArray = (set) ->
  key for key of set.values

mapToArray = (map) ->
  val for key, val of map.values

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

# end of Set

# Type inference and checker ala Mark Jones

unify = (ctx, t1, t2) ->
  throw new Error "invalid args to unify" unless ctx instanceof Context and t1 and t2
  sub = ctx.substitution
  ctx.extendSubstitution mostGeneralUnifier (substitute sub, t1), (substitute sub, t2)

# Returns a substitution
mostGeneralUnifier = (t1, t2) ->
  if t1 instanceof TypeVariable
    bindVariable t1, t2
  else if t2 instanceof TypeVariable
    bindVariable t2, t1
  else if t1 instanceof TypeConstr and t2 instanceof TypeConstr and
    t1.name is t2.name
      emptySubstitution()
  else if t1 instanceof TypeApp and t2 instanceof TypeApp
    s1 = mostGeneralUnifier t1.op, t2.op
    s2 = mostGeneralUnifier (substitute s1, t1.arg), (substitute s1, t2.arg)
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

# Returns a substitution
matchType = (t1, t2) ->
  if t1 instanceof TypeVariable and kindsEq (kind t1), (kind t2)
    newMapWith t1.name, t2
  else if t1 instanceof TypeConstr and t2 instanceof TypeConstr and
    t1.name is t2.name
      emptySubstitution()
  else if t1 instanceof TypeApp and t2 instanceof TypeApp
    s1 = matchType t1.op, t2.op
    s2 = matchType t1.arg, t2.arg
    s3 = mergeSubs s1, s2
    s3 or
      newMapWith "could not unify", [(printType t1), (printType t2)]
  else
    newMapWith "could not unify", [(printType t1), (printType t2)]

joinSubs = (s1,s2) ->
  concatMaps s1, mapMap ((type) -> substitute s1, type), s2

mergeSubs = (s1, s2) ->
  agree = (varName) ->
    variable = new TypeVariable varName, star
    typeEq (substitute s1, variable), (substitute s2, variable)
  if allMap agree, keysOfMap intersectRight s1, s2
    concatMaps s1, s2
  else
    null

emptySubstitution = ->
  newMap()

# Unlike in Jones, we simply use substitute for both variables and quantifieds
# - variables are strings, wheres quantifieds are ints
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
  else if type instanceof Constrained
    new Constrained (substituteList substitution, type.constraints),
      (substitute substitution, type.type)
  else if type instanceof ClassContraint
    new ClassContraint type.className, substitute substitution, type.type
  else
    type

substituteList = (substitution, list) ->
  map ((t) -> substitute substitution, t), list

findFree = (type) ->
  if type instanceof TypeVariable
    newMapWith type.name, type.kind
  else if type instanceof TypeApp
    concatMaps (findFree type.op), (findFree type.arg)
  else if type instanceof Constrained
    concatMaps (findFree (map findFree, type.constraints)), (findFree type.type)
  else if type instanceof ClassContraint
    findFree type.type
  else
    newMap()

findBound = (name, binding) ->
  (lookupInMap binding, name) or 'unbound name #{name}'

freshInstance = (ctx, type) ->
  throw new Error "not a forall in freshInstance" unless type instanceof ForAll
  freshes = map ((kind) -> ctx.freshTypeVariable kind), type.kinds
  (substitute freshes, type).type

freshName = (nameIndex) ->
  suffix = if nameIndex > 25 then freshName (Math.floor nameIndex / 25) - 1 else ''
  (String.fromCharCode 97 + nameIndex % 25) + suffix

# Normalized constraint has a type which has type variable at its head
#   that is either ordinary type variable or type variable standing for a constructor
#   with arbitrary type arguments
isNormalizedConstraint = (constraint) ->
  {type} = constraint
  if type instanceof TypeVariable
    yes
  else if type instanceof TypeConstr
    no
  else if type instanceof TypeApp
    isNormalizedConstraint type.op

typeEq = (a, b) ->
  if a instanceof TypeVariable and b instanceof TypeVariable or
      a instanceof TypeConstr and b instanceof TypeConstr
    a.name is b.name
  else if a instanceof QuantifiedVar and b instanceof QuantifiedVar
    a.var is b.var
  else if a instanceof TypeApp and b instanceof TypeApp
    (typeEq a.op, b.op) and (typeEq a.arg, b.arg)
  else if a instanceof ForAll and b instanceof ForAll
    typeEq a.type, b.type
  else if a instanceof Constrained and b instanceof Constrained
    (all zipWith typeEq, a.constraints, b.constraints) and
      (typeEq a.type, b.type)
  else if a instanceof ClassContraint and b instanceof ClassContraint
    a.className is b.className and (typeEq a.type, b.type)
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
  if arity is 1
    new KindFn star, star
  else
    new KindFn star, kindFn arity - 1

typeFn = (from, to, args...) ->
  if args.length is 0
    if not to
      from
    else
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
    throw new Error "Invalid type in kind"

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

class Constrained
  constructor: (@constraints, @type) ->
class ClassContraint
  constructor: (@className, @type) ->


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

printType = (type) ->
  if type instanceof TypeVariable
    type.name
  else if type instanceof QuantifiedVar
    type.var
  else if type instanceof TypeConstr
    type.name
  else if type instanceof TypeApp
    flattenType collectArgs type
  else if type instanceof ForAll
    "(∀ #{printType type.type})"
  else if type instanceof ClassContraint
    "(#{type.className} #{printType type.type})"
  else if type instanceof Constrained
    "(: #{(map printType, join [type.type], type.constraints).join ' '})"
  else if type instanceof TempType
    "(. #{printType type.type})"
  else if Array.isArray type
    "\"#{listOf type}\""
  else if type is undefined
    "undefined"
  else
    throw new Error "Unrecognized type in printType"

collectArgs = (type) ->
  if type instanceof TypeApp
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
  if (xs.length !== null) {
    return xs.length;
  }
  return 1 + seq_size(xs.tail);
};

var seq_at = function (i, xs) {
  if (typeof xs === "undefined" || xs === null) {
    throw new Error('Pattern matching required sequence got undefined');
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
    return xs.slice(from, xs.length - leave);
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
(for i in [0..9]
  """var λ#{i} = function (f) {
      f._ = #{i};
      return f;
    };""").join('\n\n') +
"""
;
"""

# API

syntaxedExpHtml = (string) ->
  collapse toHtml astize tokenize string

compileTopLevel = (source) ->
  {js, ast, ctx} = compileToJs topLevel, "(#{source})", -1
  {js, ast, types: typeEnumaration ctx}

compileTopLevelAndExpression = (source) ->
  topLevelAndExpression source

topLevelAndExpression = (source) ->
  ast = astize tokenize "(#{source})", -1
  [terms..., expression] = _terms ast
  {ctx} = compiledDefinitions = compileAstToJs definitionList, pairs terms
  compiledExpression = compileCtxAstToJs topLevelExpression, ctx, expression
  types: ctx._scope()
  subs: filterMap ((name) -> name is 'could not unify'), ctx.substitution
  ast: ast
  compiled: library + compiledDefinitions.js + compiledExpression.js

typeEnumaration = (ctx) ->
  values mapMap _type, ctx._scope()

compileToJs = (compileFn, source, offset = 0) ->
  ast = astize tokenize source, offset
  compileAstToJs compileFn, ast

compileAstToJs = (compileFn, ast) ->
  ctx = new Context
  compileCtxAstToJs compileFn, ctx, ast

compileCtxAstToJs = (compileFn, ctx, ast) ->
  ir = compileFn ctx, ast
  jsIr = translateIr ctx, ir
  js = (if Array.isArray jsIr
      translateStatementsToJs
    else
      translateToJs) jsIr
  {ctx, ast, js}

astizeList = (source) ->
  parentize astize tokenize "(#{source})", -1

astizeExpression = (source) ->
  parentize astize tokenize source

astizeExpressionWithWrapper = (source) ->
  parentize astize tokenize "(#{source})", -1


# end of API

# AST accessors

_operator = (call) ->
  (_terms call)[0]

_arguments = (call) ->
  (_terms call)[1..]

_terms = (form) ->
  form[1...-1].filter ({label}) -> label isnt 'whitespace'

_snd = ([a, b]) -> b

_fst = ([a, b]) -> a

_labelName = (atom) -> (_symbol atom)[0...-1]

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
    if not isMapEmpty compiled.subs
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

  'typed function'
  """f (fn [x y]
    (: (Fn Bool String Bool))
    x)"""
  """(f True "a")""", yes

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
        n (adults (- 1 month))))"""
    "(fibonacci 6)", 8

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

  # TODO: will need more work
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
          [False False] False)))

    ord-bool (instance (Ord Bool)
      <= (fn [x y]
        (match [x y]
          [True any] True
          [w z] (= w z))))

    """
  """(<= "Michal" "Adam")""", no

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
    return source
  throw new Error "Test #{givenName} not found!"

logError = (message, error) ->
  log message, error.message, error.stack
    .replace(/\n?((\w+)[^>\n]+>[^>\n]+>[^>\n]+:(\d+:\d+)|.*)(?=\n)/g, '\n$2 $3')
    .replace(/\n (?=\n)/g, '')

debug = (fun) ->
  try
    fun()
  catch e
    logError "debug", e

runTests = (tests) ->
  for [name, source, expression, result] in tuplize 4, tests
    test name, source + " " + expression, result
  "Finished"
# end of tests

exports.compileTopLevel = compileTopLevel
exports.compileTopLevelAndExpression = compileTopLevelAndExpression
exports.astizeList = astizeList
exports.astizeExpression = astizeExpression
exports.astizeExpressionWithWrapper = astizeExpressionWithWrapper
exports.syntaxedExpHtml = syntaxedExpHtml

# exports.compileModule = (source) ->
#   """
#   #{library}
#   var exports = {};
#   #{compileDefinitionsInModule source}
#   exports"""

exports.library = library

exports.isForm = isForm
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