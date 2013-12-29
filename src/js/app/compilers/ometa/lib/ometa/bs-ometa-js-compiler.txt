ometa BSOMetaJSParser <: BSJSParser {
  srcElem = spaces BSOMetaParser.grammar:r sc -> r
          | ^srcElem
}

ometa BSOMetaJSTranslator <: BSJSTranslator {
  Grammar = BSOMetaTranslator.Grammar
}

