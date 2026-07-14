"""Tests for the opt-in (never-automatic) TRELLIS model download.

Covers two guarantees added in task 0403:

(a) ``download_model.sh`` is a thin pass-through wrapper around the worker's
    ``fetch-model`` subcommand (args forwarded verbatim).
(b) The TRELLIS backend NEVER auto-downloads at generation time: when the
    weights are absent it raises a clear, actionable ``model_missing`` error
    naming the download command; when present it forces huggingface_hub fully
    offline BEFORE building the pipeline. Both branches are exercised without
    torch / huggingface_hub installed (mock/stub the pipeline import).
"""

from __future__ import annotations

import contextlib
import io
import os
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

from vibe3d_ai3d_worker import server


MODEL = "jetx/TRELLIS-image-large"
SCRIPT = Path(__file__).resolve().parents[1] / "download_model.sh"


def _make_fake_snapshot(cache_dir: str, model: str, revision: str = "deadbeef") -> Path:
    """Minimal HF-cache-style snapshot dir so the filesystem probe finds it."""
    repo = Path(cache_dir) / ("models--" + model.replace("/", "--"))
    snap = repo / "snapshots" / revision
    snap.mkdir(parents=True, exist_ok=True)
    (snap / "config.json").write_text("{}", encoding="utf-8")
    return snap


@contextlib.contextmanager
def _hf_hub_absent():
    """Force ``import huggingface_hub`` to fail so the offline / fs-probe path
    runs deterministically regardless of what is installed on the host."""
    with mock.patch.dict(sys.modules, {"huggingface_hub": None}):
        yield


class DownloadScriptCase(unittest.TestCase):
    """(a) download_model.sh forwards its arguments to `fetch-model`."""

    def _run(self, *args: str) -> subprocess.CompletedProcess:
        # The script sets PYTHONPATH to its own dir, so `-m vibe3d_ai3d_worker`
        # resolves without an install. Run with a clean-ish env otherwise.
        return subprocess.run(
            ["bash", str(SCRIPT), *args],
            capture_output=True, text=True, timeout=60,
        )

    def test_script_is_executable(self) -> None:
        self.assertTrue(SCRIPT.exists(), SCRIPT)
        self.assertTrue(os.access(SCRIPT, os.X_OK), "download_model.sh not executable")

    def test_help_forwards_to_fetch_model(self) -> None:
        res = self._run("--help")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("fetch-model", res.stdout)
        self.assertIn("--check", res.stdout)
        self.assertIn("--model", res.stdout)

    def test_check_forwards_cache_dir_and_reports_absent(self) -> None:
        # --check + --cache-dir both forwarded: an empty cache => absent (exit 3).
        with tempfile.TemporaryDirectory() as cache:
            res = self._run("--check", "--cache-dir", cache)
        self.assertEqual(res.returncode, server.EXIT_MODEL_ABSENT, res.stderr)
        self.assertIn("not present", res.stdout)
        self.assertIn(MODEL, res.stdout)

    def test_check_forwards_model_id(self) -> None:
        # --model forwarded: the (absent) report echoes the custom id back.
        with tempfile.TemporaryDirectory() as cache:
            res = self._run("--check", "--model", "custom/some-model", "--cache-dir", cache)
        self.assertEqual(res.returncode, server.EXIT_MODEL_ABSENT, res.stderr)
        self.assertIn("custom/some-model", res.stdout)

    def test_check_reports_present_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as cache:
            _make_fake_snapshot(cache, MODEL)
            res = self._run("--check", "--cache-dir", cache)
        # exit 0 when present (fs-probe) — proves the wrapper returns the
        # subcommand's exit code, not a shell-mangled one.
        self.assertEqual(res.returncode, server.EXIT_OK, res.stderr)
        self.assertIn("present:", res.stdout)


class TrellisModelGuardCase(unittest.TestCase):
    """(b) backend refuses to auto-download; clear error when absent."""

    def test_absent_model_raises_actionable_error(self) -> None:
        with tempfile.TemporaryDirectory() as root, \
             tempfile.TemporaryDirectory() as cache, _hf_hub_absent():
            backend = server.TrellisBackend(Path(root), MODEL, "cpu", cache_dir=cache)
            with self.assertRaises(server.ProtocolError) as cm:
                backend._load()
        exc = cm.exception
        self.assertEqual(exc.code, "model_missing")
        self.assertEqual(exc.status, 503)
        msg = exc.message
        # names the exact download command(s), and says why it failed
        self.assertIn("download_model.sh", msg)
        self.assertIn("fetch-model", msg)
        self.assertIn("not in the local cache", msg)
        self.assertIn(MODEL, msg)

    def test_missing_message_helper_is_actionable(self) -> None:
        msg = server._model_missing_message(MODEL, "/some/cache")
        self.assertIn(MODEL, msg)
        self.assertIn("/some/cache", msg)
        self.assertIn("download_model.sh", msg)
        self.assertIn("fetch-model", msg)

    def test_present_model_forces_offline_before_pipeline_build(self) -> None:
        # Stub torch + trellis.pipelines so the present-model path runs with no
        # torch, no network. Assert HF_HUB_OFFLINE is set BEFORE from_pretrained
        # (proving no lazy download can leak out) and the model path is passed.
        seen: dict[str, object] = {}

        fake_torch = types.ModuleType("torch")
        fake_torch.cuda = types.SimpleNamespace(is_available=lambda: True)
        fake_torch.float16 = "float16"

        class FakePipe:
            models: dict = {}

            @staticmethod
            def from_pretrained(path):
                seen["path"] = path
                seen["offline"] = os.environ.get("HF_HUB_OFFLINE")
                return FakePipe()

            def to(self, *a):  # unused (precision='full')
                seen["to"] = a

        fake_pipelines = types.ModuleType("trellis.pipelines")
        fake_pipelines.TrellisImageTo3DPipeline = FakePipe
        fake_trellis = types.ModuleType("trellis")
        fake_trellis.pipelines = fake_pipelines
        mods = {
            "torch": fake_torch,
            "trellis": fake_trellis,
            "trellis.pipelines": fake_pipelines,
        }

        with tempfile.TemporaryDirectory() as root, \
             tempfile.TemporaryDirectory() as cache, _hf_hub_absent():
            _make_fake_snapshot(cache, MODEL)
            backend = server.TrellisBackend(
                Path(root), MODEL, "cpu", precision="full", cache_dir=cache,
            )
            with mock.patch.dict(os.environ, {}, clear=False), \
                 mock.patch.dict(sys.modules, mods):
                torch_mod, pipe = backend._load()

        self.assertIs(torch_mod, fake_torch)
        self.assertIsInstance(pipe, FakePipe)
        self.assertEqual(seen["path"], MODEL)
        # offline kill-switch was ON at the moment from_pretrained ran
        self.assertEqual(seen["offline"], "1")


if __name__ == "__main__":
    unittest.main()
