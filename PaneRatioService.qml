import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

Item {
  id: root
  property var shell: null
  property bool rerunRequested: false

  readonly property string cliPath: Quickshell.env("HOME")
    + "/.config/omarchy/plugins/io.github.r404r.pane-ratio/bin/pane-ratio"
  readonly property var relevantEvents: [
    "openwindow", "closewindow", "movewindow", "movewindowv2",
    "changefloatingmode", "fullscreen", "activewindow", "activewindowv2",
    "workspace", "workspacev2",
    "focusedmon", "focusedmonv2", "togglegroup", "moveintogroup",
    "moveoutofgroup", "configreloaded"
  ]

  function scheduleReconcile() {
    debounce.restart()
  }

  function reconcile() {
    if (reconcileProcess.running) {
      root.rerunRequested = true
      return
    }
    root.rerunRequested = false
    reconcileProcess.running = true
  }

  Component.onCompleted: startup.start()

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = String(event && event.name ? event.name : "")
      if (root.relevantEvents.indexOf(name) >= 0) root.scheduleReconcile()
    }
  }

  Timer {
    id: startup
    interval: 600
    repeat: false
    onTriggered: root.reconcile()
  }

  Timer {
    id: debounce
    interval: 140
    repeat: false
    onTriggered: root.reconcile()
  }

  Process {
    id: reconcileProcess
    command: [root.cliPath, "reconcile"]
    stdout: SplitParser { onRead: function(line) {} }
    stderr: SplitParser { onRead: function(line) {} }
    onExited: function(exitCode, exitStatus) {
      if (root.rerunRequested) debounce.restart()
    }
  }
}
