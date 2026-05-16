"""Client for the security gateway authorization endpoint."""
import httpx
import structlog
from app.config import settings

log = structlog.get_logger()


async def authorize(tool: str, args: dict, intent: str, task_id: str) -> tuple[bool, str, bool]:
    """
    Ask the gateway to authorize a tool call.
    Returns (allowed, reason, hitl_required).
    """
    payload = {
        "agent_id": f"spiffe://{settings.trust_domain}/agent/{settings.agent_type}",
        "tool": tool,
        "args": args,
        "intent": intent,
        "task_id": task_id,
    }
    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            resp = await client.post(f"{settings.gateway_url}/authorize", json=payload)
            resp.raise_for_status()
            data = resp.json()
            return data["allowed"], data.get("reason", ""), data.get("hitl_required", False)
    except Exception as exc:
        log.error("gateway_authorize_failed", tool=tool, error=str(exc))
        return False, f"gateway_error: {exc}", False


async def get_tool_catalog(intent: str, task_scope: str) -> list[dict]:
    """Fetch the intent-filtered tool catalog from the gateway."""
    payload = {
        "agent_id": f"spiffe://{settings.trust_domain}/agent/{settings.agent_type}",
        "intent": intent,
        "task_scope": task_scope,
    }
    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            resp = await client.post(f"{settings.gateway_url}/catalog/tools", json=payload)
            resp.raise_for_status()
            return resp.json().get("tools", [])
    except Exception as exc:
        log.warning("catalog_fetch_failed", error=str(exc))
        return []
