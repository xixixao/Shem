$ = require 'ejquery'
ace = require 'ace/ace'
Prelude = require 'vendor/prelude/prelude-browser-min'
CodeMirror = require 'vendor/codemirror/codemirror'
TimeLine = require 'app/UniqueTimeLine'
Commands = require 'app/Commands'
History = require 'app/History'
jsDump = require 'vendor/jsDump'

console.log "Loaded sourceArea"
Prelude.installPrelude window
sourceFragment = "try:"
compiledJS = ""
compiler = null
compilerOptions = null
sourceCompiled = false
autoCompile = true
lastHit = 0
lastErrorType = ""
currentMode = ""
AUTOSAVE_DELAY = 6000
LAST_CODE = "lastEditedSourceCodeCOOKIE"
UNNAMED_CODE = "@unnamed"
TIMELINE_COOKIE = "timelineCOOKIE"
sourceChanged = false
saveName = UNNAMED_CODE
cookieFilePrefix = "TeaTableFile_"
timeline = new TimeLine

addMessage = (text, id) ->
  tag = if id?
    " data-id=#{id}"
  else
    ""
  newMessage = $("<pre#{tag}>#{text}</pre>")
  $("#output").prepend newMessage
  setMaxPreWidth newMessage

eraseMessages = (except...) ->
  excepts = join ", ", except
  $("#output").children().not ->
    $(this).find(excepts).size() > 0
  .remove()

getMessage = (n) ->
  $("#output pre").eq n

getCurrentMessage = ->
  getMessage 0

setCurrentMessage = (text, id) ->
  getCurrentMessage().text(text).data "id", id

isCurrentMessage = (id) ->
  getCurrentMessage().data("id") is id

log = (input...) ->
  input = for i in input
    jsDump.parse i ? "Nothing"
  message = input.join ", "
  if message.length > 0
    addMessage lastMessage = message

showImportantMessage = (type, message) ->
  $("#messages").attr "class", type
  $("#messages pre").text message
  $("#messages").stop(true, true).fadeIn 200

showErrorMessage = (type, message) ->
  lastErrorType = type
  showImportantMessage "errorMessage", message

showFileMessage = (message) ->
  showImportantMessage "fileMessage", message

currentMessage = ->
  $("#messages pre").text()

hideError = (types...) ->
  if lastErrorType in types
    $("#messages").fadeOut 700

# TODO: get rid of the duplication between dump and run
dump = ->
  compileCode() unless sourceCompiled
  if compiledJS
    log compiledJS
  else
    showErrorMessage "compiler", "Fix: '#{currentMessage()}' first"

run = ->
  compileCode() unless sourceCompiled
  if compiledJS
    execute compiledJS
  else
    showErrorMessage "compiler", "Fix: '#{currentMessage()}' first"

# TODO: create help out of the command definitions, make them pluggable instead of defined here
commands = Commands.initialize [
  "dump", "d", -> dump()
  "run", "r", -> run()
  "erase", "e", -> eraseMessages arguments...
  "copy", "c", -> selectLastOutput()
  "link", "l", -> saveToAdress()
  "toggle", "t", -> toggleAutoCompilation()
  "save", -> switchCurrentCode arguments...
  "load", -> loadFromClient arguments...
  "close", -> exitCurrentCode()
  "delete", -> removeFromClient arguments...
  "modes", "m", -> displayModes()
  "mode", -> setMode arguments...
  "canvas", -> createCanvas arguments...
  "browse", "b", -> displayClient()
  "help", "h", -> log(helpDescription)
  "ph", -> history.print(log)
]

compileAndRun = ->
  # TODO use prelude trim
  source = $.trim commandArea.getValue()
  return if source.length is 0

  timeline.push source
  hideError "command", "runtime"
  try
    if pref = source.match(/^(< |:)/)
      source = source[pref[0].length..]
      for command in commands
        match = command.match source
        break if match?
      saveTimeline()
      outputScrollTop()
    else
      command = compiler.compile source, getCompilerOptions()
      try
        log execute compiledJS + command
        saveTimeline()
        outputScrollTop()
      catch error
        showErrorMessage "runtime", "Runtime: #{error}"
  catch error
    console.log error
    showErrorMessage "command", "Command Line: #{error.message}"
  return

