"""
MCP server for vibe3d — exposes app state and event playback as tools.

Workflow:
  1. In the app: F1 → do things → F2  (records to recording.jsonl)
  2. Claude calls get_recorded_events() to fetch the log
  3. Claude calls reset_app(), then play_events(log), then wait_playback()
  4. Claude calls get_state() and asserts the expected result
"""

import httpx
from mcp.server.fastmcp import FastMCP

APP_BASE = "http://localhost:8080"
TIMEOUT  = 10.0

mcp = FastMCP("vibe3d")


def _get(path: str) -> dict:
    r = httpx.get(f"{APP_BASE}{path}", timeout=TIMEOUT)
    r.raise_for_status()
    return r.text


def _post(path: str, body: str = "", content_type: str = "application/json") -> str:
    r = httpx.post(
        f"{APP_BASE}{path}",
        content=body.encode(),
        headers={"Content-Type": content_type},
        timeout=TIMEOUT,
    )
    r.raise_for_status()
    return r.text


# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------

@mcp.tool()
def get_recorded_events() -> str:
    """
    Returns the JSON Lines event log captured between the last F1 and F2
    key presses in the app. Each line is one SDL event (mouse, keyboard, etc.).
    Use this to load a recording before calling play_events().
    """
    return _get("/api/recorded-events")


@mcp.tool()
def reset_app() -> str:
    """
    Resets the app to its initial state: cube mesh, default camera, no selection.
    Always call this before play_events() to ensure a clean slate.
    """
    return _post("/api/reset")


@mcp.tool()
def play_events(events: str) -> str:
    """
    Loads a JSON Lines event log into the app and starts playback.
    The app must be running in --test mode.
    Pass the raw text returned by get_recorded_events().
    After calling this, poll wait_playback() until it returns finished=true.
    """
    return _post("/api/play-events", events, content_type="text/plain")


@mcp.tool()
def wait_playback(poll_interval_ms: int = 100, timeout_ms: int = 30000) -> str:
    """
    Blocks until event playback finishes (or timeout).
    Returns a JSON object: {"finished": true, "total": N, "elapsed_ms": M}
    Use after play_events() before checking app state.
    """
    import time
    import json

    deadline = time.monotonic() + timeout_ms / 1000.0
    while time.monotonic() < deadline:
        text = _get("/api/play-events/status")
        data = json.loads(text)
        if data.get("finished"):
            return json.dumps({"finished": True, "total": data.get("total", 0),
                               "elapsed_ms": int((timeout_ms / 1000.0 - (deadline - time.monotonic())) * 1000)})
        time.sleep(poll_interval_ms / 1000.0)

    return json.dumps({"finished": False, "error": "timeout"})


@mcp.tool()
def get_state() -> str:
    """
    Returns the full current app state as JSON:
    {
      "model":     { "vertexCount", "edgeCount", "faceCount", "vertices": [[x,y,z],...], "faces": [[...]] },
      "selection": { "mode", "selected": [indices] },
      "camera":    { "azimuth", "elevation", "distance", "focus", "eye" }
    }
    """
    import json

    model     = json.loads(_get("/api/model"))
    selection = json.loads(_get("/api/selection"))
    camera    = json.loads(_get("/api/camera"))

    return json.dumps({"model": model, "selection": selection, "camera": camera}, indent=2)


@mcp.tool()
def get_model() -> str:
    """
    Returns only the mesh state: vertex/edge/face counts + full vertex and face arrays.
    Lighter alternative to get_state() when you only care about geometry.
    """
    return _get("/api/model")


@mcp.tool()
def get_selection() -> str:
    """
    Returns the current selection: edit mode and list of selected indices.
    """
    return _get("/api/selection")


@mcp.tool()
def get_camera() -> str:
    """
    Returns the camera state: azimuth, elevation, distance, focus point, eye position.
    """
    return _get("/api/camera")


if __name__ == "__main__":
    mcp.run()
