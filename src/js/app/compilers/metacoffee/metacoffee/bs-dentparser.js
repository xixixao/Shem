(function() {
  var OMeta, Stack, subclass, _ref;

  OMeta = require('./ometa-base');

  _ref = require('./ometa-lib'), subclass = _ref.subclass, Stack = _ref.Stack;

  BSDentParser = subclass(OMeta, {
    "initialize": function() {
      return this.mindent = new Stack().push(-1)
    },
    "exactly": function() {
      var other;
      return this._or((function() {
        return (function() {
          switch (this._apply('anything')) {
            case "\n":
              return this._applyWithArgs("apply", "nl");
            default:
              throw this.fail
          }
        }).call(this)
      }), (function() {
        return (function() {
          other = this._apply("anything");
          return OMeta._superApplyWithArgs(this, 'exactly', other)
        }).call(this)
      }))
    },
    "inspace": function() {
      return (function() {
        this._not((function() {
          return this._applyWithArgs("exactly", '\n')
        }));
        return this._apply("space")
      }).call(this)
    },
    "nl": function() {
      var p;
      return (function() {
        OMeta._superApplyWithArgs(this, 'exactly', '\n');
        p = this._apply("pos");
        this.lineStart = p;
        return '\n'
      }).call(this)
    },
    "blankLine": function() {
      return (function() {
        this._many((function() {
          return this._apply("inspace")
        }));
        return this._applyWithArgs("exactly", "\n")
      }).call(this)
    },
    "dent": function() {
      var ss;
      return (function() {
        this._many((function() {
          return this._apply("inspace")
        }));
        this._applyWithArgs("exactly", "\n");
        this._many((function() {
          return this._apply("blankLine")
        }));
        ss = this._many((function() {
          return this._applyWithArgs("exactly", " ")
        }));
        return ss.length
      }).call(this)
    },
    "linePos": function() {
      var p;
      return (function() {
        p = this._apply("pos");
        return p - (this.lineStart || 0)
      }).call(this)
    },
    "stripdent": function() {
      var d, p;
      return (function() {
        d = this._apply("anything");
        p = this._apply("anything");
        return '\n' + Array(d - p).join(' ')
      }).call(this)
    },
    "nodent": function() {
      var p, d;
      return (function() {
        p = this._apply("anything");
        d = this._apply("dent");
        return this._pred(d === p)
      }).call(this)
    },
    "moredent": function() {
      var p, d;
      return (function() {
        p = this._apply("anything");
        d = this._apply("dent");
        this._pred(d >= p);
        return this._applyWithArgs("stripdent", d, p)
      }).call(this)
    },
    "lessdent": function() {
      var p, d;
      return (function() {
        p = this._apply("anything");
        return this._or((function() {
          return (function() {
            d = this._apply("dent");
            return this._pred(d <= p)
          }).call(this)
        }), (function() {
          return (function() {
            this._many((function() {
              return this._apply("inspace")
            }));
            return this._apply("end")
          }).call(this)
        }))
      }).call(this)
    },
    "setdent": function() {
      var p;
      return (function() {
        p = this._apply("anything");
        return this.mindent.push(p)
      }).call(this)
    },
    "redent": function() {
      return this.mindent.pop()
    },
    "spacedent": function() {
      return (function() {
        this._pred(this.mindent.top() >= 0);
        return this._applyWithArgs("moredent", this.mindent.top())
      }).call(this)
    }
  });;

  module.exports = BSDentParser;

}).call(this);