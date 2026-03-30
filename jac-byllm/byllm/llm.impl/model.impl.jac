"""Post-initialization hook for Model.

Sets up proxy mode and mock delegation based on config.
Configures logging when using real LLM backends.
"""
impl Model.postinit -> None {
    # Check instance config first, then fall back to global config
    self.proxy = bool(self.config.get("proxy", _model_config.get("proxy", False)));
    self.http_client = bool(
        self.config.get("http_client", _model_config.get("http_client", False))
    );
    # Resolve api_key: constructor > instance config > global config > env vars (litellm fallback)
    self.api_key = (
        self.api_key
        or self.config.get("api_key", "")
        or _model_config.get("api_key", "")
    );
    # When model_name is 'mockllm', delegate to MockLLM behavior
    if self.model_name == MODEL_MOCK {
        self._mock_delegate = MockLLM(model_name=self.model_name, config=self.config);
    }
    if not self._mock_delegate {
        logging.getLogger("httpx").setLevel(logging.WARNING);
        if not _litellm_config.get("debug", False) {
            _disable_debugging();
        }
        litellm.drop_params = _litellm_config.get("drop_params", True);
    }
}

"""Invoke the LLM, delegating to MockLLM if applicable.

Wraps the full invocation with telemetry. Sets a unique invocation_id
on mt_run, then delegates all telemetry extraction to _emit_agent_telemetry.
"""
impl Model.invoke(mt_run: MTRuntime) -> object {
    import uuid;
    import time;

    mt_run._invocation_id = str(uuid.uuid4());
    _start = time.time();

    try {
        result = self._mock_delegate.invoke(mt_run)
            if self._mock_delegate
            else super.invoke(mt_run);

        _emit_agent_telemetry(
            mt_run,
            result,
            self.model_name,
            (time.time() - _start) * 1000,
            "success",
            None
        );
        return result;
    } except Exception as e {
        _emit_agent_telemetry(
            mt_run, None, self.model_name, (time.time() - _start) * 1000, "error", e
        );
        raise;
    }
}

"""Resolve the effective proxy URL and per-user API key.

Returns (proxy_url, user_key) when the proxy is active, (None, None) otherwise.
Raises LiteLLMAccessError if the proxy is configured but no user key is present
(unauthenticated walker attempting an LLM call).
"""
def _resolve_proxy_params -> tuple[str | None, str | None] {
    import from byllm.exceptions { LiteLLMAccessError }
    proxy_url = (
        _model_config.get("base_url", "")
        or _model_config.get("proxy_base_url", "")
    );
    if not proxy_url {
        return (None, None);
    }
    # Proxy is active — read the per-user key from the execution contextvar
    try {
        import from jaclang.jac0core.runtime { JacRuntime }
        ctx = JacRuntime.get_context();
        user_llm_key_cv = getattr(ctx, 'user_llm_key', None);
        user_key = user_llm_key_cv.get() if user_llm_key_cv is not None else None;
    } except Exception {
        user_key = None;
    }
    if user_key is None {
        raise LiteLLMAccessError(
            message="LLM access requires authentication. "
                    "Walkers must be invoked with a valid user token."
        );
    }
    return (proxy_url, user_key);
}

"""Map an HTTP status code from a proxy error to a typed byLLM exception."""
def _raise_proxy_error(status_code: int, model: str, raw: str) -> None {
    import from byllm.exceptions { LiteLLMAccessError }
    if status_code == 401 {
        raise LiteLLMAccessError(
            message="LLM access denied. User API key is invalid or revoked."
        );
    } elif status_code == 402 {
        raise LiteLLMAccessError(message="LLM budget exceeded for current user.");
    } elif status_code == 404 {
        raise LiteLLMAccessError(
            message=f"Model '{model}' not found in LiteLLM proxy. "
                    f"Ensure it is listed in [[plugins.scale.litellm.models]] in jac.toml."
        );
    } elif status_code == 429 {
        raise LiteLLMAccessError(
            message="LLM rate limit exceeded for current user. Try again later."
        );
    }
    # Unknown proxy error — preserve original message
    raise LiteLLMAccessError(message=f"LiteLLM proxy error {status_code}: {raw}");
}

