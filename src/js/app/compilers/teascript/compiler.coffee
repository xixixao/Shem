colorize = (color, string) ->
  "<span style=\"color: #{color}\">#{string}</span>"

keywords = 'def defn data class fn proc match if type :: \\'.split ' '

controls = '\\(\\)\\[\\]'

tokenize = (input) ->
  whitespace = ''
  loop
    match = input.match ///
      ^ # must be at the start
      (
        \s+ # pure whitespace
      | [#{controls}] # brackets
      | [^#{controls}"'\s]+ # normal tokens
      | "[^"]*?" # strings
      | '\\?[^']' # char
      )///
    break if not match
    [token] = match
    input = input[token.length...]
    if /\s+$/.test token
      whitespace = token
      continue
    ws = whitespace
    whitespace = ''
    {token, ws}

astize = (tokens) ->
  tree = []
  current = []
  stack = [[]]
  for token in tokens
    if token.token in ['(', '[']
      stack.push [token]
    else if token.token in [')', ']']
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
      ['typename', /^[A-Z]/.test token]
      ['label', /\w+:/.test token]
      ['string', /^["']/.test token]
      ['paren', token in ['(', ')']]

labelMatches = (ast) ->
  macro 'match', ast, (node, args) ->
    [keyword, over, patterns...] = args
    for pattern in patterns by 2
      labelNames pattern
    node

fnDefinition = (node) ->
  words = inside node
  [keyword, paramList, defs...] = words
  params = if paramList? then inside paramList else []
  defs ?= []
  for def, i in defs
    if matchNode '::', def
      type = def
    else if matchNode '#', def
      doc = def
    if not matchAnyNode ['::', '#'], def
      implementation = defs[i...]
      break
  {body, wheres} = fnImplementation implementation
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
    labelParams node, params
    node

labelFnBody = (node) ->
  return

labelNames = (pattern) ->
  if Array.isArray pattern
    if isList pattern
      (inside pattern).map labelNames
    else
      [op, args...] = inside pattern
      args.map labelNames
  else
    pattern.label = 'name' unless pattern.label

labelWhere = (wheres) ->
  for [name, def] in wheres
    labelNames name
    if matchNode 'fn', def
      labelRecursiveCall def, name.token
  return

labelParams = (ast, params) ->
  paramNames = (token for {token} in params)
  mapTokens paramNames, ast, (word) ->
    word.label = 'param' unless word.label

labelRecursiveCall = (ast, fnname) ->
  mapTokens [fnname], ast, (word) ->
    word.label = 'recurse'

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

typify = (ast) ->
  apply ast, typeComments, labelSimple, labelMatches, labelFns, labelComments

typifyTop = (ast) ->
  apply ast, typeComments, labelSimple, labelMatches, labelFns, labelTop, labelComments

typifyDefinitions = (ast) ->
  apply ast, typeComments, labelSimple, labelMatches, labelFns, labelDefinitions, labelComments

toHtml = (highlighted) ->
  crawl highlighted, (word) ->
    (word.ws or '') + colorize(theme[word.label ? 'normal'], word.token)

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

variableCounter = 1

# exp followed by list of definitions
compiled = (source) ->
  variableCounter = 1
  toJs typifyTop astize tokenize "(#{source})"

# single exp
compiledExp = (source) ->
  variableCounter = 1
  compileImpl typify astize tokenize source

compileDefinitions = (source) ->
  variableCounter = 1
  compileWheres typifyDefinitions astize tokenize "(#{source})"

compileComments = (ast) ->
  typedMacro 'comment', ast, (node) ->
    ''

compileList = (elems) ->
  # "[#{elems.join ', '}]"
  "$listize([#{elems.map(compileImpl).join ', '}])"

isList = (node) ->
  Array.isArray(node) and (node[0].token is '[')

isMap = (node) ->
  (isList node) and (elems = inside node; elems.length > 0) and elems[0].label is 'label'

compileImpl = (node) ->
  switch node.type
    when 'comment' then ''
    when 'function' then compileFn node
    else
      if Array.isArray node
        exps = inside node
        if isMap node
          compileMap exps
        else if isList node
          compileList exps
        else
          [op, args...] = exps
          fn = compileImpl op
          if expander = trueMacros[fn]
            expander args...
          else
            compiledArgs = args.map compileImpl
            if expander = macros[fn]
              expander compiledArgs...
            else
              # TODO: this expandMacro doesn't make sense
              "#{fn}(#{compiledArgs.map(expandMacro).join ', '})"
      else if node.token.match /^"/
        node.token
      else
        validIdentifier node.token

compileMap = (elems) ->
  [constr, args...] = elems
  "({\"#{constr.token}\": [#{args.map(compileImpl).join ', '}]})"

expandMacro = (macro) ->
  macros[macro]?() ? macro

validIdentifier = (name) ->
  if macros[name]
    expandMacro name
  else
    [minus, actualName] = name
    if minus == '-'
      "(- #{validIdentifier actualName})"
    else
      name
        .replace('+', 'plus_')
        .replace('-', 'minus_')
        .replace('*', 'times_')
        .replace('/', 'over_')
        .replace('√', 'sqrt_')
        .replace('.', 'dot_')
        .replace('&', 'and_')
        .replace(/^const$/, 'const_')

compileDef = ([name, def]) ->
  pm = patternMatch(name, compileImpl def)
  pm.precs.filter(({cache}) -> cache).map(({cache}) -> cache)
  .concat(pm.assigns).map(compileAssign).join '\n'

newVar = ->
  "i#{variableCounter++}"

compileFnImpl = (body, wheres, doReturn) ->
  [
    compileWhereImpl wheres
  ,
    if doReturn
      "return #{compileImpl body};"
    else
      compileImpl body
  ].join '\n'

compileWhereImpl = (wheres) ->
  "#{wheres.map(compileDef).reverse().join '\n'}"

getToken = (word) -> word.token

compileFn = (ast) ->
  typedMacro 'function', ast, (node) ->
    {params, body, wheres} = fnDefinition node
    """$curry(function (#{params.map(getToken).map(validIdentifier).join ', '}) {
         #{compileFnImpl body, wheres, yes}
       })"""

repeat = (x, n) ->
  new Array(n + 1).join x

patternMatchingRules = [
  (pattern) ->
    trigger: pattern.label is 'numerical'
    cond: (exp) -> ["#{exp} == #{pattern.token}"]
  (pattern) ->
    trigger: pattern.label is 'name'
    assignTo: (exp) ->
      if exp isnt identifier = validIdentifier pattern.token
        [[identifier, exp]]
      else
        []
  (pattern) ->
    trigger: matchNode '&', pattern
    cache: true
    cond: (exp) -> ["#{exp}.head"]
    assignTo: (exp) ->
      [op, head, tail] = inside pattern
      recurse: [
        [head, "#{exp}.head"]
        [tail, "#{exp}.tail"]
      ]
  (pattern) ->
    elems = inside pattern
    trigger: not isMap pattern
    cache: true
    cond: (exp) -> ["#{exp}.size() == #{elems.length}"]
    assignTo: (exp) ->
      recurse: (for elem, i in elems
        if i is 0
          [elem, "#{exp}.head"]
        else
          [elem, "#{exp}#{repeat '.tail', i}.head"])
  (pattern) ->
    [constr, elems...] = inside pattern
    label = "'#{constr.token}'"
    trigger: isMap pattern
    cache: true
    cacheMore: (exp) -> if elems.length > 1 then ["#{exp}[#{label}]"] else []
    cond: (exp) ->
      ["#{label} in #{exp}"]
    assignTo: (exp, value) ->
      value ?= "#{exp}[#{label}]"
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

trueMacros =
  'match': (onwhat, cases...) ->
    varNames = []
    exp = compileImpl onwhat
    compiledCases = (for [pattern, result], i in pairs cases
      control = if i is 0 then 'if' else ' else if'
      {precs, assigns} = patternMatch pattern, exp, mainCache
      vars = findDeclarables precs
      if vars.length is 1
        mainCache = [precs[0]]
        varNames.push vars[1...]...
      else
        varNames.push vars...
      {conds, preassigns} = constructCond precs
      """#{control} (#{conds}) {
           #{preassigns.concat(assigns).map(compileAssign).join '\n'}
           return #{compileImpl result};
        }"""
      )
    mainCache ?= []
    mainCache = mainCache.map ({cache}) -> compileAssign cache
    varDecls = if varNames.length > 0 then ["var #{varNames.join ', '};"] else []
    content = mainCache.concat(varDecls, compiledCases.join '').join '\n'

    """(function(){
      #{content}}())"""

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
  from: '√ alert! not'.split ' '
  to: 'Math.sqrt window.log !'.split ' '

expandBuiltings unaryFnMapping, (to) ->
  (x) ->
    if x
      "#{to}(#{x})"
    else
      "function(__a){return #{to}(__a);}"

binaryFnMapping =
  from: '^'.split ' '
  to: 'Math.pow'.split ' '

expandBuiltings binaryFnMapping, (to) ->
  (x, y) ->
    if x and y
      "#{to}(#{x}, #{y})"
    else if x
      "function(__b){return #{to}(#{a}, __b);}"
    else
      "function(__a, __b){return #{to}(__a, __b);}"

binaryOpMapping =
  from: '+ - / * = rem != and or'.split ' '
  to: '+ - / * == % != && ||'.split ' '

expandBuiltings binaryOpMapping, (to) ->
  (x, y) ->
    if x and y
      "(#{x} #{to} #{y})"
    else if x
      "function(__b){return #{x} #{to} __b;}"
    else
      "function(__a, __b){return __a #{to} __b;}"

compileTop = (ast) ->
  {body, wheres} = fnImplementation inside ast
  compileFnImpl body, wheres

compileWheres = (ast) ->
  wheres = whereList inside ast
  compileWhereImpl wheres

toJs = (typified) ->
  compileTop typified


library = """
var $listize = function (list) {
  if (list.length == 0) {
   x = [];
   x.size = function() { return 0 };
   return x;
  }
  return and_(list[0], $listize(list.splice(1)));
};

var and_ = function (x, xs) {
  return {
    head: x,
    tail: xs,
    size: function() {
      return 1 + this.tail.size();
    }
  };
}

var showminus_list = function (x) {
  var t = [];
  while (x.length != 0) {
    t.push(x.head);
    x = x.tail;
  }
  return t;
}

$curry = function (f) {
  _curry = function(args) {
    return f.length == 1 ? f : function(){
      var params = args ? args.concat() : [];
      return params.push.apply(params, arguments) < f.length && arguments.length
        ? _curry.call(this, params)
        : f.apply(this, params);
    };
  };
  return _curry();
};
"""

exports.compile = (source) ->
  library + compileDefinitions source

exports.compileExp = (source) ->
  compiledExp source
