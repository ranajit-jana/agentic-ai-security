import structlog
from app import gateway

log = structlog.get_logger()


async def handle(data: dict, task_id: str) -> dict:
    allowed, reason, hitl = await gateway.authorize(
        tool="generate_report", args=data, intent="generate report from data", task_id=task_id
    )
    if not allowed:
        return {"status": "denied", "reason": reason, "task_id": task_id}
    if hitl:
        return {"status": "hitl_pending", "reason": "awaiting human approval", "task_id": task_id}

    log.info("report_generate", task_id=task_id)
    return {
        "status": "ok",
        "report": f"Report generated for task {task_id}",
        "format": "markdown",
        "task_id": task_id,
    }