"""Make a direct model call without streaming.

When a proxy_base_url is configured:
  - reads the per-user virtual key from the execution contextvar
  - routes the call through the LiteLLM proxy (OpenAI-compatible API)
  - raises LiteLLMAccessError for 401/402/404/429 responses — never falls back

When no proxy is configured: uses litellm directly (existing behaviour).
If http_client is set: uses direct HTTP (existing behaviour, proxy is ignored).
"""
impl Model.model_call_no_stream(params: dict) -> dict {
    import from byllm.exceptions { LiteLLMAccessError }
    using_proxy = False;
    try {
        if self.http_client {
            response = self.model_call_http(
                url=self.api_base,
                token=self.api_key,
                payload=params,
                ca_bundle=self.config.get("ca_bundle", None),
            );
        } else {
            (proxy_url, user_key) = _resolve_proxy_params();
            if proxy_url is not None {
                using_proxy = True;
                client = OpenAI(base_url=proxy_url, api_key=user_key);
                response = client.chat.completions.create(**params);
            } else {
                response = litellm.completion(api_key=self.api_key or None, **params);
            }
        }
    } except LiteLLMAccessError {
        raise;
    } except litellm.exceptions.AuthenticationError as e {
        logger.error(f"LLM AuthenticationError: {e}");
        raise AuthenticationError(str(e));
    } except litellm.exceptions.RateLimitError as e {
        logger.error(f"LLM RateLimitError: {e}");
        raise RateLimitError(str(e));
    } except litellm.exceptions.NotFoundError as e {
        logger.error(f"LLM ModelNotFoundError: {e}");
        raise ModelNotFoundError(str(e));
    } except openai.AuthenticationError as e {
        logger.error(f"LLM AuthenticationError: {e}");
        raise AuthenticationError(str(e));
    } except openai.RateLimitError as e {
        logger.error(f"LLM RateLimitError: {e}");
        raise RateLimitError(str(e));
    } except openai.NotFoundError as e {
        logger.error(f"LLM ModelNotFoundError: {e}");
        raise ModelNotFoundError(str(e));
    } except openai.APIStatusError as e {
        if using_proxy and e.status_code in (401, 402, 404, 429) {
            _raise_proxy_error(e.status_code, params.get('model', ''), str(e));
        }
        raise;
    } except Exception as e {
        logger.error(f"LLM call failed with {type(e).__name__}: {e}");
        raise;
    }
    return response;
}

"""Make a direct model call with streaming.

Same proxy routing logic as model_call_no_stream — reads per-user key from
contextvar when proxy_base_url is configured, raises LiteLLMAccessError on
auth/rate/budget/model errors. Never falls back to direct provider when proxy
is active.
"""
impl Model.model_call_with_stream(params: dict) {
    import from byllm.exceptions { LiteLLMAccessError }
    using_proxy = False;
    try {
        (proxy_url, user_key) = _resolve_proxy_params();
        if proxy_url is not None {
            using_proxy = True;
            client = OpenAI(base_url=proxy_url, api_key=user_key);
            response = client.chat.completions.create(stream=True, **params);
        } else {
            response = litellm.completion(
                stream=True, api_key=self.api_key or None, **params
            );
        }
    } except LiteLLMAccessError {
        raise;
    } except litellm.exceptions.AuthenticationError as e {
        raise AuthenticationError(str(e));
    } except litellm.exceptions.RateLimitError as e {
        raise RateLimitError(str(e));
    } except litellm.exceptions.NotFoundError as e {
        raise ModelNotFoundError(str(e));
    } except openai.AuthenticationError as e {
        raise AuthenticationError(str(e));
    } except openai.RateLimitError as e {
        raise RateLimitError(str(e));
    } except openai.NotFoundError as e {
        raise ModelNotFoundError(str(e));
    } except openai.APIStatusError as e {
        if using_proxy and e.status_code in (401, 402, 404, 429) {
            _raise_proxy_error(e.status_code, params.get('model', ''), str(e));
        }
        raise;
    }
    return response;
}

"""Make a direct HTTP request to LLM endpoint.

Useful for custom endpoints with specific SSL/mTLS requirements.
"""
impl Model.model_call_http(
    url: str, token: str, payload: dict, ca_bundle: str
) -> object {
    import requests;
    headers = {"Content-Type": "application/json", "Authorization": f"Bearer {token}"};
    response = requests.post(
        url=url, headers=headers, json=payload, timeout=60, verify=ca_bundle or True,
    );
    return response.json();
}
