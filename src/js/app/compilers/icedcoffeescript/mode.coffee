Tokenizer    = require("ace/tokenizer").Tokenizer
Rules        = require './highlighter'
Outdent      = require("ace/mode/matching_brace_outdent").MatchingBraceOutdent
FoldMode     = require("ace/mode/folding/coffee").FoldMode
Range        = require("ace/range").Range
TextMode     = require("ace/mode/text").Mode
WorkerClient = require("ace/worker/worker_client").WorkerClient

indenter = ///
  (?:
      [ ({[=: ] # opening braces, equal or colon
    | [-=]>     # function symbol
    | \b (?:    # any of keywords starting a block:
        else
      | switch
      | try
      | catch (?: \s*[$A-Za-z_\x7f-\uffff][$\w\x7f-\uffff]* )? # name of error
      | finally
    )
  )\s*$
///
commentLine = /^(\s*)# ?/
hereComment = /^\s*###(?!#)/
indentation = /^\s*/

exports.Mode = class extends TextMode
  constructor: ->
    @$tokenizer = new Tokenizer new Rules().getRules()
    @$outdent = new Outdent
    @foldingRules = new FoldMode

  getNextLineIndent: (state, line, tab) ->
    indent = @$getIndent line
    tokens = @$tokenizer.getLineTokens(line, state).tokens
    if not (tokens.length and tokens[tokens.length - 1].type is "comment") and
        state is "start" and indenter.test(line)
      indent += tab
    indent

  toggleCommentLines: (state, doc, startRow, endRow) ->
    console.log "toggle"
    range = new Range 0, 0, 0, 0

    for i in [startRow..endRow]
      line = doc.getLine(i)
      if hereComment.test line
        continue

      if commentLine.test line
        line = line.replace commentLine, '$1'
      else
        line = line.replace indentation, '$&# '

      range.end.row = range.start.row = i
      range.end.column = line.length + 2
      doc.replace range, line
    return

  checkOutdent: (state, line, input) ->
    @$outdent.checkOutdent line, input

  autoOutdent: (state, doc, row) ->
    @$outdent.autoOutdent doc, row

  createWorker: (session) ->
    worker = new WorkerClient ["ace", "compilers"],
      "compilers/icedcoffeescript/worker",
      "Worker"

    if session
      worker.attachToDocument session.getDocument()
      worker.on "error", (e) ->
        session.setAnnotations [e.data]

      worker.on "ok", (e) =>
        session.clearAnnotations()

    worker

  preExecute: ->
    window.iced = require('./coffee-script/iced').runtime
