
/*
  new syntax:
    #foo and `foo match the string object 'foo' (it's also accepted in my JS)
    'abc'   match the string object 'abc'
    'c'     match the string object 'c'
    ``abc''   match the sequence of string objects 'a', 'b', 'c'
    "abc"   token('abc')
    [1 2 3]   match the array object [1, 2, 3]
    foo(bar)    apply rule foo with argument bar
    -> ...    semantic actions written in JS (see OMetaParser's atomicHostExpr rule)
*/


/*
ometa M
  number = number:n digit:d -> n * 10 + d.digitValue()
         | digit:d          -> d.digitValue()

translates to...

class M extends OMeta
  number: ->
    @_or ->
      n = @_apply("number")
      d = @_apply("digit")
      n * 10 + d.digitValue()
    , ->
      d = @_apply("digit")
      d.digitValue()

(new M).matchAll("123456789", "number")
*/


(function() {
  var ListOMInputStream, OMInputStream, OMInputStreamEnd, OMeta, getTag, isImmutable, isSequenceable, makeOMInputStreamProxy, objectThatDelegatesTo, stringDigitValue,
    __hasProp = {}.hasOwnProperty,
    __extends = function(child, parent) { for (var key in parent) { if (__hasProp.call(parent, key)) child[key] = parent[key]; } function ctor() { this.constructor = child; } ctor.prototype = parent.prototype; child.prototype = new ctor(); child.__super__ = parent.prototype; return child; },
    __slice = [].slice;

  isImmutable = function(x) {
    return x === null || x === void 0 || typeof x === "boolean" || typeof x === "number" || typeof x === "string";
  };

  stringDigitValue = function(string) {
    return string.charCodeAt(0) - "0".charCodeAt(0);
  };

  isSequenceable = function(x) {
    return typeof x === "string" || x.constructor === Array;
  };

  getTag = (function() {
    var numIdx;
    numIdx = 0;
    return function(x) {
      if (x == null) {
        x;
      }
      switch (typeof x) {
        case "boolean":
          if (x === true) {
            return "Btrue";
          } else {
            return "Bfalse";
          }
          break;
        case "string":
          return "S" + x;
        case "number":
          return "N" + x;
        default:
          if (x.hasOwnProperty("_id_")) {
            return x._id_;
          } else {
            return x._id_ = "R" + numIdx++;
          }
      }
    };
  })();

  OMInputStream = (function() {

    function OMInputStream(hd, tl) {
      this.hd = hd;
      this.tl = tl;
      this.memo = {};
      this.lst = tl.lst;
      this.idx = tl.idx;
    }

    OMInputStream.prototype.head = function() {
      return this.hd;
    };

    OMInputStream.prototype.tail = function() {
      return this.tl;
    };

    OMInputStream.prototype.type = function() {
      return this.lst.constructor;
    };

    OMInputStream.prototype.upTo = function(that) {
      var curr, r;
      r = [];
      curr = this;
      while (curr !== that) {
        r.push(curr.head());
        curr = curr.tail();
      }
      if (this.type() === String) {
        return r.join('');
      } else {
        return r;
      }
    };

    return OMInputStream;

  })();

  OMInputStreamEnd = (function(_super) {

    __extends(OMInputStreamEnd, _super);

    function OMInputStreamEnd(lst, idx) {
      this.lst = lst;
      this.idx = idx;
      this.memo = {};
    }

    OMInputStreamEnd.prototype.head = function() {
      throw OMeta.prototype.fail;
    };

    OMInputStreamEnd.prototype.tail = function() {
      throw OMeta.prototype.fail;
    };

    return OMInputStreamEnd;

  })(OMInputStream);

  ListOMInputStream = (function(_super) {
    var makeStreamFrom;

    __extends(ListOMInputStream, _super);

    function ListOMInputStream(lst, idx) {
      this.lst = lst;
      this.idx = idx;
      this.memo = {};
      this.hd = lst[idx];
    }

    ListOMInputStream.prototype.head = function() {
      return this.hd;
    };

    ListOMInputStream.prototype.tail = function() {
      return this.tl || (this.tl = makeStreamFrom(this.lst, this.idx + 1));
    };

    makeStreamFrom = function(lst, idx) {
      var kind;
      kind = idx < lst.length ? ListOMInputStream : OMInputStreamEnd;
      return new kind(lst, idx);
    };

    ListOMInputStream.toStream = function(iterable) {
      return makeStreamFrom(iterable, 0);
    };

    return ListOMInputStream;

  })(OMInputStream);

  objectThatDelegatesTo = function(x, props) {
    var f, key, r, val;
    f = function() {};
    f.prototype = x;
    r = new f;
    for (key in props) {
      if (!__hasProp.call(props, key)) continue;
      val = props[key];
      r[key] = val;
    }
    return r;
  };

  makeOMInputStreamProxy = function(target) {
    return objectThatDelegatesTo(target, {
      memo: {},
      target: target,
      tl: void 0,
      tail: function() {
        return this.tl || (this.tl = makeOMInputStreamProxy(target.tail()));
      }
    });
  };

  module.exports = OMeta = (function() {

    OMeta.prototype.fail = {
      toString: function() {
        return "match failed";
      }
    };

    function OMeta(input) {
      this.input = input;
      this.initialize();
    }

    OMeta.prototype._apply = function(rule) {
      var ans, failer, memo, memoRec, origInput, sentinel;
      memo = this.input.memo;
      memoRec = memo[rule];
      if (memoRec === void 0) {
        origInput = this.input;
        if (this[rule] == null) {
          throw 'tried to apply undefined rule "' + rule + '"';
        }
        memo[rule] = false;
        memoRec = {
          ans: this[rule].call(this),
          nextInput: this.input
        };
        failer = memo[rule];
        memo[rule] = memoRec;
        if (failer === true) {
          sentinel = this.input;
          while (true) {
            try {
              this.input = origInput;
              ans = this[rule].call(this);
              if (this.input === sentinel) {
                throw this.fail;
              }
              memoRec.ans = ans;
              memoRec.nextInput = this.input;
            } catch (f) {
              if (f !== this.fail) {
                throw f;
              }
              break;
            }
          }
        }
      } else if (typeof memoRec === 'boolean') {
        memo[rule] = true;
        throw this.fail;
      }
      this.input = memoRec.nextInput;
      return memoRec.ans;
    };

    OMeta.prototype._applyWithArgs = function() {
      var args, idx, rule, ruleFn, ruleFnArity, _i, _ref;
      rule = arguments[0], args = 2 <= arguments.length ? __slice.call(arguments, 1) : [];
      ruleFn = this[rule];
      if (ruleFn == null) {
        throw 'tried to apply undefined rule "' + rule + '"';
      }
      ruleFnArity = ruleFn.length;
      for (idx = _i = _ref = args.length - 1; _i >= ruleFnArity; idx = _i += -1) {
        this._prependInput(args[idx]);
      }
      if (ruleFnArity === 0) {
        return ruleFn.call(this);
      } else {
        return ruleFn.apply(this, args.slice(0, +ruleFnArity + 1 || 9e9));
      }
    };

    OMeta._superApplyWithArgs = function() {
      var args, idx, recv, rule, ruleFn, ruleFnArity, _i, _ref;
      recv = arguments[0], rule = arguments[1], args = 3 <= arguments.length ? __slice.call(arguments, 2) : [];
      ruleFn = this.prototype[rule];
      if (ruleFn == null) {
        throw 'tried to apply undefined super rule "' + rule + '"';
      }
      ruleFnArity = ruleFn.length;
      for (idx = _i = _ref = args.length - 1; _i > ruleFnArity; idx = _i += -1) {
        recv._prependInput(args[idx]);
      }
      if (ruleFnArity === 0) {
        return ruleFn.call(recv);
      } else {
        return ruleFn.apply(recv, args.slice(0, +(ruleFnArity + 1) + 1 || 9e9));
      }
    };

    OMeta.prototype._prependInput = function(v) {
      return this.input = new OMInputStream(v, this.input);
    };

    OMeta.prototype.memoizeParameterizedRules = function() {
      this._prependInput = function(v) {
        var newInput;
        newInput = null;
        if (isImmutable(v)) {
          newInput = this.input[getTag(v)];
          if (!newInput) {
            newInput = new OMInputStream(v, this.input);
            this.input[getTag(v)] = newInput;
          }
        } else {
          newInput = new OMInputStream(v, this.input);
        }
        return this.input = newInput;
      };
      return this._applyWithArgs = function(rule) {
        var idx, ruleFn, ruleFnArity, _i, _ref;
        ruleFn = this[rule];
        ruleFnArity = ruleFn.length;
        for (idx = _i = _ref = args.length - 1; _i >= ruleFnArity; idx = _i += -1) {
          this._prependInput(arguments[idx]);
        }
        if (ruleFnArity === 0) {
          return this._apply(rule);
        } else {
          return this[rule].apply(this, arguments.slice(0, +ruleFnArity + 1 || 9e9));
        }
      };
    };

    OMeta.prototype._pred = function(b) {
      if (b) {
        return true;
      }
      throw this.fail;
    };

    OMeta.prototype._not = function(x) {
      var origInput;
      origInput = this.input;
      try {
        x.call(this);
      } catch (f) {
        if (f !== this.fail) {
          throw f;
        }
        this.input = origInput;
        return true;
      }
      throw this.fail;
    };

    OMeta.prototype._lookahead = function(x) {
      var origInput, r;
      origInput = this.input;
      r = x.call(this);
      this.input = origInput;
      return r;
    };

    OMeta.prototype._or = function() {
      var arg, origInput, _i, _len;
      origInput = this.input;
      for (_i = 0, _len = arguments.length; _i < _len; _i++) {
        arg = arguments[_i];
        try {
          this.input = origInput;
          return arg.call(this);
        } catch (f) {
          if (f !== this.fail) {
            throw f;
          }
        }
      }
      throw this.fail;
    };

    OMeta.prototype._xor = function(ruleName) {
      var ans, idx, newInput, origInput;
      origInput = this.input;
      idx = 1;
      newInput = ans = null;
      while (idx < arguments.length) {
        try {
          this.input = origInput;
          ans = arguments[idx].call(this);
          if (newInput) {
            throw 'more than one choice matched by "exclusive-OR" in ' + ruleName;
          }
          newInput = this.input;
        } catch (f) {
          if (f !== this.fail) {
            throw f;
          }
        }
        idx++;
      }
      if (newInput) {
        this.input = newInput;
        return ans;
      } else {
        throw this.fail;
      }
    };

    OMeta.prototype.disableXORs = function() {
      return this._xor = this._or;
    };

    OMeta.prototype._opt = function(x) {
      var ans, origInput;
      origInput = this.input;
      ans = void 0;
      try {
        ans = x.call(this);
      } catch (f) {
        if (f !== this.fail) {
          throw f;
        }
        this.input = origInput;
      }
      return ans;
    };

    OMeta.prototype._many = function(x) {
      var ans, origInput;
      ans = arguments[1] !== void 0 ? [arguments[1]] : [];
      while (true) {
        origInput = this.input;
        try {
          ans.push(x.call(this));
        } catch (f) {
          if (f !== this.fail) {
            console.log("many error");
            console.log(f);
            throw f;
          }
          this.input = origInput;
          break;
        }
      }
      return ans;
    };

    OMeta.prototype._many1 = function(x) {
      return this._many(x, x.call(this));
    };

    OMeta.prototype._form = function(x) {
      var origInput, r, v;
      v = this._apply("anything");
      if (!isSequenceable(v)) {
        throw this.fail;
      }
      origInput = this.input;
      this.input = ListOMInputStream.toStream(v);
      r = x.call(this);
      this._apply("end");
      this.input = origInput;
      return v;
    };

    OMeta.prototype._consumedBy = function(x) {
      var origInput;
      origInput = this.input;
      x.call(this);
      return origInput.upTo(this.input);
    };

    OMeta.prototype._idxConsumedBy = function(x) {
      var origInput;
      origInput = this.input;
      x.call(this);
      return [origInput.idx, this.input.idx];
    };

    OMeta.prototype._interleave = function(mode1, part1, mode2, part2) {
      var allDone, ans, arg, currInput, idx, _i, _len;
      currInput = this.input;
      ans = [];
      for (idx = _i = 0, _len = arguments.length; _i < _len; idx = _i += 2) {
        arg = arguments[idx];
        ans[idx / 2] = arg === "*" || arg === "+" ? [] : void 0;
      }
      while (true) {
        idx = 0;
        allDone = true;
        while (idx < arguments.length) {
          if (arguments[idx] !== "0") {
            try {
              this.input = currInput;
              switch (arguments[idx]) {
                case "*":
                  ans[idx / 2].push(arguments[idx + 1].call(this));
                  break;
                case "+":
                  ans[idx / 2].push(arguments[idx + 1].call(this));
                  arguments[idx] = "*";
                  break;
                case "?":
                  ans[idx / 2] = arguments[idx + 1].call(this);
                  arguments[idx] = "0";
                  break;
                case "1":
                  ans[idx / 2] = arguments[idx + 1].call(this);
                  arguments[idx] = "0";
                  break;
                default:
                  throw "invalid mode '" + arguments[idx] + "' in OMeta._interleave";
              }
              currInput = this.input;
              break;
            } catch (f) {
              if (f !== this.fail) {
                throw f;
              }
              allDone = allDone && (arguments[idx] === "*" || arguments[idx] === "?");
            }
          }
          idx += 2;
        }
        if (idx === arguments.length) {
          if (allDone) {
            return ans;
          } else {
            throw this.fail;
          }
        }
      }
    };

    OMeta.prototype._currIdx = function() {
      return this.input.idx;
    };

    OMeta.prototype.anything = function() {
      var r;
      r = this.input.head();
      this.input = this.input.tail();
      return r;
    };

    OMeta.prototype.end = function() {
      return this._not(function() {
        return this._apply("anything");
      });
    };

    OMeta.prototype.pos = function() {
      return this.input.idx;
    };

    OMeta.prototype.empty = function() {
      return true;
    };

    OMeta.prototype.apply = function(r) {
      return this._apply(r);
    };

    OMeta.prototype.foreign = function(g, r) {
      var ans, gi;
      gi = new g(makeOMInputStreamProxy(this.input));
      ans = gi._apply(r);
      this.input = gi.input.target;
      return ans;
    };

    OMeta.prototype.exactly = function(wanted) {
      if (wanted === this._apply("anything")) {
        return wanted;
      }
      throw this.fail;
    };

    OMeta.prototype["true"] = function() {
      var r;
      r = this._apply("anything");
      this._pred(r === true);
      return r;
    };

    OMeta.prototype["false"] = function() {
      var r;
      r = this._apply("anything");
      this._pred(r === false);
      return r;
    };

    OMeta.prototype.undefined = function() {
      var r;
      r = this._apply("anything");
      this._pred(r === void 0);
      return r;
    };

    OMeta.prototype.number = function() {
      var r;
      r = this._apply("anything");
      this._pred(typeof r === "number");
      return r;
    };

    OMeta.prototype.string = function() {
      var r;
      r = this._apply("anything");
      this._pred(typeof r === "string");
      return r;
    };

    OMeta.prototype.char = function() {
      var r;
      r = this._apply("anything");
      this._pred(typeof r === "string" && r.length === 1);
      return r;
    };

    OMeta.prototype.space = function() {
      var r;
      r = this._apply("char");
      this._pred(r.charCodeAt(0) <= 32);
      return r;
    };

    OMeta.prototype.spaces = function() {
      return this._many(function() {
        return this._apply("space");
      });
    };

    OMeta.prototype.digit = function() {
      var r;
      r = this._apply("char");
      this._pred(r >= "0" && r <= "9");
      return r;
    };

    OMeta.prototype.lower = function() {
      var r;
      r = this._apply("char");
      this._pred(r >= "a" && r <= "z");
      return r;
    };

    OMeta.prototype.upper = function() {
      var r;
      r = this._apply("char");
      this._pred(r >= "A" && r <= "Z");
      return r;
    };

    OMeta.prototype.letter = function() {
      return this._or((function() {
        return this._apply("lower");
      }), (function() {
        return this._apply("upper");
      }));
    };

    OMeta.prototype.letterOrDigit = function() {
      return this._or((function() {
        return this._apply("letter");
      }), (function() {
        return this._apply("digit");
      }));
    };

    OMeta.prototype.firstAndRest = function(first, rest) {
      return this._many((function() {
        return this._apply(rest);
      }), this._apply(first));
    };

    OMeta.prototype.seq = function(xs) {
      var x, _i, _len;
      for (_i = 0, _len = xs.length; _i < _len; _i++) {
        x = xs[_i];
        this._applyWithArgs("exactly", x);
      }
      return xs;
    };

    OMeta.prototype.notLast = function(rule) {
      var r;
      r = this._apply(rule);
      this._lookahead(function() {
        return this._apply(rule);
      });
      return r;
    };

    OMeta.prototype.listOf = function(rule, delim) {
      return this._or(function() {
        var r;
        r = this._apply(rule);
        return this._many(function() {
          this._applyWithArgs("token", delim);
          return this._apply(rule);
        }, r);
      }, function() {
        return [];
      });
    };

    OMeta.prototype.token = function(cs) {
      this._apply("spaces");
      return this._applyWithArgs("seq", cs);
    };

    OMeta.prototype.fromTo = function(x, y) {
      return this._consumedBy(function() {
        this._applyWithArgs("seq", x);
        this._many(function() {
          this._not(function() {
            return this._applyWithArgs("seq", y);
          });
          return this._apply("char");
        });
        return this._applyWithArgs("seq", y);
      });
    };

    OMeta.prototype.prepend = function(xs) {
      var i, _i, _ref, _results;
      _results = [];
      for (i = _i = _ref = xs.length - 1; _i >= 0; i = _i += -1) {
        _results.push(this._prependInput(xs[i]));
      }
      return _results;
    };

    OMeta.prototype.initialize = function() {};

    OMeta._genericMatch = function(input, rule, args, matchFailed) {
      var arg, m, realArgs, _i, _len;
      if (args == null) {
        args = [];
      }
      realArgs = [rule];
      for (_i = 0, _len = args.length; _i < _len; _i++) {
        arg = args[_i];
        realArgs.push(arg);
      }
      m = new this(input);
      try {
        if (realArgs.length === 1) {
          return m._apply.call(m, realArgs[0]);
        } else {
          return m._applyWithArgs.apply(m, realArgs);
        }
      } catch (f) {
        if (f === this.prototype.fail && (matchFailed != null)) {
          input = m.input;
          if (input.idx != null) {
            while ((input.tl != null) && (input.tl.idx != null)) {
              input = input.tl;
            }
            input.idx--;
          }
          return matchFailed(m, input.idx);
        }
        if (matchFailed != null) {
          console.log("Special error: " + f);
        }
        throw f;
      }
    };

    OMeta.match = function(obj, rule, args, matchFailed) {
      return this._genericMatch(ListOMInputStream.toStream([obj]), rule, args, matchFailed);
    };

    OMeta.matchAll = function(listyObj, rule, args, matchFailed) {
      return this._genericMatch(ListOMInputStream.toStream(listyObj), rule, args, matchFailed);
    };

    return OMeta;

  })();

}).call(this);
