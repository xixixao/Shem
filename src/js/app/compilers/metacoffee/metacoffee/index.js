(function() {
  var BSMetaCoffeeParser, BSMetaCoffeeTranslator, OMLib, OMeta, runtime, _ref;

  OMeta = require('./ometa-base');

  OMLib = require('./ometa-lib');

  _ref = require('./bs-metacoffee-compiler'), BSMetaCoffeeParser = _ref.BSMetaCoffeeParser, BSMetaCoffeeTranslator = _ref.BSMetaCoffeeTranslator;

  runtime = OMLib.extend({
    OMeta: OMeta
  }, OMLib);

  module.exports = {
    runtime: runtime,
    installRuntime: function(to) {
      return OMLib.extend(to, runtime);
    },
    compile: function(code, options) {
      var result, tree;
      if (options == null) {
        options = {};
      }
      tree = BSMetaCoffeeParser.matchAll(code, "topLevel", void 0, function(m, i) {
        var error;
        error = new SyntaxError("Parse error");
        error.position = i;
        throw error;
      });
      return result = BSMetaCoffeeTranslator.matchAll(tree, "trans", [options.bare], function(m, i) {
        throw new SyntaxError("Translation error");
      });
    }
  };

}).call(this);
