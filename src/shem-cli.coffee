fs = require 'fs'
path = require 'path'
helpers = require './helpers'
compiler = require './compiler'

exports.compileModule = compile = (source, options) ->
  result = compiler.compileModule source
  if result.request
    console.error options
    console.error result
  else
    result.js


# Compile and execute a string of CoffeeScript (on the server), correctly
# setting `__filename`, `__dirname`, and relative `require()`.
exports.run = (code, options = {}) ->
  mainModule = require.main

  # Set the filename.
  mainModule.filename = process.argv[1] =
    if options.filename then fs.realpathSync(options.filename) else '.'

  # Clear the module cache.
  mainModule.moduleCache and= {}

  # Assign paths for node_modules loading
  dir = if options.filename
    path.dirname fs.realpathSync options.filename
  else
    fs.realpathSync '.'
  mainModule.paths = require('module')._nodeModulePaths dir

  # Compile.
  if not helpers.isCoffee(mainModule.filename) or require.extensions
    answer = compile code, options
    code = compiler.library + compiler.immutable + (answer.js ? answer)

  mainModule._compile code, mainModule.filename