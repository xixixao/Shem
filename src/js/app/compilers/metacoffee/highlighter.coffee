###
Link to the project's GitHub page:
https://github.com/pickhardt/coffeescript-codemirror-mode
###

define ['../../codemirror/codemirror'], (CodeMirror) ->
  CodeMirror.defineMode "metacoffee", (conf) ->
    ERRORCLASS = 'error'

    wordRegexp = (words) ->
      new RegExp "^((" + words.join(")|(") + "))\\b"



    singleOperators = new RegExp "^[\\+\\-\\*/%&|\\^~<>!?]"
    #var singleDelimiters = new RegExp '^[\\(\\)\\[\\]\\{\\}@,:`=;\\.]';
    singleDelimiters = new RegExp "^[\\(\\)@,`;\\.]"
    doubleOperators = new RegExp "^((=)|(:)|(->)|(=>)|(\\+\\+)|(\\+\\=)|(\\-\\-)|(\\-\\=)|(\\*\\*)|(\\*\\=)|(\\/\\/)|(\\/\\=)|(==)|(!=)|(<=)|(>=)|(<>)|(<<)|(>>)|(//))"
    doubleDelimiters = new RegExp "^((\\.\\.)|(\\+=)|(\\-=)|(\\*=)|(%=)|(/=)|(&=)|(\\|=)|(\\^=)|(&&=)|(\\||=))"
    tripleDelimiters = new RegExp "^((\\.\\.\\.)|(//=)|(>>=)|(<<=)|(\\*\\*=))"
    parenConstructors = new RegExp "^[\\[\\]\\{\\}]"

    constantIdentifiers = new RegExp "^[_A-Z$][_A-Z$0-9]+\\b"
    classIdentifiers = new RegExp "^[_A-Z$][_A-Za-z$0-9]*"
    identifiers = new RegExp "^[_a-z$][_A-Za-z$0-9]*"

    field = new RegExp "^@[_A-Za-z$][_A-Za-z$0-9]*"


    functionIdentifier = new RegExp "^[_a-z$][_A-Za-z$0-9]*\\s?(:|=)\\s?(\\([_A-Za-z$0-9@,=\\.\\[\\]\\s]*\\)\\s*)?((->)|(=>))"
    functionDeclaration = new RegExp "^(\\([_A-Za-z$0-9@,=\\.\\[\\]\\s]*\\)\\s*)?((->)|(=>))"

    wordOperators = wordRegexp ['and', 'or', 'not',
                                'is', 'isnt', 'in',
                                'instanceof', 'typeof']
    indentKeywords = ['for', 'while', 'loop', 'if', 'unless', 'else',
                      'switch', 'try', 'catch', 'finally', 'class']
    commonKeywords = ['break', 'by', 'continue', 'delete',
                      'do', 'in', 'of', 'new', 'return', 'then',
                      'throw', 'when', 'until', 'extends']

    otherKeywords = wordRegexp ['debugger', 'this']

    keywords = wordRegexp indentKeywords.concat(commonKeywords)

    indentKeywords = wordRegexp indentKeywords


    stringPrefixes = new RegExp "^('{3}|\"{3}|['\"])"
    regexPrefixes = new RegExp "^(/{3}|/)"
    commonConstants = ["Infinity", "NaN", "undefined", "null", "true", "false", "on", "off", "yes", "no"]
    constants = wordRegexp commonConstants

    # Tokenizers
    tokenBase = (stream, state) ->
      # Handle scope changes
      if stream.sol()
        scopeOffset = state.scopes[0].offset
        if stream.eatSpace()
          lineOffset = stream.indentation()
          if lineOffset > scopeOffset
            return 'indent'
          else if lineOffset < scopeOffset
             return 'dedent'
          return null
        else if scopeOffset > 0
          dedent stream, state
      if stream.eatSpace()
        return null

      ch = stream.peek()

      # Handle multi line comments
      if stream.match "###"
        state.tokenize = longComment
        return state.tokenize stream, state

      # Single line comment
      if ch is "#"
        stream.skipToEnd()
        return "comment"

      # Handle number literals
      if stream.match /^-?[0-9\.]/, false
        floatLiteral = false

        # Floats
        if (stream.match /^-?\d*\.\d+(e[\+\-]?\d+)?/i) ||
           (stream.match /^-?\d+\.\d*/) ||
           (stream.match /^-?\.\d+/)
          floatLiteral = true

        if floatLiteral
          # prevent from getting extra . on 1..
          if stream.peek() is "."
            stream.backUp 1
          return "number"

        # Integers
        if (stream.match /^-?0x[0-9a-f]+/i) ||
           (stream.match /^-?[1-9]\d*(e[\+\-]?\d+)?/) ||
           (stream.match /^-?0(?![\dx])/i)
          return "number"

      # Handle strings
      if stream.match stringPrefixes
        state.tokenize = tokenFactory stream.current(), "string"
        return state.tokenize stream, state

      # Handle regex literals
      if stream.match regexPrefixes
        # prevent highlight of division
        if stream.current() isnt "/" or stream.match /^.*\//, false
          state.tokenize = regexToken stream.current(), "string-2"
          return state.tokenize stream, state
        else
          stream.backUp 1

      # Handle function definitions
      if stream.match functionIdentifier, false
        stream.match identifiers
        return "functionid"

      # Handle operators and delimiters
      token = simpleTokenMatcher stream, [
        "functiondec", functionDeclaration
        "field", field
        "operator", tripleDelimiters, doubleDelimiters
        "operator", doubleOperators, singleOperators, wordOperators
        "punctuation", singleDelimiters
        "atom", constants
        "keyword", keywords
        "keyword2", otherKeywords
        "constructor", parenConstructors
        "constant", constantIdentifiers
        "classname", classIdentifiers
        "variable", identifiers
      ]
      if token
        return token

      # Handle non-detected items
      stream.next()
      return ERRORCLASS

    simpleTokenMatcher = (stream, keysForPatterns) ->
      token = ""
      tokenMatches = false
      for item in keysForPatterns
        if typeof item is 'string'
          if tokenMatches
            break
          token = item
          tokenMatches = false
        else
          tokenMatches ||= stream.match item

      if tokenMatches then token else null

    tokenFactory = (delimiter, outclass) ->
      boundaryToken delimiter, outclass

    regexToken = (delimiter, outclass) ->
      boundaryToken delimiter, outclass, (stream) ->
        stream.match /^[igm]*\b/

    boundaryToken = (delimiter, outclass, suffix) ->
      singleline = delimiter.length is 1
      # tokenString
      return (stream, state) ->
        until stream.eol()
          stream.eatWhile /[^'"\/\\]/
          if stream.eat("\\")
            stream.next()
            if singleline and stream.eol()
              return outclass
          else if stream.match delimiter
            state.tokenize = tokenBase
            # include suffix (f.e. after regex literal)
            if suffix
              suffix stream
            return outclass
          else
            stream.eat /['"\/]/
        if singleline
          if conf.mode.singleLineStringErrors
            outclass = ERRORCLASS
          else
            state.tokenize = tokenBase
        outclass

    longComment = (stream, state) ->
      until stream.eol()
        stream.eatWhile /[^#]/
        if stream.match("###")
          state.tokenize = tokenBase
          break
        stream.eatWhile "#"
      "comment"

    indent = (stream, state, type) ->
      type = type or "coffee"
      indentUnit = 0
      if type is "coffee"
        for scope in state.scopes
          if scope.type is "coffee"
            indentUnit = scope.offset + conf.indentUnit
            break
      else
        indentUnit = stream.column() + stream.current().length

      state.scopes.unshift
        offset: indentUnit
        type: type

    dedent = (stream, state) ->
      return if state.scopes.length is 1

      if state.scopes[0].type is "coffee"
        _indent = stream.indentation()
        _indent_index = -1

        for scope, i in state.scopes
          if _indent is scope.offset
            _indent_index = i
            break

        if _indent_index is -1
          return true

        while state.scopes[0].offset isnt _indent
          state.scopes.shift()
        return false
      else
        state.scopes.shift()
        return false

    tokenLexer = (stream, state) ->
      style = state.tokenize stream, state
      current = stream.current()

      # Handle '.' connected identifiers
      if current is "."
        style = state.tokenize stream, state
        current = stream.current()

        if anyIs ["variable", "constant", "classname", "functionid"], style
          return style
        else
          return ERRORCLASS

      # Handle properties
      if current is "@"
        stream.eat "@"
        return "keyword"

      # Handle scope changes.
      if current is "return"
        state.dedent += 1
      if ((current is "->" or current is "=>") and
          not state.lambda and
          state.scopes[0].type is "coffee" and
          stream.peek() is "") or
         style is "indent"
        indent stream, state

      delimiter_index = "[({".indexOf current
      if delimiter_index isnt -1
        indent stream, state, "])}".slice delimiter_index, delimiter_index + 1
      if indentKeywords.exec(current)
        indent stream, state
      if current is "then"
        dedent stream, state

      if style is "dedent" and dedent stream, state
        return ERRORCLASS
      delimiter_index = "])}".indexOf current
      if delimiter_index isnt -1 and dedent stream, state
        return ERRORCLASS
      if state.dedent > 0 and stream.eol() and state.scopes[0].type is "coffee"
        if state.scopes.length > 1
          state.scopes.shift()
        state.dedent -= 1

      return style

    anyIs = (list, what) ->
      for item in list
        if item is what
          return true
      false

    # external

    startState: (basecolumn) ->
      tokenize: tokenBase
      scopes: [
        offset: basecolumn or 0
        type: "coffee"
      ]
      lastToken: null
      lambda: false
      dedent: 0

    token: (stream, state) ->
      style = tokenLexer stream, state
      state.lastToken =
        style: style
        content: stream.current()

      if stream.eol() and stream.lambda
        state.lambda = false

      return style

    indent: (state, textAfter) ->
      if state.tokenize isnt tokenBase
        return 0
      return state.scopes[0].offset

  CodeMirror.defineMIME "text/x-coffeescript", "coffeescript"