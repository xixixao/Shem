Rules = require("ace/mode/coffee_highlight_rules").CoffeeHighlightRules


module.exports = class extends Rules

  constructor: ->
    super

    @$rules.start.unshift [
      token: "keyword"
      regex: "await"
    ,
      token: ["keyword", "variable.parameter"]
      regex: /(defer)([^)\]}]+)/.source
    ]...

