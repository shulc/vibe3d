from __future__ import annotations

import http.client
import json
import tempfile
import threading
import time
import unittest
import uuid
from pathlib import Path

from vibe3d_ai3d_worker.server import WorkerServer


PNG_1X1 = (
    b"\x89PNG\r\n\x1a\n"
    b"\x00\x00\x00\rIHDR"
    b"\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00"
    b"\x90wS\xde"
    b"\x00\x00\x00\x0cIDATx\x9cc```\x00\x00\x00\x04\x00\x01"
    b"\xf6\x178U"
    b"\x00\x00\x00\x00IEND\xaeB`\x82"
)


class WorkerCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.server = WorkerServer(("127.0.0.1", 0), Path(self.tmp.name))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = ("127.0.0.1", self.server.server_port)

    def tearDown(self) -> None:
        self.server.shutdown()
        self.thread.join(timeout=2.0)
        self.server.server_close()
        self.tmp.cleanup()

    def request(self, method: str, path: str, body: bytes = b"", headers: dict[str, str] | None = None):
        conn = http.client.HTTPConnection(*self.base, timeout=5)
        conn.request(method, path, body=body, headers=headers or {})
        response = conn.getresponse()
        data = response.read()
        conn.close()
        return response.status, response.getheaders(), data

    def json_request(self, method: str, path: str, body: bytes = b"", headers: dict[str, str] | None = None):
        status, response_headers, data = self.request(method, path, body, headers)
        return status, dict((k.lower(), v) for k, v in response_headers), json.loads(data.decode("utf-8"))

    def create_job(self) -> dict:
        boundary = "----vibe3d-test-" + uuid.uuid4().hex
        options = json.dumps({"protocol": 1, "output": "obj", "maxFaces": 50000}).encode("utf-8")
        body = b"".join(
            [
                f"--{boundary}\r\n".encode("ascii"),
                b'Content-Disposition: form-data; name="image"; filename="image.png"\r\n',
                b"Content-Type: image/png\r\n\r\n",
                PNG_1X1,
                b"\r\n",
                f"--{boundary}\r\n".encode("ascii"),
                b'Content-Disposition: form-data; name="options"\r\n',
                b"Content-Type: application/json; charset=utf-8\r\n\r\n",
                options,
                b"\r\n",
                f"--{boundary}--\r\n".encode("ascii"),
            ]
        )
        status, _, data = self.json_request(
            "POST",
            "/v1/jobs",
            body,
            {
                "Content-Type": f"multipart/form-data; boundary={boundary}",
                "X-Vibe3D-AI3D-Protocol": "1",
            },
        )
        self.assertEqual(status, 202, data)
        return data

    def wait_terminal(self, job_id: str) -> dict:
        last = {}
        for _ in range(100):
            status, _, data = self.json_request(
                "GET",
                f"/v1/jobs/{job_id}",
                headers={"X-Vibe3D-AI3D-Protocol": "1"},
            )
            self.assertEqual(status, 200, data)
            last = data
            if data["state"] in {"succeeded", "failed", "cancelled"}:
                return data
            time.sleep(0.02)
        self.fail(f"job did not finish: {last}")

    def test_health_schema(self) -> None:
        status, headers, data = self.json_request("GET", "/v1/health")
        self.assertEqual(status, 200)
        self.assertEqual(headers["content-type"], "application/json; charset=utf-8")
        self.assertEqual(data["protocol"], 1)
        self.assertEqual(data["backend"]["id"], "triposr")
        self.assertTrue(data["ready"])
        self.assertIn("model/obj", data["capabilities"]["artifact"])

    def test_create_poll_and_artifact(self) -> None:
        created = self.create_job()
        self.assertEqual(created["generation"], 1)
        self.assertFalse(created["cancellationRequested"])
        terminal = self.wait_terminal(created["jobId"])
        self.assertEqual(terminal["state"], "succeeded")
        artifact = terminal["artifact"]
        status, headers, data = self.request(
            "GET",
            artifact["url"],
            headers={
                "X-Vibe3D-AI3D-Protocol": "1",
                "X-Vibe3D-AI3D-Expected-Generation": str(terminal["generation"]),
            },
        )
        self.assertEqual(status, 200)
        self.assertEqual(dict((k.lower(), v) for k, v in headers)["content-type"], "model/obj")
        self.assertIn(b"v 0 0 0", data)

    def test_missing_protocol_header_is_protocol_mismatch(self) -> None:
        status, _, data = self.json_request("GET", "/v1/jobs/not-a-job")
        self.assertEqual(status, 400)
        self.assertEqual(data["code"], "protocol_mismatch")

    def test_cancel_requires_matching_generation(self) -> None:
        created = self.create_job()
        status, _, data = self.json_request(
            "DELETE",
            f"/v1/jobs/{created['jobId']}",
            headers={
                "X-Vibe3D-AI3D-Protocol": "1",
                "X-Vibe3D-AI3D-Expected-Generation": "2",
            },
        )
        self.assertEqual(status, 409)
        self.assertEqual(data["code"], "generation_mismatch")
        terminal = self.wait_terminal(created["jobId"])
        self.assertNotEqual(terminal["state"], "cancelled")

    def test_cancel_same_generation_prevents_artifact(self) -> None:
        created = self.create_job()
        status, _, data = self.json_request(
            "DELETE",
            f"/v1/jobs/{created['jobId']}",
            headers={
                "X-Vibe3D-AI3D-Protocol": "1",
                "X-Vibe3D-AI3D-Expected-Generation": "1",
            },
        )
        self.assertIn(status, {200, 202})
        self.assertTrue(data["cancellationRequested"])
        terminal = self.wait_terminal(created["jobId"])
        self.assertEqual(terminal["state"], "cancelled")
        status, _, data = self.json_request(
            "GET",
            f"/v1/jobs/{created['jobId']}/artifact",
            headers={
                "X-Vibe3D-AI3D-Protocol": "1",
                "X-Vibe3D-AI3D-Expected-Generation": "1",
            },
        )
        self.assertEqual(status, 409)
        self.assertEqual(data["code"], "artifact_unavailable")

    def test_rejects_bad_image_magic(self) -> None:
        boundary = "----vibe3d-test-" + uuid.uuid4().hex
        body = b"".join(
            [
                f"--{boundary}\r\n".encode("ascii"),
                b'Content-Disposition: form-data; name="image"; filename="image.png"\r\n',
                b"Content-Type: image/png\r\n\r\nnot-png\r\n",
                f"--{boundary}\r\n".encode("ascii"),
                b'Content-Disposition: form-data; name="options"\r\n',
                b"Content-Type: application/json; charset=utf-8\r\n\r\n",
                b'{"protocol":1,"output":"obj","maxFaces":50000}\r\n',
                f"--{boundary}--\r\n".encode("ascii"),
            ]
        )
        status, _, data = self.json_request(
            "POST",
            "/v1/jobs",
            body,
            {
                "Content-Type": f"multipart/form-data; boundary={boundary}",
                "X-Vibe3D-AI3D-Protocol": "1",
            },
        )
        self.assertEqual(status, 400)
        self.assertEqual(data["code"], "invalid_input")


if __name__ == "__main__":
    unittest.main()

