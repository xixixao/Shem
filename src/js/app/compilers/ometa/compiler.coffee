define [
 './lib/src/ometajs'
 './lib/workspace/ErrorHandler'
], (OMetaJS, ErrorHandler) ->
  # options are ignored
  compile: (text, options) ->
    ast = OMetaJS.BSOMetaJSParser.matchAll text,
      "topLevel", undefined, (m, i) ->
          handled = ErrorHandler.handle m, i
          throw new Error "Parser error at line " + (handled.lineNumber + 1) + "\n" +
            ErrorHandler.bottomErrorArrow handled
    code = OMetaJS.BSOMetaJSTranslator.match ast,
      "trans", undefined, (m, i) ->
        handled = ErrorHandler.handle m, i
        throw new Error "Translation error at line" + (handled.lineNumber + 1) + "\n" +
          ErrorHandler.bottomErrorArrow handled

  preExecute: (code) ->
    window.OMetaJS = OMetaJS

    window.ometaError = (m, i) ->
      handled = ErrorHandler.handle m, i
      "Error at line " + (handled.lineNumber + 1) + "\n" +
        ErrorHandler.bottomErrorArrow handled

    "$.extend(window, OMetaJS);" +
    "$.extend(window, OMLib);" +
    code

