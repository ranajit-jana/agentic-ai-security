import httpx
import structlog
from app.config import settings

log = structlog.get_logger()


def _parse_agent_type(spiffe_id: str) -> str:
    """Extract agent type from SPIFFE ID path segment."""
    # spiffe://firm.internal/agent/<type>/...
    parts = spiffe_id.split("/")
    try:
        idx = parts.index("agent")
        return parts[idx + 1]
    except (ValueError, IndexError):
        return spiffe_id


async def check_baseline(agent_id: str, tool: str, data_class: str = "public") -> tuple[bool, str]:
    """Evaluate OPA baseline policy. Returns (allowed, rule_matched)."""
    agent_type = _parse_agent_type(agent_id)
    payload = {
        "input": {
            "principal_type": "agent",
            "spiffe_id": agent_id,
            "agent_type": agent_type,
            "tool": tool,
            "data_class": data_class,
        }
    }
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.post(
                f"{settings.opa_url}/v1/data/agentic/baseline/allow",
                json=payload,
            )
            resp.raise_for_status()
            result = resp.json().get("result", False)
            return bool(result), "agentic/baseline/allow"
    except Exception as exc:
        log.warning("opa_check_failed", error=str(exc))
        # Fail open only if OPA is unreachable during startup; in prod fail closed
        return False, f"opa_error: {exc}"


async def get_allowed_tools(agent_id: str, intent_tags: list[str]) -> list[str]:
    """Query OPA for the tool set this agent+intent combination is allowed to call."""
    agent_type = _parse_agent_type(agent_id)
    payload = {
        "input": {
            "agent_type": agent_type,
            "intent_tags": intent_tags,
        }
    }
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.post(
                f"{settings.opa_url}/v1/data/agentic/catalog/allowed_tools",
                json=payload,
            )
            resp.raise_for_status()
            return resp.json().get("result", [])
    except Exception as exc:
        log.warning("opa_catalog_failed", error=str(exc))
        return []
