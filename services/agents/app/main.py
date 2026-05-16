import logging
import uuid
import structlog
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import Any

from app.config import settings
from app.handlers import orchestrator, web_search, internal_data, report_generation, email

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

app = FastAPI(title=f"Agent: {settings.agent_type}", version="0.1.0")


class TaskRequest(BaseModel):
    task: str
    task_id: str = ""
    data: dict[str, Any] = {}


@app.get("/health")
async def health():
    return {"status": "ok", "agent_type": settings.agent_type, "version": "0.1.0"}


@app.post("/task")
async def run_task(req: TaskRequest):
    task_id = req.task_id or str(uuid.uuid4())
    log.info("task_received", agent=settings.agent_type, task_id=task_id)

    agent = settings.agent_type

    if agent == "orchestrator-agent":
        result = await orchestrator.handle(task=req.task, task_id=task_id)

    elif agent == "web-search-agent":
        result = await web_search.handle(query=req.task, task_id=task_id)

    elif agent == "internal-data-agent":
        result = await internal_data.handle(query=req.task, task_id=task_id)

    elif agent == "report-generation-agent":
        result = await report_generation.handle(data=req.data, task_id=task_id)

    elif agent == "email-agent":
        result = await email.handle(
            to=req.data.get("to", ""),
            subject=req.data.get("subject", ""),
            body=req.data.get("body", ""),
            task_id=task_id,
        )

    else:
        raise HTTPException(status_code=400, detail=f"unknown agent type: {agent}")

    log.info("task_complete", agent=agent, task_id=task_id, status=result.get("status"))
    return result
