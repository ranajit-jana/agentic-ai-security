from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    opa_url: str = "http://opa.infra.svc.cluster.local:8181"
    consul_url: str = "http://consul-server.infra.svc.cluster.local:8500"
    redis_url: str = "redis://redis-master.infra.svc.cluster.local:6379"
    ollama_url: str = "http://ollama.agents.svc.cluster.local:11434"
    audit_loki_url: str = "http://loki.observability.svc.cluster.local:3100"
    judge_model: str = "llama3.1:8b"
    judge_confidence_threshold: float = 0.7
    trust_domain: str = "firm.internal"
    log_format: str = "json"
    log_level: str = "INFO"
    # Verifier interval in seconds
    verifier_interval: int = 60
    # Risk score threshold for HITL escalation
    hitl_threshold: float = 0.75

    class Config:
        env_file = ".env"


settings = Settings()
