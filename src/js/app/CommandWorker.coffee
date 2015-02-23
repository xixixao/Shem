_require = require

# path is my addition to ace, it is passed from CommandMode and it is the path
# to the worker backing the source editor
exports.Worker = (sender, path) ->
  SourceWorker = (_require path).Worker

  class CommandWorker extends SourceWorker
    constructor: (sender) ->
      super sender

    prefix: (source) ->
      @source = source

    onUpdate: (execute) ->
      value = @doc.getValue()

      if value[0] is ':'
        if execute
          @sender.emit "ok",
            result: value[1..]
            commandSource : value
            type: 'command'
      else
        if value.length > 0
          # console.log "from command worker", (@source or '') + value
          sourceAndCommand = (@source or '') + value
          try
            # [res, warnings] = compiler.compileExp value
            # [";" + res, warnings])
            @sender.emit "ok",
              type: (if execute then 'execute' else 'normal')
              commandSource: value
              result:
                @compiler.compileTopLevelAndExpression sourceAndCommand

          catch e
            console.log sourceAndCommand
            console.log e.stack
            @sender.emit "error",
              text: e.message
              type: 'error'
            return

  new CommandWorker sender