modes =
  CoffeeScript:
    id: "coffeescript"
    options:
      bare: true

  IcedCoffeeScript:
    id: "icedcoffeescript"
    options:
      bare: true

  Ometa:
    id: "ometa"

  MetaCoffee:
    id: "metacoffee"

modesList = ->
  join "\n", map keys(modes), (mode) ->
    "#{if mode is currentMode then "> " else "  "}#{mode}"

displayModes = ->
  addMessage modesList(), "modesList"

setNewMode = (name, callback) ->
  if name isnt currentMode
    setMode name, callback
  else
    callback?()

setMode = (name, callback) ->
  mode = modes[name]
  if mode?
    id = mode.id
    require [
      "vendor/compilers/" + id + "/compiler"
      "vendor/compilers/" + id + "/highlighter"
    ], (compilerClass, highlighter) ->
      compiler = compilerClass
      compilerOptions = mode.options
      sourceArea.setOption "mode", id
      commandArea.setOption "mode", id
      mode.init?()
      currentMode = name
      if isCurrentMessage "modesList"
        setCurrentMessage modesList(), "modesList"
      else
        log "#{name} compiler loaded"
      compileCode()
      callback?()
    , (error) ->
      log "#{name} loading failed"
  else
    log "Wrong mode name, choose from:\n\n#{modesList()}"

createCanvas = (width, height) ->
  log "#canvas\n<canvas id='canvas' width=#{width} height=#{height}></canvas>"

toggleAutoCompilation = ->
  autoCompile = not autoCompile
  log "Autocompilation switched #{if autoCompile then 'on' else 'off'}"

getCompilerOptions = ->
  # TODO: use prelude
  $.extend {}, compilerOptions

compileCode = ->
  startColor = "#151515"
  endColor = "#ccc"
  normalColor = "#050505"
  indicator = $ "#compilationIndicator"
  indicateBy = (color) ->
    indicator.animate
      color: color
    ,
      complete: ->
        indicator.css color: color

  compileSource ->
    indicateBy startColor
  , ->
    indicateBy endColor
    indicateBy normalColor

compileSource = (start, finish) ->
  start()
  source = sourceArea.getValue()
  compiledJS = ""
  saveCurrent()
  try
    compiledJS = compiler.compile source, getCompilerOptions()
    hideError "compiler", "runtime"
  catch error
    showErrorMessage "compiler", "Compiler: #{error.message ? error}"
  sourceCompiled = true
  finish()
  $("#repl_permalink").attr "href", "##{sourceFragment}#{encodeURIComponent(source)}"

execute = (code) ->
  eval (compiler.preExecute? code) ? code

history = new History
sourceChange = (e) ->
  sourceCompiled = false
  sourceChanged = true
  history.add e
  return unless autoCompile
  DELAY = 700
  lastHit = +new Date
  setTimeout ->
    if +new Date() - lastHit > DELAY
      compileCode() unless sourceCompiled
  , 2 * DELAY

# TODO: this is not used, it is connected to History
printHistory = ->
  insert = undefined
  point = undefined
  text = undefined
  _i = undefined
  _len = undefined
  _results = undefined
  text = [""]
  insert = (from, to, what) ->
    appended = undefined
    curr = undefined
    newLines = undefined
    oldLines = undefined
    singleLine = undefined
    singleLine = from.line is to.line
    if singleLine
      curr = text[from.line]
      text[from.line] = curr.slice(0, from.ch) + what[0] + curr.slice(to.ch)
    else
      text[from.line] = text[from.line].slice(0, from.ch) + what[0]
      text[to.line] = what[what.length - 1] + text[to.line].slice(to.ch)
    newLines = what.length
    oldLines = 1 + to.line - from.line
    if newLines > 2 or oldLines > 2
      appended = (if singleLine then what.slice(1) else what.slice(1, -1))
      text.splice.apply text, [
        from.line + 1
        Math.max(0, oldLines - newLines)
      ].concat(__slice_.call(appended))

  _results = []
  _i = 0
  _len = history.length

  while _i < _len
    point = history[_i]
    insert point.from, point.to, point.text
    _results.push log(text)
    _i++
  _results

