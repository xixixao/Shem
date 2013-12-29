define ->    

  ###
    new syntax:
      #foo and `foo match the string object 'foo' (it's also accepted in my JS)
      'abc'   match the string object 'abc'
      'c'     match the string object 'c'
      ``abc''   match the sequence of string objects 'a', 'b', 'c'
      "abc"   token('abc')
      [1 2 3]   match the array object [1, 2, 3]
      foo(bar)    apply rule foo with argument bar
      -> ...    semantic actions written in JS (see OMetaParser's atomicHostExpr rule)
  ###

  ###
  ometa M 
    number = number:n digit:d -> n * 10 + d.digitValue()
           | digit:d          -> d.digitValue()

  translates to...

  class M extends OMeta
    number: ->
      @_or ->
        n = @_apply("number")
        d = @_apply("digit")
        n * 10 + d.digitValue()    
      , ->
        d = @_apply("digit")
        d.digitValue()
      }
     )
    }

  (new M).matchAll("123456789", "number")
  ###

  # Some reflexive stuff

  isImmutable = (x) ->
     x == null || x == undefined || 
     typeof x == "boolean" || typeof x == "number" || typeof x == "string"

  stringDigitValue = (string) -> 
    string.charCodeAt(0) - "0".charCodeAt(0)

  isSequenceable = (x) ->
    typeof x == "string" || x.constructor == Array

  # unique tags for objects (useful for making "hash tables")
  getTag = do ->
    numIdx = 0
    (x) ->
      if not x?
        x
      switch typeof x
        when "boolean"
          if x == true then "Btrue" 
          else              "Bfalse"
        when "string"  then "S" + x
        when "number"  then "N" + x
        else
          if x.hasOwnProperty "_id_" then x._id_ 
          else                            x._id_ = "R" + numIdx++

  # streams and memoization
  class OMInputStream
    constructor: (@hd, @tl) ->
      @memo = {}
      @lst  = tl.lst
      @idx  = tl.idx
    head: -> @hd
    tail: -> @tl
    type: -> @lst.constructor
    upTo: (that) ->
      r = []
      curr = this
      while curr != that
        r.push curr.head()
        curr = curr.tail()    
      if @type() is String then r.join '' else r  

  class OMInputStreamEnd extends OMInputStream
    constructor: (@lst, @idx) ->
      @memo = {}
    head: -> throw OMeta.prototype.fail
    tail: -> throw OMeta.prototype.fail


  class ListOMInputStream extends OMInputStream
    constructor: (@lst, @idx) ->
      @memo = {}
      @hd   = lst[idx]
    head: -> @hd
    tail: -> @tl || @tl = makeStreamFrom @lst, @idx + 1

    makeStreamFrom = (lst, idx) ->
      kind = if idx < lst.length then ListOMInputStream else OMInputStreamEnd
      new kind lst, idx

    @toStream = (iterable) ->
      makeStreamFrom iterable, 0

  objectThatDelegatesTo = (x, props) ->
    f = ->
    f.prototype = x
    r = new f
    for own key, val of props
      r[key] = val        
    r

  makeOMInputStreamProxy = (target) ->  
    objectThatDelegatesTo target,
      memo:   {},
      target: target,
      tl: undefined,
      tail: -> @tl || @tl = makeOMInputStreamProxy target.tail()  

  # Failer (i.e., that which makes things fail) is used to detect (direct)
  # left recursion and memoize failures

  class Failer
    used: false

  # the OMeta "class" and basic functionality
  class OMeta
  
    # failure exception
    fail: toString: -> "match failed"    

    # input is OMListInputStream
    constructor: (@input) ->

    _apply: (rule) ->
      memoRec = @input.memo[rule]
      if memoRec == undefined
        origInput = @input
        failer    = new Failer()
        unless this[rule]?
          throw 'tried to apply undefined rule "' + rule + '"'
        @input.memo[rule] = failer
        @input.memo[rule] = memoRec =
          ans: this[rule].call(this)
          nextInput: @input
        if failer.used
          sentinel = @input
          loop
            try
              @input = origInput
              ans = this[rule].call(this)
              if @input == sentinel
                throw @fail
              memoRec.ans       = ans
              memoRec.nextInput = @input          
            catch f
              if f != @fail
                throw f
              break                  
      else if memoRec instanceof Failer
        memoRec.used = true
        throw @fail    
      @input = memoRec.nextInput
      return memoRec.ans  

    # note: _applyWithArgs and _superApplyWithArgs are not memoized, so they can't be left-recursive
    _applyWithArgs: (rule, args...) ->
      ruleFn = this[rule]
      unless ruleFn?
          throw 'tried to apply undefined rule "' + rule + '"'
      ruleFnArity = ruleFn.length
      # prepend "extra" arguments in reverse order
      for idx in [args.length - 1..ruleFnArity] by -1
        @_prependInput args[idx]        
      if ruleFnArity == 0
        ruleFn.call(this)
      else
        ruleFn.apply this, args[..ruleFnArity]
    
    @_superApplyWithArgs: (recv, rule, args...) ->
      ruleFn = @prototype[rule]
      unless ruleFn?
          throw 'tried to apply undefined rule "' + rule + '"'
      ruleFnArity = ruleFn.length
      # prepend "extra" arguments in reverse order
      for idx in [args.length - 1...ruleFnArity] by -1      
        recv._prependInput(args[idx])        
      if ruleFnArity == 0
        ruleFn.call(recv)
      else
        ruleFn.apply(recv, args[..ruleFnArity + 1])

    _prependInput: (v) ->
      @input = new OMInputStream v, @input

    # if you want your grammar (and its subgrammars) to memoize parameterized rules, invoke this method on it:
    memoizeParameterizedRules: ->
      @_prependInput = (v) ->
        newInput = null
        if isImmutable v
          newInput = @input[getTag v]
          if !newInput
            newInput = new OMInputStream v, @input
            @input[getTag v] = newInput
        else 
          newInput = new OMInputStream v, @input
        @input = newInput    
      
      @_applyWithArgs = (rule) ->
        ruleFn = this[rule]
        ruleFnArity = ruleFn.length
        # prepend "extra" arguments in reverse order
        for idx in [args.length - 1..ruleFnArity] by -1        
          @_prependInput arguments[idx]
        if ruleFnArity == 0
          @_apply(rule)
        else
          this[rule].apply this, arguments[..ruleFnArity]

    _pred: (b) ->
      if b
        return true
      throw @fail
    
    _not: (x) ->
      origInput = @input
      try
        x.call(this)
      catch f
        if f != @fail
          throw f
        @input = origInput
        return true      
      throw @fail
    
    _lookahead: (x) ->
      origInput = @input
      r         = x.call(this)
      @input = origInput
      return r
    
    _or: ->
      origInput = @input
      for arg in arguments
        try 
          @input = origInput
          return arg.call(this)
        catch f
          if f != @fail
            throw f      
      throw @fail
    
    _xor: (ruleName) ->
      origInput = @input
      idx = 1
      newInput = ans = null
      while idx < arguments.length
        try 
          @input = origInput
          ans = arguments[idx].call(this)
          if newInput
            throw 'more than one choice matched by "exclusive-OR" in ' + ruleName
          newInput = @input      
        catch f
          if f != @fail
            throw f      
        idx++    
      if newInput
        @input = newInput
        return ans    
      else
        throw @fail
    
    disableXORs: ->
      @_xor = @_or
    
    _opt: (x) ->
      origInput = @input
      ans = undefined
      try 
        ans = x.call(this)
      catch f
        if f != @fail
          throw f
        @input = origInput    
      return ans
    
    _many: (x) ->
      ans = if arguments[1] != undefined then [arguments[1]] else []
      loop
        origInput = @input
        try
          ans.push(x.call(this))
        catch f
          if f != @fail
            throw f
          @input = origInput
          break
      return ans
    
    _many1: (x) -> 
      @_many(x, x.call(this))

    _form: (x) ->
      v = @_apply("anything")
      if !isSequenceable v
        throw @fail
      origInput = @input
      @input = ListOMInputStream.toStream v
      r = x.call(this)
      @_apply("end")
      @input = origInput
      return v
    
    _consumedBy: (x) ->
      origInput = @input
      x.call(this)
      return origInput.upTo(@input)
    
    _idxConsumedBy: (x) ->
      origInput = @input
      x.call(this)    
      return [origInput.idx, @input.idx]
    
    # (mode1, part1, mode2, part2 ..., moden, partn)
    _interleave: (mode1, part1, mode2, part2) -> 
      currInput = @input
      ans = []
      for arg, idx in arguments by 2
        ans[idx / 2] = if (arg == "*" || arg == "+") then [] else undefined
      loop
        idx = 0
        allDone = true
        while idx < arguments.length
          if arguments[idx] != "0"
            try
              @input = currInput
              switch arguments[idx]
                when "*" then ans[idx / 2].push(arguments[idx + 1].call(this))
                when "+" then ans[idx / 2].push(arguments[idx + 1].call(this)); arguments[idx] = "*"
                when "?" then ans[idx / 2] =    arguments[idx + 1].call(this);  arguments[idx] = "0"
                when "1" then ans[idx / 2] =    arguments[idx + 1].call(this);  arguments[idx] = "0"
                else throw "invalid mode '" + arguments[idx] + "' in OMeta._interleave"            
              currInput = @input
              break          
            catch f
              if f != @fail
                throw f
              # if this (failed) part's mode is "1" or "+", we're not done yet
              allDone = allDone && (arguments[idx] == "*" || arguments[idx] == "?")          
          idx += 2      
        if idx == arguments.length
          if allDone
            return ans
          else
            throw @fail      
      
    _currIdx: -> @input.idx


    # Some basic rules!
    anything: ->
      r = @input.head()
      @input = @.input.tail()
      r
    
    end: ->
      @._not -> @._apply("anything")
    
    pos: ->
      @.input.idx
    
    empty: -> true 

    apply: (r) ->
      @._apply(r)
    
    foreign: (g, r) ->
      gi  = new g makeOMInputStreamProxy @.input
      ans = gi._apply(r)
      @.input = gi.input.target
      ans
    
    # some useful "derived" rules
    exactly: (wanted) ->
      if wanted == @_apply("anything")
        return wanted
      throw @fail
    
    true: ->
      r = @_apply("anything")
      @_pred(r == true)
      r
    
    false: ->
      r = @_apply("anything")
      @_pred(r == false)
      r
    
    undefined: ->
      r = @_apply("anything")
      @_pred(r == undefined)
      r
    
    number: ->
      r = @_apply("anything")
      @_pred(typeof r == "number")
      r
    
    string: ->
      r = @_apply("anything")
      @_pred(typeof r == "string")
      r
    
    char: ->
      r = @_apply("anything")
      @_pred(typeof r == "string" && r.length == 1)
      r
    
    space: ->
      r = @_apply("char")
      @_pred(r.charCodeAt(0) <= 32)
      r
    
    spaces: ->
      @_many -> @_apply("space")
    
    digit: ->
      r = @_apply("char")
      @_pred(r >= "0" && r <= "9")
      r
    
    lower: ->
      r = @_apply("char")
      @_pred(r >= "a" && r <= "z")
      r
    
    upper: ->
      r = @_apply("char")
      @_pred(r >= "A" && r <= "Z")
      r
    
    letter: ->
      @_or (-> @_apply("lower")), 
               (-> @_apply("upper"))
    
    letterOrDigit: ->
      @_or (-> @_apply("letter")),
               (-> @_apply("digit"))
    
    firstAndRest: (first, rest) ->
        @_many (-> @_apply(rest)), @_apply(first)
    
    seq: (xs) ->
      for x in xs
        @_applyWithArgs("exactly", x)
      xs
    
    notLast: (rule) ->
      r = @_apply(rule)
      @_lookahead -> @_apply(rule)
      return r
    
    listOf: (rule, delim) ->
      @_or ->
        r = @_apply(rule)
        @_many ->
          @_applyWithArgs("token", delim)
          @_apply(rule)
        , r                    
      , -> []

    token: (cs) ->
      @_apply("spaces")
      @_applyWithArgs("seq", cs)
    
    fromTo: (x, y) ->
      @_consumedBy ->
        @_applyWithArgs("seq", x)
        @_many ->
          @_not -> @_applyWithArgs("seq", y)
          @_apply("char")        
        @_applyWithArgs("seq", y)      

    initialize: ->

    # match and matchAll are a grammar's "public interface"
    @_genericMatch: (input, rule, args, matchFailed) ->
      args ?= []
      realArgs = [rule]
      for arg in args    
        realArgs.push(arg)
      m = new this input
      m.initialize()
      try 
        return if realArgs.length == 1
          m._apply.call(m, realArgs[0]) 
        else 
          m._applyWithArgs.apply(m, realArgs)
      catch f
        if f == @prototype.fail && matchFailed?
          input = m.input
          if input.idx?
            while input.tl? && input.tl.idx?
              input = input.tl
            input.idx--        
          return matchFailed(m, input.idx)      
        throw f
    
    @match: (obj, rule, args, matchFailed) ->
      @_genericMatch ListOMInputStream.toStream([obj]),    rule, args, matchFailed
    
    @matchAll: (listyObj, rule, args, matchFailed) ->
      @_genericMatch ListOMInputStream.toStream(listyObj), rule, args, matchFailed  
    
    @interpreters: {}

    #createInstance: ->
    #  m = extendWith this
    #  m.initialize()
    #  m.matchAll = (listyObj, aRule) ->
    #    @input = listyObj.toOMInputStream()
    #    @_apply(aRule)    
    #  m

  return OMeta