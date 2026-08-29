#!/usr/bin/env python3

import importlib.util
import importlib.machinery
import contextlib
import io
import json
import os
import pathlib
import stat
import sys
import tempfile
import threading
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
        "name": "1",
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
        self.assertIn("3 tiled windows", state.message)

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
            self.expressions = []
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
            self.expressions.append(expression)
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
        self.assertIn("#windows~=2", fake.expression)
        self.assertIn("window.fullscreen~=0", fake.expression)
        self.assertIn('hl.get_config("dwindle.split_bias")', fake.expression)
        self.assertIn("window.group~=nil", fake.expression)
        self.assertIn("left.at.x<right.at.x", fake.expression)

    def test_atomic_guard_failure_is_propagated_without_verification(self):
        initial = self.snapshot(500, 500)
        fake = self.FakeHyprctl(
            [initial, initial], pane_ratio.PaneRatioError("target changed")
        )

        with self.assertRaisesRegex(pane_ratio.PaneRatioError, "target changed"):
            pane_ratio.apply_ratio(fake, "2:1")

        self.assertEqual(fake.call_index, 6)

    def test_already_applied_ratio_is_idempotent(self):
        initial = self.snapshot(1000, 500)
        fake = self.FakeHyprctl([initial, initial])

        state = pane_ratio.apply_ratio(fake, "2:1")

        self.assertEqual(state.phase, "applied")
        self.assertEqual(fake.expression, "")
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

    def test_pseudo_flag_does_not_override_safe_geometry(self):
        state = pane_ratio.analyze(
            workspace(),
            [
                client("0x1", 0, 0, 500, 800, pseudo=True),
                client("0x2", 505, 0, 500, 800),
            ],
            SPLIT_BIAS,
        )
        self.assertTrue(state.eligible)

    def test_large_horizontal_gap_is_rejected(self):
        state = pane_ratio.analyze(
            workspace(),
            [client("0x1", 0, 0, 100, 800), client("0x2", 1000, 0, 100, 800)],
            SPLIT_BIAS,
        )
        self.assertFalse(state.eligible)
        self.assertEqual(state.orientation, "unknown")


class SplitToggleTests(unittest.TestCase):
    class FakeHyprctl(ApplyAndEdgeCaseTests.FakeHyprctl):
        pass

    @staticmethod
    def horizontal():
        return (
            workspace(),
            [client("0x1", 0, 0, 500, 800), client("0x2", 505, 0, 500, 800)],
        )

    @staticmethod
    def vertical():
        return (
            workspace(),
            [client("0x1", 0, 0, 1000, 400), client("0x2", 0, 405, 1000, 400)],
        )

    @classmethod
    def vertical_reversed(cls):
        current_workspace, clients = cls.vertical()
        return current_workspace, list(reversed(clients))

    def test_horizontal_split_toggles_to_vertical(self):
        with tempfile.TemporaryDirectory() as directory:
            store = pane_ratio.IntentStore(pathlib.Path(directory) / "state")
            fake = self.FakeHyprctl(
                [self.horizontal(), self.horizontal(), self.vertical_reversed()]
            )
            state = pane_ratio.toggle_split(fake, store)
            self.assertEqual(state.orientation, "vertical")
            self.assertIn('hl.dsp.layout("togglesplit")', fake.expression)
            self.assertIn("if #windows~=2", fake.expression)
            self.assertIn("if not horizontal then", fake.expression)
            self.assertNotIn("if not vertical then", fake.expression)

    def test_vertical_split_toggles_to_horizontal_and_reconciles_intent(self):
        with tempfile.TemporaryDirectory() as directory:
            store = pane_ratio.IntentStore(pathlib.Path(directory) / "state")
            store.set("1", "1:1")
            fake = self.FakeHyprctl(
                [
                    self.vertical_reversed(),
                    self.vertical(),
                    self.horizontal(),
                    self.horizontal(),
                ]
            )
            state = pane_ratio.toggle_split(fake, store)
            self.assertEqual(state.orientation, "horizontal")
            self.assertEqual(state.phase, "applied")
            self.assertIn("Switched to left and right", state.message)
            self.assertIn("if not vertical then", fake.expression)
            self.assertNotIn("if not horizontal then", fake.expression)

    def test_three_windows_cannot_toggle_split(self):
        with tempfile.TemporaryDirectory() as directory:
            store = pane_ratio.IntentStore(pathlib.Path(directory) / "state")
            snapshot = (
                workspace(),
                [
                    client("0x1", 0, 0, 300, 800),
                    client("0x2", 305, 0, 300, 800),
                    client("0x3", 610, 0, 300, 800),
                ],
            )
            fake = self.FakeHyprctl([snapshot])
            state = pane_ratio.toggle_split(fake, store)
            self.assertEqual(state.tiled_windows, 3)
            self.assertEqual(fake.expression, "")

    def test_execute_rejected_toggle_reports_ok_false_and_exit_two(self):
        with tempfile.TemporaryDirectory() as directory:
            store = pane_ratio.IntentStore(pathlib.Path(directory) / "state")
            snapshot = (workspace(), [client("0x1", 0, 0, 1000, 800)])
            fake = self.FakeHyprctl([snapshot])
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                code = pane_ratio.execute(["split", "toggle"], fake, store, pane_ratio.PRESETS)
            payload = json.loads(output.getvalue())
            self.assertEqual(code, 2)
            self.assertFalse(payload["ok"])
            self.assertFalse(payload["splitEligible"])

    def test_floating_focus_is_not_split_eligible(self):
        state = pane_ratio.analyze(
            workspace(lastwindow="0x3"),
            [
                client("0x1", 0, 0, 500, 800),
                client("0x2", 505, 0, 500, 800),
                client("0x3", 100, 100, 300, 300, floating=True),
            ],
            SPLIT_BIAS,
        )
        self.assertFalse(state.split_eligible)


