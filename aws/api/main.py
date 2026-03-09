import os
import httpx
from typing import Optional, AsyncIterator
from fastapi import FastAPI, HTTPException, Header, Request
from fastapi.responses import StreamingResponse, JSONResponse
from pydantic import BaseModel
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="LLM API Gateway", version="1.0.0")

LLAMA_URL = os.environ["LLAMA_SERVER_URL"]      # set via K8s secret
API_KEY   = os.environ.get("API_KEY", "")       # empty = auth disabled
MODEL_ID  = os.environ.get("MODEL_ID", "qwen2.5-7b-instruct")

# ── Models ────────────────────────────────────────────────────────────────────

class Message(BaseModel):
    role: str
    content: str

class ChatRequest(BaseModel):
    model: Optional[str] = MODEL_ID
    messages: list[Message]
    temperature: Optional[float] = 0.7
    top_p: Optional[float] = 0.9
    max_tokens: Optional[int] = 1024
    stream: Optional[bool] = False
    stop: Optional[list[str]] = None

class CompletionRequest(BaseModel):
    model: Optional[str] = MODEL_ID
    prompt: str
    temperature: Optional[float] = 0.7
    max_tokens: Optional[int] = 512
    stream: Optional[bool] = False

# ── Auth ──────────────────────────────────────────────────────────────────────

def verify(authorization: Optional[str]):
    if not API_KEY:
        return
    if not authorization:
        raise HTTPException(status_code=401, detail="Authorization header missing")
    token = authorization.removeprefix("Bearer ").strip()
    if token != API_KEY:
        raise HTTPException(status_code=403, detail="Invalid API key")

# ── Streaming ─────────────────────────────────────────────────────────────────

async def stream_upstream(url: str, payload: dict) -> AsyncIterator[bytes]:
    async with httpx.AsyncClient(timeout=httpx.Timeout(300.0)) as client:
        async with client.stream("POST", url, json=payload) as r:
            if r.status_code != 200:
                body = await r.aread()
                raise HTTPException(status_code=r.status_code, detail=body.decode())
            async for chunk in r.aiter_bytes():
                yield chunk

# ── Routes ────────────────────────────────────────────────────────────────────

@app.get("/health")
async def health():
    """
    Checks both API layer health and upstream llama-server health.
    K8s readiness/liveness probes hit this endpoint.
    Returns 503 if llama-server is unreachable.
    """
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            r = await client.get(f"{LLAMA_URL}/health")
            upstream = r.json()
            if r.status_code != 200:
                raise HTTPException(status_code=503, detail="Upstream unhealthy")
    except httpx.ConnectError as e:
        logger.error(f"Cannot reach llama-server: {e}")
        raise HTTPException(status_code=503, detail=f"llama-server unreachable: {e}")
    except httpx.TimeoutException:
        raise HTTPException(status_code=503, detail="llama-server timeout")
    return {"status": "ok", "upstream": upstream}

@app.get("/v1/models")
async def list_models(authorization: Optional[str] = Header(default=None)):
    verify(authorization)
    return {
        "object": "list",
        "data": [{"id": MODEL_ID, "object": "model", "owned_by": "local"}]
    }

@app.post("/v1/chat/completions")
async def chat_completions(
    req: ChatRequest,
    authorization: Optional[str] = Header(default=None)
):
    verify(authorization)
    logger.info(f"Chat request: model={req.model} stream={req.stream} msgs={len(req.messages)}")

    payload = {
        "messages": [m.model_dump() for m in req.messages],
        "temperature": req.temperature,
        "top_p": req.top_p,
        "max_tokens": req.max_tokens,
        "stream": req.stream,
    }
    if req.stop:
        payload["stop"] = req.stop

    if req.stream:
        return StreamingResponse(
            stream_upstream(f"{LLAMA_URL}/v1/chat/completions", payload),
            media_type="text/event-stream"
        )

    async with httpx.AsyncClient(timeout=httpx.Timeout(300.0)) as client:
        r = await client.post(f"{LLAMA_URL}/v1/chat/completions", json=payload)
        if r.status_code != 200:
            logger.error(f"Upstream error {r.status_code}: {r.text}")
            raise HTTPException(status_code=r.status_code, detail=r.text)
        return r.json()

@app.post("/v1/completions")
async def completions(
    req: CompletionRequest,
    authorization: Optional[str] = Header(default=None)
):
    verify(authorization)

    payload = {
        "prompt": req.prompt,
        "temperature": req.temperature,
        "max_tokens": req.max_tokens,
        "stream": req.stream,
    }

    if req.stream:
        return StreamingResponse(
            stream_upstream(f"{LLAMA_URL}/v1/completions", payload),
            media_type="text/event-stream"
        )

    async with httpx.AsyncClient(timeout=httpx.Timeout(300.0)) as client:
        r = await client.post(f"{LLAMA_URL}/v1/completions", json=payload)
        if r.status_code != 200:
            raise HTTPException(status_code=r.status_code, detail=r.text)
        return r.json()
