fs = require 'fs'
path = require 'path'
helpers = require './helpers'
compiler = require './compiler'

nameToTypedPath = (moduleName, filename) ->
  modulePath = moduleName.split path.sep
  type = if isIndex filename then 'index' else 'commonJs'
  names: modulePath
  types: (for _, i in modulePath
    if i < modulePath.lenght - 1
      'commonJs'
    else
      type)
  exported: isExported filename

isIndex = (name) ->
  /index.shem$/.test name

isExported = (name) ->
  /.xshem$/.test name

exports.compileModule = compile = (source, options) ->
  result =
    if options.name
      compiler.compileModuleTopLevel source, nameToTypedPath options.name, options.filename
    else
      compiler.compileModule source, isIndex options.filename
  if result.request
    request: result.request
  else if result.malformed
    # TODO: add info
    throw new Error "The input is not a complete valid Shem program: #{result.malformed}"
  else if result.errors
    throw new Error result.errors[0].message
  else
    result.js

exports.findModuleSourceFile = findModuleSourceFile = (name, fromPath) ->
  if name[0] is '.' # or name[0...1] is '..' already covered
    fromModule =
      if isIndex fromPath
        path.dirname fromPath
      else
        fromPath
    modulePath = path.join fromModule, name
    if fs.existsSync modulePath
      path.join modulePath, 'index.shem'
    else if fs.existsSync "#{modulePath}.xshem"
      "#{modulePath}.xshem"
    else
      "#{modulePath}.shem"
  else
    throw new Error "Global modules in run not supported yet"

runnable = (js) ->
  compiler.library + compiler.immutable + js

# Compile and execute a string of CoffeeScript (on the server), correctly
# setting `__filename`, `__dirname`, and relative `require()`.
exports.run = run = (code, options = {}) ->
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

  # Load compiled shem modules from our cache
  require.extensions['.xshem'] =
  require.extensions['.shem'] = (module, filename) ->
    compiled = compiledShemCache[filename]
    if not compiled
      throw new Error "Module #{filename} was not compiled"
    module._compile compiled, filename

  # Compile the main module and all required modules
  compiledShemCache = []
  compileAndAddToCache = (code, options) ->
    while requestedModule = (compiled = compile code, options).request
      requestedSourceFilename = findModuleSourceFile requestedModule, mainModule.filename
      requestedSource = fs.readFileSync requestedSourceFilename, 'utf8'
      # TODO: convert to js file name
      compiledShemCache[requestedSourceFilename] =
        compileAndAddToCache requestedSource,
          filename: requestedSourceFilename
          name: requestedModule
    runnable compiled
  code = runnable compileAndAddToCache code, options

  mainModule._compile code, mainModule.filename