class WorkspaceLayoutTests(unittest.TestCase):
    class FakeLayoutStore:
        def __init__(self, error=None):
            self.saved = None
            self.error = error

        def save(self, workspace_id, layout):
            if self.error:
                raise self.error
            self.saved = (workspace_id, layout)

    @staticmethod
    def horizontal():
        return (
            workspace(),
            [client("0x1", 0, 0, 500, 800), client("0x2", 505, 0, 500, 800)],
        )

    @staticmethod
    def scrolling():
        return (workspace(tiledLayout="scrolling"), [])

    def test_set_scrolling_uses_explicit_guard_and_persists_omarchy_rule(self):
        fake = ApplyAndEdgeCaseTests.FakeHyprctl(
            [self.horizontal(), self.horizontal(), self.scrolling(), self.scrolling()]
        )
        layout_store = self.FakeLayoutStore()
        with tempfile.TemporaryDirectory() as directory:
            state = pane_ratio.set_workspace_layout(
                fake,
                pane_ratio.IntentStore(pathlib.Path(directory) / "state"),
                layout_store,
                "scrolling",
            )
        self.assertEqual(state.layout, "scrolling")
        self.assertEqual(state.phase, "layout_scrolling")
        self.assertEqual(layout_store.saved, (1, "scrolling"))
        self.assertIn("workspace.id~=1", fake.expression)
        self.assertIn('workspace.tiled_layout~="dwindle"', fake.expression)
        self.assertIn('layout = "scrolling"', fake.expression)

    def test_setting_current_layout_is_idempotent(self):
        fake = ApplyAndEdgeCaseTests.FakeHyprctl([self.horizontal()])
        layout_store = self.FakeLayoutStore()
        with tempfile.TemporaryDirectory() as directory:
            state = pane_ratio.set_workspace_layout(
                fake,
                pane_ratio.IntentStore(pathlib.Path(directory) / "state"),
                layout_store,
                "dwindle",
            )
        self.assertEqual(state.phase, "layout_current")
        self.assertEqual(fake.expressions, [])
        self.assertEqual(layout_store.saved, (1, "dwindle"))

    def test_set_dwindle_resumes_saved_ratio(self):
        fake = ApplyAndEdgeCaseTests.FakeHyprctl(
            [
                self.scrolling(),
                self.scrolling(),
                self.horizontal(),
                self.horizontal(),
                self.horizontal(),
            ]
        )
        layout_store = self.FakeLayoutStore()
        with tempfile.TemporaryDirectory() as directory:
            store = pane_ratio.IntentStore(pathlib.Path(directory) / "state")
            store.set("1", "1:1")
            state = pane_ratio.set_workspace_layout(fake, store, layout_store, "dwindle")
        self.assertEqual(state.layout, "dwindle")
        self.assertEqual(state.phase, "applied")
        self.assertEqual(state.intent_ratio, "1:1")
        self.assertEqual(layout_store.saved, (1, "dwindle"))

    def test_persistence_failure_rolls_runtime_layout_back(self):
        fake = ApplyAndEdgeCaseTests.FakeHyprctl(
            [self.horizontal(), self.horizontal(), self.scrolling(), self.horizontal()]
        )
        layout_store = self.FakeLayoutStore(pane_ratio.PaneRatioError("disk failure"))
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(pane_ratio.PaneRatioError, "runtime change was restored"):
                pane_ratio.set_workspace_layout(
                    fake,
                    pane_ratio.IntentStore(pathlib.Path(directory) / "state"),
                    layout_store,
                    "scrolling",
                )
        self.assertEqual(len(fake.expressions), 2)
        self.assertIn('layout = "dwindle"', fake.expressions[-1])

    def test_post_replace_fsync_uncertainty_does_not_rollback_committed_rule(self):
        fake = ApplyAndEdgeCaseTests.FakeHyprctl(
            [self.horizontal(), self.horizontal(), self.scrolling(), self.scrolling()]
        )
        layout_store = self.FakeLayoutStore(
            pane_ratio.WorkspaceLayoutPersistenceError("fsync failed", committed=True)
        )
        with tempfile.TemporaryDirectory() as directory:
            state = pane_ratio.set_workspace_layout(
                fake,
                pane_ratio.IntentStore(pathlib.Path(directory) / "state"),
                layout_store,
                "scrolling",
            )
        self.assertEqual(state.phase, "layout_scrolling")
        self.assertIn("durability", state.message)
        self.assertEqual(len(fake.expressions), 1)

    def test_backend_toggle_uses_live_layout_instead_of_panel_cache(self):
        fake = ApplyAndEdgeCaseTests.FakeHyprctl(
            [self.scrolling(), self.scrolling(), self.horizontal(), self.horizontal()]
        )
        layout_store = self.FakeLayoutStore()
        with tempfile.TemporaryDirectory() as directory:
            state = pane_ratio.set_workspace_layout(
                fake,
                pane_ratio.IntentStore(pathlib.Path(directory) / "state"),
                layout_store,
                "toggle",
            )
        self.assertEqual(state.layout, "dwindle")
        self.assertEqual(layout_store.saved, (1, "dwindle"))
        self.assertIn('workspace.tiled_layout~="scrolling"', fake.expressions[0])

    def test_concurrent_native_change_persists_observed_layout(self):
        fake = ApplyAndEdgeCaseTests.FakeHyprctl(
            [self.horizontal(), self.horizontal(), self.scrolling(), self.horizontal()]
        )
        layout_store = self.FakeLayoutStore()
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(pane_ratio.PaneRatioError, "changed concurrently"):
                pane_ratio.set_workspace_layout(
                    fake,
                    pane_ratio.IntentStore(pathlib.Path(directory) / "state"),
                    layout_store,
                    "scrolling",
                )
        self.assertEqual(layout_store.saved, (1, "dwindle"))

    def test_workspace_change_skips_ratio_restore(self):
        switched_workspace = (
            workspace(id=2, name="2"),
            [client("0x3", 0, 0, 1000, 800, workspace={"id": 2, "name": "2"})],
        )
        fake = ApplyAndEdgeCaseTests.FakeHyprctl(
            [self.scrolling(), self.scrolling(), self.horizontal(), switched_workspace]
        )
        layout_store = self.FakeLayoutStore()
        with tempfile.TemporaryDirectory() as directory:
            store = pane_ratio.IntentStore(pathlib.Path(directory) / "state")
            store.set("1", "1:1")
            state = pane_ratio.set_workspace_layout(fake, store, layout_store, "dwindle")
        self.assertEqual(state.workspace, 1)
        self.assertEqual(state.phase, "layout_dwindle")
        self.assertIn("will resume", state.message)
        self.assertEqual(len(fake.expressions), 1)

    def test_special_workspace_is_rejected_without_mutation(self):
        snapshot = (workspace(id=-99, name="special:scratch"), [])
        fake = ApplyAndEdgeCaseTests.FakeHyprctl([snapshot])
        with tempfile.TemporaryDirectory() as directory:
            state = pane_ratio.set_workspace_layout(
                fake,
                pane_ratio.IntentStore(pathlib.Path(directory) / "state"),
                self.FakeLayoutStore(),
                "scrolling",
            )
        self.assertEqual(state.phase, "paused_mode")
        self.assertEqual(fake.expressions, [])


