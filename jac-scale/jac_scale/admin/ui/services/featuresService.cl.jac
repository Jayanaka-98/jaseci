"""Features service — fetches which optional server features are active."""

cl {
    import from .api { get }

    async def:pub getFeatures(token: str) -> dict {
        return await get("/admin/features", token);
    }
}
