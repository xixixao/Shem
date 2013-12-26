(function() {
  var __slice = [].slice;

  define(function() {
    var History;
    return History = (function() {
      var insert;

      function History() {
        this.data = [];
      }

      History.prototype.add = function(change) {
        return this.data.push(change);
      };

      History.prototype.print = function(log) {
        var point, text, _i, _len, _ref, _results;
        text = [""];
        _ref = this.data;
        _results = [];
        for (_i = 0, _len = _ref.length; _i < _len; _i++) {
          point = _ref[_i];
          insert(text, point.from, point.to, point.text);
          _results.push(log(text));
        }
        return _results;
      };

      insert = function(text, from, to, what) {
        var appended, curr, newLines, oldLines, singleLine;
        singleLine = from.line === to.line;
        if (singleLine) {
          curr = text[from.line];
          text[from.line] = curr.slice(0, from.ch) + what[0] + curr.slice(to.ch);
        } else {
          text[from.line] = text[from.line].slice(0, from.ch) + what[0];
          text[to.line] = what[what.length - 1] + text[to.line].slice(to.ch);
        }
        newLines = what.length;
        oldLines = 1 + to.line - from.line;
        if (newLines > 2 || oldLines > 2) {
          appended = singleLine ? what.slice(1) : what.slice(1, -1);
          return text.splice.apply(text, [from.line + 1, Math.max(0, oldLines - newLines)].concat(__slice.call(appended)));
        }
      };

      History.prototype.merge = function() {};

      return History;

    })();
  });

}).call(this);
