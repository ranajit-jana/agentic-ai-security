import asyncio
import logging
import uuid
import structlog
from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse

from app.config import settings
from app.models import AuthorizeRequest, AuthorizeResponse, CatalogRequest, CatalogResponse
from app import opa, consul, judge, rate_limit, audit, verifier

# ── Logging setup ──────────────────────────────────────────────────────────────

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


# ── Lifespan ───────────────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    task = asyncio.create_task(verifier.run(settings.verifier_interval))
    log.info("gateway_started", trust_domain=settings.trust_domain)
    yield
    task.cancel()
    await rate_limit.close()
    log.info("gateway_stopped")


app = FastAPI(title="Security Gateway", version="0.1.0", lifespan=lifespan)


# ── Health ─────────────────────────────────────────────────────────────────────

@app.get("/health")
async def health():
    return {"status": "ok", "version": "0.1.0"}


# ── Authorization ──────────────────────────────────────────────────────────────

@app.post("/authorize", response_model=AuthorizeResponse)
async def authorize(req: AuthorizeRequest, request: Request):
    trace_id = req.task_id or str(uuid.uuid4())
    logger = log.bind(trace_id=trace_id, agent_id=req.agent_id, tool=req.tool)

    # ── Step 1: Verify tool exists in registry and is active ──────────────────
    tool_entry = await consul.get_tool(req.tool)
    if not tool_entry:
        await audit.emit({
            "trace_id": trace_id, "agent_id": req.agent_id, "tool": req.tool,
            "decision": "deny", "reason": "tool_not_in_registry",
        })
        return AuthorizeResponse(allowed=False, reason="tool not registered", trace_id=trace_id)

    if tool_entry.get("status") != "active":
        await audit.emit({
            "trace_id": trace_id, "agent_id": req.agent_id, "tool": req.tool,
            "decision": "deny", "reason": f"tool_status={tool_entry.get('status')}",
        })
        return AuthorizeResponse(
            allowed=False,
            reason=f"tool status is {tool_entry.get('status')}",
            trace_id=trace_id,
        )

    # ── Step 2: OPA baseline policy check ─────────────────────────────────────
    data_class = tool_entry.get("data_classification", "public")
    allowed, rule = await opa.check_baseline(req.agent_id, req.tool, data_class)
    if not allowed:
        logger.info("baseline_deny", rule=rule)
        await audit.emit({
            "trace_id": trace_id, "agent_id": req.agent_id, "tool": req.tool,
            "decision": "deny", "reason": "opa_baseline_deny", "rule": rule,
        })
        return AuthorizeResponse(allowed=False, reason="policy denied", trace_id=trace_id)

    # ── Step 3: LLM-as-Judge (semantic intent check) ──────────────────────────
    consistent, confidence, judge_reason = await judge.judge_tool_call(
        req.agent_id, req.tool, req.args, req.intent
    )
    if not consistent and confidence >= settings.judge_confidence_threshold:
        logger.warning("judge_deny", confidence=confidence, reason=judge_reason)
        await audit.emit({
            "trace_id": trace_id, "agent_id": req.agent_id, "tool": req.tool,
            "decision": "deny", "reason": "judge_intent_mismatch",
            "judge_confidence": confidence, "judge_reason": judge_reason,
        })
        return AuthorizeResponse(allowed=False, reason=f"intent mismatch: {judge_reason}", trace_id=trace_id)

    # ── Step 4: Rate limit ────────────────────────────────────────────────────
    rate_limit_val = tool_entry.get("rate_limit", 10)
    within_limit, count = await rate_limit.check_rate_limit(req.agent_id, req.tool, limit=rate_limit_val)
    if not within_limit:
        logger.warning("rate_limit_exceeded", count=count)
        await audit.emit({
            "trace_id": trace_id, "agent_id": req.agent_id, "tool": req.tool,
            "decision": "deny", "reason": "rate_limit_exceeded", "count": count,
        })
        return AuthorizeResponse(allowed=False, reason="rate limit exceeded", trace_id=trace_id)

    # ── Step 5: Compute risk score → HITL trigger ─────────────────────────────
    blast_map = {"low": 0.2, "medium": 0.5, "high": 0.9}
    class_map = {"public": 0.1, "internal": 0.4, "confidential": 0.8, "restricted": 1.0}
    blast_score = blast_map.get(tool_entry.get("blast_radius", "low"), 0.2)
    class_score = class_map.get(data_class, 0.1)
    anomaly = 0.0 if consistent else (1.0 - confidence)
    risk_score = round((blast_score * 0.4) + (class_score * 0.4) + (anomaly * 0.2), 3)
    hitl_required = risk_score > settings.hitl_threshold

    # ── Step 6: Allow + audit ─────────────────────────────────────────────────
    logger.info("authorize_allow", risk_score=risk_score, hitl=hitl_required)
    await audit.emit({
        "trace_id": trace_id, "agent_id": req.agent_id, "tool": req.tool,
        "decision": "allow", "risk_score": risk_score, "hitl_required": hitl_required,
        "judge_confidence": confidence,
    })
    return AuthorizeResponse(
        allowed=True,
        reason="ok",
        risk_score=risk_score,
        hitl_required=hitl_required,
        trace_id=trace_id,
    )


# ── Intent-Aware Tool Catalog ─────────────────────────────────────────────────

@app.post("/catalog/tools", response_model=CatalogResponse)
async def catalog_tools(req: CatalogRequest):
    # Extract intent tags via LLM
    tags = await judge.extract_intent_tags(req.intent)
    log.info("catalog_request", agent_id=req.agent_id, tags=tags)

    # OPA query for allowed tools given agent + intent
    allowed_tool_ids = await opa.get_allowed_tools(req.agent_id, tags)

    # Cross-check with Consul registry — only return active tools
    result = []
    for tool_id in allowed_tool_ids:
        entry = await consul.get_tool(tool_id)
        if entry and entry.get("status") == "active":
            result.append({
                "name": tool_id,
                "description": entry.get("description", ""),
                "mcp_endpoint": entry.get("mcp_endpoint", ""),
                "data_classification": entry.get("data_classification", ""),
            })

    log.info("catalog_response", agent_id=req.agent_id, tool_count=len(result))
    return CatalogResponse(tools=result)
