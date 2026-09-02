import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  // Injected by Omarchy plugin loader
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: -1
  property bool isLoading: false
  property bool focusPrimed: false
  property int currentEngineIndex: 0
  property bool enginePickerOpen: false

  // Strict bounding limits
  readonly property int maxQueryLength: 256
  readonly property int maxCacheKeys: 80
  readonly property int maxResponseBytes: 16384

  // Supported search engines with Nerd Font icons and bang prefixes
  readonly property var engines: [
    { name: "Google",     icon: "󰍉", prefix: "!g",  aliases: ["!g", "!google"],   url: "https://www.google.com/search?q=" },
    { name: "DuckDuckGo", icon: "󰇥", prefix: "!d",  aliases: ["!d", "!ddg", "!duck"], url: "https://duckduckgo.com/?q=" },
    { name: "GitHub",     icon: "", prefix: "!gh", aliases: ["!gh", "!git", "!github"], url: "https://github.com/search?q=" },
    { name: "YouTube",    icon: "", prefix: "!yt", aliases: ["!yt", "!y", "!youtube"], url: "https://www.youtube.com/results?search_query=" },
    { name: "Wikipedia",  icon: "󰖬", prefix: "!w",  aliases: ["!w", "!wiki", "!wikipedia"], url: "https://en.wikipedia.org/wiki/Special:Search?search=" },
    { name: "Reddit",     icon: "󰑍", prefix: "!r",  aliases: ["!r", "!reddit"],  url: "https://www.reddit.com/search/?q=" }
  ]

  readonly property var activeEngine: engines[currentEngineIndex]

  // LRU query cache & network state
  property var currentXhr: null
  property var suggestionCache: ({})
  property var cacheKeys: []

  // Regex patterns for validation
  readonly property var domainRegex: /^([a-zA-Z0-9-]+\.)+([a-zA-Z]{2,})(:[0-9]+)?(\/.*)?$/
  readonly property var localhostRegex: /^(https?:\/\/)?(localhost|127\.0\.0\.1|0\.0\.0\.0|192\.168\.\d+\.\d+|10\.\d+\.\d+\.\d+)(:\d+)?(\/.*)?$/i

  // Theme & Token Bindings from Omarchy (with sleek frosted glass translucency)
  readonly property color background: Util.alpha(Color.menu.background || Color.background, 0.88)
  readonly property color foreground: Color.menu.text || Color.foreground
  readonly property color accentColor: Color.accent
  readonly property color borderColor: Color.menu.border || Color.accent
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border || Color.accent, Math.max(1, Style.space(2)))
  readonly property color scrimColor: Color.menu.scrim || Qt.rgba(0, 0, 0, 0.50)
  readonly property color selectedBackground: Color.menu.selectedBackground || Util.alpha(Color.accent, 0.22)
  readonly property color selectedText: Color.menu.selectedText || Color.foreground
  readonly property int cornerRadius: Style.cornerRadius + Style.space(2)
  readonly property string fontFamily: Style.font.menuFamily || Style.font.family
  readonly property int cardPadding: Style.spacing.panelPadding || Style.space(12)

  FileView {
    id: configFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/quicksearch.json"
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadPreference(text())
  }

  function loadPreference(jsonStr) {
    try {
      if (!jsonStr || jsonStr.length > 2048) return
      var cfg = JSON.parse(jsonStr)
      if (cfg && cfg.defaultEngine) {
        var engineName = String(cfg.defaultEngine).trim().toLowerCase()
        for (var i = 0; i < engines.length; i++) {
          if (engines[i].name.toLowerCase() === engineName) {
            root.currentEngineIndex = i
            break
          }
        }
      }
    } catch (e) {}
  }

  function savePreference() {
    try {
      var cfg = { defaultEngine: root.activeEngine.name.toLowerCase() }
      configFile.setText(JSON.stringify(cfg, null, 2) + "\n")
    } catch (e) {}
  }

  function open(payloadJson) {
    var initialQuery = ""
    if (payloadJson) {
      try {
        if (typeof payloadJson === "string" && payloadJson.length <= 1024) {
          var parsed = JSON.parse(payloadJson)
          if (parsed && parsed.query) initialQuery = String(parsed.query).substring(0, root.maxQueryLength)
        }
      } catch (e) {
        if (typeof payloadJson === "string" && payloadJson !== "{}") {
          initialQuery = payloadJson.substring(0, root.maxQueryLength)
        }
      }
    }

    root.opened = true
    root.enginePickerOpen = false
    root.focusPrimed = false
    focusPrimeTimer.restart()
    root.filterText = initialQuery
    root.selectedIndex = -1
    root.isLoading = false

    Qt.callLater(function() {
      searchInput.text = initialQuery
      searchInput.cursorPosition = initialQuery.length
      searchInput.forceActiveFocus()
      if (initialQuery.trim()) {
        root.requestSuggestions(initialQuery)
      } else {
        root.clearDisplayModel()
      }
    })
  }

  function close() {
    root.opened = false
    root.enginePickerOpen = false
    root.focusPrimed = false
    focusPrimeTimer.stop()
    debounceTimer.stop()
    root.cancelInFlight()
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function") {
      root.shell.hide((root.manifest && root.manifest.id) || "ruwithma.quicksearch")
    }
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function selectEngine(index) {
    if (index >= 0 && index < engines.length) {
      root.currentEngineIndex = index
      root.enginePickerOpen = false
      root.savePreference()
      if (root.filterText.trim()) {
        root.requestSuggestions(root.filterText)
      }
      searchInput.forceActiveFocus()
    }
  }

  function cycleEngine(delta) {
    var step = delta === undefined ? 1 : delta
    var count = engines.length
    root.currentEngineIndex = (root.currentEngineIndex + step + count) % count
    root.savePreference()
  }

  function isUrl(text) {
    var t = String(text || "").trim()
    if (!t || t.length > 2048) return false
    if (t.indexOf("http://") === 0 || t.indexOf("https://") === 0) return true
    if (t.indexOf(" ") !== -1) return false
    if (root.localhostRegex.test(t)) return true
    return root.domainRegex.test(t)
  }

  // Pure Deterministic Recursive-Descent Math Parser (Zero dynamic code evaluation)
  function tokenizeMath(input) {
    var str = String(input || "").trim().toLowerCase()
    if (!str || str.length > 256) return null

    // Percentage pattern: "15% of 850" -> "(15 / 100 * 850)"
    str = str.replace(/([0-9.]+)\s*%\s*of\s*([0-9.]+)/g, "($1 / 100 * $2)")

    var tokens = []
    var i = 0
    var len = str.length

    while (i < len) {
      var c = str.charAt(i)
      if (c === " " || c === "\t" || c === "\r" || c === "\n") {
        i++
        continue
      }
      if (c === "+" || c === "-" || c === "*" || c === "/" || c === "^" || c === "%" || c === "(" || c === ")") {
        tokens.push({ type: c, value: c })
        i++
        continue
      }
      // Numeric literals (including decimals)
      if ((c >= "0" && c <= "9") || (c === "." && i + 1 < len && str.charAt(i + 1) >= "0" && str.charAt(i + 1) <= "9")) {
        var numStr = ""
        var dotCount = 0
        while (i < len) {
          var nc = str.charAt(i)
          if (nc >= "0" && nc <= "9") {
            numStr += nc
            i++
          } else if (nc === "." && dotCount === 0) {
            numStr += nc
            dotCount++
            i++
          } else {
            break
          }
        }
        var parsedNum = parseFloat(numStr)
        if (isNaN(parsedNum) || !isFinite(parsedNum)) return null
        tokens.push({ type: "NUM", value: parsedNum })
        continue
      }
      // Strict identifier whitelist (functions & mathematical constants)
      if (c >= "a" && c <= "z") {
        var ident = ""
        while (i < len && str.charAt(i) >= "a" && str.charAt(i) <= "z") {
          ident += str.charAt(i)
          i++
        }
        if (ident === "pi" || ident === "e") {
          tokens.push({ type: "CONST", value: ident === "pi" ? Math.PI : Math.E })
        } else if (ident === "sqrt" || ident === "sin" || ident === "cos" || ident === "tan" || ident === "abs" || ident === "log" || ident === "ln") {
          tokens.push({ type: "FN", value: ident })
        } else {
          return null // Reject any unknown identifier / member access
        }
        continue
      }
      return null // Reject any invalid character
    }
    return tokens
  }

  function tryEvaluateMath(text) {
    var tokens = tokenizeMath(text)
    if (!tokens || tokens.length === 0) return null

    // Require at least an operator, constant, or function call to avoid classifying plain numbers as math calculations
    var hasCalcToken = false
    for (var k = 0; k < tokens.length; k++) {
      var tk = tokens[k].type
      if (tk === "+" || tk === "-" || tk === "*" || tk === "/" || tk === "^" || tk === "%" || tk === "FN" || tk === "CONST") {
        hasCalcToken = true
        break
      }
    }
    if (!hasCalcToken) return null

    var pos = 0
    var depth = 0
    var maxDepth = 25

    function peek() {
      return pos < tokens.length ? tokens[pos] : null
    }

    function consume(expectedType) {
      var t = peek()
      if (!t || (expectedType && t.type !== expectedType)) return null
      pos++
      return t
    }

    function parseExpression() {
      depth++
      if (depth > maxDepth) return null
      var left = parseTerm()
      if (left === null) return null

      while (true) {
        var t = peek()
        if (t && (t.type === "+" || t.type === "-")) {
          consume()
          var right = parseTerm()
          if (right === null) return null
          left = t.type === "+" ? (left + right) : (left - right)
        } else {
          break
        }
      }
      depth--
      return left
    }

    function parseTerm() {
      depth++
      if (depth > maxDepth) return null
      var left = parsePower()
      if (left === null) return null

      while (true) {
        var t = peek()
        if (t && (t.type === "*" || t.type === "/" || t.type === "%")) {
          consume()
          var right = parsePower()
          if (right === null) return null
          if (t.type === "*") {
            left = left * right
          } else if (t.type === "/") {
            if (right === 0) return null // Reject division by zero
            left = left / right
          } else if (t.type === "%") {
            if (right === 0) return null
            left = left % right
          }
        } else {
          break
        }
      }
      depth--
      return left
    }

    function parsePower() {
      depth++
      if (depth > maxDepth) return null
      var left = parseFactor()
      if (left === null) return null

      var t = peek()
      if (t && t.type === "^") {
        consume()
        var right = parsePower()
        if (right === null) return null
        left = Math.pow(left, right)
      }
      depth--
      return left
    }

    function parseFactor() {
      depth++
      if (depth > maxDepth) return null
      var t = peek()
      if (!t) return null

      // Unary sign (+ / -)
      if (t.type === "+" || t.type === "-") {
        consume()
        var factor = parseFactor()
        if (factor === null) return null
        depth--
        return t.type === "-" ? -factor : factor
      }

      // Numeric literal
      if (t.type === "NUM") {
        consume()
        var val = t.value
        // Handle trailing percentage: e.g. "50%"
        if (peek() && peek().type === "%") {
          consume()
          val = val / 100
        }
        depth--
        return val
      }

      // Mathematical constants (pi, e)
      if (t.type === "CONST") {
        consume()
        depth--
        return t.value
      }

      // Whitelisted function calls
      if (t.type === "FN") {
        var fnName = t.value
        consume()
        if (!consume("(")) return null
        var arg = parseExpression()
        if (arg === null || !consume(")")) return null
        var fnRes = 0
        if (fnName === "sqrt") {
          if (arg < 0) return null
          fnRes = Math.sqrt(arg)
        } else if (fnName === "sin") fnRes = Math.sin(arg)
        else if (fnName === "cos") fnRes = Math.cos(arg)
        else if (fnName === "tan") fnRes = Math.tan(arg)
        else if (fnName === "abs") fnRes = Math.abs(arg)
        else if (fnName === "log") {
          if (arg <= 0) return null
          fnRes = Math.log10(arg)
        } else if (fnName === "ln") {
          if (arg <= 0) return null
          fnRes = Math.log(arg)
        } else {
          return null
        }
        depth--
        return fnRes
      }

      // Parentheses (expr)
      if (t.type === "(") {
        consume()
        var exprVal = parseExpression()
        if (exprVal === null || !consume(")")) return null
        depth--
        return exprVal
      }

      depth--
      return null
    }

    var result = parseExpression()
    if (pos !== tokens.length) return null // Reject trailing unparsed tokens
    if (result === null || !isFinite(result) || isNaN(result)) return null

    var formatted = (result !== 0 && Math.abs(result) < 1e-6) || Math.abs(result) > 1e12
      ? result.toExponential(4)
      : (Math.round(result * 1000000) / 1000000).toString()
    return formatted
  }

  function resolveBang(query) {
    var q = String(query || "").trim().substring(0, root.maxQueryLength)
    var targetEngine = root.activeEngine
    var cleanQuery = q

    for (var i = 0; i < engines.length; i++) {
      var eng = engines[i]
      if (eng.aliases) {
        for (var a = 0; a < eng.aliases.length; a++) {
          var alias = eng.aliases[a]
          if (q === alias || q.indexOf(alias + " ") === 0) {
            targetEngine = eng
            cleanQuery = q.substring(alias.length).trim()
            return { engine: targetEngine, query: cleanQuery, explicitBang: true }
          }
        }
      }
    }
    return { engine: targetEngine, query: cleanQuery, explicitBang: false }
  }

  function submitQuery(query, itemType, openInFullBrowser) {
    var q = String(query || "").trim().substring(0, root.maxQueryLength)
    if (!q) return
    root.dismiss()

    if (itemType === "calc") {
      Quickshell.execDetached(["wl-copy", q])
      return
    }

    var targetUrl = ""
    if (q.indexOf("http://") === 0 || q.indexOf("https://") === 0) {
      targetUrl = q
    } else if (root.localhostRegex.test(q)) {
      targetUrl = (q.indexOf("http://") === 0 || q.indexOf("https://") === 0) ? q : ("http://" + q)
    } else if (isUrl(q)) {
      targetUrl = "https://" + q
    } else {
      var resolved = resolveBang(q)
      if (resolved.explicitBang && !resolved.query) {
        targetUrl = resolved.engine.url.split("?")[0]
      } else {
        targetUrl = resolved.engine.url + encodeURIComponent(resolved.query || q)
      }
    }

    if (!openInFullBrowser) {
      var popinScript = Qt.resolvedUrl("popin-browser.py").toString().replace(/^file:\/\//, "")
      Quickshell.execDetached(["python3", popinScript, "--", targetUrl])
    } else {
      Quickshell.execDetached(["omarchy-launch-browser", "--", targetUrl])
    }
  }

  function cancelInFlight() {
    if (root.currentXhr) {
      try { root.currentXhr.abort() } catch (e) {}
      root.currentXhr = null
    }
    root.isLoading = false
  }

  function clearDisplayModel() {
    displayModel.clear()
    root.selectedIndex = -1
  }

  function storeInCache(key, items) {
    var boundedKey = String(key || "").substring(0, root.maxQueryLength)
    if (root.cacheKeys.length >= root.maxCacheKeys) {
      var oldest = root.cacheKeys.shift()
      delete root.suggestionCache[oldest]
    }
    root.suggestionCache[boundedKey] = items
    root.cacheKeys.push(boundedKey)
  }

  function populateModel(query, suggestList) {
    var qBounded = String(query || "").substring(0, root.maxQueryLength)
    var rows = []

    // 1. Math calculation
    var mathRes = tryEvaluateMath(qBounded)
    if (mathRes !== null) {
      rows.push({
        itemText: String(mathRes).substring(0, 128),
        itemSubtitle: ("Math: " + qBounded).substring(0, 128),
        itemType: "calc",
        iconGlyph: "󰪚",
        actionBadge: "Copy Result"
      })
    }

    // 2. Direct URL
    if (isUrl(qBounded)) {
      rows.push({
        itemText: qBounded,
        itemSubtitle: "Direct URL navigation",
        itemType: "url",
        iconGlyph: "󰌹",
        actionBadge: "Peek"
      })
    }

    // 3. Autocomplete suggestions
    var resolved = resolveBang(qBounded)
    var activeIcon = resolved.engine.icon

    if (suggestList && Array.isArray(suggestList)) {
      var limit = Math.min(suggestList.length, 5)
      for (var s = 0; s < limit; s++) {
        var sText = String(suggestList[s] || "").trim().substring(0, root.maxQueryLength)
        if (!sText) continue
        var isLink = isUrl(sText)
        rows.push({
          itemText: sText,
          itemSubtitle: isLink ? "Website link" : resolved.engine.name + " search",
          itemType: isLink ? "url" : "search",
          iconGlyph: isLink ? "󰌹" : activeIcon,
          actionBadge: isLink ? "Peek" : "Search"
        })
      }
    }

    while (displayModel.count > rows.length) {
      displayModel.remove(displayModel.count - 1)
    }
    for (var i = 0; i < rows.length; i++) {
      if (i < displayModel.count) {
        displayModel.set(i, rows[i])
      } else {
        displayModel.append(rows[i])
      }
    }
    root.selectedIndex = -1
  }

  function requestSuggestions(query) {
    var q = String(query || "").trim().substring(0, root.maxQueryLength)
    if (!q) {
      debounceTimer.stop()
      root.cancelInFlight()
      root.clearDisplayModel()
      return
    }

    var mathRes = tryEvaluateMath(q)
    var isLink = isUrl(q)

    var resolved = resolveBang(q)
    var cacheKey = (resolved.engine.name + ":" + (resolved.query || q)).substring(0, root.maxQueryLength)

    if (root.suggestionCache[cacheKey]) {
      debounceTimer.stop()
      root.cancelInFlight()
      root.populateModel(q, root.suggestionCache[cacheKey])
      return
    }

    if (mathRes !== null || isLink) {
      root.populateModel(q, [])
    }

    debounceTimer.restart()
  }

  function fetchSuggestions(query) {
    var q = String(query || "").trim().substring(0, root.maxQueryLength)
    if (!q) {
      root.clearDisplayModel()
      return
    }

    var resolved = resolveBang(q)
    var cleanQ = (resolved.query || q).substring(0, 128)
    if (!cleanQ) {
      root.populateModel(q, [])
      return
    }

    var cacheKey = (resolved.engine.name + ":" + cleanQ).substring(0, root.maxQueryLength)

    root.cancelInFlight()
    root.isLoading = true

    var xhr = new XMLHttpRequest()
    root.currentXhr = xhr
    var endpoint = "https://suggestqueries.google.com/complete/search?client=chrome&q=" + encodeURIComponent(cleanQ)
    xhr.open("GET", endpoint)
    xhr.timeout = 2000

    xhr.onreadystatechange = function() {
      if (xhr.readyState === XMLHttpRequest.DONE) {
        if (root.currentXhr === xhr) {
          root.currentXhr = null
          root.isLoading = false
        }
        if (xhr.status === 200) {
          try {
            var rawText = xhr.responseText
            // Strictly bound response buffer before parsing
            if (rawText && rawText.length <= root.maxResponseBytes) {
              var data = JSON.parse(rawText)
              if (data && data.length > 1 && Array.isArray(data[1])) {
                var items = []
                var rawList = data[1]
                var count = Math.min(rawList.length, 5)
                for (var i = 0; i < count; i++) {
                  if (typeof rawList[i] === "string") {
                    var bounded = rawList[i].trim().substring(0, root.maxQueryLength)
                    if (bounded) items.push(bounded)
                  }
                }
                root.storeInCache(cacheKey, items)
                if (root.opened && root.filterText.trim() === q) {
                  root.populateModel(q, items)
                }
              }
            }
          } catch (e) {}
        }
      }
    }
    xhr.ontimeout = function() {
      if (root.currentXhr === xhr) {
        root.currentXhr = null
        root.isLoading = false
      }
    }
    xhr.onerror = function() {
      if (root.currentXhr === xhr) {
        root.currentXhr = null
        root.isLoading = false
      }
    }
    xhr.send()
  }

  Timer {
    id: debounceTimer
    interval: 160
    repeat: false
    onTriggered: root.fetchSuggestions(root.filterText)
  }

  Timer {
    id: focusPrimeTimer
    interval: 75
    repeat: false
    onTriggered: {
      if (root.opened) root.focusPrimed = true
    }
  }

  ListModel { id: displayModel }

  // Main UI Panel Window
  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-quicksearch"
    WlrLayershell.layer: WlrLayer.Overlay
    exclusionMode: ExclusionMode.Ignore

    WlrLayershell.keyboardFocus: root.opened
      ? (root.focusPrimed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive)
      : WlrKeyboardFocus.None

    // Scrim dimming backdrop
    Rectangle {
      id: scrimRect
      anchors.fill: parent
      color: root.scrimColor

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onPressed: {
          if (root.enginePickerOpen) {
            root.enginePickerOpen = false
          } else {
            root.dismiss()
          }
        }
      }
    }

    // Main Floating Search Card with Native Omarchy BorderSurface & Frosted Translucency
    BorderSurface {
      id: card
      width: Math.min(Style.space(620), panel.width - Style.gapsOut * 2)
      height: contentColumn.childrenRect.height + root.cardPadding * 2
      radius: root.cornerRadius
      anchors.horizontalCenter: parent.horizontalCenter
      y: Math.round(panel.height * 0.22)
      color: root.background
      borderSpec: root.borderSpec
      clip: true

      Behavior on height {
        NumberAnimation { duration: 130; easing.type: Easing.OutCubic }
      }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onPressed: {
          if (root.enginePickerOpen) root.enginePickerOpen = false
          searchInput.forceActiveFocus()
        }
      }

      Column {
        id: contentColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: root.cardPadding
        spacing: Style.space(10)

        // Search Input Capsule
        Rectangle {
          id: inputCapsule
          width: parent.width
          height: Math.max(Style.space(48), Style.font.title + Style.spacing.controlPaddingY * 2)
          radius: Style.cornerRadius
          color: Util.alpha(root.foreground, 0.08)
          border.color: searchInput.activeFocus ? root.accentColor : Util.alpha(root.foreground, 0.16)
          border.width: searchInput.activeFocus ? Math.max(1, Style.space(1.5)) : 1

          // Leading Search Engine Icon
          Text {
            id: engineIcon
            anchors.left: parent.left
            anchors.leftMargin: Style.space(14)
            anchors.verticalCenter: parent.verticalCenter
            text: {
              var resolved = root.resolveBang(searchInput.text)
              return resolved.engine.icon
            }
            textFormat: Text.PlainText
            font.family: Style.font.iconFamily || "monospace"
            font.pixelSize: Style.font.title + 2
            color: root.accentColor
          }

          // Trailing Actions Cluster (Spinner, Clear, Engine Badge)
          Row {
            id: trailingCluster
            anchors.right: parent.right
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            // Async Loading Spinner
            Text {
              id: spinner
              visible: root.isLoading
              anchors.verticalCenter: parent.verticalCenter
              text: "󰑮"
              textFormat: Text.PlainText
              font.family: Style.font.iconFamily || "monospace"
              font.pixelSize: Style.font.icon
              color: root.accentColor

              RotationAnimation on rotation {
                running: spinner.visible
                loops: Animation.Infinite
                from: 0; to: 360; duration: 800
              }
            }

            // Clear Button (X)
            Rectangle {
              id: clearBtn
              visible: searchInput.text.length > 0
              width: Style.space(24)
              height: Style.space(24)
              radius: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              color: clearHover.hovered ? Util.alpha(root.foreground, 0.16) : "transparent"

              Text {
                anchors.centerIn: parent
                text: "󰅖"
                textFormat: Text.PlainText
                font.family: Style.font.iconFamily || "monospace"
                font.pixelSize: Style.font.caption
                color: root.foreground
                opacity: 0.8
              }

              HoverHandler { id: clearHover }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  searchInput.text = ""
                  root.filterText = ""
                  root.clearDisplayModel()
                  searchInput.forceActiveFocus()
                }
              }
            }

            // Interactive Engine Badge Chip
            Rectangle {
              id: engineBadge
              height: Style.space(26)
              width: engineRow.implicitWidth + Style.space(16)
              radius: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              color: root.enginePickerOpen || badgeHover.hovered ? Util.alpha(root.accentColor, 0.30) : Util.alpha(root.accentColor, 0.18)
              border.color: root.enginePickerOpen ? root.accentColor : Util.alpha(root.accentColor, 0.35)
              border.width: 1

              Row {
                id: engineRow
                anchors.centerIn: parent
                spacing: Style.space(5)

                Text {
                  text: {
                    var res = root.resolveBang(searchInput.text)
                    return res.engine.name
                  }
                  textFormat: Text.PlainText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.weight: Font.DemiBold
                  color: root.accentColor
                }

                Text {
                  text: root.enginePickerOpen ? "󰅃" : "󰅀"
                  textFormat: Text.PlainText
                  font.family: Style.font.iconFamily || "monospace"
                  font.pixelSize: Style.font.caption - 2
                  color: root.accentColor
                  opacity: 0.85
                }
              }

              HoverHandler { id: badgeHover }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.enginePickerOpen = !root.enginePickerOpen
                }
              }
            }
          }

          // Search Input
          TextInput {
            id: searchInput
            anchors.left: engineIcon.right
            anchors.leftMargin: Style.space(12)
            anchors.right: trailingCluster.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            maximumLength: root.maxQueryLength
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            color: root.foreground
            selectionColor: Util.alpha(root.accentColor, 0.35)
            selectedTextColor: root.selectedText
            clip: true

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Search " + root.activeEngine.name + ", !bang, math, or URL..."
              textFormat: Text.PlainText
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              color: root.foreground
              opacity: 0.45
              visible: !searchInput.text && !searchInput.inputMethodComposing
            }

            onTextChanged: {
              if (root.enginePickerOpen) root.enginePickerOpen = false
              if (root.filterText !== text) {
                root.filterText = text
                root.requestSuggestions(text)
              }
            }

            Keys.onPressed: function(event) {
              if (searchInput.inputMethodComposing) return

              // Engine cycling with Ctrl+Tab or toggle picker with Ctrl+E
              if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_Tab) {
                root.cycleEngine(event.modifiers & Qt.ShiftModifier ? -1 : 1)
                event.accepted = true
                return
              }
              if ((event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_E || event.key === Qt.Key_S)) {
                root.enginePickerOpen = !root.enginePickerOpen
                event.accepted = true
                return
              }

              // Escape dismiss or clear
              if (event.key === Qt.Key_Escape) {
                if (root.enginePickerOpen) {
                  root.enginePickerOpen = false
                } else if (searchInput.text.length > 0) {
                  searchInput.text = ""
                  root.filterText = ""
                  root.clearDisplayModel()
                } else {
                  root.dismiss()
                }
                event.accepted = true
              }

              // Navigation Down
              else if (event.key === Qt.Key_Down) {
                if (root.enginePickerOpen) {
                  root.cycleEngine(1)
                } else if (displayModel.count > 0) {
                  if (root.selectedIndex === -1) {
                    root.selectedIndex = 0
                  } else {
                    root.selectedIndex = (root.selectedIndex + 1) % displayModel.count
                  }
                }
                event.accepted = true
              }

              // Navigation Up
              else if (event.key === Qt.Key_Up) {
                if (root.enginePickerOpen) {
                  root.cycleEngine(-1)
                } else if (displayModel.count > 0) {
                  if (root.selectedIndex === -1) {
                    root.selectedIndex = displayModel.count - 1
                  } else if (root.selectedIndex === 0) {
                    root.selectedIndex = -1
                  } else {
                    root.selectedIndex = root.selectedIndex - 1
                  }
                }
                event.accepted = true
              }

              // Tab Autocomplete / Cycle Engine
              else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                var isBackwards = (event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab
                if (root.enginePickerOpen) {
                  root.cycleEngine(isBackwards ? -1 : 1)
                } else if (displayModel.count > 0) {
                  if (isBackwards) {
                    if (root.selectedIndex <= 0) root.selectedIndex = displayModel.count - 1
                    else root.selectedIndex -= 1
                  } else {
                    if (root.selectedIndex === -1) root.selectedIndex = 0
                    else root.selectedIndex = (root.selectedIndex + 1) % displayModel.count
                  }
                  if (root.selectedIndex >= 0 && root.selectedIndex < displayModel.count) {
                    var item = displayModel.get(root.selectedIndex)
                    searchInput.text = item.itemText
                    searchInput.cursorPosition = searchInput.text.length
                  }
                } else {
                  root.cycleEngine(isBackwards ? -1 : 1)
                }
                event.accepted = true
              }

              // PageUp / PageDown
              else if (event.key === Qt.Key_PageDown) {
                if (displayModel.count > 0) root.selectedIndex = displayModel.count - 1
                event.accepted = true
              } else if (event.key === Qt.Key_PageUp) {
                if (displayModel.count > 0) root.selectedIndex = 0
                event.accepted = true
              }

              // Enter / Shift+Enter -> Submit
              else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                if (root.enginePickerOpen) {
                  root.enginePickerOpen = false
                  event.accepted = true
                  return
                }
                var query = ""
                var type = "search"
                if (root.selectedIndex >= 0 && root.selectedIndex < displayModel.count) {
                  var selected = displayModel.get(root.selectedIndex)
                  query = selected.itemText
                  type = selected.itemType
                } else {
                  query = searchInput.text
                }
                var openInFull = (event.modifiers & Qt.ShiftModifier) !== 0
                root.submitQuery(query, type, openInFull)
                event.accepted = true
              }
            }
          }
        }

        // GUI Search Engine Selector Panel
        Column {
          id: enginePickerSection
          width: parent.width
          spacing: Style.space(6)
          visible: root.enginePickerOpen

          Rectangle {
            width: parent.width
            height: 1
            color: Util.alpha(root.accentColor, 0.30)
          }

          Row {
            width: parent.width
            Item { width: Style.space(4); height: 1 }
            Text {
              text: "SELECT DEFAULT SEARCH ENGINE"
              textFormat: Text.PlainText
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption - 1
              font.weight: Font.DemiBold
              color: Util.alpha(root.foreground, 0.45)
            }
          }

          Grid {
            width: parent.width
            columns: 2
            spacing: Style.space(6)

            Repeater {
              model: root.engines

              delegate: Rectangle {
                id: engineCard
                required property int index
                required property var modelData

                readonly property bool isCurrent: index === root.currentEngineIndex

                width: (enginePickerSection.width - Style.space(6)) / 2
                height: Style.space(44)
                radius: Style.cornerRadius
                color: isCurrent ? Util.alpha(root.accentColor, 0.20) : (cardHover.hovered ? Util.alpha(root.foreground, 0.10) : Util.alpha(root.foreground, 0.04))
                border.color: isCurrent ? root.accentColor : (cardHover.hovered ? Util.alpha(root.foreground, 0.20) : "transparent")
                border.width: isCurrent ? Math.max(1, Style.space(1.5)) : 1

                Row {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(12)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(10)

                  // Engine Icon
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: engineCard.modelData.icon
                    textFormat: Text.PlainText
                    font.family: Style.font.iconFamily || "monospace"
                    font.pixelSize: Style.font.title + 2
                    color: engineCard.isCurrent ? root.accentColor : root.foreground
                  }

                  // Engine Name
                  Column {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - Style.space(90)
                    spacing: Style.space(1)

                    Text {
                      width: parent.width
                      text: engineCard.modelData.name
                      textFormat: Text.PlainText
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.weight: engineCard.isCurrent ? Font.DemiBold : Font.Normal
                      color: engineCard.isCurrent ? root.accentColor : root.foreground
                      elide: Text.ElideRight
                    }

                    Text {
                      width: parent.width
                      text: "Shortcut: " + engineCard.modelData.prefix
                      textFormat: Text.PlainText
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption - 1
                      color: Util.alpha(root.foreground, 0.45)
                      elide: Text.ElideRight
                    }
                  }

                  // Active checkmark badge
                  Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(22)
                    height: Style.space(22)
                    radius: Style.space(11)
                    color: engineCard.isCurrent ? root.accentColor : "transparent"
                    border.color: engineCard.isCurrent ? root.accentColor : Util.alpha(root.foreground, 0.20)
                    border.width: 1

                    Text {
                      anchors.centerIn: parent
                      text: "󰄬"
                      textFormat: Text.PlainText
                      font.family: Style.font.iconFamily || "monospace"
                      font.pixelSize: Style.font.caption - 1
                      color: engineCard.isCurrent ? root.background : Util.alpha(root.foreground, 0.25)
                      visible: engineCard.isCurrent
                    }
                  }
                }

                HoverHandler { id: cardHover }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.selectEngine(engineCard.index)
                  }
                }
              }
            }
          }
        }

        // Suggestions List Section
        Column {
          id: suggestionsSection
          width: parent.width
          spacing: Style.space(3)
          visible: !root.enginePickerOpen && displayModel.count > 0

          Rectangle {
            width: parent.width
            height: 1
            color: Util.alpha(root.accentColor, 0.25)
          }

          Repeater {
            model: displayModel

            delegate: Rectangle {
              id: rowDelegate
              required property int index
              required property string itemText
              required property string itemSubtitle
              required property string itemType
              required property string iconGlyph
              required property string actionBadge

              readonly property bool isSelected: index === root.selectedIndex

              width: parent.width
              height: Style.space(42)
              radius: Style.cornerRadius
              color: isSelected ? root.selectedBackground : (rowHover.hovered ? Util.alpha(root.foreground, 0.08) : "transparent")

              // Leading Active Indicator Pill
              Rectangle {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(3)
                height: isSelected ? parent.height - Style.space(12) : 0
                radius: Style.space(2)
                color: root.accentColor
                visible: isSelected

                Behavior on height {
                  NumberAnimation { duration: 100; easing.type: Easing.OutCubic }
                }
              }

              // Item Type Icon
              Text {
                id: itemIcon
                anchors.left: parent.left
                anchors.leftMargin: Style.space(14)
                anchors.verticalCenter: parent.verticalCenter
                text: rowDelegate.iconGlyph
                textFormat: Text.PlainText
                font.family: Style.font.iconFamily || "monospace"
                font.pixelSize: Style.font.title
                color: rowDelegate.isSelected ? root.accentColor : root.foreground
                opacity: rowDelegate.isSelected ? 1.0 : 0.70
              }

              // Trailing Action Pill
              Rectangle {
                id: actionPill
                anchors.right: parent.right
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                visible: rowDelegate.isSelected
                height: Style.space(22)
                width: actionLabel.implicitWidth + Style.space(14)
                radius: Style.space(4)
                color: Util.alpha(root.accentColor, 0.22)

                Text {
                  id: actionLabel
                  anchors.centerIn: parent
                  text: rowDelegate.actionBadge
                  textFormat: Text.PlainText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.weight: Font.DemiBold
                  color: root.accentColor
                }
              }

              // Text & Subtitle Column
              Column {
                anchors.left: itemIcon.right
                anchors.leftMargin: Style.space(12)
                anchors.right: actionPill.visible ? actionPill.left : parent.right
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(1)

                Text {
                  width: parent.width
                  text: rowDelegate.itemText
                  textFormat: Text.PlainText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.weight: rowDelegate.isSelected ? Font.Medium : Font.Normal
                  color: rowDelegate.isSelected ? root.selectedText : root.foreground
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  text: rowDelegate.itemSubtitle
                  textFormat: Text.PlainText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: rowDelegate.isSelected ? Util.alpha(root.accentColor, 0.90) : Util.alpha(root.foreground, 0.50)
                  elide: Text.ElideRight
                }
              }

              HoverHandler { id: rowHover }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.selectedIndex = index
                onClicked: {
                  var openInFull = (mouse.modifiers & Qt.ShiftModifier) !== 0
                  root.submitQuery(rowDelegate.itemText, rowDelegate.itemType, openInFull)
                }
              }
            }
          }
        }

        // Bottom Keyboard Shortcuts Hint Footer
        Rectangle {
          width: parent.width
          height: 1
          color: Util.alpha(root.foreground, 0.08)
        }

        Row {
          id: footerRow
          width: parent.width
          spacing: Style.space(14)

          component KeyHint: Row {
            property string keyText
            property string labelText
            spacing: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter

            Rectangle {
              height: Style.space(20)
              width: keyLabel.implicitWidth + Style.space(10)
              radius: Style.space(4)
              color: Util.alpha(root.foreground, 0.08)
              border.color: Util.alpha(root.foreground, 0.18)
              border.width: 1

              Text {
                id: keyLabel
                anchors.centerIn: parent
                text: keyText
                textFormat: Text.PlainText
                font.family: Style.font.family
                font.pixelSize: Style.font.caption - 1
                font.bold: true
                color: root.foreground
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: labelText
              textFormat: Text.PlainText
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: Util.alpha(root.foreground, 0.55)
            }
          }

          KeyHint { keyText: "↑↓"; labelText: "Navigate" }
          KeyHint { keyText: "Tab"; labelText: root.enginePickerOpen ? "Select" : (displayModel.count > 0 ? "Complete" : "Switch Engine") }
          KeyHint {
            keyText: "↵ Enter"
            labelText: {
              if (root.enginePickerOpen) return "Choose"
              if (root.selectedIndex >= 0 && root.selectedIndex < displayModel.count) {
                var item = displayModel.get(root.selectedIndex)
                if (item.itemType === "calc") return "Copy Result"
              }
              return "Peek"
            }
          }
          KeyHint { keyText: "⇧↵"; labelText: "Full Browser" }
          KeyHint { keyText: "Esc"; labelText: "Close" }
        }
      }
    }
  }

  // Multi-Monitor outside-click dismissal overlay for secondary displays
  Variants {
    model: root.opened ? Quickshell.screens : []

    delegate: Component {
      PanelWindow {
        required property var modelData

        screen: modelData
        visible: root.opened && !!panel.screen && modelData.name !== panel.screen.name
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore

        WlrLayershell.namespace: "omarchy-quicksearch-dismiss"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors {
          top: true
          bottom: true
          left: true
          right: true
        }

        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.AllButtons
          onPressed: root.dismiss()
        }
      }
    }
  }
}
