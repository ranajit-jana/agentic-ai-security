import json
import time
import httpx
import structlog
from app.config import settings

log = structlog.get_logger()


async def emit(event: dict) -> None:
    """Ship a structured audit event to Loki via the push API."""
    ts_ns = str(int(time.time() * 1_000_000_000))
    payload = {
        "streams": [
            {
                "stream": {
                    "app": "security-gateway",
                    "agent_id": event.get("agent_id", ""),
                    "tool": event.get("tool", ""),
                    "decision": event.get("decision", ""),
                },
                "values": [[ts_ns, json.dumps(event)]],
            }
        ]
    }
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.post(
                f"{settings.audit_loki_url}/loki/api/v1/push",
                json=payload,
            )
            resp.raise_for_status()
    except Exception as exc:
        # Audit failures must not block tool calls; log locally and continue
        log.error("audit_emit_failed", error=str(exc), event=event)
