"""Background task: every 60 s, check each tool's live manifest hash
against the value stored in Consul. Set status=hash_mismatch if they differ."""
import asyncio
import structlog
from app import consul

log = structlog.get_logger()


async def _verify_once() -> None:
    tools = await consul.list_tools()
    for tool in tools:
        tool_id = tool.get("tool_id", "")
        endpoint = tool.get("mcp_endpoint", "")
        stored_hash = tool.get("manifest_hash", "")
        status = tool.get("status", "active")

        if not endpoint or status == "revoked":
            continue

        live_hash = await consul.fetch_manifest_hash(endpoint)
        if live_hash is None:
            # Can't reach endpoint — leave status as-is
            continue

        if stored_hash and live_hash != stored_hash:
            log.warning(
                "tool_hash_mismatch",
                tool=tool_id,
                stored=stored_hash,
                live=live_hash,
            )
            await consul.set_tool_status(tool_id, "hash_mismatch")
        elif status == "hash_mismatch" and live_hash == stored_hash:
            # Hash restored (e.g., rollback) — re-activate
            log.info("tool_hash_restored", tool=tool_id)
            await consul.set_tool_status(tool_id, "active")


async def run(interval: int) -> None:
    while True:
        try:
            await _verify_once()
        except Exception as exc:
            log.error("verifier_error", error=str(exc))
        await asyncio.sleep(interval)
