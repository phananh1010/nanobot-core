"""Minimal HTTP API for curl/script access to the agent (gateway only)."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
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


def create_http_app(agent: AgentLoop, *, api_key: str | None = None) -> Starlette:
    """ASGI app: POST /v1/chat with JSON body ``{\"message\": \"...\"}``."""

    async def health(_: Request) -> JSONResponse:
        return JSONResponse({"status": "ok"})

    async def chat(request: Request) -> JSONResponse:
        if not _check_api_key(request, api_key):
            return JSONResponse({"error": "unauthorized"}, status_code=401)
        try:
            body: dict[str, Any] = await request.json()
        except Exception:
            return JSONResponse({"error": "invalid JSON body"}, status_code=400)

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

        text = await agent.process_direct(
            message.strip(),
            session_key=session_key,
            channel=channel,
            chat_id=chat_id,
        )
        return JSONResponse({"response": text})

    return Starlette(
        routes=[
            Route("/health", health, methods=["GET"]),
            Route("/v1/chat", chat, methods=["POST"]),
        ],
    )
