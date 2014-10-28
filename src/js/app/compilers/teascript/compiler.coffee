keywords = 'def defn data class fn proc match if type :: \\
            access call new
            require'.split ' '

controls = '\\(\\)\\[\\]\\{\\}'

tokenize = (input) ->
  whitespace = ''
  currentPos = 0
  while input.length > 0
    match = input.match ///
      ^ # must be at the start
      (
        \s+ # pure whitespace
      | [#{controls}] # brackets
      | /([^\ /]|\\/)([^/]|\\/)*?/ # regex
      | "[^"]*?" # strings
      | '\\?[^']' # char
      | [^#{controls}"'\s]+ # normal tokens
      )///
    if not match
      throw new Error "Could not recognize a token starting with `#{input[0..10]}`"
    [token] = match
    input = input[token.length...]
    if /\s+$/.test token
      whitespace = token
      continue
    ws = whitespace
    pos = currentPos
    currentPos += ws.length + token.length
    whitespace = ''
    {token, ws, pos}

leftDelims = ['(', '[', '{']
rightDelims = [')', ']', '}']

astize = (tokens) ->
  tree = []
  current = []
  stack = [[]]
  for token in tokens
    if token.token in leftDelims
      stack.push [token]
    else if token.token in rightDelims
      closed = stack.pop()
      closed.push token
      stack[stack.length - 1].push closed
    else
      stack[stack.length - 1].push token
  stack[0][0]

typed = (a, b) ->
  b.type = a.type
  b

walk = (ast, cb) ->
  if Array.isArray ast
    ast = cb ast
    if Array.isArray ast
      ast = typed ast, (for node in ast
        walk node, cb)
  ast

walkOnly = (ast, cb) ->
  if Array.isArray ast
    cb ast
    for node in ast
      walk node, cb
  ast

crawl = (ast, cb) ->
  if Array.isArray ast
    typed ast, (for node in ast
      crawl node, cb)
  else
    cb ast, ast.token

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

theme =
  keyword: 'red'
  numerical: '#FEDF6B'
  typename: '#9C49B6'
  label: '#9C49B6'
  string: '#FEDF6B'
  paren: '#444'
  name: '#9EE062'
  recurse: '#67B3DD'
  param: '#FDA947'
  comment: 'grey'
  operator: '#cceeff'
  normal: 'white'

labelMapping = (word, rules...) ->
  for [label, cond] in rules when cond
    word.label = label
    return word
  word

