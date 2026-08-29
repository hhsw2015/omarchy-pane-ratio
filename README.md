# Pane Ratio

Pane Ratio is an Omarchy bar plugin for applying precise left-to-right ratio presets to two tiled Dwindle windows.

## What it does

- Offers `1:2`, `1:1`, and `2:1` presets from a compact bar panel.
- Detects and highlights the current preset, or shows `Custom` after manual resizing.
- Ignores floating windows.
- Refuses ambiguous layouts instead of guessing.
- Changes only the current runtime layout; it does not edit Hyprland configuration.

The first release deliberately supports exactly two horizontal, ungrouped, non-fullscreen windows on a Dwindle workspace. Scrolling and multi-level Dwindle trees need different semantics and are not silently approximated.

## Install

```bash
omarchy plugin add https://github.com/r404r/omarchy-pane-ratio.git --enable
```

No setup script or Hyprland reload is required. The backend runs directly from the installed plugin directory.

## Use

Click the Pane Ratio icon in the bar, then choose a preset. Keyboard controls inside the panel:

- `1`: 1:2
- `2`: 1:1
- `3`: 2:1
- `R`: refresh
- Arrow keys and Enter: navigate and apply
- Escape: close

If the panel reports that the workspace is unsupported, focus one of its two tiled windows and make sure the workspace uses Dwindle with a left-right split.

## Safety model

- Ratio arguments are a fixed allowlist; arbitrary commands and arbitrary Lua are rejected.
- `hyprctl` output is parsed as bounded JSON with timeouts and schema checks.
- Workspace, window addresses, focus, and layout are checked twice before applying.
- The resulting geometry is read back and verified.
- No daemon, privileged command, network access, or user configuration write is used.

## Development

```bash
python -m unittest discover -s tests -v
omarchy plugin validate .
qmllint -I "$OMARCHY_PATH/shell" BarWidget.qml Panel.qml
```

## License

MIT
