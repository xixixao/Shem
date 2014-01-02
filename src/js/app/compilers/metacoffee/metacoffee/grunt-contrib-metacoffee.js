(function() {

  module.exports = function(grunt) {
    var compileMetaCoffee;
    grunt.registerMultiTask('metacoffee', 'Compile MetaCoffee files into JavaScript', function() {
      var options;
      options = this.options({
        bare: false,
        separator: grunt.util.linefeed
      });
      grunt.verbose.writeflags(options, 'Options');
      return this.files.forEach(function(f) {
        var output;
        output = f.src.filter(function(filepath) {
          if (!grunt.file.exists(filepath)) {
            grunt.log.warn('Source file "' + filepath + '" not found.');
            return false;
          } else {
            return true;
          }
        }).map(function(filepath) {
          return compileMetaCoffee(filepath, options);
        }).join(grunt.util.normalizelf(options.separator));
        if (output.length < 1) {
          return grunt.log.warn('Destination not written because compiled files were empty.');
        } else {
          grunt.file.write(f.dest, output);
          return grunt.log.writeln('File ' + f.dest + ' created.');
        }
      });
    });
    return compileMetaCoffee = function(srcFile, options) {
      var srcCode;
      srcCode = grunt.file.read(srcFile);
      try {
        return (require('./prettyfier')(require('./index'))).compile(srcCode);
      } catch (e) {
        grunt.log.error(e);
        return grunt.fail.warn('MetaCoffee failed to compile.');
      }
    };
  };

}).call(this);
