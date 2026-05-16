from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    agent_type: str = "orchestrator-agent"
    spire_socket: str = "/run/spire/sockets/agent.sock"
    gateway_url: str = "http://security-gateway.infra.svc.cluster.local:8080"
    anthropic_model: str = "claude-sonnet-4-6"
    anthropic_api_key: str = ""
    otel_exporter_otlp_endpoint: str = "http://otel-collector.observability.svc.cluster.local:4317"
    otel_service_namespace: str = "agents"
    trust_domain: str = "firm.internal"
    log_format: str = "json"
    log_level: str = "INFO"

    class Config:
        env_file = ".env"


settings = Settings()
