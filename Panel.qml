import QtQuick
import Quickshell
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
  property int tiledWindows: 0
  property string layoutName: "unknown"
  property string orientation: "unknown"
  property string currentRatio: ""
  property string errorText: ""
  property string statusText: "Checking current workspace…"
  property string statusOutput: ""
  property string applyOutput: ""
  property bool statusOutputOverflow: false
  property bool applyOutputOverflow: false
  property bool statusFinishing: false
  property bool applyFinishing: false
  property string pendingRatio: ""

  readonly property var presets: ["1:2", "1:1", "2:1"]
  readonly property int maxOutputChars: 16384
  readonly property string cliPath: Quickshell.env("HOME")
    + "/.config/omarchy/plugins/io.github.r404r.pane-ratio/bin/pane-ratio"
  readonly property bool busy: statusProcess.running || applyProcess.running
    || root.statusFinishing || root.applyFinishing
  readonly property bool eligible: errorText === "" && layoutName === "dwindle"
    && tiledWindows === 2 && orientation === "horizontal"
  readonly property color foreground: Color.popups.text
  readonly property color mutedForeground: Qt.darker(foreground, 1.45)
  readonly property color accent: Color.accent
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property int focusTargetCount: 4

  function open() {
    root.controller.show()
    root.focusIndex = 1
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
    if (root.busy) return
    root.errorText = ""
    root.statusText = "Checking current workspace…"
    root.resetOutput(false)
    statusProcess.running = true
  }

  function applyRatio(ratio) {
    if (root.busy || !root.eligible || root.presets.indexOf(ratio) < 0) return
    root.errorText = ""
    root.pendingRatio = ratio
    root.resetOutput(true)
    applyProcess.running = true
  }

  function consumeResult(output, overflow, exitCode, applying, requestedRatio) {
    if (overflow) {
      root.errorText = "Pane Ratio returned too much data."
      root.statusText = "Pane Ratio unavailable"
      return false
    }

    try {
      var state = JSON.parse(output || "{}")
      root.workspaceId = Number(state.workspace || 0)
      root.layoutName = String(state.layout || "unknown")
      root.tiledWindows = Number(state.tiledWindows || 0)
      root.orientation = String(state.orientation || "unknown")
      root.currentRatio = String(state.ratio || "")
      if (exitCode !== 0 || state.ok !== true || state.eligible !== true) {
        root.errorText = String(state.message || "The current workspace cannot be adjusted.")
        root.statusText = "Workspace " + root.workspaceId + " · " + root.layoutName
        return false
      }
      root.errorText = ""
      root.statusText = "Workspace " + root.workspaceId + " · Dwindle · 2 tiled windows"
      if (applying) root.currentRatio = String(state.ratio || requestedRatio)
      return true
    } catch (error) {
      root.errorText = "Could not read Pane Ratio status."
      root.statusText = "Pane Ratio unavailable"
      return false
    }
  }

  function moveFocus(delta) {
    root.focusIndex = (root.focusIndex + (delta > 0 ? 1 : -1) + root.focusTargetCount)
      % root.focusTargetCount
  }

  function activateFocused() {
    if (root.focusIndex === 0) root.refresh()
    else root.applyRatio(root.presets[root.focusIndex - 1])
  }

  Process {
    id: statusProcess
    command: [root.cliPath, "status"]
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
      })
    }
  }

  Process {
    id: applyProcess
    command: [root.cliPath, "apply", root.pendingRatio]
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
    contentWidth: panel.fittedContentWidth(Style.space(380))
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
        else if (text === "1") root.applyRatio("1:2")
        else if (text === "2") root.applyRatio("1:1")
        else if (text === "3") root.applyRatio("2:1")
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
            font.pixelSize: Style.font.displaySmall
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
            text: root.busy ? "Checking…" : "Refresh"
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

        Row {
          width: parent.width
          spacing: Style.space(8)

          Repeater {
            model: root.presets

            Button {
              required property string modelData
              required property int index
              width: (content.width - Style.space(16)) / 3
              height: Style.space(46)
              text: modelData
              tooltipText: "Set tiled windows to " + modelData
              bordered: root.currentRatio === modelData
              focusable: true
              hasCursor: root.focusIndex === index + 1
              enabled: !root.busy && root.eligible
              foreground: root.currentRatio === modelData ? root.accent : root.foreground
              fontFamily: root.fontFamily
              onClicked: root.applyRatio(modelData)
              onHovered: function(hovered) { if (hovered) root.focusIndex = index + 1 }
            }
          }
        }

        Text {
          visible: root.errorText !== ""
          width: parent.width
          text: root.errorText
          textFormat: Text.PlainText
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          visible: root.errorText === ""
          width: parent.width
          text: root.currentRatio === "Custom"
            ? "Current ratio: Custom"
            : "Current ratio: " + (root.currentRatio || "Unknown")
          textFormat: Text.PlainText
          color: root.mutedForeground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          width: parent.width
          text: "Shortcuts: 1 = 1:2 · 2 = 1:1 · 3 = 2:1 · R = refresh"
          color: root.mutedForeground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
