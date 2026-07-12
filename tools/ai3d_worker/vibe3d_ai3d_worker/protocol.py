from __future__ import annotations

import json
import re
from dataclasses import dataclass
from email.parser import BytesParser
from email.policy import default
from typing import Any


PROTOCOL_VERSION = 1
JSON_MEDIA = "application/json; charset=utf-8"
OBJ_MEDIA = "model/obj"
MAX_JSON_BYTES = 64 * 1024
MAX_INPUT_BYTES = 20 * 1024 * 1024
MAX_PIXELS = 16_777_216
MAX_QUEUED_JOBS = 1
DEFAULT_MAX_FACES = 50_000
MAX_JOB_ID_BYTES = 128

ERROR_CODES = {
    "worker_unavailable",
    "protocol_mismatch",
    "generation_mismatch",
    "unsupported_gpu",
    "model_missing",
    "model_integrity_failed",
    "invalid_input",
    "queue_full",
    "timeout",
    "gpu_oom",
    "backend_failed",
    "cancelled",
    "job_not_found",
    "artifact_not_ready",
    "artifact_unavailable",
    "artifact_expired",
    "artifact_missing",
    "artifact_hash_mismatch",
    "artifact_invalid",
    "internal",
}


class ProtocolError(Exception):
    def __init__(
        self,
        status: int,
        code: str,
        message: str,
        *,
        retryable: bool = False,
        details: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(message)
        if code not in ERROR_CODES:
            code = "internal"
        self.status = status
        self.code = code
        self.message = message[:512]
        self.retryable = retryable
        self.details = details or {}

    def body(self) -> dict[str, Any]:
        result: dict[str, Any] = {
            "code": self.code,
            "message": self.message,
            "retryable": self.retryable,
        }
        if self.details:
            result["details"] = self.details
        return result


@dataclass(frozen=True)
class MultipartPart:
    name: str
    media_type: str
    data: bytes


def json_bytes(value: dict[str, Any]) -> bytes:
    data = json.dumps(value, ensure_ascii=True, separators=(",", ":")).encode("utf-8")
    if len(data) > MAX_JSON_BYTES:
        raise ProtocolError(500, "internal", "JSON response exceeded worker limit")
    return data


def parse_json_part(data: bytes) -> dict[str, Any]:
    if len(data) > MAX_JSON_BYTES:
        raise ProtocolError(400, "invalid_input", "JSON part is too large")
    try:
        value = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProtocolError(400, "invalid_input", "Malformed JSON part") from exc
    if not isinstance(value, dict):
        raise ProtocolError(400, "invalid_input", "JSON part must be an object")
    return value


def parse_expected_generation(headers: dict[str, str]) -> int:
    raw = headers.get("x-vibe3d-ai3d-expected-generation", "")
    if not re.fullmatch(r"[1-9][0-9]{0,18}", raw):
        raise ProtocolError(400, "invalid_input", "Missing or invalid expected generation")
    return int(raw)


def require_protocol_header(headers: dict[str, str]) -> None:
    if headers.get("x-vibe3d-ai3d-protocol") != str(PROTOCOL_VERSION):
        raise ProtocolError(400, "protocol_mismatch", "Unsupported protocol header")


def validate_job_id(job_id: str) -> str:
    if not job_id or len(job_id.encode("utf-8")) > MAX_JOB_ID_BYTES:
        raise ProtocolError(404, "job_not_found", "Job was not found")
    if not re.fullmatch(r"[0-9a-fA-F-]{1,128}", job_id):
        raise ProtocolError(404, "job_not_found", "Job was not found")
    return job_id


def validate_image(media_type: str, data: bytes) -> None:
    if media_type not in {"image/png", "image/jpeg", "image/webp"}:
        raise ProtocolError(400, "invalid_input", "Unsupported image media type")
    if not data:
        raise ProtocolError(400, "invalid_input", "Image part is empty")
    if len(data) > MAX_INPUT_BYTES:
        raise ProtocolError(400, "invalid_input", "Image exceeds byte limit")
    if media_type == "image/png" and not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ProtocolError(400, "invalid_input", "Image magic bytes do not match PNG")
    if media_type == "image/jpeg" and not data.startswith(b"\xff\xd8"):
        raise ProtocolError(400, "invalid_input", "Image magic bytes do not match JPEG")
    if media_type == "image/webp" and not (data.startswith(b"RIFF") and data[8:12] == b"WEBP"):
        raise ProtocolError(400, "invalid_input", "Image magic bytes do not match WebP")


def validate_options(value: dict[str, Any]) -> None:
    allowed = {"protocol", "output", "maxFaces"}
    if set(value) != allowed:
        raise ProtocolError(400, "invalid_input", "Options must contain protocol, output, and maxFaces")
    if value["protocol"] != PROTOCOL_VERSION:
        raise ProtocolError(400, "protocol_mismatch", "Unsupported options protocol")
    if value["output"] != "obj":
        raise ProtocolError(400, "invalid_input", "Only OBJ output is supported")
    if not isinstance(value["maxFaces"], int) or value["maxFaces"] <= 0:
        raise ProtocolError(400, "invalid_input", "maxFaces must be a positive integer")
    if value["maxFaces"] > DEFAULT_MAX_FACES:
        raise ProtocolError(400, "invalid_input", "maxFaces exceeds worker limit")


def parse_multipart(content_type: str, body: bytes) -> dict[str, MultipartPart]:
    if not content_type.lower().startswith("multipart/form-data;"):
        raise ProtocolError(400, "invalid_input", "POST /v1/jobs requires multipart/form-data")
    if "boundary=" not in content_type:
        raise ProtocolError(400, "invalid_input", "Multipart boundary is required")
    header = f"Content-Type: {content_type}\r\nMIME-Version: 1.0\r\n\r\n".encode("ascii")
    try:
        message = BytesParser(policy=default).parsebytes(header + body)
    except Exception as exc:
        raise ProtocolError(400, "invalid_input", "Malformed multipart body") from exc
    if not message.is_multipart():
        raise ProtocolError(400, "invalid_input", "Malformed multipart body")
    parts: dict[str, MultipartPart] = {}
    for item in message.iter_parts():
        disposition = item.get("Content-Disposition", "")
        params = dict(item.get_params(header="content-disposition", failobj=[]))
        name = params.get("name")
        if name not in {"image", "options"}:
            raise ProtocolError(400, "invalid_input", "Unknown multipart part")
        if name in parts:
            raise ProtocolError(400, "invalid_input", "Duplicate multipart part")
        media_type = item.get_content_type()
        payload = item.get_payload(decode=True)
        if payload is None:
            raise ProtocolError(400, "invalid_input", "Multipart part is not binary")
        parts[name] = MultipartPart(name=name, media_type=media_type, data=payload)
    if set(parts) != {"image", "options"}:
        raise ProtocolError(400, "invalid_input", "Missing required multipart part")
    return parts

