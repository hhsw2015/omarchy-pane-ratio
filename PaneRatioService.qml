import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

Item {
  id: root
  property var shell: null
  property bool alive: true
  property string processOutput: ""
  property bool processOutputOverflow: false
  property string lastDiagnostic: ""

  readonly property int maxOutputChars: 16384
  readonly property string cliPath: root.localPath(Qt.resolvedUrl("bin/pane-ratio"))
  readonly property var relevantEvents: [
    "openwindow", "closewindow", "movewindow", "movewindowv2",
    "changefloatingmode", "fullscreen", "activewindow", "activewindowv2",
    "workspace", "workspacev2",
    "activespecial",
    "focusedmon", "focusedmonv2", "togglegroup", "moveintogroup",
    "moveoutofgroup", "renameworkspace", "configreloaded"
  ]

  function localPath(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) value = value.substring(7)
    try { return decodeURIComponent(value) } catch (error) { return value }
  }

  function appendOutput(chunk) {
    if (root.processOutputOverflow) return
    var value = String(chunk)
    if (root.processOutput.length + value.length > root.maxOutputChars) {
      root.processOutputOverflow = true
      return
    }
    root.processOutput += value
  }

  Component.onCompleted: scheduler.startup()
  Component.onDestruction: root.alive = false

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = String(event && event.name ? event.name : "")
      if (root.relevantEvents.indexOf(name) >= 0) scheduler.notifyEvent()
    }
  }

  PaneRatioProtocol { id: protocol }

  ReconcileScheduler {
    id: scheduler
    onStartRequested: {
      root.processOutput = ""
      root.processOutputOverflow = false
      reconcileProcess.running = true
    }
  }

  Process {
    id: reconcileProcess
    command: [root.cliPath, "reconcile-background"]
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root.appendOutput(chunk) }
    }
    stderr: SplitParser { onRead: function(line) {} }
    onExited: function(exitCode, exitStatus) {
      Qt.callLater(function() {
        if (!root.alive) return
        var result = protocol.parse(root.processOutput, root.processOutputOverflow)
        var success = result.valid && result.payload.ok === true && exitCode === 0
        var retryable = result.valid && result.payload.retryable === true && exitCode !== 0
        var reason = result.valid ? result.payload.reasonCode : "protocol_invalid"
        root.lastDiagnostic = reason
        scheduler.complete(result.valid, success, retryable, reason)
      })
    }
  }
}
