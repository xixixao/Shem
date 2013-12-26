(function() {
  var __slice = [].slice;

  define(function() {
    var Command;
    Command = (function() {

      function Command(keywords, handler) {
        this.keywords = keywords;
        this.handler = handler;
      }

      Command.prototype.match = function(string) {
        var match;
        match = string.match(RegExp("^\\s*(?:" + (this.keywords.join('|')) + ")\\b((?:\\s+(?:.*\\\\|\\S+\\b))*)\\s*"));
        if (match) {
          this.handler.apply(this, match[1].split(/\s+/).slice(1));
        }
        return match;
      };

      return Command;

    })();
    return {
      initialize: function(commands) {
        var handler, keywords, _ref, _ref1, _results;
        _results = [];
        while (commands.length > 0) {
          _ref = span(commands, function(el) {
            return (typeOf(el)) === 'String';
          }), keywords = _ref[0], commands = _ref[1];
          _ref1 = commands, handler = _ref1[0], commands = 2 <= _ref1.length ? __slice.call(_ref1, 1) : [];
          _results.push(new Command(keywords, handler));
        }
        return _results;
      }
    };
  });

}).call(this);
