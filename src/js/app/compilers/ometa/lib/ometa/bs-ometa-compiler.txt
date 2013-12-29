ometa BSOMetaParser {
  space          = ^space | fromTo('//', '\n') | fromTo('/*', '*/'),
  nameFirst      = '_' | '$' | letter,
  nameRest       = nameFirst | digit,
  tsName         = <nameFirst nameRest*>,
  name           = spaces tsName,
  hexDigit       = char:x {this.hexDigits.indexOf(x.toLowerCase())}:v
                                                             ?(v >= 0) -> v,
  eChar          = <'\\' ( 'u' hexDigit hexDigit hexDigit hexDigit
                         | 'x' hexDigit hexDigit
                         | char                                   )>:s -> unescape(s)
                 | char,
  tsString       = '\'' (~'\'' eChar)*:xs '\''                         -> xs.join(''),
  characters     = '`' '`' (~('\'' '\'') eChar)*:xs '\'' '\''          -> [#App, #seq,     programString(xs.join(''))],
  sCharacters    = '"'     (~'"'         eChar)*:xs '"'                -> [#App, #token,   programString(xs.join(''))],
  string         = (('#' | '`') tsName | tsString):xs                  -> [#App, #exactly, programString(xs)],
  number         = <'-'? digit+>:n                                     -> [#App, #exactly, n],
  keyword :xs    = token(xs) ~letterOrDigit                            -> xs,
  args           = '(' listOf(#hostExpr, ','):xs ")"                   -> xs
                 | empty                                               -> [],
  application    = "^"          name:rule args:as                      -> [#App, "super",        "'" + rule + "'"].concat(as)
                 | name:grm "." name:rule args:as                      -> [#App, "foreign", grm, "'" + rule + "'"].concat(as)
                 |              name:rule args:as                      -> [#App, rule].concat(as),
  hostExpr       = BSSemActionParser.expr:r                               BSJSTranslator.trans(r),
  curlyHostExpr  = BSSemActionParser.curlySemAction:r                     BSJSTranslator.trans(r),
  primHostExpr   = BSSemActionParser.semAction:r                          BSJSTranslator.trans(r),
  atomicHostExpr = curlyHostExpr | primHostExpr,
  semAction      = curlyHostExpr:x                                     -> [#Act, x]
                 | "!"  atomicHostExpr:x                               -> [#Act, x],
  arrSemAction   = "->" atomicHostExpr:x                               -> [#Act, x],
  semPred        = "?"  atomicHostExpr:x                               -> [#Pred, x],
  expr           = expr5(true):x ("|"  expr5(true))+:xs                -> [#Or,  x].concat(xs)
                 | expr5(true):x ("||" expr5(true))+:xs                -> [#XOr, x].concat(xs)
                 | expr5(false),
  expr5 :ne      = interleavePart:x ("&&" interleavePart)+:xs          -> [#Interleave, x].concat(xs)
                 | expr4(ne),
  interleavePart = "(" expr4(true):part ")"                            -> ["1", part]
                 | expr4(true):part modedIPart(part),
  modedIPart     = [#And [#Many  :part]]                               -> ["*", part]
                 | [#And [#Many1 :part]]                               -> ["+", part]
                 | [#And [#Opt   :part]]                               -> ["?", part]
                 | :part                                               -> ["1", part],
  expr4 :ne      =                expr3*:xs arrSemAction:act           -> [#And].concat(xs).concat([act])
                 | ?ne            expr3+:xs                            -> [#And].concat(xs)
                 | ?(ne == false) expr3*:xs                            -> [#And].concat(xs),
  optIter :x     = '*'                                                 -> [#Many,  x]
                 | '+'                                                 -> [#Many1, x]
                 | '?'                                                 -> [#Opt,   x]
                 | empty                                               -> x,
  optBind :x     = ':' name:n                                          -> { this.locals[n] = true; [#Set, n, x] }
                 | empty                                               -> x,
  expr3          = ":" name:n                                          -> { this.locals[n] = true; [#Set, n, [#App, #anything]] }
                 | (expr2:x optIter(x) | semAction):e optBind(e)
                 | semPred,
  expr2          = "~" expr2:x                                         -> [#Not,       x]
                 | "&" expr1:x                                         -> [#Lookahead, x]
                 | expr1,
  expr1          = application 
                 | ( keyword('undefined') | keyword('nil')
                   | keyword('true')      | keyword('false') ):x       -> [#App, #exactly, x]
                 | spaces (characters | sCharacters | string | number)
                 | "["  expr:x "]"                                     -> [#Form,      x]
                 | "<"  expr:x ">"                                     -> [#ConsBy,    x]
                 | "@<" expr:x ">"                                     -> [#IdxConsBy, x]
                 | "("  expr:x ")"                                     -> x,
  ruleName       = name
                 | spaces tsString,
  rule           = &(ruleName:n) !(this.locals = {'$elf=this': true, '_fromIdx=this.input.idx': true})
                     rulePart(n):x ("," rulePart(n))*:xs               -> [#Rule, n, propertyNames(this.locals),
                                                                            [#Or, x].concat(xs)],
  rulePart :rn   = ruleName:n ?(n == rn) expr4(false):b1 ( "=" expr:b2 -> [#And, b1, b2]
                                                         | empty       -> b1
                                                         ),
  grammar        = keyword('ometa') name:n
                     ( "<:" name | empty -> 'OMeta' ):sn
                     "{" listOf(#rule, ','):rs "}"                        BSOMetaOptimizer.optimizeGrammar(
                                                                            [#Grammar, n, sn].concat(rs)
                                                                          )
}
BSOMetaParser.hexDigits = "0123456789abcdef"

// By dispatching on the head of a list, the following idiom allows translators to avoid doing a linear search.
// (Note that the "=" in a rule definition is optional, so you can give your rules an "ML feel".)
ometa BSOMetaTranslator {
  App        'super' anything+:args        -> [this.sName, '._superApplyWithArgs(this,', args.join(','), ')']      .join(''),
  App        :rule   anything+:args        -> ['this._applyWithArgs("', rule, '",',      args.join(','), ')']      .join(''),
  App        :rule                         -> ['this._apply("', rule, '")']                                        .join(''),
  Act        :expr                         -> expr,
  Pred       :expr                         -> ['this._pred(', expr, ')']                                           .join(''),
  Or         transFn*:xs                   -> ['this._or(',  xs.join(','), ')']                                    .join(''),
  XOr        transFn*:xs                       {xs.unshift(programString(this.name + "." + this.rName))}
                                           -> ['this._xor(', xs.join(','), ')']                                    .join(''),
  And        notLast(#trans)*:xs trans:y
             {xs.push('return ' + y)}      -> ['(function(){', xs.join(';'), '}).call(this)']                      .join(''),
  And                                      -> 'undefined',
  Opt        transFn:x                     -> ['this._opt(',           x, ')']                                     .join(''),
  Many       transFn:x                     -> ['this._many(',          x, ')']                                     .join(''),
  Many1      transFn:x                     -> ['this._many1(',         x, ')']                                     .join(''),
  Set        :n trans:v                    -> [n, '=', v]                                                          .join(''),
  Not        transFn:x                     -> ['this._not(',           x, ')']                                     .join(''),
  Lookahead  transFn:x                     -> ['this._lookahead(',     x, ')']                                     .join(''),
  Form       transFn:x                     -> ['this._form(',          x, ')']                                     .join(''),
  ConsBy     transFn:x                     -> ['this._consumedBy(',    x, ')']                                     .join(''),
  IdxConsBy  transFn:x                     -> ['this._idxConsumedBy(', x, ')']                                     .join(''),
  JumpTable  jtCase*:cases                 -> this.jumpTableCode(cases),
  Interleave intPart*:xs                   -> ['this._interleave(', xs.join(','), ')']                             .join(''),
  
  Rule       :name {this.rName = name}
             locals:ls trans:body          -> ['\n"', name, '":function(){', ls, 'return ', body, '}']             .join(''),
  Grammar    :name :sName
             {this.name = name}
             {this.sName = sName}
             trans*:rules                  -> [name, '=subclass(', sName, ',{', rules.join(','), '});'].join(''),
  intPart  = [:mode transFn:part]          -> (programString(mode)  + "," + part),
  jtCase   = [:x trans:e]                  -> [programString(x), e],
  locals   = [string+:vs]                  -> ['var ', vs.join(','), ';']                                          .join('')
           | []                            -> '',
  trans    = [:t apply(t):ans]             -> ans,
  transFn  = trans:x                       -> ['(function(){return ', x, '})']                                     .join('')
}
BSOMetaTranslator.jumpTableCode = function(cases) {
  var buf = new StringBuffer()
  buf.nextPutAll("(function(){switch(this._apply('anything')){")
  for (var i = 0; i < cases.length; i += 1)
    buf.nextPutAll("case " + cases[i][0] + ":return " + cases[i][1] + ";")
  buf.nextPutAll("default: throw fail}}).call(this)")
  return buf.contents()
}