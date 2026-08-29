# Pane Ratio

Pane Ratio is an Omarchy bar plugin that remembers a left-to-right ratio for each workspace and applies it whenever the Dwindle layout is safe to adjust.

## What it does

- Offers `1:3`, `1:2`, `1:1`, `2:1`, and `3:1` presets from a compact bar panel.
- Saves the selected ratio even when the workspace has zero or one tiled window.
- Automatically applies the saved ratio when a second tiled window appears.
- Pauses without changing geometry when three or more tiled windows are present, then resumes after the workspace returns to two.
- Detects and highlights the current preset, or shows `Custom` after manual resizing.
- Ignores floating windows.
- Refuses ambiguous layouts instead of guessing.
- Stores per-workspace intentions under `~/.local/state/omarchy-pane-ratio/`; it does not edit Hyprland configuration.

Automatic application deliberately supports exactly two horizontal, ungrouped, non-fullscreen windows on a Dwindle workspace. Scrolling and multi-level Dwindle trees need different semantics and are not silently approximated.

## Install

```bash
omarchy plugin add https://github.com/r404r/omarchy-pane-ratio.git --enable
```

No setup script or Hyprland reload is required. The backend runs directly from the installed plugin directory.

## Use

Click the Pane Ratio icon, then choose a preset. The rule belongs to the current workspace. It can be selected before the second window exists.

Keyboard controls inside the panel:

- `1`–`9`: choose the preset at that position (the default list uses `1`–`5`)
- `D`: forget the current workspace rule
- `R`: refresh
- Arrow keys and Enter: navigate and apply
- Escape: close

`Waiting` means the intention is saved and needs a second tiled window. `Paused` means the rule is retained but the current topology is unsafe to change. The plugin never changes a three-window tree by approximation.

## Custom presets

The five defaults can be replaced without editing the plugin. Create
`~/.config/omarchy-pane-ratio/presets.json`:

```json
{
  "schemaVersion": 1,
  "presets": ["1:3", "1:2", "1:1", "5:3", "2:1", "3:1"]
}
```

Use one to nine ratios. Each side must be an integer from 1 through 20. Ratios are reduced to canonical form, so write `1:1` instead of `2:2` when that ratio is already saved. Close and reopen the panel after changing the file; the event service reads it again on its next reconciliation. A saved ratio removed from the preset file is retained but paused until it is restored or forgotten.

## Safety model

- Ratio arguments are a fixed allowlist; arbitrary commands and arbitrary Lua are rejected.
- State is bounded, schema-validated, symlink-resistant, private (`0700` directory and `0600` file), and atomically replaced.
- `hyprctl` output is parsed as bounded JSON with timeouts and schema checks.
- Workspace, window addresses, focus, and layout are checked twice before applying.
- The atomic Lua guard rechecks the window set, focus, Dwindle layout, split bias, groups, fullscreen state, and horizontal geometry immediately before dispatch. Pseudotile is not treated as a separate policy flag because Hyprland's Lua window API does not expose it; the same geometry eligibility applies.
- The resulting geometry is read back and verified.
- A lightweight Omarchy QML service reacts to relevant Hyprland events with a 140 ms debounce; there is no polling, privileged command, network access, or user configuration write.

## Development

```bash
python -m unittest discover -s tests -v
omarchy plugin validate .
qmllint -I "$OMARCHY_PATH/shell" BarWidget.qml Panel.qml PaneRatioService.qml
```

## License

MIT
