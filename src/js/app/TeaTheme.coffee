# theme =
# keyword: 'red'
# numerical: '#FEDF6B'
# typename: '#9C49B6'
# label: '#9C49B6'
# string: '#FEDF6B'
# paren: '#444'
# name: '#9EE062'
# recurse: '#67B3DD'
# param: '#FDA947'
# comment: 'grey'
# operator: '#cceeff'
# normal: 'white'

exports.isDark = true
exports.cssClass = "ace-tea"
exports.cssText = """
.ace_layer, .ace_content {
    overflow: visible !important;
}

.ace-tea .ace_gutter {
  background: #222;
  color: #444
}

.ace-tea .ace_print-margin {
  width: 1px;
  background: #011e3a
}

.ace-tea {
  background-color: #222;
  color: #FFFFFF
}

.ace-tea .ace_cursor {
  color: #FFFFFF
}

.ace-tea .ace_marker-layer .ace_selection {
  border-radius: 1px;
  border: 2px solid rgba(0, 170, 255, 0.75);
  border-width: 0 0 2px 0
}

.ace-tea .ace_marker-layer .ace_active-token {
  position: absolute;
  border-radius: 1px;
  border: 2px solid rgba(0, 170, 255, 0.25);
  border-width: 0 0 2px 0
}

.ace-tea.ace_multiselect .ace_selection.ace_start {
  box-shadow: 0 0 3px 0px #002240;
  border-radius: 2px
}

.ace-tea .ace_marker-layer .ace_step {
  background: rgb(127, 111, 19)
}

.ace-tea .ace_marker-layer .ace_bracket {
  margin: -1px 0 0 -1px;
  border: 1px solid rgba(255, 255, 255, 0.15)
}

.ace-tea .ace_marker-layer .ace_active-line {
  background: rgba(0, 0, 0, 0.35)
}

.ace-tea .ace_gutter-active-line {
  background-color: rgba(0, 0, 0, 0.35)
}

/*.ace-tea .ace_marker-layer .ace_selected-word {
  border: 1px solid rgba(179, 101, 57, 0.75)
}*/

.ace-tea .ace_invisible {
  color: rgba(255, 255, 255, 0.15)
}

.ace-tea .ace_indent-guide {
  background: url(data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAACCAYAAACZgbYnAAAAEklEQVQImWNgYGBgYHCLSvkPAAP3AgSDTRd4AAAAAElFTkSuQmCC) right repeat-y
}

.ace-tea .ace_token_keyword {
  color: red
}

.ace-tea .ace_token_numerical {
  color: #FEDF6B
}

.ace-tea .ace_token_typename {
  color: #9C49B6
}

.ace-tea .ace_token_label {
  color: #9C49B6
}

.ace-tea .ace_token_string {
  color: #FEDF6B
}

.ace-tea .ace_token_paren {
  color: #444
}

.ace-tea .ace_token_name {
  color: #9EE062
}

.ace-tea .ace_token_recurse {
  color: #67B3DD
}

.ace-tea .ace_token_param {
  color: #FDA947
}

.ace-tea .ace_token_comment {
  color: grey
}

.ace-tea .ace_token_operator {
  color: #cceeff
}

.ace-tea .ace_token_normal {
  color: white
}

"""

dom = require("ace/lib/dom")
dom.importCssString(exports.cssText, exports.cssClass)

