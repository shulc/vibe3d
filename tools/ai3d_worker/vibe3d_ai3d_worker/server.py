from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile
import threading
import time
import uuid
from dataclasses import dataclass, field
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from . import __version__
from .protocol import (
    DEFAULT_MAX_FACES,
    JSON_MEDIA,
    MAX_INPUT_BYTES,
    MAX_JSON_BYTES,
    MAX_PIXELS,
    MAX_QUEUED_JOBS,
    OBJ_MEDIA,
    PROTOCOL_VERSION,
    ProtocolError,
    json_bytes,
    parse_expected_generation,
    parse_json_part,
    parse_multipart,
    require_protocol_header,
    validate_image,
    validate_job_id,
    validate_options,
)


FAKE_OBJ = b"""# Vibe3D AI3D fake backend\nv 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n"""


@dataclass
class Job:
    job_id: str
    generation: int
    state: str = "queued"
    stage: str = "queued"
    progress: float = 0.0
    cancellation_requested: bool = False
    error: dict[str, Any] | None = None
    input_path: Path | None = None
    artifact_path: Path | None = None
    artifact_sha256: str = ""
    artifact_bytes: int = 0
    created_at: float = field(default_factory=time.time)
    updated_at: float = field(default_factory=time.time)


class FakeBackend:
    backend_id = "triposr"
    code_revision = "fake-dev"
    model_revision = "fake"

    def generate(self, image_path: Path, output_path: Path) -> None:
        output_path.write_bytes(FAKE_OBJ)


class TripoSRBackend:
    backend_id = "triposr"

    def __init__(
        self,
        triposr_root: Path,
        model: str,
        device: str,
        chunk_size: int,
        mc_resolution: int,
        foreground_ratio: float = 0.85,
        remove_bg: bool = True,
    ) -> None:
        self.triposr_root = triposr_root
        self.model_name_or_path = model
        self.device = device
        self.chunk_size = chunk_size
        self.mc_resolution = mc_resolution
        self.foreground_ratio = foreground_ratio
        self.remove_bg = remove_bg
        self.code_revision = self._git_revision(triposr_root)
        self.model_revision = model
        self._model = None
        self._torch = None
        self._rembg_session = None
        self._lock = threading.Lock()

    def _git_revision(self, root: Path) -> str:
        head = root / ".git" / "HEAD"
        try:
            text = head.read_text(encoding="utf-8").strip()
            if text.startswith("ref: "):
                ref = root / ".git" / text[5:]
                return ref.read_text(encoding="utf-8").strip()[:40]
            return text[:40]
        except OSError:
            return "unknown"

    def _load(self):
        with self._lock:
            if self._model is not None:
                return self._torch, self._model
            if not self.triposr_root.exists():
                raise ProtocolError(503, "model_missing", "TripoSR root does not exist")
            sys.path.insert(0, str(self.triposr_root))
            import torch
            from tsr.system import TSR

            if self.device.startswith("cuda") and not torch.cuda.is_available():
                raise ProtocolError(503, "unsupported_gpu", "CUDA is not available")
            model = TSR.from_pretrained(
                self.model_name_or_path,
                config_name="config.yaml",
                weight_name="model.ckpt",
            )
            model.renderer.set_chunk_size(self.chunk_size)
            model.to(self.device)
            model.eval()
            self._torch = torch
            self._model = model
            return torch, model

    def generate(self, image_path: Path, output_path: Path) -> None:
        torch, model = self._load()
        from PIL import Image
        import numpy as np

        # TripoSR REQUIRES foreground segmentation + centering BEFORE inference
        # (this mirrors upstream TripoSR run.py exactly). Feeding a raw RGB image
        # whose background is not removed makes the model reconstruct the whole
        # frame as a near-flat slab — "a square with the subject in low relief" —
        # which is the classic failure even on a clean product photo on white.
        # remove_background() cuts the subject out, resize_foreground() centers +
        # scales it into the frame, then it is composited onto mid-gray (0.5),
        # exactly the distribution TripoSR was trained on.
        if self.remove_bg:
            from tsr.utils import remove_background, resize_foreground
            import rembg
            if self._rembg_session is None:
                self._rembg_session = rembg.new_session()
            image = remove_background(Image.open(image_path), self._rembg_session)
            image = resize_foreground(image, self.foreground_ratio)
            arr = np.array(image).astype(np.float32) / 255.0
            arr = arr[:, :, :3] * arr[:, :, 3:4] + (1.0 - arr[:, :, 3:4]) * 0.5
            image = Image.fromarray((arr * 255.0).astype(np.uint8))
        else:
            image = Image.open(image_path).convert("RGB")

        with torch.no_grad():
            scene_codes = model([image], device=self.device)
            meshes = model.extract_mesh(
                scene_codes,
                True,
                resolution=self.mc_resolution,
            )
        mesh = meshes[0]
        # TripoSR emits meshes Z-up (the subject's height runs along +Z); vibe3d
        # and conventional OBJ consumers are Y-up, so a raw import lies on its
        # side. Rotate -90 deg about X (Z-up -> Y-up): (x, y, z) -> (x, z, -y).
        # Verified on a real figurine: this stands the subject upright, head +Y.
        import trimesh
        mesh.apply_transform(
            trimesh.transformations.rotation_matrix(-np.pi / 2.0, [1, 0, 0])
        )
        mesh.export(output_path)


