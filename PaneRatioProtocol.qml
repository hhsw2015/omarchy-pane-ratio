import QtQuick

QtObject {
  id: root

  readonly property int schemaVersion: 2
  readonly property int maxMessageChars: 240
  readonly property int maxWorkspaceNameChars: 128
  readonly property var operations: [
    "status", "reconcile", "intent_set", "intent_clear", "split_toggle",
    "layout_set", "layout_toggle", "apply", "cols_apply", "tree_apply"
  ]
  readonly property var states: [
    "unknown", "no_intent", "eligible", "applied", "waiting_window",
    "paused_topology", "paused_mode", "paused_config", "special_workspace",
    "unknown_workspace", "migration_required", "split_vertical",
    "split_horizontal", "layout_current", "layout_dwindle",
    "layout_scrolling", "error_transient", "error_permanent"
  ]
  readonly property var workspaceKinds: ["numbered", "named", "special", "unknown"]
  readonly property var reasonCodes: [
    "none", "no_intent", "ready", "applied", "waiting_window", "topology",
    "unsupported_layout", "fullscreen", "split_bias", "grouped_windows",
    "focus_required", "vertical_split", "ambiguous_split", "special_workspace",
    "unknown_workspace", "paused_config", "migration_required",
    "unsupported_ratio", "invalid_config", "state_invalid", "state_permission",
    "schema_unsupported", "invalid_layout_rule", "lock_busy",
    "hyprctl_unavailable", "hyprctl_timeout", "hyprctl_exit",
    "hyprctl_invalid_json", "active_target_changed", "operation_timeout",
    "target_changed", "persistence_failed", "internal"
  ]

  function invalid(message) {
    return { valid: false, error: String(message || "Invalid Pane Ratio response.") }
  }

  function parse(output, overflow) {
    if (overflow) return root.invalid("Pane Ratio returned too much data.")
    var payload
    try {
      payload = JSON.parse(String(output || ""))
    } catch (error) {
      return root.invalid("Pane Ratio returned invalid JSON.")
    }
    if (!payload || Array.isArray(payload) || typeof payload !== "object")
      return root.invalid("Pane Ratio returned an invalid object.")
    if (payload.schemaVersion !== root.schemaVersion)
      return root.invalid("Pane Ratio protocol versions do not match.")
    if (typeof payload.ok !== "boolean" || typeof payload.retryable !== "boolean")
      return root.invalid("Pane Ratio response flags are invalid.")
    if (root.operations.indexOf(payload.operation) < 0 || root.states.indexOf(payload.state) < 0)
      return root.invalid("Pane Ratio response state is unsupported.")
    if (typeof payload.reasonCode !== "string"
        || root.reasonCodes.indexOf(payload.reasonCode) < 0)
      return root.invalid("Pane Ratio response reason is invalid.")
    if (typeof payload.message !== "string" || payload.message.length > root.maxMessageChars
        || /[\u0000-\u001f\u007f]/.test(payload.message))
      return root.invalid("Pane Ratio response message is invalid.")
    var workspace = payload.workspace
    if (!workspace || Array.isArray(workspace) || typeof workspace !== "object"
        || root.workspaceKinds.indexOf(workspace.kind) < 0
        || !Number.isInteger(workspace.rawId)
        || Math.abs(workspace.rawId) > 2147483647
        || typeof workspace.displayName !== "string"
        || workspace.displayName.length > root.maxWorkspaceNameChars
        || /[\u0000-\u001f\u007f]/.test(workspace.displayName))
      return root.invalid("Pane Ratio workspace identity is invalid.")
    if (workspace.kind === "numbered") {
      if (workspace.rawId <= 0 || typeof workspace.selector !== "string"
          || workspace.selector !== "id:" + workspace.rawId)
        return root.invalid("Pane Ratio numbered selector is invalid.")
    } else if (workspace.kind === "named") {
      if (workspace.rawId >= 0 || workspace.displayName.length < 1
          || workspace.displayName.indexOf("special:") === 0
          || typeof workspace.selector !== "string"
          || workspace.selector !== "name:" + workspace.displayName)
        return root.invalid("Pane Ratio named selector is invalid.")
    } else if (workspace.kind === "special") {
      if (workspace.rawId === 0 || workspace.selector !== null
          || workspace.displayName.indexOf("special:") !== 0)
        return root.invalid("Pane Ratio special workspace is invalid.")
    } else if (workspace.rawId !== 0 || workspace.displayName !== ""
               || workspace.selector !== null) {
      return root.invalid("Pane Ratio unsupported workspace has a selector.")
    }
    if ((payload.state === "error_transient"
         && (payload.ok || !payload.retryable))
        || (payload.state === "error_permanent"
            && (payload.ok || payload.retryable))
        || (payload.retryable && payload.state !== "error_transient"))
      return root.invalid("Pane Ratio error response is inconsistent.")
    if ((workspace.kind === "special" || workspace.kind === "unknown")
        && (payload.eligible || payload.splitEligible || payload.layoutEligible))
      return root.invalid("Pane Ratio unsupported workspace is actionable.")
    if (typeof payload.layout !== "string" || payload.layout.length > 32
        || !Number.isInteger(payload.tiledWindows) || payload.tiledWindows < 0
        || payload.tiledWindows > 4096 || typeof payload.orientation !== "string"
        || ["unknown", "horizontal", "vertical"].indexOf(payload.orientation) < 0
        || typeof payload.ratio !== "string" || payload.ratio.length > 16
        || (payload.ratio !== "" && !/^[1-9][0-9]?:[1-9][0-9]?$/.test(payload.ratio))
        || typeof payload.intentRatio !== "string" || payload.intentRatio.length > 16
        || (payload.intentRatio !== ""
            && !/^[1-9][0-9]?:[1-9][0-9]?$/.test(payload.intentRatio))
        || typeof payload.eligible !== "boolean"
        || typeof payload.splitEligible !== "boolean"
        || typeof payload.layoutEligible !== "boolean")
      return root.invalid("Pane Ratio response fields are invalid.")
    if (payload.windowClasses !== undefined) {
      if (!Array.isArray(payload.windowClasses) || payload.windowClasses.length > 64)
        return root.invalid("Pane Ratio window class list is invalid.")
      for (var classIndex = 0; classIndex < payload.windowClasses.length; classIndex++) {
        var windowClass = payload.windowClasses[classIndex]
        if (typeof windowClass !== "string" || windowClass.length > 128
            || /[\u0000-\u001f\u007f]/.test(windowClass))
          return root.invalid("Pane Ratio window class list is invalid.")
      }
    }
    if (payload.windowIcons !== undefined) {
      if (!Array.isArray(payload.windowIcons) || payload.windowIcons.length > 64)
        return root.invalid("Pane Ratio window icon list is invalid.")
      for (var iconIndex = 0; iconIndex < payload.windowIcons.length; iconIndex++) {
        var iconPath = payload.windowIcons[iconIndex]
        if (typeof iconPath !== "string" || iconPath.length > 512
            || (iconPath !== "" && iconPath.charAt(0) !== "/")
            || /[\u0000-\u001f\u007f]/.test(iconPath))
          return root.invalid("Pane Ratio window icon list is invalid.")
      }
    }
    if (payload.presets !== undefined) {
      if (!Array.isArray(payload.presets) || payload.presets.length < 1 || payload.presets.length > 9)
        return root.invalid("Pane Ratio preset response is invalid.")
      var labels = {}
      for (var index = 0; index < payload.presets.length; index++) {
        var preset = payload.presets[index]
        if (!preset || typeof preset.label !== "string"
            || !/^[1-9][0-9]?:[1-9][0-9]?$/.test(preset.label)
            || labels[preset.label] === true
            || typeof preset.leftShare !== "number" || !isFinite(preset.leftShare)
            || preset.leftShare <= 0 || preset.leftShare >= 1)
          return root.invalid("Pane Ratio preset response is invalid.")
        labels[preset.label] = true
      }
    }
    return { valid: true, payload: payload }
  }
}
