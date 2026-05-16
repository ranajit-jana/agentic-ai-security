"""Orchestrator agent: breaks user tasks into sub-tasks and delegates."""
import uuid
import anthropic
import structlog
from app.config import settings
from app import gateway

log = structlog.get_logger()

_SYSTEM = """You are a secure orchestrator agent. Your role is to:
1. Understand the user's task
2. Break it into sub-tasks mapped to available tools
3. Authorize each tool call through the security gateway before execution
4. Report results with full audit lineage

Always use the tools provided. Never fabricate results. If a tool call is denied, report the denial clearly."""


async def handle(task: str, task_id: str) -> dict:
    if not settings.anthropic_api_key:
        return {"status": "error", "result": "ANTHROPIC_API_KEY not configured", "task_id": task_id}

    # Fetch allowed tools for this intent from the gateway catalog
    tools_catalog = await gateway.get_tool_catalog(intent=task, task_scope=task_id)
    log.info("orchestrator_tools", count=len(tools_catalog), task_id=task_id)

    # Define Claude tool specs from catalog
    claude_tools = [
        {
            "name": t["name"],
            "description": t.get("description", f"Execute {t['name']}"),
            "input_schema": {"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]},
        }
        for t in tools_catalog
    ]

    client = anthropic.Anthropic(api_key=settings.anthropic_api_key)
    messages = [{"role": "user", "content": task}]
    results = []

    for _ in range(5):  # max 5 agentic rounds
        kwargs = {"model": settings.anthropic_model, "max_tokens": 2048, "system": _SYSTEM, "messages": messages}
        if claude_tools:
            kwargs["tools"] = claude_tools

        response = client.messages.create(**kwargs)

        if response.stop_reason == "end_turn":
            final = next((b.text for b in response.content if hasattr(b, "text")), "")
            return {"status": "ok", "result": final, "tool_calls": results, "task_id": task_id}

        if response.stop_reason != "tool_use":
            break

        tool_uses = [b for b in response.content if b.type == "tool_use"]
        tool_results = []

        for tu in tool_uses:
            allowed, reason, hitl = await gateway.authorize(
                tool=tu.name, args=tu.input, intent=task, task_id=task_id
            )
            if hitl:
                log.warning("hitl_required", tool=tu.name, task_id=task_id)
                tool_results.append({"type": "tool_result", "tool_use_id": tu.id,
                                     "content": "Tool call escalated for human review. Awaiting approval."})
                results.append({"tool": tu.name, "status": "hitl_pending"})
                continue

            if not allowed:
                log.warning("tool_denied", tool=tu.name, reason=reason, task_id=task_id)
                tool_results.append({"type": "tool_result", "tool_use_id": tu.id,
                                     "content": f"Tool call denied by security gateway: {reason}"})
                results.append({"tool": tu.name, "status": "denied", "reason": reason})
                continue

            # Tool authorized — in production this dispatches over mTLS to the tool's MCP endpoint
            tool_result = f"[{tu.name} executed with args: {tu.input}]"
            tool_results.append({"type": "tool_result", "tool_use_id": tu.id, "content": tool_result})
            results.append({"tool": tu.name, "status": "executed", "args": tu.input})

        messages.append({"role": "assistant", "content": response.content})
        messages.append({"role": "user", "content": tool_results})

    return {"status": "ok", "result": "Task completed", "tool_calls": results, "task_id": task_id}
