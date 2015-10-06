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


walk = (dir, dirCallback, fileCallback) ->
  files = fs.readdirSync dir
  for file in files
    filepath = path.join dir, file
    stats = fs.statSync filepath
    if stats.isDirectory()
      dirCallback file, ->
        walk filepath, dirCallback, fileCallback
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

walk './test',
  (dir, walkOn) ->
    if dir isnt 'ignore'
      openSuite dir
      walkOn()
      closeSuite()

  (file, filepath) ->
    ext = (path.extname file)
    if ext is '.shem'
      name = path.basename file, ext
      source = fs.readFileSync filepath, 'utf8'
      currentSuite().addTest new Test name, ->
        values = ''
        console.error = (output) ->
          values += '\n' + (util.inspect output, colors: yes)
        try
          shem.run source, filename: filepath
        catch e
          e.message = e.message + (if values then '\nGot:' else '') + values
          throw e

mocha.run ->
