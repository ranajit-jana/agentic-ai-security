import logging
import structlog
import boto3
import httpx
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from app.config import settings

logging.basicConfig(level=settings.log_level)
structlog.configure(
    processors=[
        structlog.stdlib.add_log_level,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.JSONRenderer() if settings.log_format == "json"
        else structlog.dev.ConsoleRenderer(),
    ],
    wrapper_class=structlog.BoundLogger,
    logger_factory=structlog.PrintLoggerFactory(),
)
log = structlog.get_logger()

app = FastAPI(title="CIBA Authentication Channel Provider", version="0.1.0")


class NotifyRequest(BaseModel):
    user: str
    auth_req_id: str
    binding_message: str
    preferred_channel: str = "sms"  # sms | duo


class NotifyResponse(BaseModel):
    status: str
    channel: str


@app.get("/health")
async def health():
    return {"status": "ok", "version": "0.1.0"}


@app.post("/notify", response_model=NotifyResponse)
async def notify(req: NotifyRequest):
    log.info("ciba_notify", user=req.user, auth_req_id=req.auth_req_id, channel=req.preferred_channel)

    approval_url = (
        f"{settings.keycloak_url}/realms/{settings.keycloak_realm}"
        f"/login-actions/authenticate?auth_req_id={req.auth_req_id}"
    )

    if req.preferred_channel == "sms" and settings.sns_topic_arn:
        message = (
            f"Agent action requires your approval.\n"
            f"Action: {req.binding_message}\n"
            f"Approve: {approval_url}"
        )
        try:
            sns = boto3.client("sns", region_name=settings.aws_region)
            # Resolve user's phone number from Keycloak
            phone = await _get_user_phone(req.user)
            if phone:
                sns.publish(PhoneNumber=phone, Message=message)
                log.info("sms_sent", user=req.user)
                return NotifyResponse(status="sent", channel="sms")
        except Exception as exc:
            log.warning("sms_failed", error=str(exc))

    # Fallback: publish to SNS topic for downstream routing
    if settings.sns_topic_arn:
        try:
            sns = boto3.client("sns", region_name=settings.aws_region)
            sns.publish(
                TopicArn=settings.sns_topic_arn,
                Message=f"CIBA approval needed for {req.user}: {req.binding_message}",
                Subject="Agent Approval Required",
                MessageAttributes={
                    "auth_req_id": {"DataType": "String", "StringValue": req.auth_req_id},
                    "user": {"DataType": "String", "StringValue": req.user},
                    "approval_url": {"DataType": "String", "StringValue": approval_url},
                },
            )
            log.info("sns_topic_published", user=req.user)
            return NotifyResponse(status="sent", channel="sns_topic")
        except Exception as exc:
            log.error("sns_topic_failed", error=str(exc))
            raise HTTPException(status_code=502, detail=f"notification failed: {exc}")

    log.warning("no_channel_configured", user=req.user)
    return NotifyResponse(status="no_channel", channel="none")


async def _get_user_phone(username: str) -> str | None:
    """Fetch the user's phone number from Keycloak admin API."""
    try:
        # Get admin token
        async with httpx.AsyncClient(timeout=5.0) as client:
            token_resp = await client.post(
                f"{settings.keycloak_url}/realms/master/protocol/openid-connect/token",
                data={
                    "client_id": "admin-cli",
                    "grant_type": "client_credentials",
                },
            )
            if token_resp.status_code != 200:
                return None
            token = token_resp.json().get("access_token")

            users_resp = await client.get(
                f"{settings.keycloak_url}/admin/realms/{settings.keycloak_realm}/users",
                params={"username": username, "exact": "true"},
                headers={"Authorization": f"Bearer {token}"},
            )
            users = users_resp.json()
            if users:
                attrs = users[0].get("attributes", {})
                phones = attrs.get("phoneNumber", [])
                return phones[0] if phones else None
    except Exception:
        return None
