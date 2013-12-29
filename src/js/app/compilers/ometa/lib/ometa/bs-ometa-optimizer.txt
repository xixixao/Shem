// TODO: turn off the "seq" inliner when G.seq !== OMeta.seq (will require some refactoring)
// TODO: add a factorizing optimization (will make jumptables more useful)

ometa BSNullOptimization {
  setHelped = !(this._didSomething = true),
  helped    = ?this._didSomething,
  trans     = [:t ?(this[t] != undefined) apply(t):ans] -> ans,
  optimize  = trans:x helped                         -> x,

  App        :rule anything*:args          -> ['App', rule].concat(args),
  Act        :expr                         -> ['Act', expr],
  Pred       :expr                         -> ['Pred', expr],
  Or         trans*:xs                     -> ['Or'].concat(xs),
  XOr        trans*:xs                     -> ['XOr'].concat(xs),
  And        trans*:xs                     -> ['And'].concat(xs),
  Opt        trans:x                       -> ['Opt',  x],
  Many       trans:x                       -> ['Many',  x],
  Many1      trans:x                       -> ['Many1', x],
  Set        :n trans:v                    -> ['Set', n, v],
  Not        trans:x                       -> ['Not',       x],
  Lookahead  trans:x                       -> ['Lookahead', x],
  Form       trans:x                       -> ['Form',      x],
  ConsBy     trans:x                       -> ['ConsBy',    x],
  IdxConsBy  trans:x                       -> ['IdxConsBy', x],
  JumpTable  ([:c trans:e] -> [c, e])*:ces -> ['JumpTable'].concat(ces),
  Interleave ([:m trans:p] -> [m, p])*:xs  -> ['Interleave'].concat(xs),
  Rule       :name :ls trans:body          -> ['Rule', name, ls, body]
}
BSNullOptimization.initialize = function() { this._didSomething = false }

ometa BSAssociativeOptimization <: BSNullOptimization {
  And trans:x end           setHelped -> x,
  And transInside('And'):xs           -> ['And'].concat(xs),
  Or  trans:x end           setHelped -> x,
  Or  transInside('Or'):xs            -> ['Or'].concat(xs),
  XOr trans:x end           setHelped -> x,
  XOr transInside('XOr'):xs           -> ['XOr'].concat(xs),

  transInside :t = [exactly(t) transInside(t):xs] transInside(t):ys setHelped -> xs.concat(ys)
                 | trans:x                        transInside(t):xs           -> [x].concat(xs)
                 |                                                            -> []
}

ometa BSSeqInliner <: BSNullOptimization {
  App        = 'seq' :s end seqString(s):cs setHelped -> ['And'].concat(cs).concat([['Act', s]])
             | :rule anything*:args                   -> ['App', rule].concat(args),
  inlineChar = BSOMetaParser.eChar:c ~end             -> ['App', 'exactly', c.toProgramString()],
  seqString  = &(:s ?(typeof s === 'string'))
                 ( ['"'  inlineChar*:cs '"' ]         -> cs
                 | ['\'' inlineChar*:cs '\'']         -> cs
                 )
}

JumpTable = function(choiceOp, choice) {
  this.choiceOp = choiceOp
  this.choices = {}
  this.add(choice)
}
JumpTable.prototype.add = function(choice) {
  var c = choice[0], t = choice[1]
  if (this.choices[c]) {
    if (this.choices[c][0] == this.choiceOp)
      this.choices[c].push(t)
    else
      this.choices[c] = [this.choiceOp, this.choices[c], t]
  }
  else
    this.choices[c] = t
}
JumpTable.prototype.toTree = function() {
  var r = ['JumpTable'], choiceKeys = ownPropertyNames(this.choices)
  for (var i = 0; i < choiceKeys.length; i += 1)
    r.push([choiceKeys[i], this.choices[choiceKeys[i]]])
  return r
}
ometa BSJumpTableOptimization <: BSNullOptimization {
  Or  (jtChoices('Or')  | trans)*:cs -> ['Or'].concat(cs),
  XOr (jtChoices('XOr') | trans)*:cs -> ['XOr'].concat(cs),
  quotedString  = &string [ '"'  (BSOMetaParser.eChar:c ~end -> c)*:cs '"'
                          | '\'' (BSOMetaParser.eChar:c ~end -> c)*:cs '\'']               -> cs.join(''),
  jtChoice      = ['And' ['App' 'exactly' quotedString:x] anything*:rest]                  -> [x, ['And'].concat(rest)]
                |        ['App' 'exactly' quotedString:x]                                  -> [x, ['Act', x.toProgramString()]],
  jtChoices :op = jtChoice:c {new JumpTable(op, c)}:jt (jtChoice:c {jt.add(c)})* setHelped -> jt.toTree()
}

ometa BSOMetaOptimizer {
  optimizeGrammar = ['Grammar' :n :sn optimizeRule*:rs]          -> ['Grammar', n, sn].concat(rs),
  optimizeRule    = :r (BSSeqInliner.optimize(r):r | empty)
                       ( BSAssociativeOptimization.optimize(r):r
                       | BSJumpTableOptimization.optimize(r):r
                       )*                                        -> r
}

