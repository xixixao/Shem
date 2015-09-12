compiler = require './compiler'

exports.compileModule = (source, options) ->
  result = compiler.compileModule source
  if result.request
    console.log options
    console.log result
  else
    result.js