(function() {

  define(function() {
    var UniqueTimeLine;
    return UniqueTimeLine = (function() {
      var El;

      El = (function() {

        function El(e, next, prev) {
          var _ref, _ref1;
          this.e = e;
          this.next = next;
          this.prev = prev;
          if ((_ref = this.prev) != null) {
            _ref.next = this;
          }
          if ((_ref1 = this.next) != null) {
            _ref1.prev = this;
          }
        }

        El.prototype.remove = function() {
          var _ref;
          return _ref = [this.next, this.prev], this.prev.next = _ref[0], this.next.prev = _ref[1], _ref;
        };

        return El;

      })();

      function UniqueTimeLine() {
        this.length = 0;
        this.head = new El;
        this.elems = new El;
        this.head.prev = this.elems;
        this.elems.next = this.head;
        this.now = this.head;
        this.set = {};
        this.temporary = null;
      }

      UniqueTimeLine.prototype.push = function(e) {
        var n, nn;
        nn = new El(e, this.head, this.head.prev);
        n = this.set[e];
        if (n != null) {
          n.remove();
        } else {
          this.length++;
        }
        this.set[e] = nn;
        return this.goNewest();
      };

      UniqueTimeLine.prototype.temp = function(e) {
        this.temporary = e;
        return this.goNewest();
      };

      UniqueTimeLine.prototype.goBack = function() {
        if (this.now.prev.e != null) {
          this.now = this.now.prev;
        }
        return this.curr();
      };

      UniqueTimeLine.prototype.goForward = function() {
        var res;
        res = this.curr();
        if (this.now.e != null) {
          this.now = this.now.next;
        }
        return this.curr();
      };

      UniqueTimeLine.prototype.goOldest = function() {
        this.now = this.elems.next;
        return this.curr();
      };

      UniqueTimeLine.prototype.goNewest = function() {
        this.now = this.head;
        return this.curr();
      };

      UniqueTimeLine.prototype.isInPast = function() {
        return this.now !== this.head;
      };

      UniqueTimeLine.prototype.curr = function() {
        if (this.now === this.head) {
          return this.temporary;
        } else {
          return this.now.e;
        }
      };

      UniqueTimeLine.prototype.newest = function(count) {
        var e, i, n, res, _i;
        n = this.head;
        res = [];
        for (i = _i = 0; 0 <= count ? _i < count : _i > count; i = 0 <= count ? ++_i : --_i) {
          if (e = n.prev.e) {
            res.push(e);
            n = n.prev;
          } else {
            break;
          }
        }
        return res.reverse();
      };

      UniqueTimeLine.prototype.from = function(arr) {
        var e, _i, _len;
        for (_i = 0, _len = arr.length; _i < _len; _i++) {
          e = arr[_i];
          this.push(e);
        }
        return this.goNewest();
      };

      UniqueTimeLine.prototype.size = function() {
        return this.length;
      };

      return UniqueTimeLine;

    })();
  });

}).call(this);
