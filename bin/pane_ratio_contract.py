"""Typed workspace identity and versioned Pane Ratio response contract."""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from typing import Any


PROTOCOL_SCHEMA_VERSION = 2
STATE_SCHEMA_VERSION = 2
MAX_WORKSPACE_NAME_BYTES = 128
MAX_WORKSPACE_ID = 2_147_483_647

WORKSPACE_KINDS = frozenset({"numbered", "named", "special", "unknown"})
STATES = frozenset(
    {
        "unknown",
        "no_intent",
        "eligible",
        "applied",
        "waiting_window",
        "paused_topology",
        "paused_mode",
        "paused_config",
        "special_workspace",
        "unknown_workspace",
        "migration_required",
        "split_vertical",
        "split_horizontal",
        "layout_current",
        "layout_dwindle",
        "layout_scrolling",
        "error_transient",
        "error_permanent",
    }
)
REASON_CODES = frozenset(
    {
        "none",
        "no_intent",
        "ready",
        "applied",
        "waiting_window",
        "topology",
        "unsupported_layout",
        "fullscreen",
        "split_bias",
        "grouped_windows",
        "focus_required",
        "vertical_split",
        "ambiguous_split",
        "special_workspace",
        "unknown_workspace",
        "paused_config",
        "migration_required",
        "unsupported_ratio",
        "invalid_config",
        "state_invalid",
        "state_permission",
        "schema_unsupported",
        "invalid_layout_rule",
        "lock_busy",
        "hyprctl_unavailable",
        "hyprctl_timeout",
        "hyprctl_exit",
        "hyprctl_invalid_json",
        "active_target_changed",
        "operation_timeout",
        "target_changed",
        "persistence_failed",
        "internal",
    }
)


class PaneRatioError(RuntimeError):
    """Expected bounded failure with a stable protocol classification."""

    def __init__(
        self,
        message: str,
        *,
        reason_code: str = "internal",
        retryable: bool = False,
    ) -> None:
        super().__init__(message)
        self.reason_code = reason_code if reason_code in REASON_CODES else "internal"
        self.retryable = bool(retryable)


class TransientPaneRatioError(PaneRatioError):
    def __init__(self, message: str, *, reason_code: str) -> None:
        super().__init__(message, reason_code=reason_code, retryable=True)


class ActiveWorkspaceChangedError(TransientPaneRatioError):
    def __init__(self, message: str) -> None:
        super().__init__(message, reason_code="active_target_changed")


@dataclass(frozen=True)
class WorkspaceIdentity:
    kind: str
    raw_id: int
    display_name: str
    selector: str | None

    @property
    def supported(self) -> bool:
        return self.kind in ("numbered", "named") and self.selector is not None

    @property
    def reason_code(self) -> str:
        if self.kind == "special":
            return "special_workspace"
        if self.kind == "unknown":
            return "unknown_workspace"
        return "none"

    def public(self) -> dict[str, Any]:
        return {
            "kind": self.kind,
            "selector": self.selector,
            "rawId": self.raw_id,
            "displayName": self.display_name,
        }

    def layout_operand(self) -> str:
        if not self.supported or self.selector is None:
            raise PaneRatioError(
                "workspace identity cannot be persisted",
                reason_code=self.reason_code,
            )
        return str(self.raw_id) if self.kind == "numbered" else self.selector

    def layout_filename(self) -> str:
        if not self.supported or self.selector is None:
            raise PaneRatioError(
                "workspace identity cannot be persisted",
                reason_code=self.reason_code,
            )
        if self.kind == "numbered":
            return f"{self.raw_id}.lua"
        digest = hashlib.sha256(self.selector.encode("utf-8")).hexdigest()
        return f"name-{digest}.lua"


def _valid_workspace_name(value: Any) -> str | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        encoded = value.encode("utf-8", "strict")
    except UnicodeEncodeError:
        return None
    if len(encoded) > MAX_WORKSPACE_NAME_BYTES:
        return None
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        return None
    return value


def workspace_identity(workspace: Any) -> WorkspaceIdentity:
    if not isinstance(workspace, dict):
        return WorkspaceIdentity("unknown", 0, "", None)
    raw_id = workspace.get("id")
    if not isinstance(raw_id, int) or isinstance(raw_id, bool) or raw_id == 0:
        return WorkspaceIdentity("unknown", 0, "", None)
    if abs(raw_id) > MAX_WORKSPACE_ID:
        return WorkspaceIdentity("unknown", 0, "", None)
    name = _valid_workspace_name(workspace.get("name"))
    if name is None:
        return WorkspaceIdentity("unknown", 0, "", None)
    if name.startswith("special:"):
        return WorkspaceIdentity("special", raw_id, name, None)
    if raw_id > 0:
        return WorkspaceIdentity("numbered", raw_id, name, f"id:{raw_id}")
    return WorkspaceIdentity("named", raw_id, name, f"name:{name}")


def validate_selector(selector: Any) -> str:
    if not isinstance(selector, str):
        raise PaneRatioError("workspace selector is invalid", reason_code="state_invalid")
    if selector.startswith("id:"):
        value = selector[3:]
        if not value.isascii() or not value.isdigit() or value.startswith("0"):
            raise PaneRatioError("workspace selector is invalid", reason_code="state_invalid")
        number = int(value)
        if number <= 0 or number > MAX_WORKSPACE_ID:
            raise PaneRatioError("workspace selector is invalid", reason_code="state_invalid")
        return selector
    if selector.startswith("name:"):
        name = _valid_workspace_name(selector[5:])
        if name is None or name.startswith("special:"):
            raise PaneRatioError("workspace selector is invalid", reason_code="state_invalid")
        return selector
    raise PaneRatioError("workspace selector is invalid", reason_code="state_invalid")


def lua_string(value: str) -> str:
    """Serialize a validated UTF-8 value as one inert Lua quoted string."""

    if _valid_workspace_name(value) is None:
        raise PaneRatioError("workspace name cannot be serialized", reason_code="invalid_layout_rule")
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def error_payload(operation: str, error: PaneRatioError) -> dict[str, Any]:
    return {
        "schemaVersion": PROTOCOL_SCHEMA_VERSION,
        "ok": False,
        "operation": operation,
        "state": "error_transient" if error.retryable else "error_permanent",
        "reasonCode": error.reason_code,
        "retryable": error.retryable,
        "eligible": False,
        "message": str(error)[:240],
        "workspace": WorkspaceIdentity("unknown", 0, "", None).public(),
        "layout": "unknown",
        "tiledWindows": 0,
        "orientation": "unknown",
        "ratio": "",
        "intentRatio": "",
        "splitEligible": False,
        "layoutEligible": False,
    }
