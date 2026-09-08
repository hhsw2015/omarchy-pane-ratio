import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.r404r.pane-ratio"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property int focusIndex: 1
  property int workspaceId: 0
  property string workspaceKind: "unknown"
  property string workspaceName: ""
  property int tiledWindows: 0
  property string layoutName: "unknown"
  property string orientation: "unknown"
  property string currentRatio: ""
  property string intentRatio: ""
  property string intentState: "no_intent"
  property string reasonCode: "none"
  property bool backendSplitEligible: false
  property bool backendLayoutEligible: false
  property string errorText: ""
  property string statusText: "Checking current workspace…"
  property string statusOutput: ""
  property string applyOutput: ""
  property bool statusOutputOverflow: false
  property bool applyOutputOverflow: false
  property bool statusFinishing: false
  property bool applyFinishing: false
  property bool clearFinishing: false
  property bool splitFinishing: false
  property bool layoutFinishing: false
  property bool refreshPending: false
  property string pendingRatio: ""
  property string pendingLayout: ""

  property var presets: ["1:3", "1:2", "1:1", "2:1", "3:1"]
  property var presetShares: [1 / 4, 1 / 3, 1 / 2, 2 / 3, 3 / 4]
  property string pendingCols: ""
  property bool colsFinishing: false

  // Scrolling column presets, keyed by tiled-window count. The panel already
  // refreshes on openwindow/closewindow, so this list follows the workspace
  // live as windows appear and disappear.
  // 'f' = that column takes the full viewport width (colresize 1.0); the
  // strip then scrolls. Numeric weights tile the viewport together.
  readonly property var colPresetsByCount: ({
    2: ["1:1", "1:2", "2:1", "1:3", "3:1", "f:f"],
    3: ["1:1:1", "1:2:1", "2:1:1", "1:1:2", "f:1:1", "f:f:f"],
    4: ["1:1:1:1", "1:2:2:1", "2:1:1:2", "f:1:1:1", "f:f:f:f"],
    5: ["1:1:1:1:1", "1:1:2:1:1", "f:1:1:1:1"],
    6: ["1:1:1:1:1:1", "f:1:1:1:1:1"]
  })
  readonly property var colPresets: root.layoutName === "scrolling"
    ? (root.colPresetsByCount[root.tiledWindows] || []) : []
  readonly property bool colsAvailable: !root.busy && root.colPresets.length > 0
    && (root.workspaceKind === "numbered" || root.workspaceKind === "named")

  // Viewport fractions per column; 'f' tokens are full-width (1.0). For the
  // thumbnail the fractions are rescaled so the segments fit the box.
  function colWeights(spec) {
    var parts = String(spec).split(":")
    var weights = []
    var total = 0
    for (var index = 0; index < parts.length; index++) {
      if (parts[index] === "f") continue
      total += Number(parts[index])
    }
    var sum = 0
    for (var j = 0; j < parts.length; j++) {
      var fraction = parts[j] === "f" ? 1.0 : Number(parts[j]) / total
      weights.push(fraction)
      sum += fraction
    }
    if (sum > 1.001)
      for (var k = 0; k < weights.length; k++) weights[k] = weights[k] / sum
    return weights
  }

  function applyCols(spec) {
    if (!root.colsAvailable || root.colPresets.indexOf(spec) < 0) return
    root.errorText = ""
    root.statusText = "Sizing columns " + spec + "…"
    root.pendingCols = spec
    root.resetOutput(true)
    colsProcess.running = true
  }

  property string pendingTree: ""
  property bool treeFinishing: false

  // Dwindle tree presets, keyed by tiled-window count. Two windows get the
  // vertical ratios (the horizontal ones are the intent cards above); three
  // windows get every root+nested shape the backend can build.
  // Spec: AXES:R1:...:R(n-1) — chain node axes (h/v) and first-child shares.
  // Covers the classic tiling families: master+stack, columns, rows, grid,
  // fibonacci/dwindle spiral, centered-ish wide main.
  // No 2-window entry: the ratio cards are orientation-aware and the split
  // toggle flips h/v, which together cover every two-pane shape.
  readonly property var treePresetsByCount: ({
    3: [
      { spec: "hv:2-1:1-1", label: "Main left" },
      { spec: "hv:1-1:1-1", label: "Half + stack" },
      { spec: "hh:1-2:1-1", label: "3 columns" },
      { spec: "vh:2-1:1-1", label: "Main top" },
      { spec: "vh:1-1:1-1", label: "½ + 2 below" },
      { spec: "vv:1-2:1-1", label: "3 rows" },
      { spec: "hv:1-2:1-1", label: "Fibonacci" }
    ],
    4: [
      { spec: "hvv:1-1:1-2:1-1", label: "Main + 3 stack" },
      { spec: "hvv:2-1:1-2:1-1", label: "Wide main + 3" },
      { spec: "hhh:1-3:1-2:1-1", label: "4 columns" },
      { spec: "vvv:1-3:1-2:1-1", label: "4 rows" },
      { spec: "hhv:1-2:1-1:1-1", label: "3 cols + split" },
      { spec: "hvh:1-1:1-1:1-1", label: "Spiral" }
    ],
    5: [
      { spec: "hvvv:1-1:1-3:1-2:1-1", label: "Main + 4 stack" },
      { spec: "hvvv:2-1:1-3:1-2:1-1", label: "Wide main + 4" },
      { spec: "hhhh:1-4:1-3:1-2:1-1", label: "5 columns" },
      { spec: "vvvv:1-4:1-3:1-2:1-1", label: "5 rows" },
      { spec: "hvhv:1-1:1-1:1-1:1-1", label: "Spiral" }
    ],
    6: [
      { spec: "hvvvv:1-1:1-4:1-3:1-2:1-1", label: "Main + 5 stack" },
      { spec: "hhhhh:1-5:1-4:1-3:1-2:1-1", label: "6 columns" },
      { spec: "hvhvh:1-1:1-1:1-1:1-1:1-1", label: "Spiral" }
    ]
  })
  readonly property var treePresets: root.layoutName === "dwindle"
    ? (root.treePresetsByCount[root.tiledWindows] || []) : []
  readonly property bool treeAvailable: !root.busy && root.treePresets.length > 0
    && (root.workspaceKind === "numbered" || root.workspaceKind === "named")

  // Unit-space rectangles {x,y,w,h in 0..1} for a chain spec AXES:R1:...:Rk,
  // used by the preset card thumbnails. Mirrors the backend's
  // _tree_expected_rects.
  function treeRects(spec) {
    var parts = String(spec).split(":")
    var axes = parts[0]
    var rects = []
    var x = 0, y = 0, w = 1, h = 1
    for (var index = 0; index < axes.length; index++) {
      var ratio = parts[index + 1].split("-")
      var share = Number(ratio[0]) / (Number(ratio[0]) + Number(ratio[1]))
      if (axes[index] === "h") {
        rects.push({ x: x, y: y, w: w * share, h: h })
        x += w * share
        w *= 1 - share
      } else {
        rects.push({ x: x, y: y, w: w, h: h * share })
        y += h * share
        h *= 1 - share
      }
    }
    rects.push({ x: x, y: y, w: w, h: h })
    return rects
  }

  function applyTree(spec) {
    if (!root.treeAvailable) return
    var known = false
    for (var index = 0; index < root.treePresets.length; index++)
      if (root.treePresets[index].spec === spec) known = true
    if (!known) return
    root.errorText = ""
    root.statusText = "Shaping layout…"
    root.pendingTree = spec
    root.resetOutput(true)
    treeProcess.running = true
  }
  readonly property int maxOutputChars: 16384
  readonly property string cliPath: root.localPath(Qt.resolvedUrl("bin/pane-ratio"))
  readonly property bool busy: statusProcess.running || applyProcess.running || clearProcess.running
    || splitProcess.running || root.statusFinishing || root.applyFinishing
    || layoutProcess.running || root.clearFinishing || root.splitFinishing
    || root.layoutFinishing || colsProcess.running || root.colsFinishing
    || treeProcess.running || root.treeFinishing
  readonly property bool applying: applyProcess.running || root.applyFinishing
  // Two-pane ratios only make sense up to two tiled windows (0/1 = save a
  // Waiting intent, 2 = apply now). At 3+ the arrangements section rules;
  // leaving these active would silently save an intent that fires later
  // when the count drops back to 2.
  readonly property bool ratioAvailable: !root.busy && root.errorText === ""
    && root.tiledWindows <= 2
    && (root.workspaceKind === "numbered" || root.workspaceKind === "named")
  readonly property color foreground: Color.popups.text
  readonly property color mutedForeground: Qt.darker(foreground, 1.45)
  readonly property color accent: Color.accent
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property int focusTargetCount: root.presets.length + 4
    + (root.intentRatio === "" ? 0 : 1)
  readonly property bool splitAvailable: !root.busy && root.errorText === ""
    && root.backendSplitEligible
  readonly property bool layoutAvailable: !root.busy && root.errorText === ""
    && root.backendLayoutEligible
  readonly property var relevantEvents: [
    "openwindow", "closewindow", "movewindow", "movewindowv2",
    "changefloatingmode", "fullscreen", "activewindow", "activewindowv2",
    "workspace", "workspacev2", "activespecial", "focusedmon", "focusedmonv2",
    "togglegroup", "moveintogroup", "moveoutofgroup", "renameworkspace",
    "configreloaded"
  ]

  function localPath(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) value = value.substring(7)
    try { return decodeURIComponent(value) } catch (error) { return value }
  }

  function open() {
    root.controller.show()
    root.focusIndex = 0
    root.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.open() }
  function closeForPopoutSwitch() { root.close() }
  function switchPanel(direction) {
    return root.bar && root.bar.switchPanelFrom
      ? root.bar.switchPanelFrom(root.hostWidget || root, direction)
      : false
  }

  function resetOutput(applying) {
    if (applying) {
      root.applyOutput = ""
      root.applyOutputOverflow = false
    } else {
      root.statusOutput = ""
      root.statusOutputOverflow = false
    }
  }

  function appendOutput(chunk, applying) {
    var output = applying ? root.applyOutput : root.statusOutput
    if (applying ? root.applyOutputOverflow : root.statusOutputOverflow) return
    var value = String(chunk)
    var remaining = root.maxOutputChars - output.length
    if (remaining <= 0 || value.length > remaining) {
      if (applying) root.applyOutputOverflow = true
      else root.statusOutputOverflow = true
      return
    }
    if (applying) root.applyOutput += value
    else root.statusOutput += value
  }

  function refresh() {
    if (root.busy) {
      root.refreshPending = true
      return
    }
    root.refreshPending = false
    root.errorText = ""
    root.statusText = "Checking current workspace…"
    root.resetOutput(false)
    statusProcess.running = true
  }

  // Two tiled windows stacked top/bottom: the ratio section follows the
  // pair's orientation instead of always claiming left:right.
  readonly property bool pairVertical: root.orientation === "vertical"
    && root.tiledWindows === 2

  function applyRatio(ratio) {
    if (!root.ratioAvailable || root.presets.indexOf(ratio) < 0) return
    root.errorText = ""
    root.statusText = "Applying " + ratio + "…"
    if (root.pairVertical) {
      // Vertical pairs go through tree apply (direct, no saved intent —
      // the intent store's auto-reapply is horizontal-only by design).
      // Custom presets with double-digit sides fall outside TREE_SPEC_RE
      // and are rejected by the backend with a visible message.
      root.pendingTree = "v:" + ratio.replace(":", "-")
      root.resetOutput(true)
      treeProcess.running = true
      return
    }
    root.pendingRatio = ratio
    root.resetOutput(true)
    applyProcess.running = true
  }

  function clearIntent() {
    if (root.busy || root.intentRatio === "") return
    root.errorText = ""
    root.statusText = "Removing saved ratio…"
    root.resetOutput(true)
    clearProcess.running = true
  }

  function toggleSplit() {
    if (!root.splitAvailable) return
    root.errorText = ""
    root.statusText = "Switching pane direction…"
    root.resetOutput(true)
    splitProcess.running = true
  }

  function setWorkspaceLayout(layout) {
    if (!root.layoutAvailable || ["dwindle", "scrolling"].indexOf(layout) < 0) return
    root.errorText = ""
    root.statusText = "Switching workspace to " + layout + "…"
    root.pendingLayout = layout
    root.resetOutput(true)
    layoutProcess.running = true
  }

  function toggleWorkspaceLayout() {
    if (!root.layoutAvailable) return
    root.errorText = ""
    root.statusText = "Switching workspace layout…"
    root.pendingLayout = "toggle"
    root.resetOutput(true)
    layoutProcess.running = true
  }

  function failClosed(message) {
    root.workspaceId = 0
    root.workspaceKind = "unknown"
    root.workspaceName = ""
    root.layoutName = "unknown"
    root.tiledWindows = 0
    root.orientation = "unknown"
    root.currentRatio = ""
    root.intentRatio = ""
    root.intentState = "unknown"
    root.reasonCode = "internal"
    root.backendSplitEligible = false
    root.backendLayoutEligible = false
    root.errorText = String(message || "Pane Ratio unavailable")
    root.statusText = "Pane Ratio unavailable"
  }

  function consumeResult(output, overflow, exitCode, applying, requestedRatio) {
    if (overflow) {
      root.failClosed("Pane Ratio returned too much data.")
      return false
    }

    var parsed = protocol.parse(output, overflow)
    if (!parsed.valid) {
      root.failClosed(parsed.error)
      return false
    }

    try {
      var state = parsed.payload
      root.workspaceId = Number(state.workspace.rawId)
      root.workspaceKind = String(state.workspace.kind || "unknown")
      root.workspaceName = String(state.workspace.displayName || "")
      root.layoutName = String(state.layout || "unknown")
      root.tiledWindows = Number(state.tiledWindows || 0)
      root.orientation = String(state.orientation || "unknown")
      root.currentRatio = String(state.ratio || "")
      root.intentRatio = String(state.intentRatio || "")
      root.intentState = String(state.state || "unknown")
      root.reasonCode = String(state.reasonCode || "internal")
      root.backendSplitEligible = state.splitEligible === true
      root.backendLayoutEligible = state.layoutEligible === true
      if (Array.isArray(state.presets) && state.presets.length > 0) {
        var labels = []
        var shares = []
        for (var index = 0; index < state.presets.length; index++) {
          labels.push(String(state.presets[index].label || ""))
          shares.push(Number(state.presets[index].leftShare || 0.5))
        }
        root.presets = labels
        root.presetShares = shares
        root.focusIndex = Math.min(root.focusIndex, root.focusTargetCount - 1)
      }
      if (exitCode !== 0 || state.ok !== true) {
        root.errorText = String(state.message || "The current workspace cannot be adjusted.")
        root.statusText = "Workspace " + (root.workspaceName || root.workspaceId)
          + " · " + root.layoutName
        return false
      }
      root.errorText = ""
      root.statusText = String(state.message
        || ("Workspace " + (root.workspaceName || root.workspaceId)))
      if (applying && root.intentState === "applied")
        root.currentRatio = String(state.ratio || requestedRatio)
      return true
    } catch (error) {
      root.failClosed("Could not read Pane Ratio status.")
      return false
    }
  }

  PaneRatioProtocol { id: protocol }

  function moveFocus(delta) {
    if (root.busy) {
      root.focusIndex = 0
      return
    }
    var direction = delta > 0 ? 1 : -1
    for (var step = 0; step < root.focusTargetCount; step++) {
      var candidate = (root.focusIndex + direction + root.focusTargetCount)
        % root.focusTargetCount
      root.focusIndex = candidate
      if (root.focusTargetEnabled(candidate)) return
    }
    root.focusIndex = 0
  }

  function focusTargetEnabled(index) {
    if (root.busy) return false
    if (index === 0) return true
    if (index >= 1 && index <= root.presets.length) return root.ratioAvailable
    if (index === root.presets.length + 1 || index === root.presets.length + 2)
      return root.layoutAvailable
    if (index === root.presets.length + 3) return root.splitAvailable
    return index === root.presets.length + 4 && root.intentRatio !== ""
  }

  function activateFocused() {
    if (root.focusIndex === 0) root.refresh()
    else if (root.focusIndex <= root.presets.length)
      root.applyRatio(root.presets[root.focusIndex - 1])
    else if (root.focusIndex === root.presets.length + 1) root.setWorkspaceLayout("dwindle")
    else if (root.focusIndex === root.presets.length + 2) root.setWorkspaceLayout("scrolling")
    else if (root.focusIndex === root.presets.length + 3) root.toggleSplit()
    else root.clearIntent()
  }

  Process {
    id: statusProcess
    command: [root.cliPath, "reconcile"]
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root.appendOutput(chunk, false) }
    }
    stderr: SplitParser { splitMarker: ""; onRead: function(chunk) {} }
    onExited: function(exitCode) {
      root.statusFinishing = true
      Qt.callLater(function() {
        root.consumeResult(root.statusOutput, root.statusOutputOverflow, exitCode, false, "")
        root.statusFinishing = false
        if (root.refreshPending) Qt.callLater(root.refresh)
      })
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = String(event && event.name ? event.name : "")
      if (root.opened && root.relevantEvents.indexOf(name) >= 0)
        panelRefreshDebounce.restart()
    }
  }

  Timer {
    id: panelRefreshDebounce
    interval: 220
    repeat: false
    onTriggered: root.refresh()
  }

  Process {
    id: applyProcess
    command: [root.cliPath, "intent", "set", root.pendingRatio]
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root.appendOutput(chunk, true) }
    }
    stderr: SplitParser { splitMarker: ""; onRead: function(chunk) {} }
    onExited: function(exitCode) {
      root.applyFinishing = true
      var completedRatio = root.pendingRatio
      Qt.callLater(function() {
        root.consumeResult(root.applyOutput, root.applyOutputOverflow, exitCode, true, completedRatio)
        root.applyFinishing = false
        if (root.refreshPending) Qt.callLater(root.refresh)
      })
    }
  }

  Process {
    id: clearProcess
    command: [root.cliPath, "intent", "clear"]
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root.appendOutput(chunk, true) }
    }
    stderr: SplitParser { splitMarker: ""; onRead: function(chunk) {} }
    onExited: function(exitCode) {
      root.clearFinishing = true
      Qt.callLater(function() {
        root.consumeResult(root.applyOutput, root.applyOutputOverflow, exitCode, true, "")
        root.clearFinishing = false
        if (root.refreshPending) Qt.callLater(root.refresh)
      })
    }
  }

  Process {
    id: splitProcess
    command: [root.cliPath, "split", "toggle"]
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root.appendOutput(chunk, true) }
    }
    stderr: SplitParser { splitMarker: ""; onRead: function(chunk) {} }
    onExited: function(exitCode) {
      root.splitFinishing = true
      Qt.callLater(function() {
        root.consumeResult(root.applyOutput, root.applyOutputOverflow, exitCode, true, "")
        root.splitFinishing = false
        if (root.refreshPending) Qt.callLater(root.refresh)
      })
    }
  }

  Process {
    id: treeProcess
    command: [root.cliPath, "tree", "apply", root.pendingTree]
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root.appendOutput(chunk, true) }
    }
    stderr: SplitParser { splitMarker: ""; onRead: function(chunk) {} }
    onExited: function(exitCode) {
      root.treeFinishing = true
      Qt.callLater(function() {
        root.consumeResult(root.applyOutput, root.applyOutputOverflow, exitCode, true, "")
        root.treeFinishing = false
        if (root.refreshPending) Qt.callLater(root.refresh)
      })
    }
  }

  Process {
    id: colsProcess
    command: [root.cliPath, "cols", "apply", root.pendingCols]
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root.appendOutput(chunk, true) }
    }
    stderr: SplitParser { splitMarker: ""; onRead: function(chunk) {} }
    onExited: function(exitCode) {
      root.colsFinishing = true
      Qt.callLater(function() {
        root.consumeResult(root.applyOutput, root.applyOutputOverflow, exitCode, true, "")
        root.colsFinishing = false
        if (root.refreshPending) Qt.callLater(root.refresh)
      })
    }
  }

  Process {
    id: layoutProcess
    command: root.pendingLayout === "toggle"
      ? [root.cliPath, "layout", "toggle"]
      : [root.cliPath, "layout", "set", root.pendingLayout]
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root.appendOutput(chunk, true) }
    }
    stderr: SplitParser { splitMarker: ""; onRead: function(chunk) {} }
    onExited: function(exitCode) {
      root.layoutFinishing = true
      Qt.callLater(function() {
        root.consumeResult(root.applyOutput, root.applyOutputOverflow, exitCode, true, "")
        root.layoutFinishing = false
        if (root.refreshPending) Qt.callLater(root.refresh)
      })
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.moveFocus(dx)
        else if (dy !== 0) root.moveFocus(dy)
      }
      onActivateRequested: root.activateFocused()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") root.refresh()
        else if (/^[1-9]$/.test(text)) {
          var index = Number(text) - 1
          if (index < root.presets.length) root.applyRatio(root.presets[index])
        }
        else if (text === "d" || text === "D") root.clearIntent()
        else if (text === "s" || text === "S") root.toggleSplit()
        else if (text === "l" || text === "L") root.toggleWorkspaceLayout()
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(12)

        Row {
          width: parent.width
          spacing: Style.space(10)

          Text {
            text: "󰕭"
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            width: parent.width - refreshButton.width - parent.spacing * 2 - Style.space(34)
            spacing: Style.space(2)

            Text {
              text: "Pane Ratio"
              color: root.foreground
              font.family: root.fontFamily
              font.bold: true
              font.pixelSize: Style.font.title
            }

            Text {
              width: parent.width
              text: root.statusText
              textFormat: Text.PlainText
              color: root.mutedForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }
          }

          Button {
            id: refreshButton
            width: Style.space(82)
            text: root.applying ? "Applying…" : (root.busy ? "Checking…" : "Refresh")
            tooltipText: "Refresh workspace state (R)"
            bordered: false
            focusable: true
            hasCursor: root.focusIndex === 0
            enabled: !root.busy
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.refresh()
            onHovered: function(hovered) { if (hovered) root.focusIndex = 0 }
          }
        }

        Rectangle {
          width: parent.width
          height: 1
          color: Util.alpha(Color.popups.border, 0.28)
        }

        Text {
          visible: root.layoutName === "dwindle" && root.tiledWindows <= 2
          width: parent.width
          text: root.pairVertical
            ? "Choose a top : bottom ratio"
            : "Choose a left : right ratio"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Grid {
          visible: root.layoutName === "dwindle" && root.tiledWindows <= 2
          width: parent.width
          columns: 3
          spacing: Style.space(8)

          Repeater {
            model: root.presets

            Rectangle {
              id: presetCard
              required property string modelData
              required property int index
              readonly property bool selected: root.intentRatio === modelData
              readonly property bool focused: root.focusIndex === index + 1
              readonly property bool available: root.ratioAvailable
              width: (content.width - Style.space(16)) / 3
              height: Style.space(78)
              radius: Math.max(4, Style.cornerRadius)
              color: selected
                ? Util.alpha(root.accent, 0.16)
                : Util.alpha(root.foreground, focused ? 0.08 : 0.035)
              border.width: selected || focused ? 1 : 0
              border.color: selected ? root.accent : Util.alpha(root.foreground, 0.42)
              opacity: available ? 1 : 0.48
              Accessible.role: Accessible.Button
              Accessible.name: modelData + (root.pairVertical ? " top to bottom" : " left to right")
              Accessible.description: selected ? "Saved workspace rule" : "Save workspace rule"
              Accessible.onPressAction: root.applyRatio(modelData)

              Column {
                anchors.centerIn: parent
                spacing: Style.space(6)

                Rectangle {
                  width: root.pairVertical
                    ? Style.space(40)
                    : Math.max(Style.space(38),
                        Math.min(Style.space(64), presetCard.width - Style.space(16)))
                  height: root.pairVertical ? Style.space(30) : Style.space(24)
                  radius: Math.max(3, Style.cornerRadius - 1)
                  color: "transparent"
                  border.width: 1
                  border.color: presetCard.selected
                    ? root.accent
                    : Util.alpha(root.foreground, 0.58)

                  Rectangle {
                    x: Style.space(3)
                    y: Style.space(3)
                    width: root.pairVertical
                      ? parent.width - Style.space(6)
                      : (parent.width - Style.space(8)) * root.presetShares[presetCard.index]
                    height: root.pairVertical
                      ? (parent.height - Style.space(8)) * root.presetShares[presetCard.index]
                      : parent.height - Style.space(6)
                    radius: Math.max(2, Style.cornerRadius - 2)
                    color: presetCard.selected
                      ? root.accent
                      : Util.alpha(root.foreground, 0.48)
                  }

                  Rectangle {
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(3)
                    anchors.bottom: root.pairVertical ? parent.bottom : undefined
                    anchors.bottomMargin: root.pairVertical ? Style.space(3) : 0
                    y: root.pairVertical ? 0 : Style.space(3)
                    width: root.pairVertical
                      ? parent.width - Style.space(6)
                      : (parent.width - Style.space(8))
                        * (1 - root.presetShares[presetCard.index])
                    height: root.pairVertical
                      ? (parent.height - Style.space(8))
                        * (1 - root.presetShares[presetCard.index])
                      : parent.height - Style.space(6)
                    radius: Math.max(2, Style.cornerRadius - 2)
                    color: presetCard.selected
                      ? Util.alpha(root.accent, 0.52)
                      : Util.alpha(root.foreground, 0.22)
                  }
                }

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  width: presetCard.width - Style.space(12)
                  text: presetCard.modelData
                  textFormat: Text.PlainText
                  color: presetCard.selected ? root.accent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: presetCard.selected
                  horizontalAlignment: Text.AlignHCenter
                  elide: Text.ElideRight
                }
              }

              Text {
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: Style.space(5)
                text: String(index + 1)
                color: root.mutedForeground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                anchors.fill: parent
                enabled: presetCard.available
                hoverEnabled: true
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.applyRatio(presetCard.modelData)
                onEntered: root.focusIndex = presetCard.index + 1
              }
            }
          }
        }

        Text {
          visible: root.layoutName === "dwindle" && root.treePresets.length > 0
          width: parent.width
          text: "Arrangements · " + root.tiledWindows + " windows"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Grid {
          visible: root.layoutName === "dwindle" && root.treePresets.length > 0
          width: parent.width
          columns: 3
          spacing: Style.space(8)

          Repeater {
            model: root.treePresets

            Rectangle {
              id: treeCard
              required property var modelData
              readonly property var rects: root.treeRects(modelData.spec)
              readonly property bool available: root.treeAvailable
              width: (content.width - Style.space(16)) / 3
              height: Style.space(64)
              radius: Math.max(4, Style.cornerRadius)
              color: Util.alpha(root.foreground, 0.035)
              opacity: available ? 1 : 0.48
              Accessible.role: Accessible.Button
              Accessible.name: modelData.label
              Accessible.onPressAction: root.applyTree(modelData.spec)

              Column {
                anchors.centerIn: parent
                spacing: Style.space(4)

                Item {
                  anchors.horizontalCenter: parent.horizontalCenter
                  width: Style.space(44)
                  height: Style.space(26)

                  Repeater {
                    model: treeCard.rects

                    Rectangle {
                      required property var modelData
                      x: modelData.x * Style.space(44) + 1
                      y: modelData.y * Style.space(26) + 1
                      width: Math.max(3, modelData.w * Style.space(44) - 2)
                      height: Math.max(3, modelData.h * Style.space(26) - 2)
                      radius: 2
                      color: Util.alpha(root.foreground, 0.48)
                    }
                  }
                }

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: treeCard.modelData.label
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              MouseArea {
                anchors.fill: parent
                enabled: treeCard.available
                hoverEnabled: true
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.applyTree(treeCard.modelData.spec)
              }
            }
          }
        }

        Text {
          visible: root.layoutName === "scrolling"
          width: parent.width
          text: root.colPresets.length > 0
            ? "Column layout · " + root.tiledWindows + " windows"
            : (root.tiledWindows < 2
               ? "Column layout · open a second window"
               : "Column layout · unsupported window count")
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Grid {
          visible: root.layoutName === "scrolling" && root.colPresets.length > 0
          width: parent.width
          columns: 3
          spacing: Style.space(8)

          Repeater {
            model: root.colPresets

            Rectangle {
              id: colCard
              required property string modelData
              required property int index
              readonly property var weights: root.colWeights(modelData)
              readonly property bool available: root.colsAvailable
              width: (content.width - Style.space(16)) / 3
              height: Style.space(64)
              radius: Math.max(4, Style.cornerRadius)
              color: Util.alpha(root.foreground, 0.035)
              opacity: available ? 1 : 0.48
              Accessible.role: Accessible.Button
              Accessible.name: modelData + " columns"
              Accessible.onPressAction: root.applyCols(modelData)

              Column {
                anchors.centerIn: parent
                spacing: Style.space(5)

                Row {
                  anchors.horizontalCenter: parent.horizontalCenter
                  spacing: Style.space(2)

                  Repeater {
                    model: colCard.weights

                    Rectangle {
                      required property real modelData
                      width: Math.max(Style.space(6),
                        (Math.min(Style.space(64), colCard.width - Style.space(16))
                         - Style.space(2) * (colCard.weights.length - 1)) * modelData)
                      height: Style.space(20)
                      radius: Math.max(2, Style.cornerRadius - 2)
                      color: Util.alpha(root.foreground, 0.48)
                    }
                  }
                }

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: colCard.modelData
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              MouseArea {
                anchors.fill: parent
                enabled: colCard.available
                hoverEnabled: true
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.applyCols(colCard.modelData)
              }
            }
          }
        }

        Text {
          width: parent.width
          text: "Workspace layout"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          Button {
            width: (parent.width - parent.spacing) / 2
            text: (root.layoutName === "dwindle" ? "✓  " : "") + "Dwindle"
            tooltipText: "Recursive tiling with ratio and split controls"
            bordered: root.layoutName !== "dwindle"
            focusable: true
            hasCursor: root.focusIndex === root.presets.length + 1
            enabled: root.layoutAvailable
            foreground: root.layoutName === "dwindle" ? root.accent : root.foreground
            fontFamily: root.fontFamily
            onClicked: root.setWorkspaceLayout("dwindle")
            onHovered: function(hovered) {
              if (hovered) root.focusIndex = root.presets.length + 1
            }
          }

          Button {
            width: (parent.width - parent.spacing) / 2
            text: (root.layoutName === "scrolling" ? "✓  " : "") + "Scrolling"
            tooltipText: "Horizontal columns with a movable viewport"
            bordered: root.layoutName !== "scrolling"
            focusable: true
            hasCursor: root.focusIndex === root.presets.length + 2
            enabled: root.layoutAvailable
            foreground: root.layoutName === "scrolling" ? root.accent : root.foreground
            fontFamily: root.fontFamily
            onClicked: root.setWorkspaceLayout("scrolling")
            onHovered: function(hovered) {
              if (hovered) root.focusIndex = root.presets.length + 2
            }
          }
        }

        Button {
          visible: root.layoutName === "dwindle"
          width: parent.width
          text: root.orientation === "vertical"
            ? "Switch to left ↔ right"
            : "Switch to top ↕ bottom"
          tooltipText: "Toggle the two-pane Dwindle split (S)"
          bordered: true
          focusable: true
          hasCursor: root.focusIndex === root.presets.length + 3
          enabled: root.splitAvailable
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.toggleSplit()
          onHovered: function(hovered) {
            if (hovered) root.focusIndex = root.presets.length + 3
          }
        }

        Button {
          visible: root.layoutName === "dwindle" || root.intentRatio !== ""
          width: parent.width
          text: root.intentRatio === "" ? "No saved workspace rule" : "Forget " + root.intentRatio + " for this workspace"
          tooltipText: "Remove saved ratio (D)"
          bordered: true
          focusable: true
          hasCursor: root.focusIndex === root.presets.length + 4
          enabled: !root.busy && root.intentRatio !== ""
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.clearIntent()
          onHovered: function(hovered) { if (hovered) root.focusIndex = root.presets.length + 4 }
        }

        Text {
          visible: root.errorText !== ""
          width: parent.width
          text: "Unavailable — " + root.errorText
          textFormat: Text.PlainText
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          visible: root.errorText === "" && root.layoutName === "dwindle"
          width: parent.width
          text: "Saved: " + (root.intentRatio || "None")
            + "   ·   Current: " + (root.currentRatio || "Unavailable")
          textFormat: Text.PlainText
          color: root.mutedForeground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          width: parent.width
          text: (root.layoutName === "dwindle"
              ? "Keys 1–" + root.presets.length + " choose ratios · S split"
                + (root.intentRatio === "" ? "" : " · D forget")
              : "Click a column preset to size the strip")
            + " · L layout · R refresh"
          color: root.mutedForeground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
