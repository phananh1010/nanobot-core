"""Tests for gateway HTTP API (batch + NDJSON stream)."""

from __future__ import annotations

import json

from starlette.testclient import TestClient

from nanobot.gateway.http import create_http_app


class _FakeAgent:
    async def process_direct(
        self,
        content: str,
        session_key: str = "cli:direct",
        channel: str = "cli",
        chat_id: str = "direct",
        on_progress=None,
    ) -> str:
        if on_progress:
            await on_progress("step-a", tool_hint=False)
            await on_progress('tool("x")', tool_hint=True)
        return "final"


def test_chat_batch_json() -> None:
    app = create_http_app(_FakeAgent())
    client = TestClient(app)
    r = client.post("/v1/chat", json={"message": "hello"})
    assert r.status_code == 200
    assert r.json() == {"response": "final"}


def test_chat_stream_ndjson() -> None:
    app = create_http_app(_FakeAgent(), send_progress=True, send_tool_hints=True)
    client = TestClient(app)
    with client.stream("POST", "/v1/chat/stream", json={"message": "hello"}) as r:
        assert r.status_code == 200
        assert r.headers["content-type"].startswith("application/x-ndjson")
        body = "".join(chunk.decode("utf-8") for chunk in r.iter_bytes())
    lines = [json.loads(line) for line in body.strip().split("\n") if line]
    assert lines[0] == {"type": "progress", "text": "step-a"}
    assert lines[1] == {"type": "tool_hint", "text": 'tool("x")'}
    assert lines[2] == {"type": "done", "response": "final"}


def test_chat_stream_skips_tool_hints_when_disabled() -> None:
    app = create_http_app(_FakeAgent(), send_progress=True, send_tool_hints=False)
    client = TestClient(app)
    with client.stream("POST", "/v1/chat/stream", json={"message": "hello"}) as r:
        body = "".join(chunk.decode("utf-8") for chunk in r.iter_bytes())
    lines = [json.loads(line) for line in body.strip().split("\n") if line]
    assert lines[0] == {"type": "progress", "text": "step-a"}
    assert lines[1] == {"type": "done", "response": "final"}


def test_unauthorized_stream() -> None:
    app = create_http_app(_FakeAgent(), api_key="secret")
    client = TestClient(app)
    r = client.post("/v1/chat/stream", json={"message": "hello"})
    assert r.status_code == 401
