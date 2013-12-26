
/*
Link to the project's GitHub page:
https://github.com/pickhardt/coffeescript-codemirror-mode
*/


(function() {

  define(['vendor/codemirror/codemirror'], function(CodeMirror) {
    CodeMirror.defineMode("command", function(conf) {
      var ERRORCLASS, anyIs, boundaryToken, classIdentifiers, commonConstants, commonKeywords, constantIdentifiers, constants, dedent, doubleDelimiters, doubleOperators, field, functionDeclaration, functionIdentifier, icedKeywords, identifiers, indent, indentKeywords, keywords, longComment, otherKeywords, parenConstructors, regexPrefixes, regexToken, simpleTokenMatcher, singleDelimiters, singleOperators, stringPrefixes, tokenBase, tokenFactory, tokenLexer, tripleDelimiters, wordOperators, wordRegexp;
      ERRORCLASS = 'error';
      wordRegexp = function(words) {
        return new RegExp("^((" + words.join(")|(") + "))\\b");
      };
      singleOperators = new RegExp("^[\\+\\-\\*/%&|\\^~<>!?]");
      singleDelimiters = new RegExp("^[\\(\\)@,`;\\.]");
      doubleOperators = new RegExp("^((=)|(:)|(->)|(=>)|(\\+\\+)|(\\+\\=)|(\\-\\-)|(\\-\\=)|(\\*\\*)|(\\*\\=)|(\\/\\/)|(\\/\\=)|(==)|(!=)|(<=)|(>=)|(<>)|(<<)|(>>)|(//))");
      doubleDelimiters = new RegExp("^((\\.\\.)|(\\+=)|(\\-=)|(\\*=)|(%=)|(/=)|(&=)|(\\|=)|(\\^=)|(&&=)|(\\||=))");
      tripleDelimiters = new RegExp("^((\\.\\.\\.)|(//=)|(>>=)|(<<=)|(\\*\\*=))");
      parenConstructors = new RegExp("^[\\[\\]\\{\\}]");
      constantIdentifiers = new RegExp("^[_A-Z$][_A-Z$0-9]+\\b");
      classIdentifiers = new RegExp("^[_A-Z$][_A-Za-z$0-9]*");
      identifiers = new RegExp("^[_a-z$][_A-Za-z$0-9]*");
      field = new RegExp("^@[_A-Za-z$][_A-Za-z$0-9]*");
      functionIdentifier = new RegExp("^[_a-z$][_A-Za-z$0-9]*\\s?(:|=)\\s?(\\([_A-Za-z$0-9@,=\\.\\[\\]\\s]*\\)\\s*)?((->)|(=>))");
      functionDeclaration = new RegExp("^(\\([_A-Za-z$0-9@,=\\.\\[\\]\\s]*\\)\\s*)?((->)|(=>))");
      wordOperators = wordRegexp(['and', 'or', 'not', 'is', 'isnt', 'in', 'instanceof', 'typeof']);
      indentKeywords = ['for', 'while', 'loop', 'if', 'unless', 'else', 'switch', 'try', 'catch', 'finally', 'class'];
      commonKeywords = ['break', 'by', 'continue', 'delete', 'do', 'in', 'of', 'new', 'return', 'then', 'throw', 'when', 'until', 'extends'];
      otherKeywords = wordRegexp(['debugger', 'this']);
      icedKeywords = wordRegexp(['await', 'defer']);
      keywords = wordRegexp(indentKeywords.concat(commonKeywords));
      indentKeywords = wordRegexp(indentKeywords);
      stringPrefixes = new RegExp("^('{3}|\"{3}|['\"])");
      regexPrefixes = new RegExp("^(/{3}|/)");
      commonConstants = ["Infinity", "NaN", "undefined", "null", "true", "false", "on", "off", "yes", "no"];
      constants = wordRegexp(commonConstants);
      tokenBase = function(stream, state) {
        var ch, floatLiteral, lineOffset, scopeOffset, token;
        if (stream.sol()) {
          scopeOffset = state.scopes[0].offset;
          if (stream.eatSpace()) {
            lineOffset = stream.indentation();
            if (lineOffset > scopeOffset) {
              return 'indent';
            } else if (lineOffset < scopeOffset) {
              return 'dedent';
            }
            return null;
          } else if (scopeOffset > 0) {
            dedent(stream, state);
          }
        }
        if (stream.eatSpace()) {
          return null;
        }
        ch = stream.peek();
        if (stream.match("###")) {
          state.tokenize = longComment;
          return state.tokenize(stream, state);
        }
        if (ch === "#") {
          stream.skipToEnd();
          return "comment";
        }
        if (stream.match(/^-?[0-9\.]/, false)) {
          floatLiteral = false;
          if ((stream.match(/^-?\d*\.\d+(e[\+\-]?\d+)?/i)) || (stream.match(/^-?\d+\.\d*/)) || (stream.match(/^-?\.\d+/))) {
            floatLiteral = true;
          }
          if (floatLiteral) {
            if (stream.peek() === ".") {
              stream.backUp(1);
            }
            return "number";
          }
          if ((stream.match(/^-?0x[0-9a-f]+/i)) || (stream.match(/^-?[1-9]\d*(e[\+\-]?\d+)?/)) || (stream.match(/^-?0(?![\dx])/i))) {
            return "number";
          }
        }
        if (stream.match(stringPrefixes)) {
          state.tokenize = tokenFactory(stream.current(), "string");
          return state.tokenize(stream, state);
        }
        if (stream.match(regexPrefixes)) {
          if (stream.current() !== "/" || stream.match(/^.*\//, false)) {
            state.tokenize = regexToken(stream.current(), "string-2");
            return state.tokenize(stream, state);
          } else {
            stream.backUp(1);
          }
        }
        if (stream.match(functionIdentifier, false)) {
          stream.match(identifiers);
          return "functionid";
        }
        token = simpleTokenMatcher(stream, ["functiondec", functionDeclaration, "field", field, "operator", tripleDelimiters, doubleDelimiters, "operator", doubleOperators, singleOperators, wordOperators, "punctuation", singleDelimiters, "atom", constants, "keyword", keywords, "keyword2", otherKeywords, "keyword3", icedKeywords, "constructor", parenConstructors, "constant", constantIdentifiers, "classname", classIdentifiers, "variable", identifiers]);
        if (token) {
          return token;
        }
        stream.next();
        return ERRORCLASS;
      };
      simpleTokenMatcher = function(stream, keysForPatterns) {
        var item, token, tokenMatches, _i, _len;
        token = "";
        tokenMatches = false;
        for (_i = 0, _len = keysForPatterns.length; _i < _len; _i++) {
          item = keysForPatterns[_i];
          if (typeof item === 'string') {
            if (tokenMatches) {
              break;
            }
            token = item;
            tokenMatches = false;
          } else {
            tokenMatches || (tokenMatches = stream.match(item));
          }
        }
        if (tokenMatches) {
          return token;
        } else {
          return null;
        }
      };
      tokenFactory = function(delimiter, outclass) {
        return boundaryToken(delimiter, outclass);
      };
      regexToken = function(delimiter, outclass) {
        return boundaryToken(delimiter, outclass, function(stream) {
          return stream.match(/^[igm]*\b/);
        });
      };
      boundaryToken = function(delimiter, outclass, suffix) {
        var singleline;
        singleline = delimiter.length === 1;
        return function(stream, state) {
          while (!stream.eol()) {
            stream.eatWhile(/[^'"\/\\]/);
            if (stream.eat("\\")) {
              stream.next();
              if (singleline && stream.eol()) {
                return outclass;
              }
            } else if (stream.match(delimiter)) {
              state.tokenize = tokenBase;
              if (suffix) {
                suffix(stream);
              }
              return outclass;
            } else {
              stream.eat(/['"\/]/);
            }
          }
          if (singleline) {
            if (conf.mode.singleLineStringErrors) {
              outclass = ERRORCLASS;
            } else {
              state.tokenize = tokenBase;
            }
          }
          return outclass;
        };
      };
      longComment = function(stream, state) {
        while (!stream.eol()) {
          stream.eatWhile(/[^#]/);
          if (stream.match("###")) {
            state.tokenize = tokenBase;
            break;
          }
          stream.eatWhile("#");
        }
        return "comment";
      };
      indent = function(stream, state, type) {
        var indentUnit, scope, _i, _len, _ref;
        type = type || "coffee";
        indentUnit = 0;
        if (type === "coffee") {
          _ref = state.scopes;
          for (_i = 0, _len = _ref.length; _i < _len; _i++) {
            scope = _ref[_i];
            if (scope.type === "coffee") {
              indentUnit = scope.offset + conf.indentUnit;
              break;
            }
          }
        } else {
          indentUnit = stream.column() + stream.current().length;
        }
        return state.scopes.unshift({
          offset: indentUnit,
          type: type
        });
      };
      dedent = function(stream, state) {
        var i, scope, _i, _indent, _indent_index, _len, _ref;
        if (state.scopes.length === 1) {
          return;
        }
        if (state.scopes[0].type === "coffee") {
          _indent = stream.indentation();
          _indent_index = -1;
          _ref = state.scopes;
          for (i = _i = 0, _len = _ref.length; _i < _len; i = ++_i) {
            scope = _ref[i];
            if (_indent === scope.offset) {
              _indent_index = i;
              break;
            }
          }
          if (_indent_index === -1) {
            return true;
          }
          while (state.scopes[0].offset !== _indent) {
            state.scopes.shift();
          }
          return false;
        } else {
          state.scopes.shift();
          return false;
        }
      };
      tokenLexer = function(stream, state) {
        var current, delimiter_index, style;
        style = state.tokenize(stream, state);
        current = stream.current();
        if (current === ".") {
          style = state.tokenize(stream, state);
          current = stream.current();
          if (anyIs(["variable", "constant", "classname", "functionid"], style)) {
            return style;
          } else {
            return ERRORCLASS;
          }
        }
        if (current === "@") {
          stream.eat("@");
          return "keyword";
        }
        if (current === "return") {
          state.dedent += 1;
        }
        if (((current === "->" || current === "=>") && !state.lambda && state.scopes[0].type === "coffee" && stream.peek() === "") || style === "indent") {
          indent(stream, state);
        }
        delimiter_index = "[({".indexOf(current);
        if (delimiter_index !== -1) {
          indent(stream, state, "])}".slice(delimiter_index, delimiter_index + 1));
        }
        if (indentKeywords.exec(current)) {
          indent(stream, state);
        }
        if (current === "then") {
          dedent(stream, state);
        }
        if (style === "dedent" && dedent(stream, state)) {
          return ERRORCLASS;
        }
        delimiter_index = "])}".indexOf(current);
        if (delimiter_index !== -1 && dedent(stream, state)) {
          return ERRORCLASS;
        }
        if (state.dedent > 0 && stream.eol() && state.scopes[0].type === "coffee") {
          if (state.scopes.length > 1) {
            state.scopes.shift();
          }
          state.dedent -= 1;
        }
        return style;
      };
      anyIs = function(list, what) {
        var item, _i, _len;
        for (_i = 0, _len = list.length; _i < _len; _i++) {
          item = list[_i];
          if (item === what) {
            return true;
          }
        }
        return false;
      };
      return {
        startState: function(basecolumn) {
          return {
            tokenize: tokenBase,
            scopes: [
              {
                offset: basecolumn || 0,
                type: "coffee"
              }
            ],
            lastToken: null,
            lambda: false,
            dedent: 0
          };
        },
        token: function(stream, state) {
          var style;
          style = tokenLexer(stream, state);
          state.lastToken = {
            style: style,
            content: stream.current()
          };
          if (stream.eol() && stream.lambda) {
            state.lambda = false;
          }
          return style;
        },
        indent: function(state, textAfter) {
          if (state.tokenize !== tokenBase) {
            return 0;
          }
          return state.scopes[0].offset;
        }
      };
    });
    return CodeMirror.defineMIME("text/x-coffeescript", "coffeescript");
  });

}).call(this);
