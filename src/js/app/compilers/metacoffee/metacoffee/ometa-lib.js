(function() {
  var Set, Stack, StringBuffer, c, escapeChar, escapeStringFor, extend, key, objectThatDelegatesTo, ownPropertyNames, padStringWith, specials, toProgramString, trim, unescape, val, _i,
    __hasProp = {}.hasOwnProperty,
    __extends = function(child, parent) { for (var key in parent) { if (__hasProp.call(parent, key)) child[key] = parent[key]; } function ctor() { this.constructor = child; } ctor.prototype = parent.prototype; child.prototype = new ctor(); child.__super__ = parent.prototype; return child; },
    __slice = [].slice;

  StringBuffer = (function() {

    function StringBuffer() {
      var arg, _i, _len;
      this.strings = [];
      for (_i = 0, _len = arguments.length; _i < _len; _i++) {
        arg = arguments[_i];
        this.nextPutAll(arg);
      }
    }

    StringBuffer.prototype.nextPutAll = function(s) {
      return this.strings.push(s);
    };

    StringBuffer.prototype.contents = function() {
      return this.strings.join('');
    };

    StringBuffer.writeStream = function(string) {
      return new StringBuffer(string);
    };

    return StringBuffer;

  })();

  objectThatDelegatesTo = function(x, props) {
    var key, sub, val;
    sub = (function(_super) {

      __extends(_Class, _super);

      function _Class() {
        return _Class.__super__.constructor.apply(this, arguments);
      }

      return _Class;

    })(x);
    for (key in props) {
      if (!__hasProp.call(props, key)) continue;
      val = props[key];
      sub.prototype[key] = val;
    }
    return sub;
  };

  ownPropertyNames = function(x) {
    var key, _results;
    _results = [];
    for (key in x) {
      if (!__hasProp.call(x, key)) continue;
      _results.push(key);
    }
    return _results;
  };

  Set = (function() {

    function Set() {
      this.data = {};
    }

    Set.prototype.add = function() {
      var one, what, _i, _len;
      what = 1 <= arguments.length ? __slice.call(arguments, 0) : [];
      for (_i = 0, _len = what.length; _i < _len; _i++) {
        one = what[_i];
        this.data[one] = true;
      }
      return this;
    };

    Set.prototype.values = function() {
      var key, _ref, _results;
      _ref = this.data;
      _results = [];
      for (key in _ref) {
        if (!__hasProp.call(_ref, key)) continue;
        _results.push(key);
      }
      return _results;
    };

    return Set;

  })();

  Stack = (function() {

    function Stack() {
      this.data = [];
    }

    Stack.prototype.push = function(v) {
      this.data.push(v);
      return this;
    };

    Stack.prototype.pop = function() {
      this.data = this.data.slice(0, -1);
      return this;
    };

    Stack.prototype.top = function() {
      return this.data.slice(-1)[0];
    };

    return Stack;

  })();

  trim = function(str) {
    var i, ws;
    str = str.replace(/^\s\s*/, '');
    ws = /\s/;
    i = str.length - 1;
    while (ws.test(str.charAt(i))) {
      --i;
    }
    return str.slice(0, +i + 1 || 9e9);
  };

  extend = function(a, b) {
    var key, value;
    for (key in b) {
      if (!__hasProp.call(b, key)) continue;
      value = b[key];
      a[key] = value;
    }
    return a;
  };

  padStringWith = function(string, s, len) {
    var r;
    r = string;
    while (r.length < len) {
      r = s + r;
    }
    return r;
  };

  escapeStringFor = new Object();

  for (c = _i = 0; _i < 128; c = ++_i) {
    escapeStringFor[c] = String.fromCharCode(c);
  }

  specials = {
    "'": "\\'",
    '"': '\\"',
    "\\": "\\\\",
    "\b": "\\b",
    "\f": "\\f",
    "\n": "\\n",
    "\r": "\\r",
    "\t": "\\t",
    "\v": "\\v"
  };

  for (key in specials) {
    val = specials[key];
    escapeStringFor[key.charCodeAt(0)] = val;
  }

  escapeChar = function(c) {
    var charCode;
    charCode = c.charCodeAt(0);
    if (charCode < 128) {
      return escapeStringFor[charCode];
    } else if ((128 <= charCode && charCode < 256)) {
      return "\\x" + padStringWith(charCode.toString(16), "0", 2);
    } else {
      return "\\u" + padStringWith(charCode.toString(16), "0", 4);
    }
  };

  unescape = function(s) {
    if (s.charAt(0) === '\\') {
      switch (s.charAt(1)) {
        case "'":
          return "'";
        case '"':
          return '"';
        case '\\':
          return '\\';
        case 'b':
          return '\b';
        case 'f':
          return '\f';
        case 'n':
          return '\n';
        case 'r':
          return '\r';
        case 't':
          return '\t';
        case 'v':
          return '\v';
        case 'x':
          return String.fromCharCode(parseInt(s.substring(2, 4), 16));
        case 'u':
          return String.fromCharCode(parseInt(s.substring(2, 6), 16));
        default:
          return s.charAt(1);
      }
    } else {
      return s;
    }
  };

  toProgramString = function(string) {
    var ch, ws, _j, _len;
    ws = StringBuffer.writeStream('"');
    for (_j = 0, _len = string.length; _j < _len; _j++) {
      ch = string[_j];
      ws.nextPutAll(escapeChar(ch));
    }
    ws.nextPutAll('"');
    return ws.contents();
  };

  module.exports = {
    escapeChar: escapeChar,
    unescape: unescape,
    propertyNames: ownPropertyNames,
    programString: toProgramString,
    subclass: objectThatDelegatesTo,
    StringBuffer: StringBuffer,
    Set: Set,
    Stack: Stack,
    trim: trim,
    extend: extend
  };

}).call(this);
