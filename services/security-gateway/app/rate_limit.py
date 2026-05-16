import redis.asyncio as aioredis
import structlog
from app.config import settings

log = structlog.get_logger()

_redis: aioredis.Redis | None = None


def get_redis() -> aioredis.Redis:
    global _redis
    if _redis is None:
        _redis = aioredis.from_url(settings.redis_url, decode_responses=True)
    return _redis


async def check_rate_limit(agent_id: str, tool: str, limit: int = 10, window: int = 60) -> tuple[bool, int]:
    """
    Sliding window counter. Returns (allowed, current_count).
    Key: ratelimit:<agent_id>:<tool>
    """
    key = f"ratelimit:{agent_id}:{tool}"
    try:
        r = get_redis()
        pipe = r.pipeline()
        pipe.incr(key)
        pipe.expire(key, window)
        results = await pipe.execute()
        count = int(results[0])
        return count <= limit, count
    except Exception as exc:
        log.warning("rate_limit_check_failed", error=str(exc))
        return True, 0


async def close() -> None:
    global _redis
    if _redis:
        await _redis.aclose()
        _redis = None