labelSimple = (ast) ->
  crawl ast, (word, token) ->
    labelMapping word,
      ['keyword', token in keywords]
      ['numerical', /^-?\d+/.test(token)]
      #['typename', /^[A-Z]/.test token]
      ['label', /^[^\s]*:$/.test token]
      ['const', /^;[^\s]*$/.test token]
      ['string', /^["']/.test token]
      ['regex', /^\/[^ \/]/.test token]
      ['paren', token in ['(', ')']]
      ['bracket', token in ['[', ']']]
      ['brace', token in ['{', '}']]

labelMatches = (ast) ->
  macro 'match', ast, (node, args) ->
    [keyword, over, patterns...] = args
    for pattern in patterns by 2
      labelNames pattern
    node

fnDefinition = (node) ->
  words = inside node
  [keyword, paramList, defs...] = words
  params = if Array.isArray(paramList) then inside paramList else undefined
  defs ?= []
  for def, i in defs
    if matchNode '::', def
      type = def
    else if matchNode '#', def
      doc = def
    if not matchAnyNode ['::', '#'], def
      implementation = defs[i...]
      break
  {body, wheres} = fnImplementation implementation ? []
  {params, type, doc, body, wheres}

fnImplementation = (defs) ->
  [body, where...] = defs
  wheres = whereList where
  {body, wheres}

whereList = (defs) ->
  pairs defs

pairs = (list) ->
  for el, i in list by 2
    [el, list[i + 1]]

labelTop = (ast) ->
  {wheres} = fnImplementation inside ast
  labelWhere wheres
  ast

labelDefinitions = (ast) ->
  labelWhere whereList inside ast
  ast

labelFns = (ast) ->
  macro 'fn', ast, (node, args) ->
    node.type = 'function'
    {params, body, wheres} = fnDefinition node
    labelFnBody body
    labelWhere wheres
    labelParams node, params if params?
    node

labelFnBody = (node) ->
  return

labelNames = (pattern) ->
  if Array.isArray pattern
    if isList(pattern) or isTuple pattern
      (inside pattern).map labelNames
    else
      [op, args...] = inside pattern
      args.map labelNames
  else
    pattern.label = 'name' unless pattern.label

labelWhere = (wheres) ->
  for [name, def] in wheres
    labelNames name
    if def
      if matchNode 'fn', def
        labelRecursiveCall def, name.token
  return

labelParams = (ast, params) ->
  paramNames = (token for {token} in params)
  mapTokens paramNames, ast, (word) ->
    word.label = 'param' unless word.label and word.label isnt 'recurse'

labelRecursiveCall = (ast, fnname) ->
  mapTokens [fnname], ast, (word) ->
    word.label = 'recurse' if word.label isnt 'param'

typeDatas = (ast) ->
  macro 'data', ast, (node) ->
    node.type = 'data'
    node

typeTypes = (ast) ->
  macro 'type', ast, (node) ->
    node.type = 'type'
    node

typeComments = (ast) ->
  macro '#', ast, (node) ->
    node.type = 'comment'
    node

labelComments = (ast) ->
  typedMacro 'comment', ast, (node, words) ->
    for word in words
      word.label = 'comment' unless word.label in ['param', 'recurse']
    node

labelOperators = (ast) ->
  walk ast, (node) ->
    [paren, operator] = node
    if paren.token == '(' and not operator.type
      operator.type = 'operator'
    node

apply = (onto, fns...) ->
  result = onto
  for fn in fns
    result = fn result
  result

typifyMost = (ast) ->
  apply ast, typeComments, typeDatas, typeTypes, labelSimple, labelMatches, labelFns

typify = (ast) ->
  apply ast, typifyMost, labelComments, labelOperators

typifyTop = (ast) ->
  apply ast, typifyMost, labelTop, labelComments, labelOperators

typifyDefinitions = (ast) ->
  apply ast, typifyMost, labelDefinitions, labelComments, labelOperators

toHtml = (highlighted) ->
  crawl highlighted, (word) ->
    (word.ws or '') + colorize(theme[word.label ? 'normal'], word.token)

# Correct offset by 1 in positions, when we wrap the source in an S-exp
shiftPos = (ast) ->
  crawl ast, (word) ->
    word.pos = word.pos - 1
    word

parentize = (highlighted) ->
  walkOnly highlighted, (node) ->
    for subNode in node
      subNode.parent = node
    node

collapse = (nodes) ->
  collapsed = ""
  for node in nodes
    crawl node, (node) ->
      collapsed += node
  collapsed

syntaxed = (source) ->
  collapse inside toHtml typifyTop astize tokenize "(#{source})"

syntaxedExp = (source) ->
  collapse inside toHtml typify astize tokenize source

tokenizedDefinitions = (source) ->
  (parentize shiftPos [inside typifyDefinitions astize tokenize "(#{source})"])[0]

tokenizedExp = (source) ->
  parentize typify astize tokenize source

variableCounter = 1

# exp followed by list of definitions
compiled = (source) ->
  variableCounter = 1
  compileTop preCompileTop source

# single exp
compiledExp = (source) ->
  variableCounter = 1
  "(#{compileSingleExp preCompileExp source})"

# list of definitions
compileDefinitions = (source) ->
  variableCounter = 1
  compileWheres preCompileDefs source

# exported list of definitions
compileDefinitionsInModule = (source) ->
  variableCounter = 1
  compileWheresInModule preCompileDefs source

preCompileExp = (source) ->
  parentize typify astize tokenize source

preCompileTop = (source) ->
  parentize typifyTop astize tokenize "(#{source})"

preCompileDefs = (source) ->
  parentize typifyDefinitions astize tokenize "(#{source})"

compileSingleExp = (ast) ->
  ast.scope = topScopeDefines()
  compileImpl ast

compileTop = (ast) ->
  ast.scope = topScopeDefines()
  {body, wheres} = fnImplementation inside ast
  compileFnImpl body, wheres

compileWheres = (ast) ->
  ast.scope = topScopeDefines()
  wheres = whereList inside ast
  compileWhereImpl wheres

compileWheresInModule = (ast) ->
  ast.scope = topScopeDefines()
  wheres = whereList inside ast
  "#{wheres.map(compileExportedDef).join '\n'}"

compileExportedDef = ([name, def]) ->
  if !def?
    throw new Error 'missing definition in top level assignment'
  if name.token
    identifier = validIdentifier name.token
    addToEnclosingScope name.token, def
    "var #{identifier} = exports['#{identifier}'] = #{compileImpl def};"
  else
    compileDef [name, def]

compileImpl = (node, hoistableWheres = []) ->
  # For now special case match to allow definition hoisting up one level
  if Array.isArray(node) and node.length > 0
    [op, args...] = inside node
    if op.type is 'operator' and op.token is 'match'
      return trueMacros[op.token] hoistableWheres, args...

    ###
    if hoistableWheres.length > 0
      allNames = []
      for [_, _, names] in hoistableWheres
        allNames.push names...
      throw new Error "#{allNames.join ','} used but not defined yet"###

  switch node.type
    when 'comment' then 'null'
    when 'data' then 'null'
    when 'type' then 'null'
    when 'function'
      compileFn node
    else
      if Array.isArray node
        exps = inside node
        if isMap node
          compileMap exps
        else if isTuple(node) or isList(node)
          compileList exps
        else
          [op, args...] = exps
          opName = op.token
          if opName and expander = trueMacros[opName]
            expander args...
          else if opName and expander = macros[opName]
            expander (args.map compileImpl)...
          else
            compileFunctionCall op, args
      else if node.label is 'const'
        compileConst node
      else if node.token.match /^"/
        node.token
      else
        name = validIdentifier node.token
        if not node.label
          defLocation = lookupIdentifier name, node
          if not defLocation
            throw new Error "#{name} used but not defined"
        name

isList = (node) ->
  Array.isArray(node) and node[0].token is '['

isTuple = (node) ->
  Array.isArray(node) and node[0].token is '{'

isMap = (node) ->
  isTuple(node) and (elems = inside node; elems.length > 0) and elems[0].label is 'label'

compileMap = (elems) ->
  [constr, args...] = elems
  items = args.map(compileImpl).join ', '
  "({\"#{constr.token}\": [#{items}]})"

compileConst = (token) ->
  "({'#{token.token}': true})"

compileList = (elems) ->
  # "[#{elems.join ', '}]"
  "[#{elems.map(compileImpl).join ', '}]"

compileFunctionCall = (op, args) ->
  fn = compileImpl op
  # Ignore labels for now
  params = for arg in args when arg.label isnt 'label'
    compileImpl arg
  "#{fn}(#{params.join ', '})"

expandMacro = (macro) ->
  macros[macro]?() ? macro

validIdentifier = (name) ->
  if macros[name]
    expandMacro name
  else
    [firstChar] = name
    if firstChar is '-'
      "(- #{validIdentifier name[1...]})"
    else if firstChar is '/'
      # regex
      name
    else
      name
        .replace(/\+/g, 'plus_')
        .replace(/\-/g, '__')
        .replace(/\*/g, 'times_')
        .replace(/\//g, 'over_')
        .replace(/\√/g, 'sqrt_')
        .replace(/\./g, 'dot_')
        .replace(/\&/g, 'and_')
        .replace(/\?/g, 'p_')
        .replace(/^const$/, 'const_')
        .replace(/^default$/, 'default_')
        .replace(/^with$/, 'with_')
        .replace(/^in$/, 'in_')

lookupIdentifier = (name, node) ->
  while node.parent
    node = node.parent
    if node.scope and name of node.scope
      return node
  null

addToEnclosingScope = (name, node) ->
  while node.parent
    node = node.parent
    if node.scope
      node.scope[name] = true
      return
  throw new Error "Defining #{name} without enclosing scope"

compileFn = (node) ->
  {params, body, wheres} = fnDefinition node
  if !params?
    throw new Error 'missing parameter list'
  paramNames = params.map(getToken).map(validIdentifier)
  node.scope = toMap paramNames
  curry paramNames, """
    (function (#{paramNames.join ', '}) {
      #{compileFnImpl body, wheres, yes}
    })"""

curry = (paramNames, fnDef) ->
  if paramNames.length > 1
    """$curry#{fnDef}"""
  else
    fnDef

toMap = (array) ->
  map = {}
  for x in array
    map[x] = true
  map

getToken = (word) -> word.token

compileFnImpl = (body, wheres, doReturn) ->
  if not body
    throw new Error "Missing definition of a function"
  # Find invalid (hoistable) wheres and let the function body
  # define them
  [validWheres, hoistableWheres] = findHoistableWheres wheres
  wheresDef = compileWhereImpl validWheres
  bodyDef = compileImpl body, hoistableWheres
  [
    wheresDef
  ,
    if doReturn
      "return #{bodyDef};"
    else
      bodyDef
  ].join '\n'

# Returns two lists, first the wheres that can be defined, second
# the wheres which use an identifier which is not in scope (possibly
# defined inside match)

  # get list of names from wheres
  # for each where, get list of used names
  #   if some used name is not in newly defined or any parent scope
  #     save it for later, maybe it's defined inside body
findHoistableWheres = (wheres) ->
  names = {}
  hoistable = []
  valid = []
  for [pattern, def], i in wheres
    crawl pattern, (node) ->
      if node.label is 'name'
        names[node.token] = yes
  for [pattern, def], i in wheres
    log "def", printAst def
    decided = no
    crawl def, (node) ->
      if not node.label
        name = node.token
        if not names[name] and not lookupIdentifier name, node
          if not decided
            hoistable.push [pattern, def]
            decided = yes
          # also save all undefined names
          (hoistable[hoistable.length - 1][2] ?= []).push name
    if not decided
      valid.push [pattern, def]
  [valid, hoistable]


compileWhereImpl = (wheres) ->
  sorted = (sortTopologically constructDependencyGraph wheres).map ({def}) -> def
  "#{sorted.map(compileDef).join '\n'}"

sortTopologically = ([graph, dependencies]) ->
  reversedDependencies = reverseGraph graph
  independent = []

  moveToIndependent = (node) ->
    independent.push node
    delete dependencies[name] for name in node.names

  for parent in graph when parent.set.numDependencies is 0
    moveToIndependent parent

  sorted = []
  while independent.length > 0
    finishedParent = independent.pop()
    sorted.push finishedParent
    for child in reversedDependencies[finishedParent.names[0]] or []
      removeDependency child.set, name for name in finishedParent.names
      moveToIndependent child if child.set.numDependencies is 0

  for parent of dependencies
    throw new Error "Cyclic definitions between #{(name for name of dependencies).join ','}"
  sorted

reverseGraph = (nodes) ->
  reversed = {}
  for child in nodes
    for dependencyName of child.set.dependencies
      (reversed[dependencyName] ?= []).push child
  reversed

constructDependencyGraph = (wheres) ->
  lookupByName = {}
  deps = dependencySet()
  # find all defined names
  graph = []
  for [pattern, def], i in wheres
    graph[i] = whereDef = def: [pattern, def], set: dependencySet(), names: []
    crawl pattern, (node) ->
      if node.label is 'name'
        whereDef.names.push node.token
        lookupByName[node.token] = whereDef
  # then construct local graph
  for [pattern, def], i in wheres
    crawl def, (node) ->
      if node.token of lookupByName
        child = graph[i]
        parent = lookupByName[node.token]
        addDependency child.set, name for name in parent.names unless child is parent
        addDependency deps, parent
  [graph, lookupByName]

dependencySet = ->
  numDependencies: 0
  dependencies: {}

addDependency = (set, parentName) ->
  return if set.dependencies[parentName]
  set.numDependencies += 1
  set.dependencies[parentName] = true

removeDependency = (set, parentName) ->
  return if !set.dependencies[parentName]
  set.numDependencies -= 1
  delete set.dependencies[parentName]

compileDef = ([name, def]) ->
  if !def?
    throw new Error 'missing definition in assignment'
  pm = patternMatch(name, compileImpl def)
  pm.precs.filter(({cache}) -> cache).map(({cache}) -> cache)
  .concat(pm.assigns).map(compileAssign).join '\n'

newVar = ->
  "i#{variableCounter++}"

repeat = (x, n) ->
  new Array(n + 1).join x

isSplat = (elem) ->
  elem.token and elem.token[...2] is '..'

stripSplatFromName = (token) ->
  if token[...2] is '..'
    token[2...]
  else
    token

patternMatchingRules = [
  (pattern) ->
    trigger: pattern.label is 'numerical'
    cond: (exp) -> ["#{exp}" + " == #{pattern.token}"]
  (pattern) ->
    trigger: pattern.label is 'const'
    cond: (exp) -> ["'#{pattern.token}' in #{exp}"]
  (pattern) ->
    trigger: pattern.label is 'name'
    assignTo: (exp) ->
      if exp isnt identifier = validIdentifier stripSplatFromName pattern.token
        addToEnclosingScope identifier, pattern
        [[identifier, exp]]
      else
        []
  # (pattern) ->
  #   trigger: matchNode '&', pattern
  #   cache: true
  #   cond: (exp) -> ["'head' in #{exp}"]
  #   assignTo: (exp) ->
  #     [op, head, tail] = inside pattern
  #     recurse: [
  #       [head, "#{exp}.head"]
  #       [tail, "#{exp}.tail"]
  #     ]
  (pattern) ->
    # expect lists from here on
    if not Array.isArray pattern
      throw new Error "pattern match expected pattern but saw token #{pattern.token}"
    [constr, elems...] = inside pattern
    label = "'#{constr.token}'" if constr
    trigger: isMap pattern
    cache: true
    cacheMore: (exp) -> if elems.length > 1 then ["#{exp}[#{label}]"] else []
    cond: (exp) ->
      ["#{label} in #{exp}"]
    assignTo: (exp, value) ->
      value ?= "#{exp}[#{label}]"
      recurse: (for elem, i in elems
        [elem, "#{value}[#{i}]"])
  (pattern) ->
    elems = inside pattern
    hasSplat = no
    requiredElems = 0
    for elem in elems
      if isSplat elem
        hasSplat = yes
      else
        requiredElems++
    trigger: isList pattern
    cache: true
    cond: (exp) -> ["$sequenceSize(#{exp}) #{if hasSplat then '>=' else '=='} #{requiredElems}"]
    assignTo: (exp) ->
      recurse: (for elem, i in elems
        if isSplat elem
          [elem, "$sequenceSplat(#{i}, #{elems.length - i - 1}, #{exp})"]
        else
          [elem, "$sequenceAt(#{i}, #{exp})"])
  (pattern) ->
    elems = inside pattern
    trigger: isTuple pattern
    cache: true
    cond: (exp) ->
      ["#{exp}.length == #{elems.length}"]
    assignTo: (exp, value) ->
      value ?= exp
      recurse: (for elem, i in elems
        [elem, "#{value}[#{i}]"])
  (pattern) -> throw 'unrecognized pattern in pattern matching'

]

patternMatch = (pattern, def, defCache) ->
  for rule in patternMatchingRules
    appliedRule = rule pattern
    if appliedRule.trigger
      if not defCache and appliedRule.cache
        defCache = [markCache [newVar(), def]]
      if defCache
        def = defCache[0].cache[0]
      defCache ?= []
      moreCaches = (for c in ((appliedRule.cacheMore? def) ? [])
        [newVar(), c])
      cacheNames = moreCaches.map ([n]) -> n
      assignRule = appliedRule.assignTo? def, cacheNames...
      return if not assignRule
          precs: (appliedRule.cond def).map markCond
          assigns: []
        else if not assignRule.recurse
          precs: []
          assigns: assignRule
        else
          recursed = (patternMatch p, d for [p, d] in (assignRule.recurse ? []))
          conds = ((appliedRule.cond? def) ? []).map markCond
          precs: defCache.concat(conds, moreCaches.map(markCache), (recursed.map ({precs}) -> precs)...)
          assigns: [].concat (recursed.map ({assigns}) -> assigns)...

markCond = (x) -> cond: x
markCache = (x) -> cache: x

findDeclarables = (precs) ->
  precs.filter((p) -> p.cache).map(({cache}) -> cache[0])

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


trueMacros =
  'match': (hoistableWheres, onwhat, cases...) ->
    #log printAst hoistableWheres
    varNames = []
    if not onwhat
      throw new Error 'match `onwhat` missing'
    exp = compileImpl onwhat
    compiledCases = (for [pattern, result], i in pairs cases
      control = if i is 0 then 'if' else ' else if'
      {precs, assigns} = patternMatch pattern, exp, mainCache
      vars = findDeclarables precs
      if vars.length >= 1
        mainCache = [precs[0]]
        varNames.push vars[1...]...
      else
        varNames.push vars...
      {conds, preassigns} = constructCond precs
      hoistedWheres = hoistWheres hoistableWheres, assigns
      #log "assigns", printAst assigns
      """#{control} (#{conds}) {
           #{preassigns.concat(assigns).map(compileAssign).join '\n'}
           #{hoistedWheres}
           return #{compileImpl result};
        }"""
      )
    mainCache ?= []
    mainCache = mainCache.map ({cache}) -> compileAssign cache
    varDecls = if varNames.length > 0 then ["var #{varNames.join ', '};"] else []
    content = mainCache.concat(varDecls, compiledCases.join '').join '\n'
    """(function(){
      #{content} else {throw new Error('match failed to match');}}())"""
  'require': (from, list) ->
    args = inside(list).map(compileImpl).map(toJsString).join ', '
    "$listize(window.requireModule(#{toJsString from.token}, [#{args}]))"
  'list': (items...) ->
    "$listize(#{compileList items})"

hoistWheres = (possible, assigns) ->
  defined = (n for [n, _] in assigns)
  hoisted = []
  log printAst possible
  for [pattern, def, names] in possible
    canHoist = yes
    for name in names when name not in defined
      canHoist = no
    if canHoist
      hoisted.push [pattern, def]
  if hoisted.length > 0
    compileWhereImpl hoisted
  else
    ''

toJsString = (token) ->
  "'#{token}'"

compileAssign = ([to, from]) ->
  "var #{to} = #{from};"

constructCond = (precs) ->
  return conds: ['true'], preassigns: [] if precs.length is 0
  i = 0
  lastCond = false
  cases = []
  singleCase = []
  wrapUp = ->
    cases.push if singleCase.length is 1
      singleCase[0]
    else
      "(#{singleCase.join ', '})"
  for prec, i in precs
    if i is 0 and prec.cache
      continue
    if prec.cache and lastCond
      wrapUp()
      singleCase = []
    if prec.cache
      singleCase.push "(#{prec.cache[0]} = #{prec.cache[1]})"
    else
      lastCond = yes
      singleCase.push prec.cond
  preassigns = if lastCond
    wrapUp()
    []
  else
    singleCase.map ({cache}) -> cache
  conds: cases.join " && "
  preassigns: preassigns



expandBuiltings = (mapping, cb) ->
  for op, i in mapping.from
    macros[op] = cb mapping.to[i]

unaryFnMapping =
  from: '√ alert! not empty'.split ' '
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
  if (xs.length) {
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

var $curry = function (f) {
  var _curry = function(args) {
    return f.length == 1 ? f : function(){
      var params = args ? args.concat() : [];
      return params.push.apply(params, arguments) < f.length && arguments.length
        ? _curry.call(this, params)
        : f.apply(this, params);
    };
  };
  return _curry();
};

var from__nullable = function (jsValue) {
  if (typeof jsValue === "undefined" || jsValue === null) {
    return {';none': true};
  } else {
    return {':just': [jsValue]};
  }
};

;
"""

topScopeDefines = ->
  ids = 'and_ $empty show__list from__nullable'.split ' '
    .concat unaryFnMapping.from,
      binaryOpMapping.from,
      binaryFnMapping.from,
      invertedBinaryOpMapping.from,
      invertedBinaryFnMapping.from,
      (key for own key of macros),
      (key for own key of trueMacros)
  scope = {}
  for id in ids
    scope[id] = true
  scope

exports.compile = (source) ->
  library + compileDefinitions source

exports.compileModule = (source) ->
  """
  #{library}
  var exports = {};
  #{compileDefinitionsInModule source}
  exports"""

exports.compileExp = (source) ->
  compiledExp source

exports.tokenize = (source) ->
  tokenizedDefinitions source

exports.tokenizeExp = (source) ->
  tokenizedExp source

exports.library = library

exports.walk = walk