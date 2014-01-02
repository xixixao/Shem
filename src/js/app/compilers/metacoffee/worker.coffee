Mirror = require("ace/worker/mirror").Mirror

ErrorHandler = require './errorhandler/index'
MetaCoffee = require './metacoffee/index'

window.addEventListener = ->

exports.Worker = class extends Mirror
  constructor: (sender) ->
    super sender
    @setTimeout 250

  onUpdate: ->
    value = @doc.getValue()
    try
      @sender.emit "ok",
        result: MetaCoffee.compile value, bare: true
    catch e
      loc = {}
      if e.position
        loc = ErrorHandler.handle e.interpreter, e.position
      @sender.emit "error",
        row: loc.line_number
        column: loc.position
        endRow: loc.line_number
        endColumn: loc.position
        text: e.message
        type: "error"
      return
