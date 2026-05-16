import uuid
import httpx
import structlog
from app import gateway

log = structlog.get_logger()


async def handle(query: str, task_id: str) -> dict:
    allowed, reason, hitl = await gateway.authorize(
        tool="web_search", args={"query": query}, intent=query, task_id=task_id
    )
    if not allowed:
        return {"status": "denied", "reason": reason, "task_id": task_id}
    if hitl:
        return {"status": "hitl_pending", "reason": "awaiting human approval", "task_id": task_id}

    # In production: dispatch to the registered MCP web_search tool endpoint
    log.info("web_search_execute", query=query, task_id=task_id)
    return {
        "status": "ok",
        "query": query,
        "results": [{"title": f"Result for: {query}", "url": "https://example.com", "snippet": "..."}],
        "task_id": task_id,
    }
