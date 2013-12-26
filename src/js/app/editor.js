(function() {
  var __slice = [].slice,
    __indexOf = [].indexOf || function(item) { for (var i = 0, l = this.length; i < l; i++) { if (i in this && this[i] === item) return i; } return -1; };

  define(['ejquery', 'vendor/prelude/prelude-browser-min', 'vendor/codemirror/codemirror', 'app/UniqueTimeLine', 'app/Commands', 'app/History', 'vendor/jsDump'], function($, Prelude, CodeMirror, TimeLine, Commands, History, jsDump) {
    var AUTOSAVE_DELAY, BROWSE_COOKIE, LAST_CODE, TIMELINE_COOKIE, UNNAMED_CODE, addMessage, ammendClientTable, autoCompile, autosave, commandArea, commandAreaKeyEvent, commands, compileAndRun, compileCode, compileSource, compiledJS, compiler, compilerOptions, cookieFilePrefix, createCanvas, currentMessage, currentMode, defaultEditor, displayClient, displayModes, dump, eraseMessages, execute, exitCurrentCode, fileCookie, getCompilerOptions, getCurrentMessage, getMessage, hash, helpDescription, hideError, history, hlLine, isCurrentMessage, lastErrorType, lastHit, loadFromClient, loadTimeline, loadWith, log, modes, modesList, outputScrollTop, printHistory, removeFromClient, repeat, resizeEditor, run, saveCurrent, saveName, saveTimeline, saveToAdress, selectLastOutput, setCurrentMessage, setMaxPreWidth, setMode, setNewMode, showErrorMessage, showFileMessage, showImportantMessage, sourceArea, sourceChange, sourceChanged, sourceCompiled, sourceFragment, src, switchCurrentCode, timeline, toggleAutoCompilation;
    console.log("Loaded sourceArea");
    Prelude.installPrelude(window);
    sourceFragment = "try:";
    compiledJS = '';
    compiler = null;
    compilerOptions = null;
    sourceCompiled = false;
    autoCompile = true;
    lastHit = 0;
    lastErrorType = "";
    currentMode = "";
    AUTOSAVE_DELAY = 6000;
    LAST_CODE = "lastEditedSourceCodeCOOKIE";
    UNNAMED_CODE = "@unnamed";
    TIMELINE_COOKIE = "timelineCOOKIE";
    sourceChanged = false;
    saveName = UNNAMED_CODE;
    cookieFilePrefix = "TeaTableFile_";
    timeline = new TimeLine;
    addMessage = function(text, id) {
      var newMessage, tag;
      tag = id != null ? " data-id=" + id : "";
      newMessage = $(("<pre" + tag + ">") + text + "</pre>");
      $('#output').prepend(newMessage);
      return setMaxPreWidth(newMessage);
    };
    eraseMessages = function() {
      var except, excepts;
      except = 1 <= arguments.length ? __slice.call(arguments, 0) : [];
      excepts = join(', ', except);
      return $('#output').children().not(function() {
        return $(this).find(excepts).size() > 0;
      }).remove();
    };
    getMessage = function(n) {
      return $('#output pre').eq(n);
    };
    getCurrentMessage = function() {
      return getMessage(0);
    };
    setCurrentMessage = function(text, id) {
      return getCurrentMessage().text(text).data('id', id);
    };
    isCurrentMessage = function(id) {
      return getCurrentMessage().data('id') === id;
    };
    log = function() {
      var i, input, lastMessage, message;
      input = 1 <= arguments.length ? __slice.call(arguments, 0) : [];
      input = (function() {
        var _i, _len, _results;
        _results = [];
        for (_i = 0, _len = input.length; _i < _len; _i++) {
          i = input[_i];
          _results.push(jsDump.parse(i != null ? i : "Nothing"));
        }
        return _results;
      })();
      message = input.join(", ");
      if (message.length > 0) addMessage(lastMessage = message);
    };
    repeat = function(string, num) {
      var i, result, _i, _len;
      result = "";
      for (_i = 0, _len = num.length; _i < _len; _i++) {
        i = num[_i];
        result += string;
      }
      return result;
    };
    showImportantMessage = function(type, message) {
      $("#messages").attr("class", type);
      $("#messages pre").text(message);
      return $("#messages").stop(true, true).fadeIn(200);
    };
    showErrorMessage = function(type, message) {
      lastErrorType = type;
      return showImportantMessage("errorMessage", message);
    };
    showFileMessage = function(message) {
      return showImportantMessage("fileMessage", message);
    };
    currentMessage = function() {
      return $("#messages pre").text();
    };
    hideError = function() {
      var types;
      types = 1 <= arguments.length ? __slice.call(arguments, 0) : [];
      if (__indexOf.call(types, lastErrorType) >= 0) {
        return $("#messages").fadeOut(700);
      }
    };
    dump = function() {
      if (!sourceCompiled) compileCode();
      if (compiledJS) {
        return log(compiledJS);
      } else {
        return showErrorMessage("compiler", "Fix: '" + (currentMessage()) + "' first");
      }
    };
    run = function() {
      if (!sourceCompiled) compileCode();
      if (compiledJS) {
        return execute(compiledJS);
      } else {
        return showErrorMessage("compiler", "Fix: '" + (currentMessage()) + "' first");
      }
    };
    commands = Commands.initialize([
      "dump", "d", function() {
        return dump();
      }, "run", "r", function() {
        return run();
      }, "erase", "e", function() {
        return eraseMessages.apply(null, arguments);
      }, "copy", "c", function() {
        return selectLastOutput();
      }, "link", "l", function() {
        return saveToAdress();
      }, "toggle", "t", function() {
        return toggleAutoCompilation();
      }, "save", function() {
        return switchCurrentCode.apply(null, arguments);
      }, "load", function() {
        return loadFromClient.apply(null, arguments);
      }, "close", function() {
        return exitCurrentCode();
      }, "delete", function() {
        return removeFromClient.apply(null, arguments);
      }, "modes", "m", function() {
        return displayModes();
      }, "mode", function() {
        return setMode.apply(null, arguments);
      }, "canvas", function() {
        return createCanvas.apply(null, arguments);
      }, "browse", "b", function() {
        return displayClient();
      }, "help", "h", function() {
        return log(helpDescription);
      }, "ph", function() {
        return history.print(log);
      }
    ]);
    compileAndRun = function() {
      var command, match, pref, source, _i, _len;
      source = $.trim(commandArea.getValue());
      if (source.length === 0) return;
      timeline.push(source);
      hideError("command", "runtime");
      try {
        if (pref = source.match(/^(< |:)/)) {
          source = source.slice(pref[0].length);
          for (_i = 0, _len = commands.length; _i < _len; _i++) {
            command = commands[_i];
            match = command.match(source);
            if (match != null) break;
          }
          saveTimeline();
          return outputScrollTop();
        } else {
          command = compiler.compile(source, getCompilerOptions());
          try {
            log(execute(compiledJS + command));
            saveTimeline();
            return outputScrollTop();
          } catch (error) {
            return showErrorMessage("runtime", "Runtime: " + error);
          }
        }
      } catch (error) {
        console.log(error);
        return showErrorMessage("command", "Command Line: " + error.message);
      }
    };
    modes = {
      CoffeeScript: {
        id: "coffeescript",
        options: {
          bare: true
        }
      },
      IcedCoffeeScript: {
        id: "icedcoffeescript",
        options: {
          bare: true
        }
      },
      Ometa: {
        id: "ometa"
      },
      MetaCoffee: {
        id: "metacoffee"
      }
    };
    modesList = function() {
      return join('\n', map(keys(modes), function(mode) {
        return (mode === currentMode ? '> ' : '  ') + mode;
      }));
    };
    displayModes = function() {
      return addMessage(modesList(), 'modesList');
    };
    setNewMode = function(name, callback) {
      if (name !== currentMode) {
        return setMode(name, callback);
      } else {
        return typeof callback === "function" ? callback() : void 0;
      }
    };
    setMode = function(name, callback) {
      var id, mode;
      mode = modes[name];
      if (mode != null) {
        id = mode.id;
        return require(["vendor/compilers/" + id + "/compiler", "vendor/compilers/" + id + "/highlighter"], function(compilerClass, highlighter) {
          compiler = compilerClass;
          compilerOptions = mode.options;
          sourceArea.setOption("mode", id);
          commandArea.setOption("mode", id);
          if (typeof mode.init === "function") mode.init();
          currentMode = name;
          if (isCurrentMessage('modesList')) {
            setCurrentMessage(modesList(), 'modesList');
          } else {
            log("" + name + " compiler loaded");
          }
          compileCode();
          return typeof callback === "function" ? callback() : void 0;
        }, function(error) {
          return log("" + name + " loading failed");
        });
      } else {
        return log("Wrong mode name, choose from:\n\n" + modesList());
      }
    };
    createCanvas = function(width, height) {
      return log("#canvas\n" + ("<canvas id='canvas' width=" + width + " height=" + height + "></canvas>"));
    };
    toggleAutoCompilation = function() {
      autoCompile = !autoCompile;
      return log("Autocompilation switched " + (autoCompile ? "on" : "off"));
    };
    getCompilerOptions = function() {
      return $.extend({}, compilerOptions);
    };
    compileCode = function() {
      var endColor, indicateBy, indicator, normalColor, startColor;
      startColor = "#151515";
      endColor = "#ccc";
      normalColor = "#050505";
      indicator = $('#compilationIndicator');
      indicateBy = function(color) {
        return indicator.animate({
          'color': color
        }, {
          'complete': function() {
            return indicator.css({
              'color': color
            });
          }
        });
      };
      return compileSource((function() {
        return indicateBy(startColor);
      }), function() {
        indicateBy(endColor);
        return indicateBy(normalColor);
      });
    };
    compileSource = function(start, finish) {
      var source, _ref;
      start();
      source = sourceArea.getValue();
      compiledJS = '';
      saveCurrent();
      try {
        compiledJS = compiler.compile(source, getCompilerOptions());
        hideError("compiler", "runtime");
      } catch (error) {
        showErrorMessage("compiler", "Compiler: " + ((_ref = error.message) != null ? _ref : error));
      }
      sourceCompiled = true;
      finish();
      return $('#repl_permalink').attr('href', "#" + sourceFragment + (encodeURIComponent(source)));
    };
    execute = function(code) {
      var _ref;
      return eval((_ref = typeof compiler.preExecute === "function" ? compiler.preExecute(code) : void 0) != null ? _ref : code);
    };
    history = new History;
    sourceChange = function(inst, e) {
      var DELAY;
      sourceCompiled = false;
      sourceChanged = true;
      history.add(e);
      if (!autoCompile) return;
      DELAY = 700;
      lastHit = +(new Date);
      return setTimeout(function() {
        if (+new Date() - lastHit > DELAY) {
          if (!sourceCompiled) return compileCode();
        }
      }, 2 * DELAY);
    };
    printHistory = function() {
      var insert, point, text, _i, _len, _results;
      text = [""];
      insert = function(from, to, what) {
        var appended, curr, newLines, oldLines, singleLine;
        singleLine = from.line === to.line;
        if (singleLine) {
          curr = text[from.line];
          text[from.line] = curr.slice(0, from.ch) + what[0] + curr.slice(to.ch);
        } else {
          text[from.line] = text[from.line].slice(0, from.ch) + what[0];
          text[to.line] = what[what.length - 1] + text[to.line].slice(to.ch);
        }
        newLines = what.length;
        oldLines = 1 + to.line - from.line;
        if (newLines > 2 || oldLines > 2) {
          appended = singleLine ? what.slice(1) : what.slice(1, -1);
          return text.splice.apply(text, [from.line + 1, Math.max(0, oldLines - newLines)].concat(__slice.call(appended)));
        }
      };
      _results = [];
      for (_i = 0, _len = history.length; _i < _len; _i++) {
        point = history[_i];
        insert(point.from, point.to, point.text);
        _results.push(log(text));
      }
      return _results;
    };
    BROWSE_COOKIE = "table";
    autosave = function() {
      return setTimeout(function() {
        if (sourceChanged) {
          saveCurrent();
          sourceChanged = false;
        }
        return autosave();
      }, AUTOSAVE_DELAY);
    };
    fileCookie = function(name, value) {
      return $.totalStorage(cookieFilePrefix + name, value);
    };
    saveCurrent = function() {
      var exists, source, value, valueLines;
      source = sourceArea.getValue();
      value = {
        source: source,
        mode: currentMode
      };
      valueLines = (source.split("\n")).length;
      exists = false;
      ammendClientTable(saveName, "" + saveName + "," + valueLines);
      fileCookie(saveName, value);
      return $.totalStorage(LAST_CODE, saveName);
    };
    saveTimeline = function() {
      return $.totalStorage(TIMELINE_COOKIE, timeline.newest(200));
    };
    loadTimeline = function() {
      var _ref;
      return timeline.from((_ref = $.totalStorage(TIMELINE_COOKIE)) != null ? _ref : []);
    };
    removeFromClient = function(name) {
      if (name == null) return;
      fileCookie(saveName, null);
      ammendClientTable(name);
      return showFileMessage("" + name + " deleted");
    };
    ammendClientTable = function(exclude, addition) {
      var lines, name, oldTable, pair, table, _i, _len, _ref, _ref1;
      if (addition == null) addition = null;
      table = [];
      oldTable = $.totalStorage(BROWSE_COOKIE);
      if (oldTable != null) {
        _ref = oldTable.split(";");
        for (_i = 0, _len = _ref.length; _i < _len; _i++) {
          pair = _ref[_i];
          _ref1 = pair.split(","), name = _ref1[0], lines = _ref1[1];
          if (name !== exclude) table.push(pair);
        }
      }
      if (addition) table.push(addition);
      table = table.join(";");
      if (table.length === 0) table = null;
      return $.totalStorage(BROWSE_COOKIE, table);
    };
    loadFromClient = function(name) {
      var mode, source, stored;
      if (name == null) name = $.totalStorage(LAST_CODE);
      if (name == null) {
        if (compiler == null) setMode("IcedCoffeeScript");
        return;
      }
      stored = fileCookie(name);
      if (stored != null) {
        saveName = name;
        source = stored.source, mode = stored.mode;
        sourceArea.setValue(source);
        return setNewMode(mode, function() {
          if (saveName !== UNNAMED_CODE) {
            return showFileMessage("" + saveName + " loaded");
          }
        });
      } else {
        if (name !== UNNAMED_CODE) return showFileMessage("There is no " + name);
      }
    };
    exitCurrentCode = function() {
      saveCurrent();
      saveName = UNNAMED_CODE;
      sourceArea.setValue("");
      return saveCurrent();
    };
    switchCurrentCode = function(name) {
      saveCurrent();
      saveName = name;
      saveCurrent();
      return showFileMessage("Working on " + saveName);
    };
    displayClient = function() {
      var lines, name, output, snippet, table, _i, _len, _ref, _ref1;
      table = $.totalStorage(BROWSE_COOKIE);
      output = "";
      if ((table != null) && table.length > 0) {
        _ref = table.split(";");
        for (_i = 0, _len = _ref.length; _i < _len; _i++) {
          snippet = _ref[_i];
          _ref1 = snippet.split(","), name = _ref1[0], lines = _ref1[1];
          if (name !== UNNAMED_CODE) {
            output += "" + name + ", lines: " + lines + "\n";
          }
        }
      }
      if (output === "") {
        return log("No files saved");
      } else {
        return log(output);
      }
    };
    CodeMirror.keyMap.commandLine = {
      "Up": "doNothing",
      "Down": "doNothing",
      "PageUp": "doNothing",
      "PageDown": "doNothing",
      "Enter": "doNothing",
      fallthrough: "default"
    };
    CodeMirror.commands.doNothing = function(cm) {
      return true;
    };
    outputScrollTop = function() {
      return $('#rightColumn').animate({
        scrollTop: 0
      }, $('#rightColumn').scrollTop() / 10);
    };
    commandAreaKeyEvent = function(inst, e) {
      var shouldStop;
      if (e.type === "keyup") {
        shouldStop = true;
        switch (CodeMirror.keyNames[e.keyCode]) {
          case "Enter":
            compileAndRun();
            commandArea.setValue("");
            break;
          case "Up":
            if (!timeline.isInPast()) timeline.temp(commandArea.getValue());
            commandArea.setValue(timeline.goBack());
            break;
          case "Down":
            if (timeline.isInPast()) commandArea.setValue(timeline.goForward());
            break;
          case "Esc":
            sourceArea.focus();
            break;
          default:
            shouldStop = false;
        }
        if (shouldStop) return e.stop();
      }
    };
    defaultEditor = function() {
      var column, winSize;
      winSize = {
        w: $(window).width(),
        h: $(window).height()
      };
      column = floor(winSize.w / 2);
      $('#leftColumn').width(column - 30);
      return resizeEditor();
    };
    resizeEditor = function(e) {
      var winSize;
      winSize = {
        w: $(window).width(),
        h: $(window).height()
      };
      $('#centerBar').height(winSize.h - 20);
      $('#sourceWrap .CodeMirror-scroll').css("max-height", (winSize.h - 175) + "px");
      $('#rightColumn').width(winSize.w - $('#leftColumn').width() - 60);
      $('#rightColumn').css("max-height", (winSize.h - 25) + "px");
      return setMaxPreWidth($('#output pre'));
    };
    selectLastOutput = function() {
      return (getMessage(0)).selectText();
    };
    setMaxPreWidth = function($pre) {
      return $pre.css("max-width", ($('#rightColumn').width() - 45) + "px");
    };
    loadWith = function(coffee) {
      return sourceArea.setValue(sourceArea.getValue() + coffee);
    };
    saveToAdress = function() {
      var source;
      source = sourceArea.getValue();
      return window.location = "#" + sourceFragment + (encodeURIComponent(source));
    };
    helpDescription = "Issue commands by typing \"< \" or \":\"\nfollowed by space separated commands:\n\nerase / e      - Clear all results\nerase &lt;not...> - Don't clear results containing givens\ndump / d       - Dump generated javascript\nrun / r        - Run just the source code\ncopy / c       - Select last output (right-click to copy)\ntoggle / t     - Toggle autocompilation\nlink / l       - Create a link with current source code\nmode &lt;name>    - Switch to a different compiler\nmodes / m      - Show all available modes\ncanvas &lt;w> &lt;h> - Create a canvas given width and height\nsave &lt;name>    - Save current code locally under name\nload &lt;name>    - Load code from local storage under name\ndelete &lt;name>  - Remove code from local storage\nbrowse / b     - Show content of local storage\nhelp / h       - Show this help\n\nName with arbitrary characters (spaces) must be closed by \\\nsave Long file name.txt\\";
    hlLine = null;
    sourceArea = CodeMirror.fromTextArea($("#sourceArea")[0], {
      tabSize: 2,
      indentUnit: 2,
      lineNumbers: true,
      extraKeys: {
        "Tab": "indentMore",
        "Shift-Tab": "indentLess"
      },
      onChange: function(inst, e) {
        return sourceChange(inst, e);
      },
      onCursorActivity: function() {
        sourceArea.setLineClass(hlLine, null, null);
        hlLine = sourceArea.setLineClass(sourceArea.getCursor().line, null, "activeline");
      }
    });
    hlLine = sourceArea.setLineClass(1, null, "activeline");
    commandArea = CodeMirror.fromTextArea($("#commandArea")[0], {
      tabSize: 2,
      indentUnit: 2,
      keyMap: "commandLine",
      onKeyEvent: function(inst, e) {
        return commandAreaKeyEvent(inst, e);
      }
    });
    $(sourceArea.getInputField()).keyup(function(e) {
      switch (CodeMirror.keyNames[e.keyCode]) {
        case "Esc":
          return commandArea.focus();
      }
    });
    $('#commandWrap .CodeMirror').mouseenter(function(e) {
      return commandArea.focus();
    });
    $('#sourceWrap .CodeMirror').mouseenter(function(e) {
      return sourceArea.focus();
    });
    $('#centerBar').draggable({
      axis: 'x',
      drag: function(e, ui) {
        var newRightColumnWidth;
        newRightColumnWidth = $(window).width() - ui.offset.left - 60;
        if (newRightColumnWidth > 0) {
          $('#leftColumn').width(ui.offset.left - $('#leftColumn').position().left);
          $('#rightColumn').width(newRightColumnWidth);
        }
        return ui.position = ui.originalPosition;
      }
    });
    defaultEditor();
    $(window).resize(resizeEditor);
    $(window).unload(function() {
      return saveCurrent();
    });
    hash = decodeURIComponent(window.location.hash.replace(/^#/, ''));
    if (hash.indexOf(sourceFragment) === 0) {
      src = hash.substr(sourceFragment.length);
      loadWith(src);
      window.location.hash = "";
      log("File loaded from URI, use the link command to generate new link.");
    } else {
      loadFromClient();
    }
    loadTimeline();
    if (timeline.size() < 10) log(helpDescription);
  });

}).call(this);
