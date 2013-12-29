//require.config({
//});
require({
  paths: {
    cs:              '../lib/requirejs/cs',
    'coffee-script': '../lib/cs/coffee-script-iced'
  }
},
 ['../src/ometa-base',
 '../src/lib',
 '../bin/bs-js-compiler',
 '../bin/bs-ometa-compiler',
 '../bin/bs-ometa-optimizer',
 '../bin/bs-ometa-js-compiler',
 './ErrorHandler'
 ],
 function (OMeta, OMLib, BSJCCompiler, BSOmetaCompiler, BSOmetaOptimizer, BSOmetaJSCompiler, ErrorHandler) {

  function compileSource(sourceCode) {    
    try {
      var tree = BSOmetaJSCompiler.BSOMetaJSParser.matchAll(
        sourceCode, "topLevel", undefined, function(m, i) {        
          handled = ErrorHandler.handle(m, i);
          throw new Error("Error at line: " + handled.lineNumber + "\n\n" + 
            ErrorHandler.bottomErrorArrow(handled));          
        }
      );
      var result = BSOmetaJSCompiler.BSOMetaJSTranslator.match(
        tree, "trans", undefined, function(m, i) {
        throw new Error("Translation error - please tell Alex about this!");           
        }
      );   
    } catch (e) {
      console.log(e);
      return e.toString();
    }
    
    return result;

  }

  $("#doIt").click(function (e){
    var result = compileSource($("#source").val());
    $("#result").text(result);
  });


  $("#runIt").click(function (e){    
    var translation = compileSource($("#source").val());    

    lib = "BSOMetaJSParser = BSOmetaJSCompiler.BSOMetaJSParser;" +
    "BSOmetaJSTranslator = BSOmetaJSCompiler.BSOmetaJSTranslator;" +
    "escapeChar = OMLib.escapeChar;" +
    "unescape = OMLib.unescape;" +
    "propertyNames = OMLib.propertyNames;" +
    "programString = OMLib.programString;" +
    "subclass = OMLib.subclass;" +
    "StringBuffer = OMLib.StringBuffer;"
    console.log(lib + translation);
    var result = eval(lib + translation);
    $("#result").text(result);
 });
});