class IntentStoreTests(unittest.TestCase):
    def test_round_trip_and_clear_use_private_file(self):
        with tempfile.TemporaryDirectory() as directory:
            store = pane_ratio.IntentStore(pathlib.Path(directory) / "state")
            store.set("1", "3:1")
            self.assertEqual(store.load(), {"1": "3:1"})
            self.assertEqual(stat.S_IMODE(store.path.stat().st_mode), 0o600)
            store.clear("1")
            self.assertEqual(store.load(), {})

    def test_workspace_layout_store_writes_omarchy_compatible_rule(self):
        with tempfile.TemporaryDirectory() as directory:
            state = pathlib.Path(directory) / "workspace-layouts"
            store = pane_ratio.WorkspaceLayoutStore(state)
            store.save(7, "scrolling")
            rule = state / "7.lua"
            self.assertEqual(
                rule.read_text(),
                'hl.workspace_rule({ workspace = "7", layout = "scrolling" })\n',
            )
            self.assertEqual(stat.S_IMODE(rule.stat().st_mode), 0o600)

    def test_workspace_layout_store_rejects_existing_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            state = pathlib.Path(directory) / "workspace-layouts"
            state.mkdir()
            target = pathlib.Path(directory) / "target"
            target.write_text("unchanged")
            (state / "1.lua").symlink_to(target)
            with self.assertRaisesRegex(pane_ratio.PaneRatioError, "regular file"):
                pane_ratio.WorkspaceLayoutStore(state).save(1, "dwindle")
            self.assertEqual(target.read_text(), "unchanged")

    def test_symlink_intentions_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            state = pathlib.Path(directory) / "state"
            state.mkdir()
            target = pathlib.Path(directory) / "target"
            target.write_text("{}")
            (state / "intents.json").symlink_to(target)
            store = pane_ratio.IntentStore(state)
            with self.assertRaises(pane_ratio.PaneRatioError):
                store.load()

    def test_invalid_rule_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            state = pathlib.Path(directory) / "state"
            state.mkdir()
            (state / "intents.json").write_text(
                '{"schemaVersion":1,"workspaces":{"1":{"enabled":true,"ratio":"99:1"}}}'
            )
            with self.assertRaisesRegex(pane_ratio.PaneRatioError, "invalid rule"):
                pane_ratio.IntentStore(state).load()

    def test_custom_presets_are_reduced_and_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            config = pathlib.Path(directory) / "presets.json"
            config.write_text('{"schemaVersion":1,"presets":["5:3","2:2","3:5"]}')
            presets = pane_ratio.load_presets(config)
            self.assertEqual(list(presets), ["5:3", "1:1", "3:5"])
            self.assertAlmostEqual(presets["5:3"][1], 5 / 8)

    def test_custom_preset_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            target = pathlib.Path(directory) / "target.json"
            target.write_text('{"schemaVersion":1,"presets":["1:1"]}')
            link = pathlib.Path(directory) / "presets.json"
            link.symlink_to(target)
            with self.assertRaises(pane_ratio.PaneRatioError):
                pane_ratio.load_presets(link)

    def test_custom_preset_side_over_twenty_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            config = pathlib.Path(directory) / "presets.json"
            config.write_text('{"schemaVersion":1,"presets":["21:1"]}')
            with self.assertRaisesRegex(pane_ratio.PaneRatioError, "between 1 and 20"):
                pane_ratio.load_presets(config)

    def test_fifo_preset_file_is_rejected_without_blocking(self):
        with tempfile.TemporaryDirectory() as directory:
            fifo = pathlib.Path(directory) / "presets.json"
            os.mkfifo(fifo)
            with self.assertRaisesRegex(pane_ratio.PaneRatioError, "invalid"):
                pane_ratio.load_presets(fifo)

    def test_more_than_256_workspace_rules_are_rejected_on_save(self):
        with tempfile.TemporaryDirectory() as directory:
            store = pane_ratio.IntentStore(pathlib.Path(directory) / "state")
            rules = {str(index): "1:1" for index in range(257)}
            with self.assertRaisesRegex(pane_ratio.PaneRatioError, "256"):
                store.save(rules)

    def test_operation_lock_serializes_independent_store_instances(self):
        with tempfile.TemporaryDirectory() as directory:
            state = pathlib.Path(directory) / "state"
            first = pane_ratio.IntentStore(state)
            second = pane_ratio.IntentStore(state)
            entered = threading.Event()
            finished = threading.Event()

            def contender():
                with second.locked():
                    entered.set()
                finished.set()

            with first.locked():
                thread = threading.Thread(target=contender)
                thread.start()
                self.assertFalse(entered.wait(0.1))
            self.assertTrue(finished.wait(1.0))
            thread.join()

    def test_service_listens_for_focus_recovery_events(self):
        service = (SCRIPT.parents[1] / "PaneRatioService.qml").read_text()
        self.assertIn('"activewindow"', service)
        self.assertIn('"activewindowv2"', service)


