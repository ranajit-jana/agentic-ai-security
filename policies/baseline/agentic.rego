package agentic.baseline

import future.keywords.if
import future.keywords.in

default allow = false

# ── Data classification ordering ──────────────────────────────────────────────

data_class_level := {
  "public":       1,
  "internal":     2,
  "confidential": 3,
  "restricted":   4,
}

# ── Agent type definitions ────────────────────────────────────────────────────

agent_allowed_tools := {
  "orchestrator-agent":       {"web_search", "query_internal_db", "generate_report", "send_email"},
  "web-search-agent":         {"web_search"},
  "internal-data-agent":      {"query_internal_db"},
  "report-generation-agent":  {"generate_report"},
  "email-agent":              {"send_email"},
}

agent_data_ceiling := {
  "orchestrator-agent":       "confidential",
  "web-search-agent":         "public",
  "internal-data-agent":      "confidential",
  "report-generation-agent":  "confidential",
  "email-agent":              "confidential",
}

# ── Human role definitions ────────────────────────────────────────────────────

human_allowed_tools := {
  "analyst": {"web_search", "query_internal_db", "generate_report"},
  "admin":   {"web_search", "query_internal_db", "generate_report", "send_email"},
  "viewer":  {"web_search"},
}

# ── Allow rules ───────────────────────────────────────────────────────────────

# Agent: tool must be in agent's allowed list and data class must not exceed ceiling
allow if {
  input.principal_type == "agent"
  tools := agent_allowed_tools[input.agent_type]
  input.tool in tools
  ceiling := agent_data_ceiling[input.agent_type]
  data_class_level[input.data_class] <= data_class_level[ceiling]
  not absolute_deny
}

# Human user: role must permit the tool
allow if {
  input.principal_type == "human"
  some role in input.user_roles
  tools := human_allowed_tools[role]
  input.tool in tools
  not absolute_deny
}

# ── Absolute deny rules (override any allow) ──────────────────────────────────

# No principal — human or agent — may delete production records
absolute_deny if {
  input.tool == "delete_record"
}

# Agents may not send email to external domains
absolute_deny if {
  input.principal_type == "agent"
  input.tool == "send_email"
  input.target_domain != "firm.internal"
}

# Unknown agent type is never allowed
absolute_deny if {
  input.principal_type == "agent"
  not agent_allowed_tools[input.agent_type]
}

# Restricted data is never accessible to agents
absolute_deny if {
  input.principal_type == "agent"
  input.data_class == "restricted"
}
