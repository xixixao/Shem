# path is my addition to ace, it is passed from CommandMode and it is the path
# to the worker backing the source editor
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
