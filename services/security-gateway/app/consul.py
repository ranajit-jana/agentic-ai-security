import hashlib
import json
import httpx
import structlog
from app.config import settings

log = structlog.get_logger()


async def get_tool(tool_id: str) -> dict | None:
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(
                f"{settings.consul_url}/v1/kv/tools/{tool_id}",
                params={"raw": "true"},
            )
            if resp.status_code == 404:
                return None
            resp.raise_for_status()
            return json.loads(resp.text)
    except Exception as exc:
        log.warning("consul_get_tool_failed", tool=tool_id, error=str(exc))
        return None


async def get_agent(agent_type: str) -> dict | None:
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(
                f"{settings.consul_url}/v1/kv/agents/{agent_type}",
                params={"raw": "true"},
            )
            if resp.status_code == 404:
                return None
            resp.raise_for_status()
            return json.loads(resp.text)
    except Exception as exc:
        log.warning("consul_get_agent_failed", agent=agent_type, error=str(exc))
        return None


async def list_tools() -> list[dict]:
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.get(
                f"{settings.consul_url}/v1/kv/tools/",
                params={"keys": "true"},
            )
            if resp.status_code == 404:
                return []
            resp.raise_for_status()
            keys = resp.json()
        tools = []
        for key in keys:
            tool_id = key.split("/")[-1]
            if tool_id:
                entry = await get_tool(tool_id)
                if entry:
                    entry["tool_id"] = tool_id
                    tools.append(entry)
        return tools
    except Exception as exc:
        log.warning("consul_list_tools_failed", error=str(exc))
        return []


async def set_tool_status(tool_id: str, status: str) -> None:
    try:
        entry = await get_tool(tool_id)
        if entry:
            entry["status"] = status
            async with httpx.AsyncClient(timeout=5.0) as client:
                await client.put(
                    f"{settings.consul_url}/v1/kv/tools/{tool_id}",
                    content=json.dumps(entry),
                )
    except Exception as exc:
        log.error("consul_set_tool_status_failed", tool=tool_id, error=str(exc))


async def fetch_manifest_hash(mcp_endpoint: str) -> str | None:
    """Fetch /tools/list from an MCP endpoint and return its SHA-256."""
    try:
        async with httpx.AsyncClient(timeout=10.0, verify=False) as client:
            resp = await client.get(f"{mcp_endpoint}/tools/list")
            resp.raise_for_status()
            digest = hashlib.sha256(resp.content).hexdigest()
            return f"sha256:{digest}"
    except Exception as exc:
        log.warning("manifest_fetch_failed", endpoint=mcp_endpoint, error=str(exc))
        return None
