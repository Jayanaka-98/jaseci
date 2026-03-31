"""Health status service."""

cl {
    import from .api { get }

    async def:pub getHealthStatus(token: str) -> dict {
        return await get("/admin/health", token);
    }
}
