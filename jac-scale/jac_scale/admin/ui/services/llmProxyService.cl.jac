"""LLM Proxy management service — wraps /admin/llm/proxy/* endpoints."""

cl {
    import from .api { get, post, delBody }

    async def:pub getLLMProxyKeys(token: str) -> dict {
        return await get("/admin/llm/proxy/keys", token);
    }

    async def:pub createLLMProxyKey(token: str, body: dict) -> dict {
        return await post("/admin/llm/proxy/keys", body, token);
    }

    async def:pub revokeLLMProxyKey(token: str, key: str) -> dict {
        return await delBody("/admin/llm/proxy/keys", {"key": key}, token);
    }

    async def:pub getLLMProxyUsers(token: str) -> dict {
        return await get("/admin/llm/proxy/users", token);
    }

    async def:pub updateLLMProxyUser(token: str, body: dict) -> dict {
        return await post("/admin/llm/proxy/users", body, token);
    }

    async def:pub getLLMProxySpend(token: str) -> dict {
        return await get("/admin/llm/proxy/spend", token);
    }

    async def:pub setLLMProviderKey(token: str, provider: str, value: str) -> dict {
        return await post(
            "/admin/llm/proxy/providers", {"provider": provider, "value": value}, token
        );
    }
}
