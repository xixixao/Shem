define [
 '../src/ometa-base',
 '../src/lib',
 '../bin/bs-js-compiler',
 '../bin/bs-ometa-compiler',
 '../bin/bs-ometa-optimizer',
 '../bin/bs-ometa-js-compiler'
 ], (OMeta, OMLib, BSJCCompiler, BSOmetaCompiler, BSOmetaOptimizer, BSOmetaJSCompiler, ErrorHandler) ->
  OMeta: OMeta
  OMLib: OMLib
  BSOMetaJSParser: BSOmetaJSCompiler.BSOMetaJSParser
  BSOMetaJSTranslator: BSOmetaJSCompiler.BSOMetaJSTranslator