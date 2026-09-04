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
  readonly property int maxOutputChars: 16384
  readonly property string cliPath: root.localPath(Qt.resolvedUrl("bin/pane-ratio"))
  readonly property bool busy: statusProcess.running || applyProcess.running || clearProcess.running
    || splitProcess.running || root.statusFinishing || root.applyFinishing
    || layoutProcess.running || root.clearFinishing || root.splitFinishing
    || root.layoutFinishing
  readonly property bool applying: applyProcess.running || root.applyFinishing
  readonly property bool ratioAvailable: !root.busy && root.errorText === ""
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
    "workspace", "workspacev2", "focusedmon", "focusedmonv2",
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

  function applyRatio(ratio) {
    if (!root.ratioAvailable || root.presets.indexOf(ratio) < 0) return
    root.errorText = ""
    root.statusText = "Applying " + ratio + "…"
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
          width: parent.width
          text: "Choose a left : right ratio"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Grid {
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
              Accessible.name: modelData + " left to right"
              Accessible.description: selected ? "Saved workspace rule" : "Save workspace rule"
              Accessible.onPressAction: root.applyRatio(modelData)

              Column {
                anchors.centerIn: parent
                spacing: Style.space(6)

                Rectangle {
                  width: Math.max(Style.space(38),
                    Math.min(Style.space(64), presetCard.width - Style.space(16)))
                  height: Style.space(24)
                  radius: Math.max(3, Style.cornerRadius - 1)
                  color: "transparent"
                  border.width: 1
                  border.color: presetCard.selected
                    ? root.accent
                    : Util.alpha(root.foreground, 0.58)

                  Rectangle {
                    x: Style.space(3)
                    y: Style.space(3)
                    width: (parent.width - Style.space(8)) * root.presetShares[presetCard.index]
                    height: parent.height - Style.space(6)
                    radius: Math.max(2, Style.cornerRadius - 2)
                    color: presetCard.selected
                      ? root.accent
                      : Util.alpha(root.foreground, 0.48)
                  }

                  Rectangle {
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(3)
                    y: Style.space(3)
                    width: (parent.width - Style.space(8))
                      * (1 - root.presetShares[presetCard.index])
                    height: parent.height - Style.space(6)
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
          visible: root.errorText === ""
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
          text: "Keys 1–" + root.presets.length + " choose ratios"
            + " · S split" + (root.intentRatio === "" ? "" : " · D forget")
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
