{Worker} = require 'compilers/teascript/worker'

class CommandWorker extends Worker
  constructor: (sender) ->
    super sender

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
        # sourceAndCommand = (@source or '') + '\n' + value
        try
          # [res, warnings] = compiler.compileExp value
          # [";" + res, warnings])
          @sender.emit "ok",
            type: (if execute then 'execute' else 'normal')
            commandSource: value
            result:
              @compiler.compileExpression value, @moduleName

        catch e
          console.log sourceAndCommand
          console.log e.stack
          @sender.emit "error",
            text: e.message
            type: 'error'
          return

module.exports = CommandWorker