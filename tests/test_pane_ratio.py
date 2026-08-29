#!/usr/bin/env python3

import importlib.util
import importlib.machinery
import contextlib
import io
import json
import pathlib
import sys
import time
import unittest
from unittest import mock


SCRIPT = pathlib.Path(__file__).parents[1] / "bin" / "pane-ratio"
LOADER = importlib.machinery.SourceFileLoader("pane_ratio", str(SCRIPT))
SPEC = importlib.util.spec_from_loader("pane_ratio", LOADER)
assert SPEC and SPEC.loader
pane_ratio = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = pane_ratio
SPEC.loader.exec_module(pane_ratio)


def workspace(**changes):
    value = {
        "id": 1,
        "tiledLayout": "dwindle",
        "lastwindow": "0x1",
        "hasfullscreen": False,
    }
    value.update(changes)
    return value


def client(address, x, y, width, height, **changes):
    value = {
        "address": address,
        "mapped": True,
        "floating": False,
        "pseudo": False,
        "fullscreen": 0,
        "workspace": {"id": 1, "name": "1"},
        "at": [x, y],
        "size": [width, height],
        "grouped": [],
    }
    value.update(changes)
    return value


SPLIT_BIAS = {"option": "dwindle:split_bias", "int": 0, "set": False}


class AnalyzeTests(unittest.TestCase):
    def test_equal_horizontal_pair_is_eligible(self):
        state = pane_ratio.analyze(
            workspace(),
            [client("0x1", 0, 0, 500, 800), client("0x2", 505, 0, 500, 800)],
            SPLIT_BIAS,
        )
        self.assertTrue(state.eligible)
        self.assertEqual(state.ratio, "1:1")

    def test_two_to_one_pair_is_detected(self):
        state = pane_ratio.analyze(
            workspace(),
            [client("0x1", 0, 0, 1000, 800), client("0x2", 1005, 0, 500, 800)],
            SPLIT_BIAS,
        )
        self.assertEqual(state.ratio, "2:1")

    def test_floating_window_is_ignored(self):
        state = pane_ratio.analyze(
            workspace(),
            [
                client("0x1", 0, 0, 500, 800),
                client("0x2", 505, 0, 500, 800),
                client("0x3", 100, 100, 300, 300, floating=True),
            ],
            SPLIT_BIAS,
        )
        self.assertTrue(state.eligible)
        self.assertEqual(state.tiled_windows, 2)

    def test_three_tiled_windows_are_rejected(self):
        state = pane_ratio.analyze(
            workspace(),
            [
                client("0x1", 0, 0, 500, 800),
                client("0x2", 505, 0, 250, 800),
                client("0x3", 760, 0, 250, 800),
            ],
            SPLIT_BIAS,
        )
        self.assertFalse(state.eligible)
        self.assertIn("found 3", state.message)

    def test_vertical_pair_is_rejected(self):
        state = pane_ratio.analyze(
            workspace(),
            [client("0x1", 0, 0, 1000, 400), client("0x2", 0, 405, 1000, 400)],
            SPLIT_BIAS,
        )
        self.assertFalse(state.eligible)
        self.assertEqual(state.orientation, "vertical")


