Rules = require("ace/mode/coffee_highlight_rules").CoffeeHighlightRules


module.exports = class extends Rules

  constructor: ->
    super

    identifier = "[$A-Za-z_\\x7f-\\uffff][$\\w\\x7f-\\uffff]*";

    @$rules.start.unshift [
      # meta A extends B
      token : ["keyword", "text", "language.support.class",
               "text", "keyword", "text", "language.support.class"],
      regex : "(ometa)(\\s+)(" + identifier + ")(?:(\\s+)(extends)(\\s+)(" + identifier + "))?"
    ]...

