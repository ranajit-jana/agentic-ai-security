from pydantic import BaseModel
from typing import Any


class AuthorizeRequest(BaseModel):
    agent_id: str          # SPIFFE ID of the calling agent
    tool: str              # Tool being requested
    args: dict[str, Any] = {}
    intent: str = ""       # Free-text intent for this task
    task_id: str = ""      # Correlates spans across the task
    biscuit_token: str = ""  # Delegation token (optional for now)


class AuthorizeResponse(BaseModel):
    allowed: bool
    reason: str
    risk_score: float = 0.0
    hitl_required: bool = False
    trace_id: str = ""


class CatalogRequest(BaseModel):
    agent_id: str
    intent: str
    task_scope: str = ""


class CatalogResponse(BaseModel):
    tools: list[dict[str, Any]]
