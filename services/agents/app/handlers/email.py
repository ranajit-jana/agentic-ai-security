import structlog
from app import gateway

log = structlog.get_logger()


async def handle(to: str, subject: str, body: str, task_id: str) -> dict:
    args = {"to": to, "subject": subject, "body_length": len(body)}
    allowed, reason, hitl = await gateway.authorize(
        tool="send_email", args=args, intent=f"send email to {to}", task_id=task_id
    )
    if not allowed:
        return {"status": "denied", "reason": reason, "task_id": task_id}
    if hitl:
        return {"status": "hitl_pending", "reason": "awaiting human approval — high-risk tool", "task_id": task_id}

    log.info("email_send", to=to, subject=subject, task_id=task_id)
    return {
        "status": "ok",
        "to": to,
        "subject": subject,
        "task_id": task_id,
    }
