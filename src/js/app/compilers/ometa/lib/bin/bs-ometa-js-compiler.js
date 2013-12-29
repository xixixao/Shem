define([
  '../src/ometa-base',
  '../src/lib',
  '../bin/bs-js-compiler',
  '../bin/bs-ometa-compiler'
], function (OMeta, OMLib, BSJSCompiler, BSOMetaCompiler){
subclass = OMLib.subclass;
BSJSParser = BSJSCompiler.BSJSParser;
BSJSTranslator = BSJSCompiler.BSJSTranslator;
BSOMetaParser = BSOMetaCompiler.BSOMetaParser;
BSOMetaTranslator = BSOMetaCompiler.BSOMetaTranslator;

BSOMetaJSParser=subclass(BSJSParser,{
"srcElem":function(){var $elf=this,_fromIdx=this.input.idx,r;return this._or((function(){return (function(){this._apply("spaces");r=this._applyWithArgs("foreign",BSOMetaParser,'grammar');this._apply("sc");return r}).call(this)}),(function(){return BSJSParser._superApplyWithArgs(this,'srcElem')}))}});
BSOMetaJSTranslator=subclass(BSJSTranslator,{
"Grammar":function(){var $elf=this,_fromIdx=this.input.idx;return this._applyWithArgs("foreign",BSOMetaTranslator,'Grammar')}});

  api = {
    BSOMetaJSParser: BSOMetaJSParser,
    BSOMetaJSTranslator: BSOMetaJSTranslator    
  }
  OMLib.extend(OMeta.interpreters, api);
  return api;
});