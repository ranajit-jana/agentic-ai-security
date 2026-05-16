from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    keycloak_url: str = "http://keycloak.infra.svc.cluster.local"
    keycloak_realm: str = "firm-internal"
    sns_topic_arn: str = ""
    aws_region: str = "ap-south-1"
    log_level: str = "INFO"
    log_format: str = "json"

    class Config:
        env_file = ".env"


settings = Settings()