class TrellisBackend:
    """Microsoft TRELLIS (Structured 3D Latents) image-to-3D, MIT-licensed.

    Produces markedly cleaner geometry than TripoSR on clean single-object
    photos. Runs on 8 GB VRAM via FP16 (``--trellis-precision half``) plus the
    fork's per-stage CPU<->GPU offload (only one sub-model is resident at a
    time), so peak VRAM stays ~5 GB even for TRELLIS-image-large.

    We decode ``formats=['mesh']`` ONLY: that never touches nvdiffrast /
    diff_gaussian_rasterization / diffoctreerast (the CUDA source-build
    extensions), so the worker needs only prebuilt wheels + the pure-PyTorch
    flexicubes mesh extractor. The raw mesh is very dense (~600k faces), so we
    decimate to ``max_faces`` before export; TRELLIS emits Z-up like TripoSR,
    so we apply the same -90 deg X rotation to stand the subject upright (Y-up).
    """

    backend_id = "trellis"

    def __init__(
        self,
        trellis_root: Path,
        model: str,
        device: str,
        precision: str = "half",
        ss_steps: int = 12,
        slat_steps: int = 12,
        seed: int = 1,
        max_faces: int = DEFAULT_MAX_FACES,
    ) -> None:
        self.trellis_root = trellis_root
        self.model_name_or_path = model
        self.device = device
        self.precision = precision
        self.ss_steps = ss_steps
        self.slat_steps = slat_steps
        self.seed = seed
        self.max_faces = max_faces
        self.code_revision = self._git_revision(trellis_root)
        self.model_revision = model
        self._pipeline = None
        self._torch = None
        self._lock = threading.Lock()

    def _git_revision(self, root: Path) -> str:
        head = root / ".git" / "HEAD"
        try:
            text = head.read_text(encoding="utf-8").strip()
            if text.startswith("ref: "):
                ref = root / ".git" / text[5:]
                return ref.read_text(encoding="utf-8").strip()[:40]
            return text[:40]
        except OSError:
            return "unknown"

    def _load(self):
        with self._lock:
            if self._pipeline is not None:
                return self._torch, self._pipeline
            if not self.trellis_root.exists():
                raise ProtocolError(503, "model_missing", "TRELLIS root does not exist")
            # TRELLIS reads these at import time to pick attention / sparse-conv
            # backends. 'xformers' avoids the flash-attn source build; 'native'
            # skips spconv's first-call autotune. setdefault so an operator can
            # still override from the environment.
            os.environ.setdefault("ATTN_BACKEND", "xformers")
            os.environ.setdefault("SPCONV_ALGO", "native")
            os.environ.setdefault("PYTORCH_CUDA_ALLOC_CONF", "expandable_segments:True")
            sys.path.insert(0, str(self.trellis_root))
            import torch
            from trellis.pipelines import TrellisImageTo3DPipeline

            if self.device.startswith("cuda") and not torch.cuda.is_available():
                raise ProtocolError(503, "unsupported_gpu", "CUDA is not available")
            pipeline = TrellisImageTo3DPipeline.from_pretrained(self.model_name_or_path)
            if self.precision in ("half", "float16"):
                pipeline.to(torch.float16)  # halves resident VRAM for the 8 GB path
                if "image_cond_model" in pipeline.models:
                    pipeline.models["image_cond_model"].half()
            # Deliberately NO pipeline.cuda(): the fork moves each sub-model to
            # the GPU only for its stage inside run() (dynamic offload). Forcing
            # everything resident here would blow the 8 GB budget.
            self._torch = torch
            self._pipeline = pipeline
            return torch, pipeline

    def generate(self, image_path: Path, output_path: Path) -> None:
        torch, pipeline = self._load()
        from PIL import Image
        import numpy as np
        import trimesh

        # TRELLIS does its own foreground segmentation internally
        # (preprocess_image=True runs rembg), so unlike TripoSR we pass the
        # image through untouched.
        image = Image.open(image_path)
        with torch.no_grad():
            outputs = pipeline.run(
                image,
                seed=self.seed,
                formats=["mesh"],  # geometry only; no gaussian/RF -> no CUDA-ext builds
                sparse_structure_sampler_params={"steps": self.ss_steps, "cfg_strength": 7.5},
                slat_sampler_params={"steps": self.slat_steps, "cfg_strength": 3.0},
            )
        mesh = outputs["mesh"][0]
        verts = mesh.vertices.detach().float().cpu().numpy()
        faces = mesh.faces.detach().cpu().numpy()
        tm = trimesh.Trimesh(vertices=verts, faces=faces, process=False)

        # TRELLIS, like TripoSR, emits Z-up; vibe3d is Y-up. -90 deg about X:
        # (x, y, z) -> (x, z, -y) stands the subject upright, head +Y.
        tm.apply_transform(
            trimesh.transformations.rotation_matrix(-np.pi / 2.0, [1, 0, 0])
        )

        # The raw flexicubes mesh is ~600k faces — too dense for the editor's
        # import validator and for interactive editing. Quadric-decimate down to
        # max_faces (fast_simplification). This preserves the silhouette well
        # even at a ~12x reduction.
        if self.max_faces and len(tm.faces) > self.max_faces:
            tm = tm.simplify_quadric_decimation(face_count=self.max_faces)

        tm.export(output_path)


