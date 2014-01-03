React = require 'React'
{_div} = require 'hyper'
$ = require 'ejquery'

module.exports = React.createClass

  componentDidMount: ->
    $(@getDOMNode()).draggable
      axis: 'x'
      drag: (e, ui) =>
        @props.onDrag ui.offset.left
        ui.position = ui.originalPosition

  render: ->
    @transferPropsTo _div
        className: 'movableDivider'
