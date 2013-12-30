exports.Worker = (sender, path) ->
  SourceWorker = (require path).Worker

  class CommandWorker extends SourceWorker
    constructor: (sender) ->
      super sender

    onUpdate: ->
      value = @doc.getValue()

      if value[0] is ':'
        @sender.emit "ok",
          result: value[1..]
          type: 'command'
      else
        super

  new CommandWorker sender