class JobStore:
    def __init__(self, data_dir: Path, backend, phase_delay_s: float = 0.02) -> None:
        self.data_dir = data_dir
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.backend = backend
        self.lock = threading.RLock()
        self.jobs: dict[str, Job] = {}
        # Per-phase sleep in _run_backend (task 0381 Phase 4). The default
        # (0.02s x 5 phases ~= 100ms) is far shorter than a real vibe3d
        # controller's 250ms poll tick, so a "cancel while genuinely
        # running" test would almost always land its cancel before the
        # FIRST status poll even observes "running" — collapsing straight
        # to the queued-cancel path. `--delay <ms>` (serve CLI) widens this
        # window so such tests can reliably land mid-run.
        self.phase_delay_s = phase_delay_s

    def create_job(self, image_media_type: str, image_bytes: bytes, options: dict[str, Any]) -> Job:
        with self.lock:
            active = [job for job in self.jobs.values() if job.state in {"queued", "running"}]
            if len(active) >= MAX_QUEUED_JOBS:
                raise ProtocolError(409, "queue_full", "Worker queue is full", retryable=True)
            job_id = str(uuid.uuid4())
            job_dir = self.data_dir / job_id
            job_dir.mkdir(mode=0o700, parents=True, exist_ok=False)
            suffix = {"image/png": ".png", "image/jpeg": ".jpg", "image/webp": ".webp"}[image_media_type]
            input_path = job_dir / f"input{suffix}"
            input_path.write_bytes(image_bytes)
            (job_dir / "options.json").write_text(json.dumps(options, sort_keys=True), encoding="utf-8")
            job = Job(job_id=job_id, generation=1, input_path=input_path)
            self.jobs[job_id] = job
        threading.Thread(target=self._run_backend, args=(job_id,), daemon=True).start()
        return job

    def get(self, job_id: str) -> Job:
        validate_job_id(job_id)
        with self.lock:
            job = self.jobs.get(job_id)
            if job is None:
                raise ProtocolError(404, "job_not_found", "Job was not found")
            return job

    def cancel(self, job_id: str, expected_generation: int) -> Job:
        with self.lock:
            job = self.get(job_id)
            if job.generation != expected_generation:
                raise ProtocolError(
                    409,
                    "generation_mismatch",
                    "Job generation mismatch",
                    details={
                        "expectedGeneration": expected_generation,
                        "actualGeneration": job.generation,
                    },
                )
            job.cancellation_requested = True
            job.updated_at = time.time()
            if job.state == "queued":
                job.state = "cancelled"
                job.stage = "done"
                job.progress = 1.0
            return job

    def artifact(self, job_id: str, expected_generation: int) -> bytes:
        with self.lock:
            job = self.get(job_id)
            if job.generation != expected_generation:
                raise ProtocolError(
                    409,
                    "generation_mismatch",
                    "Job generation mismatch",
                    details={
                        "expectedGeneration": expected_generation,
                        "actualGeneration": job.generation,
                    },
                )
            if job.state in {"queued", "running"}:
                raise ProtocolError(409, "artifact_not_ready", "Artifact is not ready", retryable=True)
            if job.state in {"failed", "cancelled"}:
                raise ProtocolError(409, "artifact_unavailable", "Artifact is unavailable")
            if job.artifact_path is None or not job.artifact_path.exists():
                raise ProtocolError(410, "artifact_expired", "Artifact expired")
            data = job.artifact_path.read_bytes()
            digest = hashlib.sha256(data).hexdigest()
            if digest != job.artifact_sha256 or len(data) != job.artifact_bytes:
                raise ProtocolError(409, "artifact_hash_mismatch", "Artifact hash mismatch")
            return data

    def _run_backend(self, job_id: str) -> None:
        phases = [
            ("validating_input", 0.1),
            ("preprocessing", 0.25),
            ("reconstructing", 0.55),
            ("exporting", 0.85),
            ("validating_artifact", 0.95),
        ]
        for stage, progress in phases:
            time.sleep(self.phase_delay_s)
            with self.lock:
                job = self.jobs.get(job_id)
                if job is None or job.state in {"failed", "cancelled"}:
                    return
                if job.cancellation_requested:
                    job.state = "cancelled"
                    job.stage = "done"
                    job.progress = 1.0
                    job.updated_at = time.time()
                    return
                job.state = "running"
                job.stage = stage
                job.progress = progress
                job.updated_at = time.time()
        with self.lock:
            job = self.jobs.get(job_id)
            if job is None or job.cancellation_requested:
                if job is not None:
                    job.state = "cancelled"
                    job.stage = "done"
                    job.progress = 1.0
                    job.updated_at = time.time()
                return
            job_dir = self.data_dir / job_id
            tmp_dir = Path(tempfile.mkdtemp(prefix="publish-", dir=job_dir))
            tmp_obj = tmp_dir / "result.obj"
            try:
                if job.input_path is None:
                    raise ProtocolError(500, "internal", "Missing input path")
                self.backend.generate(job.input_path, tmp_obj)
            except ProtocolError as exc:
                job.state = "failed"
                job.stage = "done"
                job.error = exc.body()
                job.updated_at = time.time()
                return
            except Exception as exc:
                job.state = "failed"
                job.stage = "done"
                job.error = ProtocolError(
                    500,
                    "backend_failed",
                    "Backend failed during mesh generation",
                    details={"type": exc.__class__.__name__},
                ).body()
                job.updated_at = time.time()
                return
            data = tmp_obj.read_bytes()
            digest = hashlib.sha256(data).hexdigest()
            manifest = {
                "schema": 1,
                "jobId": job_id,
                "backend": {
                    "id": self.backend.backend_id,
                    "codeRevision": self.backend.code_revision,
                    "modelRevision": self.backend.model_revision,
                },
                "outputSha256": digest,
                "outputBytes": len(data),
                "counts": {},
                "licenseNoticeIds": [],
            }
            (tmp_dir / "manifest.json").write_text(json.dumps(manifest, sort_keys=True), encoding="utf-8")
            published = job_dir / "result"
            os.replace(tmp_dir, published)
            job.artifact_path = published / "result.obj"
            job.artifact_sha256 = digest
            job.artifact_bytes = len(data)
            job.state = "succeeded"
            job.stage = "done"
            job.progress = 1.0
            job.updated_at = time.time()