class ApplyAndEdgeCaseTests(unittest.TestCase):
    class FakeHyprctl:
        def __init__(self, snapshots, eval_error=None):
            self.snapshots = snapshots
            self.call_index = 0
            self.expression = ""
            self.eval_error = eval_error

        def json(self, maximum_bytes, *arguments, deadline=None):
            snapshot = self.snapshots[self.call_index // 3]
            self.call_index += 1
            if arguments == ("activeworkspace",):
                return snapshot[0]
            if arguments == ("clients",):
                return snapshot[1]
            return SPLIT_BIAS

        def eval(self, expression, *, deadline=None):
            self.expression = expression
            if self.eval_error:
                raise self.eval_error

    @staticmethod
    def snapshot(left_width, right_width):
        return (
            workspace(),
            [
                client("0x1", 0, 0, left_width, 800),
                client("0x2", left_width + 5, 0, right_width, 800),
            ],
        )

    def test_apply_uses_atomic_lua_target_guards(self):
        initial = self.snapshot(500, 500)
        verified = self.snapshot(1000, 500)
        fake = self.FakeHyprctl([initial, initial, verified])

        state = pane_ratio.apply_ratio(fake, "2:1")

        self.assertEqual(state.ratio, "2:1")
        self.assertIn('active.address~="0x1"', fake.expression)
        self.assertIn("workspace.id~=1", fake.expression)
        self.assertIn('workspace.tiled_layout~="dwindle"', fake.expression)
        self.assertIn('["0x1"]=true', fake.expression)
        self.assertIn('["0x2"]=true', fake.expression)
        self.assertIn("count~=2", fake.expression)
        self.assertIn("window.fullscreen~=0", fake.expression)

    def test_atomic_guard_failure_is_propagated_without_verification(self):
        initial = self.snapshot(500, 500)
        fake = self.FakeHyprctl(
            [initial, initial], pane_ratio.PaneRatioError("target changed")
        )

        with self.assertRaisesRegex(pane_ratio.PaneRatioError, "target changed"):
            pane_ratio.apply_ratio(fake, "1:1")

        self.assertEqual(fake.call_index, 6)

    def test_expired_operation_deadline_does_not_spawn_process(self):
        with mock.patch.object(pane_ratio.subprocess, "Popen") as popen:
            with self.assertRaisesRegex(pane_ratio.PaneRatioError, "timed out"):
                pane_ratio.bounded_command(
                    ["/usr/bin/false"], 64, operation_deadline=time.monotonic() - 1
                )
        popen.assert_not_called()

    def test_process_start_failure_uses_operational_error(self):
        with mock.patch.object(
            pane_ratio.subprocess, "Popen", side_effect=OSError("unavailable")
        ):
            with self.assertRaisesRegex(pane_ratio.PaneRatioError, "could not start"):
                pane_ratio.bounded_command(["/usr/bin/false"], 64)

    def test_main_unexpected_failure_preserves_json_contract(self):
        output = io.StringIO()
        with mock.patch.object(pane_ratio, "Hyprctl", side_effect=RuntimeError("boom")):
            with contextlib.redirect_stdout(output):
                exit_code = pane_ratio.main(["status"])

        payload = json.loads(output.getvalue())
        self.assertEqual(exit_code, 1)
        self.assertFalse(payload["ok"])
        self.assertFalse(payload["eligible"])
        self.assertEqual(
            payload["message"], "Pane Ratio encountered an unexpected internal error."
        )

    def test_scrolling_is_rejected(self):
        state = pane_ratio.analyze(workspace(tiledLayout="scrolling"), [], SPLIT_BIAS)
        self.assertFalse(state.eligible)
        self.assertIn("Dwindle", state.message)

    def test_fullscreen_is_rejected(self):
        state = pane_ratio.analyze(workspace(hasfullscreen=True), [], SPLIT_BIAS)
        self.assertFalse(state.eligible)
        self.assertIn("fullscreen", state.message)

    def test_grouped_windows_are_rejected(self):
        state = pane_ratio.analyze(
            workspace(),
            [
                client("0x1", 0, 0, 500, 800, grouped=["0x2"]),
                client("0x2", 505, 0, 500, 800, grouped=["0x1"]),
            ],
            SPLIT_BIAS,
        )
        self.assertFalse(state.eligible)
        self.assertIn("Grouped", state.message)

    def test_non_directional_split_bias_is_rejected(self):
        state = pane_ratio.analyze(
            workspace(),
            [client("0x1", 0, 0, 500, 800), client("0x2", 505, 0, 500, 800)],
            {"int": 1},
        )
        self.assertFalse(state.eligible)
        self.assertIn("split_bias", state.message)

    def test_floating_focus_is_rejected(self):
        state = pane_ratio.analyze(
            workspace(lastwindow="0x3"),
            [
                client("0x1", 0, 0, 500, 800),
                client("0x2", 505, 0, 500, 800),
                client("0x3", 100, 100, 300, 300, floating=True),
            ],
            SPLIT_BIAS,
        )
        self.assertFalse(state.eligible)
        self.assertIn("Focus", state.message)

    def test_pseudotiled_window_is_rejected(self):
        state = pane_ratio.analyze(
            workspace(),
            [
                client("0x1", 0, 0, 500, 800, pseudo=True),
                client("0x2", 505, 0, 500, 800),
            ],
            SPLIT_BIAS,
        )
        self.assertFalse(state.eligible)
        self.assertIn("Pseudotiled", state.message)

    def test_large_horizontal_gap_is_rejected(self):
        state = pane_ratio.analyze(
            workspace(),
            [client("0x1", 0, 0, 100, 800), client("0x2", 1000, 0, 100, 800)],
            SPLIT_BIAS,
        )
        self.assertFalse(state.eligible)
        self.assertEqual(state.orientation, "vertical")


if __name__ == "__main__":
    unittest.main()
