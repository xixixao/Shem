define ->

  # Sting Buffering
  # ---------------

  # Try to use StringBuffer instead of string concatenation to improve 
  # performance.

  # Adds strings into internal array and concatinates only on
  # **contents** call.
  class StringBuffer
    constructor: ->
      @strings = []
      for arg in arguments
        @nextPutAll arg
  
    nextPutAll: (s) -> 
      @strings.push(s)

    contents: -> 
      @strings.join('')

    @writeStream: (string) -> 
      new StringBuffer(string)

  # Prints anything onto a StringBuffer.
  printOnto = (x, ws) ->
    if not x?
      ws.nextPutAll "" + x
    else if x.constructor == Array
      ws.nextPutAll "["
      for elem, i in x
        if (i > 0)
          ws.nextPutAll ", "
        printOnto elem, ws
      ws.nextPutAll "]"   
    else
      ws.nextPutAll x.toString()  

  # Makes Arrays print themselves sensibly.
  Array.prototype.toString = ->
    ws = StringBuffer.writeStream ""
    printOnto this, ws
    ws.contents()

  # delegation - switched for subclassing
  objectThatDelegatesTo = (x, props) ->
#    f = ( -> )
#    f.prototype = x
#    r = new f()
#    for p of props
#      if props.hasOwnProperty p
#        r[p] = props[p]
#    return r  
    sub = class extends x
    for own key, val of props
      sub.prototype[key] = val
    sub

  # some reflective stuff
  ownPropertyNames = (x) ->
    key for own key of x

  class Set
    constructor: ->
      @data = {}

    add: (what...) ->
      for one in what
        @data[one] = true
      this

    values: ->
      key for own key of @data

  extend = (a, b) ->
    for own key, value of b
      a[key] = value

  # some functional programming stuff - never used

  # Array.prototype.map - use $.map instead

  # left reduce
  #reduce = (array, z, f) ->
  #  r = z
  #  for el in array    
  #    r = f r, el
  #  return r

  #delimWith = (array, d) ->
  #  reduce array, [], (xs, x) ->      
  #    if xs.length > 0
  #      xs.push(d)
  #    xs.push(x)
  #    return xs    

  # Squeak's ReadStream, kind of
#  class ReadStream
#    constructor: (anArrayOrString) ->
#      @src = anArrayOrString
#      @pos = 0  
#    
#    atEnd: -> 
#      @pos >= @src.length
#    
#    next: -> 
#      @src.at @pos++


  # Escape Characters
  # -----------------

  # Adds **s** before the given string to get length **len**
  padStringWith = (string, s, len) ->
    r = string
    while (r.length < len)
      r = s + r
    return r  

  escapeStringFor = new Object()
  for c in [0...128]
    escapeStringFor[c] = String.fromCharCode(c)  
  specials = 
    "'":  "\\'"
    '"':  '\\"'
    "\\": "\\\\"
    "\b": "\\b"
    "\f": "\\f"
    "\n": "\\n"
    "\r": "\\r"
    "\t": "\\t"
    "\v": "\\v"
  for key, val of specials
    escapeStringFor[key.charCodeAt 0] = val

  escapeChar = (c) ->
    charCode = c.charCodeAt(0)
    if charCode < 128
      return escapeStringFor[charCode]
    else if 128 <= charCode < 256
      return "\\x" + padStringWith charCode.toString(16), "0", 2
    else
      return "\\u" + padStringWith charCode.toString(16), "0", 4

  unescape = (s) ->
    if s.charAt(0) == '\\'
      switch s.charAt 1
        when "'"  then "'"
        when '"'  then '"'
        when '\\' then '\\'
        when 'b'  then '\b'
        when 'f'  then '\f'
        when 'n'  then '\n'
        when 'r'  then '\r'
        when 't'  then '\t'
        when 'v'  then '\v'
        when 'x'  then String.fromCharCode parseInt s.substring(2, 4), 16
        when 'u'  then String.fromCharCode parseInt s.substring(2, 6), 16
        else           s.charAt(1)      
    else
      s

  toProgramString = (string) ->
    ws = StringBuffer.writeStream '"'
    for ch in string
      ws.nextPutAll escapeChar ch
    ws.nextPutAll('"')
    return ws.contents()  

  # C-style tempnam function
#  tempnam = (s) ->
#   (if s then s else "_tmpnam_") + tempnam.n++
#  tempnam.n = 0

  escapeChar:       escapeChar
  unescape:         unescape
  propertyNames:    ownPropertyNames
  programString:    toProgramString
  subclass:         objectThatDelegatesTo
  StringBuffer:     StringBuffer
  extend:           extend