BROWSE_COOKIE = "table"
autosave = ->
  setTimeout ->
    if sourceChanged
      saveCurrent()
      sourceChanged = false
    autosave()
  , AUTOSAVE_DELAY

fileCookie = (name, value) ->
  $.totalStorage cookieFilePrefix + name, value

saveCurrent = ->
  source = sourceArea.getValue()
  value = serializeSource()

  valueLines = (source.split "\n").length
  exists = false

  ammendClientTable saveName, "#{saveName},#{valueLines}"
  fileCookie saveName, value
  $.totalStorage LAST_CODE, saveName

serializeSource = ->
  source: sourceArea.getValue()
  mode: currentMode
  selection: sourceArea.getSelectionRange()
  cursor: sourceArea.getCursorPosition()
  scroll:
    top: sourceArea.session.getScrollTop()
    left: sourceArea.session.getScrollLeft()

deseriazeSource = (serialized, callback) ->
  {source, mode, selection, cursor, scroll} = serialized
  sourceArea.setValue source
  sourceArea.session.selection.setSelectionRange selection
  sourceArea.moveCursorToPosition cursor
  sourceArea.session.setScrollTop scroll.top
  sourceArea.session.setScrollLeft scroll.left
  setNewMode mode, callback

saveTimeline = ->
  $.totalStorage TIMELINE_COOKIE, timeline.newest(200)

loadTimeline = ->
  timeline.from ($.totalStorage TIMELINE_COOKIE) ? []

removeFromClient = (name) ->
  return unless name?
  fileCookie saveName, null
  ammendClientTable name
  showFileMessage "" + name + " deleted"

ammendClientTable = (exclude, addition) ->
  addition = null unless addition?
  table = []
  oldTable = $.totalStorage BROWSE_COOKIE
  if oldTable?
    for pair in oldTable.split ";"
      [name, lines] = pair
      table.push pair if name isnt exclude

  table.push addition if addition
  table = table.join ";"
  table = null if table.length is 0
  $.totalStorage BROWSE_COOKIE, table

loadFromClient = (name) ->
  name = $.totalStorage(LAST_CODE) unless name?
  unless name?
    setMode "CoffeeScript" unless compiler?
    return
  stored = fileCookie(name)
  if stored?
    saveName = name

    deseriazeSource stored, ->
      showFileMessage "" + saveName + " loaded"  if saveName isnt UNNAMED_CODE

  else
    showFileMessage "There is no " + name  if name isnt UNNAMED_CODE

exitCurrentCode = ->
  saveCurrent()
  saveName = UNNAMED_CODE
  sourceArea.setValue ""
  saveCurrent()

switchCurrentCode = (name) ->
  saveCurrent()
  saveName = name
  saveCurrent()
  showFileMessage "Working on " + saveName

displayClient = ->
  table = $.totalStorage(BROWSE_COOKIE)
  output = ""
  if table?.length > 0
    for snippet in table.split ";"
      [name, lines] = snippet.split ","
      output += "#{name}, lines: #{lines}\n" if name isnt UNNAMED_CODE
  if output is ""
    log "No files saved"
  else
    log output

CodeMirror.keyMap.commandLine =
  Up: "doNothing"
  Down: "doNothing"
  PageUp: "doNothing"
  PageDown: "doNothing"
  Enter: "doNothing"
  fallthrough: "default"

CodeMirror.commands.doNothing = (cm) ->
  true

outputScrollTop = ->
  $("#rightColumn").animate
    scrollTop: 0
  , $("#rightColumn").scrollTop() / 10


defaultEditor = ->
  winSize =
    w: $(window).width()
    h: $(window).height()

  column = floor winSize.w / 2
  $("#leftColumn").width column - 30
  resizeEditor()

