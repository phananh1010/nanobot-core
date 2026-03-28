This project contain the core only logic of nanobot framework.
The project aims to provide a universal, flexible agentic logic where tools and mcp can be defined,

The agentic loop core logic should be tool agnostic, but maintain these properties:
+ Tool flexibility: any tools or mcp can be defined, the model
+ Context engineering with context agnostic: even thought perming context engineer, the framwork should adapt to different system of context.
+ input flexibility: Should not relied on a fixed number of channels, but the input query should be in raw text based format, so that it can be used in any system.

## HTTP API (curl and scripts)

Start the gateway so the agent listens for HTTP requests:

```bash
python -m nanobot gateway
# optional: --port 18790 --workspace /path/to/workspace --config /path/to/config.json
```

Default bind is `0.0.0.0` and port **18790** (see `gateway.host`, `gateway.port`, and optional `gateway.http_api_key` in your config).

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/health` | Liveness: returns `{"status":"ok"}` |
| `POST` | `/v1/chat` | Send a user message; returns `{"response":"..."}` when the run finishes |
| `POST` | `/v1/chat/stream` | Same JSON body as `/v1/chat`; response is **NDJSON** (`application/x-ndjson`): optional `progress` / `tool_hint` lines, then a final `done` or `error` line |

### Request body (`POST /v1/chat` and `POST /v1/chat/stream`)

JSON object:

- **`message`** or **`content`** (string, required): the user text sent to the agent.
- **`session`** (string, optional): session key for conversation continuity. If omitted or empty, the server uses `http:default`. If the value has no `:` (e.g. `my-chat`), it is normalized to `http:my-chat`. Keys with a colon (e.g. `cli:direct`) are used as-is.

### Authentication (optional)

If `gateway.http_api_key` is set in config, every `POST` to `/v1/chat` or `/v1/chat/stream` must include the same secret in either header:

- `Authorization: Bearer <your-key>`, or
- `X-API-Key: <your-key>`

### Examples

Health check:

```bash
curl -s http://127.0.0.1:18790/health
```

Chat (minimal):

```bash
curl -s http://127.0.0.1:18790/v1/chat \
  -H 'Content-Type: application/json' \
  -d '{"message":"Hello"}'
```

Streaming (NDJSON; use `-N` so chunks print as they arrive):

```bash
curl -N -s http://127.0.0.1:18790/v1/chat/stream \
  -H 'Content-Type: application/json' \
  -d '{"message":"Hello"}'
```

Each line is a JSON object: `{"type":"progress","text":"..."}`, optional `{"type":"tool_hint","text":"..."}`, then `{"type":"done","response":"..."}`. Progress and tool hints follow `channels.sendProgress` and `channels.sendToolHints` in your config.

Chat with a named session:

```bash
curl -s http://127.0.0.1:18790/v1/chat \
  -H 'Content-Type: application/json' \
  -d '{"message":"Remember my name is Ada","session":"http:ada"}'
```

With API key:

```bash
curl -s http://127.0.0.1:18790/v1/chat \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_KEY' \
  -d '{"message":"Hi"}'
```

Any HTTP client that can send `POST` with `Content-Type: application/json` and read JSON (e.g. `fetch`, `httpx`, `requests`) can use the same URL, headers, and body shape as above.


