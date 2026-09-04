import QtQuick

Item {
  id: root
  visible: false

  signal startRequested()

  property bool requestRunning: false
  property bool dirty: false
  property int retryAttempt: 0
  property string lastReasonCode: "none"
  readonly property var retryDelays: [250, 500, 1000]

  function startup() {
    root.dirty = true
    startupTimer.restart()
  }

  function notifyEvent() {
    retryTimer.stop()
    root.retryAttempt = 0
    root.dirty = true
    debounceTimer.restart()
  }

  function requestStart() {
    if (root.requestRunning) {
      root.dirty = true
      return
    }
    root.dirty = false
    root.requestRunning = true
    root.startRequested()
  }

  function complete(valid, success, retryable, reasonCode) {
    root.requestRunning = false
    root.lastReasonCode = String(reasonCode || "protocol_invalid")
    if (root.dirty) {
      retryTimer.stop()
      root.retryAttempt = 0
      debounceTimer.restart()
      return
    }
    if (valid && success) {
      retryTimer.stop()
      root.retryAttempt = 0
      return
    }
    if (valid && retryable && root.retryAttempt < root.retryDelays.length) {
      retryTimer.interval = root.retryDelays[root.retryAttempt]
      root.retryAttempt += 1
      retryTimer.restart()
      return
    }
    retryTimer.stop()
  }

  Timer {
    id: startupTimer
    interval: 600
    repeat: false
    onTriggered: root.requestStart()
  }

  Timer {
    id: debounceTimer
    interval: 140
    repeat: false
    onTriggered: root.requestStart()
  }

  Timer {
    id: retryTimer
    repeat: false
    onTriggered: root.requestStart()
  }

  Component.onDestruction: {
    startupTimer.stop()
    debounceTimer.stop()
    retryTimer.stop()
  }
}