resizeEditor = (e) ->
  winSize =
    w: $(window).width()
    h: $(window).height()

  $("#centerBar").height winSize.h - 20
  # $("#sourceWrap .CodeMirror-scroll").css "max-height", (winSize.h - 175) + "px"
  $("#commandArea").css "height", 17 + "px"
  $("#sourceArea").css "height", (winSize.h - 175) + "px"
  $("#rightColumn").width winSize.w - $("#leftColumn").width() - 60
  $("#rightColumn").css "max-height", (winSize.h - 25) + "px"
  setMaxPreWidth $("#output pre")

selectLastOutput = ->
  (getMessage(0)).selectText()

setMaxPreWidth = ($pre) ->
  $pre.css "max-width", ($("#rightColumn").width() - 45) + "px"

loadWith = (coffee) ->
  sourceArea.setValue sourceArea.getValue() + coffee

saveToAdress = ->
  source = sourceArea.getValue()
  window.location = "#" + sourceFragment + (encodeURIComponent(source))

# TODO: an easy way to distinguish code from other text in logs
helpDescription = """
  Issue commands by typing \"< \" or \":\"
  followed by space separated commands:

  erase / e      - Clear all results
  erase &lt;not...> - Don't clear results containing givens
  dump / d       - Dump generated javascript
  run / r        - Run just the source code
  copy / c       - Select last output (right-click to copy)
  toggle / t     - Toggle autocompilation
  link / l       - Create a link with current source code
  mode &lt;name>    - Switch to a different compiler
  modes / m      - Show all available modes
  canvas &lt;w> &lt;h> - Create a canvas given width and height
  save &lt;name>    - Save current code locally under name
  load &lt;name>    - Load code from local storage under name
  delete &lt;name>  - Remove code from local storage
  browse / b     - Show content of local storage
  help / h       - Show this help

  Name with arbitrary characters (spaces) must be closed by \\
  save Long file name.txt\\
"""

sourceArea = ace.edit 'sourceArea'
sourceArea.setTheme "ace/theme/monokai"
sourceArea.getSession().setMode "ace/mode/coffee"
sourceArea.setHighlightActiveLine true

sourceArea.getSession().on 'change', sourceChange

sourceArea.commands.addCommand
  name: 'leave'
  bindKey: win: 'Esc', mac: 'Esc'
  exec: ->
    commandArea.focus()

commandArea = ace.edit 'commandArea'
commandArea.setTheme "ace/theme/monokai"
commandArea.getSession().setMode "ace/mode/coffee"
commandArea.setHighlightActiveLine false

# Execute on enter
commandArea.commands.addCommand
  name: 'execute'
  bindKey: win: 'Enter', mac: 'Enter'
  exec: ->
    compileAndRun()
    commandArea.setValue ""

commandArea.commands.addCommand
  name: 'previous'
  bindKey: win: 'Up', mac: 'Up'
  exec: ->
    timeline.temp commandArea.getValue() unless timeline.isInPast()
    commandArea.setValue timeline.goBack()

commandArea.commands.addCommand
  name: 'following'
  bindKey: win: 'Down', mac: 'Down'
  exec: ->
    commandArea.setValue timeline.goForward() if timeline.isInPast()

commandArea.commands.addCommand
  name: 'leave'
  bindKey: win: 'Esc', mac: 'Esc'
  exec: ->
    sourceArea.focus()

$("#commandWrap").mouseenter -> commandArea.focus()
$("#sourceArea").mouseenter -> sourceArea.focus()

$("#centerBar").draggable
  axis: "x"
  drag: (e, ui) ->
    newRightColumnWidth = $(window).width() - ui.offset.left - 60
    if newRightColumnWidth > 0
      $("#leftColumn").width ui.offset.left - $("#leftColumn").position().left
      $("#rightColumn").width newRightColumnWidth
    ui.position = ui.originalPosition

defaultEditor()
$(window).resize resizeEditor
$(window).unload ->
  saveCurrent()

hash = decodeURIComponent window.location.hash.replace /^#/, ""
if hash.indexOf(sourceFragment) is 0
  src = hash.substr(sourceFragment.length)
  loadWith src
  window.location.hash = ""
  log "File loaded from URI, use the link command to generate new link."
else
  loadFromClient()
loadTimeline()
if timeline.size() < 10
  log helpDescription