def status_body(job: Job, *, include_artifact: bool = True) -> dict[str, Any]:
    body: dict[str, Any] = {
        "jobId": job.job_id,
        "generation": job.generation,
        "state": job.state,
        "stage": job.stage,
        "progress": job.progress,
        "cancellationRequested": job.cancellation_requested,
        "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(job.updated_at)),
    }
    if job.state == "succeeded" and include_artifact:
        body["artifact"] = {
            "url": f"/v1/jobs/{job.job_id}/artifact",
            "sha256": job.artifact_sha256,
            "bytes": job.artifact_bytes,
            "generation": job.generation,
        }
    if job.state == "failed" and job.error is not None:
        body["error"] = job.error
    return body


class WorkerHandler(BaseHTTPRequestHandler):
    server_version = "Vibe3DAI3DWorker/0.1"

    def log_message(self, fmt: str, *args: object) -> None:
        return

    @property
    def store(self) -> JobStore:
        return self.server.store  # type: ignore[attr-defined]

    def do_GET(self) -> None:
        self._handle("GET")

    def do_POST(self) -> None:
        self._handle("POST")

    def do_DELETE(self) -> None:
        self._handle("DELETE")

    def _handle(self, method: str) -> None:
        try:
            headers = {k.lower(): v for k, v in self.headers.items()}
            parsed = urlparse(self.path)
            path = parsed.path
            if path == "/v1/health" and method == "GET":
                self._send_json(HTTPStatus.OK, self._health())
                return
            require_protocol_header(headers)
            if path == "/v1/jobs" and method == "POST":
                self._create_job(headers)
                return
            if path.startswith("/v1/jobs/"):
                segments = path.strip("/").split("/")
                if len(segments) == 3 and method == "GET":
                    self._send_json(HTTPStatus.OK, status_body(self.store.get(segments[2])))
                    return
                if len(segments) == 3 and method == "DELETE":
                    expected = parse_expected_generation(headers)
                    job = self.store.cancel(segments[2], expected)
                    status = HTTPStatus.OK if job.state in {"cancelled", "failed", "succeeded"} else HTTPStatus.ACCEPTED
                    self._send_json(status, status_body(job, include_artifact=False))
                    return
                if len(segments) == 4 and segments[3] == "artifact" and method == "GET":
                    expected = parse_expected_generation(headers)
                    data = self.store.artifact(segments[2], expected)
                    self.send_response(HTTPStatus.OK)
                    self.send_header("Content-Type", OBJ_MEDIA)
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return
            raise ProtocolError(404, "job_not_found", "Endpoint was not found")
        except ProtocolError as exc:
            self._send_json(exc.status, exc.body())
        except Exception:
            self._send_json(500, ProtocolError(500, "internal", "Internal worker error").body())

    def _health(self) -> dict[str, Any]:
        return {
            "protocol": PROTOCOL_VERSION,
            "workerVersion": __version__,
            "backend": {
                "id": self.store.backend.backend_id,
                "codeRevision": self.store.backend.code_revision,
                "modelRevision": self.store.backend.model_revision,
            },
            "ready": True,
            "capabilities": {
                "input": ["image/png", "image/jpeg", "image/webp"],
                "artifact": [OBJ_MEDIA],
            },
            "limits": {
                "maxInputBytes": MAX_INPUT_BYTES,
                "maxPixels": MAX_PIXELS,
                "maxQueuedJobs": MAX_QUEUED_JOBS,
                "maxFaces": DEFAULT_MAX_FACES,
            },
        }

    def _create_job(self, headers: dict[str, str]) -> None:
        raw_len = self.headers.get("Content-Length")
        if raw_len is None or not raw_len.isdigit():
            raise ProtocolError(400, "invalid_input", "Content-Length is required")
        length = int(raw_len)
        if length <= 0 or length > MAX_INPUT_BYTES + MAX_JSON_BYTES + 16 * 1024:
            raise ProtocolError(400, "invalid_input", "Request body exceeds limit")
        body = self.rfile.read(length)
        parts = parse_multipart(headers.get("content-type", ""), body)
        image = parts["image"]
        options_part = parts["options"]
        if options_part.media_type != "application/json":
            raise ProtocolError(400, "invalid_input", "Options part must be JSON")
        options = parse_json_part(options_part.data)
        validate_options(options)
        validate_image(image.media_type, image.data)
        job = self.store.create_job(image.media_type, image.data, options)
        self._send_json(
            HTTPStatus.ACCEPTED,
            {
                "jobId": job.job_id,
                "generation": job.generation,
                "state": job.state,
                "cancellationRequested": job.cancellation_requested,
                "statusUrl": f"/v1/jobs/{job.job_id}",
            },
        )

    def _send_json(self, status: int, value: dict[str, Any]) -> None:
        data = json_bytes(value)
        self.send_response(status)
        self.send_header("Content-Type", JSON_MEDIA)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class WorkerServer(ThreadingHTTPServer):
    def __init__(
        self,
        address: tuple[str, int],
        data_dir: Path,
        backend=None,
        phase_delay_s: float = 0.02,
    ) -> None:
        super().__init__(address, WorkerHandler)
        self.store = JobStore(data_dir, backend or FakeBackend(), phase_delay_s)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="vibe3d_ai3d_worker")
    sub = parser.add_subparsers(dest="command", required=True)
    serve = sub.add_parser("serve")
    serve.add_argument("--host", default="127.0.0.1")
    serve.add_argument("--port", type=int, default=47831)
    serve.add_argument("--data-dir", required=True)
    serve.add_argument("--backend", choices=["fake", "triposr", "trellis"], default="fake")
    serve.add_argument("--triposr-root", default="")
    serve.add_argument("--pretrained-model-name-or-path", default="stabilityai/TripoSR")
    serve.add_argument("--device", default="cuda:0")
    # --- TRELLIS backend (image->3D via Structured 3D Latents, MIT) ---
    serve.add_argument("--trellis-root", default="",
                       help="path to the TRELLIS checkout (added to sys.path)")
    serve.add_argument("--trellis-model", default="jetx/TRELLIS-image-large",
                       help="HuggingFace model id for the TRELLIS pipeline")
    serve.add_argument("--trellis-precision", choices=["half", "full"], default="half",
                       help="'half' (FP16) fits 8 GB VRAM; 'full' needs ~16 GB")
    serve.add_argument("--trellis-ss-steps", type=int, default=12,
                       help="sparse-structure sampler steps (more = slower/finer)")
    serve.add_argument("--trellis-slat-steps", type=int, default=12,
                       help="structured-latent sampler steps (more = slower/finer)")
    serve.add_argument("--trellis-seed", type=int, default=1)
    serve.add_argument("--trellis-max-faces", type=int, default=DEFAULT_MAX_FACES,
                       help="decimate the (very dense) raw mesh down to this many "
                            "faces before export")
    serve.add_argument("--chunk-size", type=int, default=8192)
    serve.add_argument("--mc-resolution", type=int, default=120)
    serve.add_argument("--foreground-ratio", type=float, default=0.85,
                       help="fraction of the frame the segmented subject fills "
                            "after background removal (TripoSR default 0.85)")
    serve.add_argument("--no-remove-bg", action="store_true",
                       help="skip rembg background removal + foreground resize. "
                            "NOT recommended: feeding a raw image whose background "
                            "is not removed makes TripoSR reconstruct the whole "
                            "frame as a shapeless blob instead of the subject.")
    # Task 0381 Phase 4: per-phase delay (ms) for the `fake` backend's
    # simulated 5-phase run, so a client's "cancel while genuinely running"
    # test can land its cancel after the worker has actually reported
    # state=="running" at least once, instead of the ~100ms default window
    # collapsing every such test into the queued-cancel path. Ignored by
    # the triposr backend (real GPU inference sets its own pace).
    serve.add_argument("--delay", type=int, default=20)
    args = parser.parse_args(argv)
    if args.command == "serve":
        if args.backend == "triposr":
            if not args.triposr_root:
                parser.error("--backend triposr requires --triposr-root")
            backend = TripoSRBackend(
                Path(args.triposr_root),
                args.pretrained_model_name_or_path,
                args.device,
                args.chunk_size,
                args.mc_resolution,
                foreground_ratio=args.foreground_ratio,
                remove_bg=not args.no_remove_bg,
            )
        elif args.backend == "trellis":
            if not args.trellis_root:
                parser.error("--backend trellis requires --trellis-root")
            backend = TrellisBackend(
                Path(args.trellis_root),
                args.trellis_model,
                args.device,
                precision=args.trellis_precision,
                ss_steps=args.trellis_ss_steps,
                slat_steps=args.trellis_slat_steps,
                seed=args.trellis_seed,
                max_faces=args.trellis_max_faces,
            )
        else:
            backend = FakeBackend()
        server = WorkerServer(
            (args.host, args.port), Path(args.data_dir), backend, args.delay / 1000.0
        )
        print(f"vibe3d_ai3d_worker listening on http://{args.host}:{server.server_port}", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            server.server_close()
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
