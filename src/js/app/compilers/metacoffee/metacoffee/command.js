(function() {
  var MetaCoffee, code, compiled, fileName, fs, path, targetDirectory, targetFileName;

  path = require('path');

  fs = require('fs');

  MetaCoffee = (require('./prettyfier'))(require('./index'));

  targetDirectory = process.argv[2];

  fileName = process.argv[3];

  code = fs.readFileSync(fileName, "utf-8");

  compiled = MetaCoffee.compile(code);

  targetFileName = path.basename(fileName, path.extname(fileName));

  fs.writeFileSync("" + targetDirectory + "/" + targetFileName + ".js", compiled, "utf-8");

}).call(this);
