fs = require 'fs'
path = require 'path'
util = require 'util'
Mocha = require 'mocha'
child_process = require 'child_process'

shem = require '../lib/shem/shem-cli'

Test = Mocha.Test
Suite = Mocha.Suite
mocha = new Mocha
  reporter: 'spec'
  ui: 'tdd'
  slow: 250 # default
  timeout: 3000 # for large modules
  grep: process.argv[2] # first argument is passed as grep to mocha

INDEX = 'index.shem'
EXT = '.shem'

walk = (dir, dirCallback, fileCallback, files) ->
  files ?= fs.readdirSync dir
  for file in files
    filepath = path.join dir, file
    stats = fs.statSync filepath
    if stats.isDirectory()
      children = fs.readdirSync filepath
      dirCallback file, filepath, children, ->
        walk filepath, dirCallback, fileCallback, children
    else if stats.isFile()
      fileCallback file, filepath

suites = [mocha.suite]

currentSuite = ->
  [..., last] = suites
  last

openSuite = (name) ->
  newSuite = Suite.create currentSuite(), name
  suites.push newSuite

closeSuite = ->
  suites.pop()

addTest = (name, filepath) ->
  source = fs.readFileSync filepath, 'utf8'
  suite = currentSuite()
  suite.addTest new Test name, ->
    values = ''
    console.error = (output) ->
      values += '\n' + (util.inspect output, colors: yes)
    try
      shem.run source, filename: filepath
    catch e
      switch suite.title
        when 'malformed'
          throw e if e.name isnt 'ShemError'
          malformed = yes
        else
          e.message = e.message + (if values then '\nGot:' else '') + values
          throw e
    if suite.title is 'malformed' and not malformed
      throw new Error "Expected a malformed Shem source"

walk './test',
  (dir, filepath, fileNames, walkOn) ->
    hasIndex = INDEX in fileNames
    if dir isnt 'ignore'
      if hasIndex
        indexpath = path.join filepath, INDEX
        addTest dir, indexpath
      else
        openSuite dir
        walkOn()
        closeSuite()

  (file, filepath) ->
    ext = (path.extname file)
    if ext is EXT
      name = path.basename file, ext
      addTest name, filepath

mocha.run ->
