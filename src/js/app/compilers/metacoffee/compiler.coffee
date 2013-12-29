define [
  './lib/loader'
  './lib/errorhandler'
], (MetaCoffee, ErrorHandler) ->
  console.log "wrrr"
  BSMetaCoffeeParser = MetaCoffee.BSMetaCoffeeParser
  BSMetaCoffeeTranslator = MetaCoffee.BSMetaCoffeeTranslator

  MetaCoffee.OMLib.errorHandler = ErrorHandler

  # options are ignored
  compile: (text, options) ->
    ast = BSMetaCoffeeParser.matchAll text,
      "topLevel", undefined, (m, i) ->
          handled = ErrorHandler.handle m, i
          throw new Error "Parser error at line " + (handled.lineNumber + 1) + "\n" +
            ErrorHandler.bottomErrorArrow handled
    code = BSMetaCoffeeTranslator.matchAll ast,
      "trans", undefined, (m, i) ->
        handled = ErrorHandler.handle m, i
        throw new Error "Translation error at line" + (handled.lineNumber + 1) + "\n" +
          ErrorHandler.bottomErrorArrow handled

  preExecute: (code) ->
    window.MetaCoffee = MetaCoffee

    window.ometaError = (m, i) ->
      handled = ErrorHandler.handle m, i
      "Error at line " + (handled.lineNumber + 1) + "\n" +
        ErrorHandler.bottomErrorArrow handled

    "$.extend(window, MetaCoffee.OMeta);" +
    "$.extend(window, MetaCoffee.OMLib);" +
    code