class ReconcileTests(unittest.TestCase):
    class StaticHyprctl:
        def __init__(self, current_workspace, current_clients):
            self.current_workspace = current_workspace
            self.current_clients = current_clients

        def json(self, maximum_bytes, *arguments, deadline=None):
            if arguments == ("activeworkspace",):
                return self.current_workspace
            if arguments == ("clients",):
                return self.current_clients
            return SPLIT_BIAS

    def test_one_window_waits_with_saved_intent(self):
        with tempfile.TemporaryDirectory() as directory:
            store = pane_ratio.IntentStore(pathlib.Path(directory) / "state")
            store.set("1", "2:1")
            hyprctl = self.StaticHyprctl(workspace(), [client("0x1", 0, 0, 1000, 800)])
            state = pane_ratio.reconcile(hyprctl, store)
            self.assertEqual(state.phase, "waiting")
            self.assertEqual(state.intent_ratio, "2:1")

    def test_three_windows_pause_without_apply(self):
        with tempfile.TemporaryDirectory() as directory:
            store = pane_ratio.IntentStore(pathlib.Path(directory) / "state")
            store.set("1", "1:3")
            clients = [
                client("0x1", 0, 0, 500, 800),
                client("0x2", 505, 0, 250, 800),
                client("0x3", 760, 0, 250, 800),
            ]
            state = pane_ratio.reconcile(self.StaticHyprctl(workspace(), clients), store)
            self.assertEqual(state.phase, "paused_topology")
            self.assertEqual(state.intent_ratio, "1:3")

    def test_fullscreen_pauses_instead_of_waiting(self):
        with tempfile.TemporaryDirectory() as directory:
            store = pane_ratio.IntentStore(pathlib.Path(directory) / "state")
            store.set("1", "2:1")
            state = pane_ratio.reconcile(
                self.StaticHyprctl(workspace(hasfullscreen=True), []), store
            )
            self.assertEqual(state.phase, "paused_mode")
            self.assertIn("fullscreen", state.message)

    def test_matching_geometry_is_reported_as_applied(self):
        with tempfile.TemporaryDirectory() as directory:
            store = pane_ratio.IntentStore(pathlib.Path(directory) / "state")
            store.set("1", "2:1")
            clients = [
                client("0x1", 0, 0, 1000, 800),
                client("0x2", 1005, 0, 500, 800),
            ]
            state = pane_ratio.status_with_intent(
                self.StaticHyprctl(workspace(), clients), store
            )
            self.assertEqual(state.phase, "applied")


if __name__ == "__main__":
    unittest.main()
