Mirror = require("ace/worker/mirror").Mirror
{Lexer} = require "./coffee-script/lexer"
{parser} = require "./coffee-script/parser"
nodes = require "./coffee-script/nodes"
helpers = require "./coffee-script/helpers"
iced = require "./coffee-script/iced"

window.addEventListener = ->

# Instantiate a Lexer for our use here.
lexer = new Lexer

# The real Lexer produces a generic stream of tokens. This object provides a
# thin wrapper around it, compatible with the Jison API. We can then pass it
# directly as a "Jison lexer".
parser.lexer =
  lex: ->
    token = @tokens[@pos++]
    if token
      [tag, @yytext, @yylloc] = token
      @yylineno = @yylloc.first_line
    else
      tag = ''

    tag
  setInput: (@tokens) ->
    @pos = 0
  upcomingInput: ->
    ""

# Make all the AST nodes visible to the parser.
parser.yy = nodes

compile = (code, options = {bare: true}) ->
  iced.transform(parser.parse(lexer.tokenize code, options), options).compile options

# Override Jison's default error handling function.
parser.yy.parseError = (message, {token}) ->
  # Disregard Jison's message, it contains redundant line numer information.
  message = "unexpected #{if token is 1 then 'end of input' else token}"
  # The second argument has a `loc` property, which should have the location
  # data for this token. Unfortunately, Jison seems to send an outdated `loc`
  # (from the previous token), so we take the location information directly
  # from the lexer.
  helpers.throwSyntaxError message, parser.lexer.yylloc

exports.Worker = class extends Mirror
  constructor: (sender) ->
    super sender
    @setTimeout 250

  onUpdate: ->
    value = @doc.getValue()
    try
      @sender.emit "ok",
        result: compile value

    catch e
      loc = e.location
      if loc
        @sender.emit "error",
          row: loc.first_line
          column: loc.first_column
          endRow: loc.last_line
          endColumn: loc.last_column
          text: e.message
          type: "error"
      return
