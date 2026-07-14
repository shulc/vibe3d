from __future__ import annotations

import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vibe3d_ai3d_worker import server


MODEL = "jetx/TRELLIS-image-large"


def _make_fake_snapshot(cache_dir: str, model: str, revision: str = "deadbeef") -> Path:
    """Build a minimal HF-cache-style snapshot dir so the filesystem probe can
    find it. Layout: <cache>/models--<org>--<name>/snapshots/<rev>/config.json.
    """
    repo = Path(cache_dir) / ("models--" + model.replace("/", "--"))
    snap = repo / "snapshots" / revision
    snap.mkdir(parents=True, exist_ok=True)
    (snap / "config.json").write_text("{}", encoding="utf-8")
    return snap


@contextlib.contextmanager
def _hf_hub_absent():
    """Force `import huggingface_hub` to fail regardless of whether it is
    actually installed, so tests exercise the offline / base-worker path
    deterministically on any host."""
    with mock.patch.dict(sys.modules, {"huggingface_hub": None}):
        yield


class FetchModelHelperCase(unittest.TestCase):
    def test_import_hf_snapshot_download_missing_message(self) -> None:
        with _hf_hub_absent():
            with self.assertRaises(ImportError) as cm:
                server._import_hf_snapshot_download()
        msg = str(cm.exception)
        self.assertIn("huggingface_hub is not installed", msg)
        self.assertIn("install", msg.lower())

    def test_fs_find_snapshot_present_and_absent(self) -> None:
        with tempfile.TemporaryDirectory() as cache:
            self.assertIsNone(server._fs_find_snapshot(cache, MODEL))
            snap = _make_fake_snapshot(cache, MODEL)
            found = server._fs_find_snapshot(cache, MODEL)
            self.assertIsNotNone(found)
            self.assertEqual(found, snap)

    def test_fs_find_snapshot_empty_snapshot_is_absent(self) -> None:
        with tempfile.TemporaryDirectory() as cache:
            # snapshot dir exists but has no files -> treated as not present
            (Path(cache) / ("models--" + MODEL.replace("/", "--"))
             / "snapshots" / "empty").mkdir(parents=True)
            self.assertIsNone(server._fs_find_snapshot(cache, MODEL))

    def test_resolve_cache_dir_precedence(self) -> None:
        self.assertEqual(server._resolve_cache_dir("/x/y"), "/x/y")
        with mock.patch.dict("os.environ", {"HF_HUB_CACHE": "/hub/cache"}, clear=False):
            self.assertEqual(server._resolve_cache_dir(None), "/hub/cache")

    def test_snapshot_report(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "a.txt").write_bytes(b"x" * 10)
            sub = root / "sub"
            sub.mkdir()
            (sub / "b.bin").write_bytes(b"y" * 25)
            rep = server._snapshot_report(root)
            self.assertEqual(rep["files"], 2)
            self.assertEqual(rep["bytes"], 35)
            self.assertTrue(rep["fingerprint"])
            # fingerprint is stable / content-addressed
            self.assertEqual(rep["fingerprint"], server._snapshot_report(root)["fingerprint"])


class FetchModelCliCase(unittest.TestCase):
    def _run(self, argv: list[str]) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = server.main(argv)
        return rc, out.getvalue(), err.getvalue()

    def test_help_exits_zero(self) -> None:
        with self.assertRaises(SystemExit) as cm:
            with contextlib.redirect_stdout(io.StringIO()):
                server.main(["fetch-model", "--help"])
        self.assertEqual(cm.exception.code, 0)

    def test_check_absent_reports_not_present(self) -> None:
        with tempfile.TemporaryDirectory() as cache, _hf_hub_absent():
            rc, out, _ = self._run(["fetch-model", "--check", "--cache-dir", cache])
        self.assertEqual(rc, server.EXIT_MODEL_ABSENT)
        self.assertIn("not present", out)
        self.assertIn(MODEL, out)

    def test_check_present_reports_present(self) -> None:
        with tempfile.TemporaryDirectory() as cache, _hf_hub_absent():
            _make_fake_snapshot(cache, MODEL)
            rc, out, _ = self._run(["fetch-model", "--check", "--cache-dir", cache])
        self.assertEqual(rc, server.EXIT_OK)
        self.assertIn("present:", out)
        self.assertNotIn("not present", out)

    def test_download_without_hf_hub_errors_cleanly(self) -> None:
        with tempfile.TemporaryDirectory() as cache, _hf_hub_absent():
            rc, _, err = self._run(["fetch-model", "--cache-dir", cache])
        self.assertEqual(rc, server.EXIT_HF_HUB_MISSING)
        self.assertIn("huggingface_hub is not installed", err)
        self.assertIn("install", err.lower())

    def test_download_invokes_snapshot_download(self) -> None:
        # Exercise the happy download path WITHOUT any network: stub the lazy
        # import to return a fake snapshot_download that populates a local dir.
        with tempfile.TemporaryDirectory() as cache:
            snap = Path(cache) / "snap"
            snap.mkdir()
            (snap / "model.safetensors").write_bytes(b"z" * 128)

            def fake_snapshot_download(**kwargs):
                self.assertEqual(kwargs["repo_id"], MODEL)
                self.assertNotIn("local_files_only", kwargs)  # real download path
                return str(snap)

            with mock.patch.object(
                server, "_import_hf_snapshot_download",
                return_value=fake_snapshot_download,
            ):
                rc, out, _ = self._run(["fetch-model", "--cache-dir", cache])
        self.assertEqual(rc, server.EXIT_OK)
        self.assertIn("Downloaded", out)
        self.assertIn("fingerprint", out)
        self.assertIn("128 bytes", out)


if __name__ == "__main__":
    unittest.main()
