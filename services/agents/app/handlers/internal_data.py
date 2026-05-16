import structlog
from app import gateway

log = structlog.get_logger()


async def handle(query: str, task_id: str) -> dict:
    allowed, reason, hitl = await gateway.authorize(
        tool="query_internal_db", args={"query": query}, intent=query, task_id=task_id
    )
    if not allowed:
        return {"status": "denied", "reason": reason, "task_id": task_id}
    if hitl:
        return {"status": "hitl_pending", "reason": "awaiting human approval", "task_id": task_id}

    log.info("internal_data_query", query=query, task_id=task_id)
    return {
        "status": "ok",
        "query": query,
        "rows": [],
        "task_id": task_id,
    }
