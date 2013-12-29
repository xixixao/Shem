ometa BSJSParser {
  space        = ^space | fromTo('//', '\n') | fromTo('/*', '*/'),
  nameFirst    = letter | '$' | '_',
  nameRest     = nameFirst | digit,
  iName        = <nameFirst nameRest*>,
  isKeyword :x = ?BSJSParser._isKeyword(x),
  name         = iName:n ~isKeyword(n)                                               -> [#name, n=='self' ? '$elf' : n],
  keyword      = iName:k isKeyword(k)                                                -> [k, k],
  hexDigit     = char:x {this.hexDigits.indexOf(x.toLowerCase())}:v ?(v >= 0)        -> v,
  hexLit       = hexLit:n hexDigit:d                                                 -> (n * 16 + d)
               | hexDigit,
  number       = ``0x'' hexLit:n                                                     -> [#number, n]
               | <digit+ ('.' digit+)?>:f                                            -> [#number, parseFloat(f)],
  escapeChar   = <'\\' ( 'u' hexDigit hexDigit hexDigit hexDigit
                       | 'x' hexDigit hexDigit
                       | char                                    )>:s                -> unescape(s),
  str          = seq('"""')  (~seq('"""') char)*:cs seq('"""')                       -> [#string, cs.join('').replace('\n', "\\n")]
               | '\'' (escapeChar | ~'\'' char)*:cs '\''                             -> [#string, cs.join('')]
               | '"'  (escapeChar | ~'"'  char)*:cs '"'                              -> [#string, cs.join('')]
               | ('#' | '`') iName:n                                                 -> [#string, n],
  special      = ( '('   | ')'    | '{'    | '}'     | '['    | ']'     | ','    
                 | ';'   | '?'    | ':'    | ``!=='' | ``!='' | ``==='' | ``==''
                 | ``='' | ``>='' | '>'    | ``<=''  | '<'    | ``++''  | ``+=''
                 | '+'   | ``--'' | ``-='' | '-'     | ``*='' | '*'     | ``/=''
                 | '/'   | ``%='' | '%'    | ``&&='' | ``&&'' | ``||='' | ``||''
                 | '.'   | '!'                                                   ):s -> [s, s],
  tok          = spaces (name | keyword | number | str | special),
  toks         = token*:ts spaces end                                                -> ts,
  token :tt    = tok:t ?(t[0] == tt)                                                 -> t[1],
  spacesNoNl   = (~'\n' space)*,
  expr         = orExpr:e ( "?"   expr:t   ":" expr:f                                -> [#condExpr, e, t, f]
                          | "="   expr:rhs                                           -> [#set,  e, rhs]
                          | "+="  expr:rhs                                           -> [#mset, e, "+",  rhs]
                          | "-="  expr:rhs                                           -> [#mset, e, "-",  rhs]
                          | "*="  expr:rhs                                           -> [#mset, e, "*",  rhs]
                          | "/="  expr:rhs                                           -> [#mset, e, "/",  rhs]
                          | "%="  expr:rhs                                           -> [#mset, e, "%",  rhs]
                          | "&&=" expr:rhs                                           -> [#mset, e, "&&", rhs]
                          | "||=" expr:rhs                                           -> [#mset, e, "||", rhs]
                          | empty                                                    -> e
                          ),
  orExpr       = orExpr:x "||" andExpr:y                                             -> [#binop, "||", x, y]
               | andExpr,
  andExpr      = andExpr:x "&&" eqExpr:y                                             -> [#binop, "&&", x, y]
               | eqExpr,
  eqExpr       = eqExpr:x ( "=="  relExpr:y                                          -> [#binop, "==",  x, y]
                          | "!="  relExpr:y                                          -> [#binop, "!=",  x, y]
                          | "===" relExpr:y                                          -> [#binop, "===", x, y]
                          | "!==" relExpr:y                                          -> [#binop, "!==", x, y]
                          )
               | relExpr,
  relExpr      = relExpr:x ( ">"          addExpr:y                                  -> [#binop, ">",          x, y]
                           | ">="         addExpr:y                                  -> [#binop, ">=",         x, y]
                           | "<"          addExpr:y                                  -> [#binop, "<",          x, y]
                           | "<="         addExpr:y                                  -> [#binop, "<=",         x, y]
                           | "instanceof" addExpr:y                                  -> [#binop, "instanceof", x, y]
                           )
               | addExpr,
  addExpr      = addExpr:x "+" mulExpr:y                                             -> [#binop, "+",          x, y]
               | addExpr:x "-" mulExpr:y                                             -> [#binop, "-",          x, y]
               | mulExpr,
  mulExpr      = mulExpr:x "*" unary:y                                               -> [#binop, "*",          x, y]
               | mulExpr:x "/" unary:y                                               -> [#binop, "/",          x, y]
               | mulExpr:x "%" unary:y                                               -> [#binop, "%",          x, y]
               | unary,
  unary        = "-"      postfix:p                                                  -> [#unop,  "-",        p]
               | "+"      postfix:p                                                  -> [#unop,  "+",        p]
               | "++"     postfix:p                                                  -> [#preop, "++",       p]
               | "--"     postfix:p                                                  -> [#preop, "--",       p]
               | "!"      unary:p                                                    -> [#unop,  "!",        p]
               | "void"   unary:p                                                    -> [#unop,  "void",     p]
               | "delete" unary:p                                                    -> [#unop,  "delete",   p]
               | "typeof" unary:p                                                    -> [#unop,  "typeof",   p]
               | postfix,
  postfix      = primExpr:p ( spacesNoNl "++"                                        -> [#postop, "++", p]
                            | spacesNoNl "--"                                        -> [#postop, "--", p]
                            | empty                                                  -> p
                            ),
  primExpr     = primExpr:p ( "[" expr:i "]"                                         -> [#getp, i, p]
                            | "." "name":m "(" listOf(#expr, ','):as ")"             -> [#send, m, p].concat(as)
                            | "." "name":f                                           -> [#getp, [#string, f], p]
                            | "(" listOf(#expr, ','):as ")"                          -> [#call, p].concat(as)
                            )
               | primExprHd,
  primExprHd   = "(" expr:e ")"                                                      -> e
               | "this"                                                              -> [#this]
               | "name":n                                                            -> [#get, n]
               | "number":n                                                          -> [#number, n]
               | "string":s                                                          -> [#string, s]
               | "function" funcRest
               | "new" "name":n "(" listOf(#expr, ','):as ")"                        -> [#new, n].concat(as)
               | "[" listOf(#expr, ','):es "]"                                       -> [#arr].concat(es)
               | json
               | re,
  json         = "{" listOf(#jsonBinding, ','):bs "}"                                -> [#json].concat(bs),
  jsonBinding  = jsonPropName:n ":" expr:v                                           -> [#binding, n, v],
  jsonPropName = "name" | "number" | "string",
  re           = spaces <'/' reBody '/' reFlag*>:x                                   -> [#regExpr, x],
  reBody       = re1stChar reChar*,
  re1stChar    = ~('*' | '\\' | '/' | '[') reNonTerm
               | escapeChar
               | reClass,
  reChar       = re1stChar | '*',
  reNonTerm    = ~('\n' | '\r') char,
  reClass      = '[' reClassChar* ']',
  reClassChar  = ~('[' | ']') reChar,
  reFlag       = nameFirst,
  formal       = spaces "name",
  funcRest     = "(" listOf(#formal, ','):fs ")" "{" srcElems:body "}"               -> [#func, fs, body],
  sc           = spacesNoNl ('\n' | &'}' | end)
               | ";",
  binding      = "name":n ( "=" expr
                          | empty -> [#get, 'undefined'] ):v                         -> [#var, n, v],
  block        = "{" srcElems:ss "}"                                                 -> ss,
  stmt         = block
               | "var" listOf(#binding, ','):bs sc                                   -> [#begin].concat(bs)
               | "if" "(" expr:c ")" stmt:t ( "else" stmt
                                            | empty -> [#get, 'undefined'] ):f       -> [#if, c, t, f]
               | "while" "(" expr:c ")" stmt:s                                       -> [#while,   c, s]
               | "do" stmt:s "while" "(" expr:c ")" sc                               -> [#doWhile, s, c]
               | "for" "(" ( "var" binding
                           | expr
                           | empty -> [#get, 'undefined'] ):i
                       ";" ( expr
                           | empty -> [#get, 'true']      ):c
                       ";" ( expr
                           | empty -> [#get, 'undefined'] ):u
                       ")" stmt:s                                                    -> [#for, i, c, u, s]
               | "for" "(" ( "var" "name":n -> [#var, n, [#get, 'undefined']]
                           | expr                                             ):v
                      "in" expr:e
                       ")" stmt:s                                                    -> [#forIn, v, e, s]
               | "switch" "(" expr:e ")" "{"
                   ( "case" expr:c ":" srcElems:cs -> [#case, c, cs]
                   | "default"     ":" srcElems:cs -> [#default, cs] )*:cs
                 "}"                                                                 -> [#switch, e].concat(cs)
               | "break" sc                                                          -> [#break]
               | "continue" sc                                                       -> [#continue]
               | "throw" spacesNoNl expr:e sc                                        -> [#throw, e]
               | "try" block:t "catch" "(" "name":e ")" block:c
                             ( "finally" block
                             | empty -> [#get, 'undefined'] ):f                      -> [#try, t, e, c, f]
               | "return" ( expr
                          | empty -> [#get, 'undefined'] ):e sc                      -> [#return, e]
               | "with" "(" expr:x ")" stmt:s                                        -> [#with, x, s]
               | expr:e sc                                                           -> e
               | ";"                                                                 -> [#get, "undefined"],
  srcElem      = "function" "name":n funcRest:f                                      -> [#var, n, f]
               | stmt,
  srcElems     = srcElem*:ss                                                         -> [#begin].concat(ss),

  topLevel     = srcElems:r spaces end                                               -> r
}
BSJSParser.hexDigits = "0123456789abcdef"
BSJSParser.keywords  = { }
keywords = ["break", "case", "catch", "continue", "default", "delete", "do", "else", "finally", "for", "function", "if", "in",
            "instanceof", "new", "return", "switch", "this", "throw", "try", "typeof", "var", "void", "while", "with", "ometa"]
for (var idx = 0; idx < keywords.length; idx++)
  BSJSParser.keywords[keywords[idx]] = true
BSJSParser._isKeyword = function(k) { return this.keywords.hasOwnProperty(k) }


ometa BSSemActionParser <: BSJSParser {
  curlySemAction = "{" expr:r sc "}" spaces                                  -> r
                 | "{" (srcElem:s &srcElem -> s)*:ss
                       ( expr:r sc -> [#return, r] | srcElem):s {ss.push(s)}
                   "}" spaces                                                -> [#send, #call,
                                                                                        [#func, [], [#begin].concat(ss)],
                                                                                        [#this]],
  semAction      = curlySemAction
                 | primExpr:r spaces                                         -> r
}

ometa BSJSTranslator {
  trans      = [:t apply(t):ans]     -> ans,
  curlyTrans = [#begin curlyTrans:r] -> r
             | [#begin trans*:rs]    -> ('{' + rs.join(';') + '}')
             | trans:r               -> ('{' + r + '}'),

  this                                                  -> 'this',
  break                                                 -> 'break',
  continue                                              -> 'continue',
  number   :n                                           -> ('(' + n + ')'),
  string   :s                                           -> programString(s),
  regExpr  :x                                           -> x,
  arr      trans*:xs                                    -> ('[' + xs.join(',') + ']'),
  unop     :op trans:x                                  -> ('(' + op + ' ' + x + ')'),
  getp     trans:fd trans:x                             -> (x + '[' + fd + ']'),
  get      :x                                           -> x,
  set      trans:lhs trans:rhs                          -> ('(' + lhs + '=' + rhs + ')'),
  mset     trans:lhs :op trans:rhs                      -> ('(' + lhs + op + '=' + rhs + ')'),
  binop    :op trans:x trans:y                          -> ('(' + x + ' ' + op + ' ' + y + ')'),
  preop    :op trans:x                                  -> (op + x),
  postop   :op trans:x                                  -> (x + op),
  return   trans:x                                      -> ('return ' + x),
  with     trans:x curlyTrans:s                         -> ('with(' + x + ')' + s),
  if       trans:cond curlyTrans:t curlyTrans:e         -> ('if(' + cond + ')' + t + 'else' + e),
  condExpr trans:cond trans:t trans:e                   -> ('(' + cond + '?' + t + ':' + e + ')'),
  while    trans:cond curlyTrans:body                   -> ('while(' + cond + ')' + body),
  doWhile  curlyTrans:body trans:cond                   -> ('do' + body + 'while(' + cond + ')'),
  for      trans:init trans:cond trans:upd
           curlyTrans:body                              -> ('for(' + init + ';' + cond + ';' + upd + ')' + body),
  forIn    trans:x trans:arr curlyTrans:body            -> ('for(' + x + ' in ' + arr + ')' + body),
  begin    trans:x end                                  -> x,
  begin    (trans:x
              ( (?(x[x.length - 1] == '}') | end) -> x
              | empty                             -> (x  + ';')
              )
           )*:xs                                        -> ('{' + xs.join('') + '}'),
  func     :args curlyTrans:body                        -> ('(function (' + args.join(',') + ')' + body + ')'),
  call     trans:fn trans*:args                         -> (fn + '(' + args.join(',') + ')'),
  send     :msg trans:recv trans*:args                  -> (recv + '.' + msg + '(' + args.join(',') + ')'),
  new      :cls trans*:args                             -> ('new ' + cls + '(' + args.join(',') + ')'),
  var      :name trans:val                              -> ('var ' + name + '=' + val),
  throw    trans:x                                      -> ('throw ' + x),
  try      curlyTrans:x :name curlyTrans:c curlyTrans:f -> ('try ' + x + 'catch(' + name + ')' + c + 'finally' + f),
  json     trans*:props                                 -> ('({' + props.join(',') + '})'),
  binding  :name trans:val                              -> (programString(name) + ': ' + val),
  switch   trans:x trans*:cases                         -> ('switch(' + x + '){' + cases.join(';') + '}'),
  case     trans:x trans:y                              -> ('case ' + x + ': '+ y),
  default          trans:y                              -> ('default: ' + y)
}
