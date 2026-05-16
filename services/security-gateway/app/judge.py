import json
import httpx
import structlog
from app.config import settings

log = structlog.get_logger()

_JUDGE_PROMPT = """You are a security judge evaluating whether an AI agent's tool call is consistent with its declared intent.

Intent: {intent}
Agent ID: {agent_id}
Requested tool: {tool}
Tool arguments: {args}

Is this tool call consistent with the stated intent? Answer with a JSON object:
{{"consistent": true/false, "confidence": 0.0-1.0, "reason": "brief explanation"}}

Answer only with valid JSON, nothing else."""

_CATALOG_PROMPT = """You are a security classifier. Extract intent tags from this agent task description.

Task: {intent}

Return a JSON array of concise lowercase tags that describe what kind of operations this task needs.
Example tags: web_search, public_data, read_only, internal_db, write, send_email, generate_report

Answer only with a JSON array, nothing else."""


async def judge_tool_call(agent_id: str, tool: str, args: dict, intent: str) -> tuple[bool, float, str]:
    """
    Ask the local LLM judge whether this tool call matches the declared intent.
    Returns (consistent, confidence, reason).
    """
    prompt = _JUDGE_PROMPT.format(
        intent=intent or "(no intent declared)",
        agent_id=agent_id,
        tool=tool,
        args=json.dumps(args),
    )
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            resp = await client.post(
                f"{settings.ollama_url}/api/generate",
                json={
                    "model": settings.judge_model,
                    "prompt": prompt,
                    "stream": False,
                    "format": "json",
                },
            )
            resp.raise_for_status()
            raw = resp.json().get("response", "{}")
            result = json.loads(raw)
            consistent = bool(result.get("consistent", True))
            confidence = float(result.get("confidence", 0.5))
            reason = result.get("reason", "")
            return consistent, confidence, reason
    except Exception as exc:
        log.warning("judge_failed", error=str(exc))
        # Fail permissive if judge is unreachable — log and continue
        return True, 0.5, f"judge_unavailable: {exc}"


async def extract_intent_tags(intent: str) -> list[str]:
    """Use the LLM to extract structured intent tags from free-text intent."""
    prompt = _CATALOG_PROMPT.format(intent=intent)
    try:
        async with httpx.AsyncClient(timeout=20.0) as client:
            resp = await client.post(
                f"{settings.ollama_url}/api/generate",
                json={
                    "model": settings.judge_model,
                    "prompt": prompt,
                    "stream": False,
                },
            )
            resp.raise_for_status()
            raw = resp.json().get("response", "[]").strip()
            tags = json.loads(raw)
            return [str(t).lower() for t in tags if isinstance(t, str)]
    except Exception as exc:
        log.warning("intent_extraction_failed", error=str(exc))
        return []
