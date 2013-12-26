define ->
  class Command
    constructor: (@keywords, @handler) ->

    match: (string) ->
      match = string.match ///
        ^ \s* # beginning whitespace
        (?:#{
          @keywords.join '|'
        })
        \b
        (
          (?:
            \s+   # word delimiter
            (?:
              .*\\ # words ended by backslash
            |           # or
              \S+\b # a word
            )
          )*
        )     # returns a list
        \s* $ # ending whitespace
      ///
      if match
        @handler match[1].split(/\s+/).slice(1)...
      match

  initialize: (commands) ->
    while commands.length > 0
      [keywords, commands] = span commands, (el) ->
        (typeOf el) is "String"

      [handler] = commands

      commands = commands[1..]

      new Command keywords, handler
