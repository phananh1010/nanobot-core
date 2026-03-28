"""Minimal HTTP API for curl/script access to the agent (gateway only)."""

from __future__ import annotations

import asyncio
import json
from collections.abc import AsyncIterator
from typing import TYPE_CHECKING, Any

from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, StreamingResponse
from starlette.routing import Route

if TYPE_CHECKING:
    from nanobot.agent.loop import AgentLoop


def _check_api_key(request: Request, api_key: str | None) -> bool:
    if not api_key:
        return True
    auth = request.headers.get("authorization") or ""
    if auth.lower().startswith("bearer "):
        token = auth[7:].strip()
    else:
        token = request.headers.get("x-api-key") or ""
    return token == api_key


def _parse_chat_json(body: dict[str, Any]) -> JSONResponse | tuple[str, str, str, str]:
    """Return ``(message, session_key, channel, chat_id)`` or a JSON error response."""
    message = body.get("message")
    if message is None:
        message = body.get("content")
    if not isinstance(message, str) or not message.strip():
        return JSONResponse(
            {"error": "missing or empty \"message\" (or \"content\") string"},
            status_code=400,
        )

    raw_session = body.get("session")
    if raw_session is not None and not isinstance(raw_session, str):
        return JSONResponse({"error": "\"session\" must be a string"}, status_code=400)
    session_key = (raw_session or "").strip() or "http:default"
    if ":" not in session_key:
        session_key = f"http:{session_key}"
    channel, chat_id = session_key.split(":", 1)
    chat_id = chat_id or "default"
    return message.strip(), session_key, channel, chat_id


def create_http_app(
    agent: AgentLoop,
    *,
    api_key: str | None = None,
    send_progress: bool = True,
    send_tool_hints: bool = False,
) -> Starlette:
    """ASGI app: ``POST /v1/chat`` (JSON body) and ``POST /v1/chat/stream`` (NDJSON)."""

    async def health(_: Request) -> JSONResponse:
        return JSONResponse({"status": "ok"})

    async def chat(request: Request) -> JSONResponse:
        if not _check_api_key(request, api_key):
            return JSONResponse({"error": "unauthorized"}, status_code=401)
        try:
            body: dict[str, Any] = await request.json()
        except Exception:
            return JSONResponse({"error": "invalid JSON body"}, status_code=400)

        parsed = _parse_chat_json(body)
        if isinstance(parsed, JSONResponse):
            return parsed
        message, session_key, channel, chat_id = parsed

        text = await agent.process_direct(
            message,
            session_key=session_key,
            channel=channel,
            chat_id=chat_id,
        )
        return JSONResponse({"response": text})

    async def chat_stream(request: Request) -> JSONResponse | StreamingResponse:
        if not _check_api_key(request, api_key):
            return JSONResponse({"error": "unauthorized"}, status_code=401)
        try:
            body: dict[str, Any] = await request.json()
        except Exception:
            return JSONResponse({"error": "invalid JSON body"}, status_code=400)

        parsed = _parse_chat_json(body)
        if isinstance(parsed, JSONResponse):
            return parsed
        message, session_key, channel, chat_id = parsed

        _sentinel = object()

        async def ndjson_bytes() -> AsyncIterator[bytes]:
            queue: asyncio.Queue[object] = asyncio.Queue()

            async def on_progress(content: str, *, tool_hint: bool = False) -> None:
                if tool_hint and not send_tool_hints:
                    return
                if not tool_hint and not send_progress:
                    return
                if tool_hint:
                    payload: dict[str, Any] = {"type": "tool_hint", "text": content}
                else:
                    payload = {"type": "progress", "text": content}
                line = json.dumps(payload, ensure_ascii=False) + "\n"
                await queue.put(line.encode("utf-8"))

            async def run_agent() -> None:
                try:
                    text = await agent.process_direct(
                        message,
                        session_key=session_key,
                        channel=channel,
                        chat_id=chat_id,
                        on_progress=on_progress,
                    )
                    done_line = json.dumps(
                        {"type": "done", "response": text},
                        ensure_ascii=False,
                    ) + "\n"
                    await queue.put(done_line.encode("utf-8"))
                except Exception as e:
                    err_line = json.dumps(
                        {"type": "error", "message": str(e)},
                        ensure_ascii=False,
                    ) + "\n"
                    await queue.put(err_line.encode("utf-8"))
                finally:
                    await queue.put(_sentinel)

            task = asyncio.create_task(run_agent())
            try:
                while True:
                    item = await queue.get()
                    if item is _sentinel:
                        break
                    yield item
            finally:
                await task

        return StreamingResponse(
            ndjson_bytes(),
            media_type="application/x-ndjson",
        )

    return Starlette(
        routes=[
            Route("/health", health, methods=["GET"]),
            Route("/v1/chat", chat, methods=["POST"]),
            Route("/v1/chat/stream", chat_stream, methods=["POST"]),
        ],
    )
