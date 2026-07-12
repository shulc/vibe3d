from __future__ import annotations

import argparse
import hashlib
import json
import os
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
    artifact_path: Path | None = None
    artifact_sha256: str = ""
    artifact_bytes: int = 0
    created_at: float = field(default_factory=time.time)
    updated_at: float = field(default_factory=time.time)


class JobStore:
    def __init__(self, data_dir: Path) -> None:
        self.data_dir = data_dir
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock()
        self.jobs: dict[str, Job] = {}

    def create_job(self, image_media_type: str, image_bytes: bytes, options: dict[str, Any]) -> Job:
        with self.lock:
            active = [job for job in self.jobs.values() if job.state in {"queued", "running"}]
            if len(active) >= MAX_QUEUED_JOBS:
                raise ProtocolError(409, "queue_full", "Worker queue is full", retryable=True)
            job_id = str(uuid.uuid4())
            job_dir = self.data_dir / job_id
            job_dir.mkdir(mode=0o700, parents=True, exist_ok=False)
            suffix = {"image/png": ".png", "image/jpeg": ".jpg", "image/webp": ".webp"}[image_media_type]
            (job_dir / f"input{suffix}").write_bytes(image_bytes)
            (job_dir / "options.json").write_text(json.dumps(options, sort_keys=True), encoding="utf-8")
            job = Job(job_id=job_id, generation=1)
            self.jobs[job_id] = job
        threading.Thread(target=self._run_fake_backend, args=(job_id,), daemon=True).start()
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

    def _run_fake_backend(self, job_id: str) -> None:
        phases = [
            ("validating_input", 0.1),
            ("preprocessing", 0.25),
            ("reconstructing", 0.6),
            ("exporting", 0.85),
            ("validating_artifact", 0.95),
        ]
        for stage, progress in phases:
            time.sleep(0.02)
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
            tmp_obj.write_bytes(FAKE_OBJ)
            digest = hashlib.sha256(FAKE_OBJ).hexdigest()
            manifest = {
                "schema": 1,
                "jobId": job_id,
                "backend": {"id": "fake", "codeRevision": "dev", "modelRevision": "none"},
                "outputSha256": digest,
                "outputBytes": len(FAKE_OBJ),
                "counts": {"vertices": 3, "faces": 1},
                "licenseNoticeIds": [],
            }
            (tmp_dir / "manifest.json").write_text(json.dumps(manifest, sort_keys=True), encoding="utf-8")
            published = job_dir / "result"
            os.replace(tmp_dir, published)
            job.artifact_path = published / "result.obj"
            job.artifact_sha256 = digest
            job.artifact_bytes = len(FAKE_OBJ)
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
            "backend": {"id": "triposr", "codeRevision": "fake-dev", "modelRevision": "fake"},
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
    def __init__(self, address: tuple[str, int], data_dir: Path) -> None:
        super().__init__(address, WorkerHandler)
        self.store = JobStore(data_dir)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="vibe3d_ai3d_worker")
    sub = parser.add_subparsers(dest="command", required=True)
    serve = sub.add_parser("serve")
    serve.add_argument("--host", default="127.0.0.1")
    serve.add_argument("--port", type=int, default=47831)
    serve.add_argument("--data-dir", required=True)
    args = parser.parse_args(argv)
    if args.command == "serve":
        server = WorkerServer((args.host, args.port), Path(args.data_dir))
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

