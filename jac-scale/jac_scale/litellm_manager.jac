"""LiteLLM Proxy Manager for jac-scale.

Manages the lifecycle of a LiteLLM proxy server and exposes its admin API.

In local mode (default): spawns litellm as a subprocess using config derived
from jac.toml, health-checks it, and tears it down on server shutdown.

In K8s mode (KUBERNETES_SERVICE_HOST env var set): skips subprocess management
and connects to an externally-deployed proxy at the configured proxy_url.
"""
import logging;
import from typing { Any }
import from jac_scale.config_loader { get_scale_config }

glob logger = logging.getLogger(__name__);

"""Raised when LiteLLM proxy configuration or startup fails.

Thrown at server boot time so problems are visible immediately rather
than surfacing as obscure errors on the first LLM call.
"""
class LiteLLMConfigError(Exception) {}

"""Built-in default model list used when [[plugins.scale.litellm.models]] is absent.

Covers the providers byLLM already supports. Each model is only active at
runtime if the corresponding env var is set — LiteLLM silently skips models
whose api_key resolves to an empty string.
"""
glob LITELLM_DEFAULT_MODELS: list[dict[str, Any]] = [
    # OpenAI — OPENAI_API_KEY
    {
        'model_name': 'gpt-4o',
        'litellm_params': {'model': 'openai/gpt-4o', 'api_key': '${OPENAI_API_KEY}'}
    },
    {
        'model_name': 'gpt-4o-mini',
        'litellm_params': {'model': 'openai/gpt-4o-mini', 'api_key': '${OPENAI_API_KEY}'}
    },
    # Anthropic — ANTHROPIC_API_KEY
    {
        'model_name': 'claude-3-5-sonnet',
        'litellm_params': {
            'model': 'anthropic/claude-3-5-sonnet-20241022',
            'api_key': '${ANTHROPIC_API_KEY}'
        }
    },
    {
        'model_name': 'claude-3-5-haiku',
        'litellm_params': {
            'model': 'anthropic/claude-3-5-haiku-20241022',
            'api_key': '${ANTHROPIC_API_KEY}'
        }
    },
    # Google — GEMINI_API_KEY
    {
        'model_name': 'gemini-2.0-flash',
        'litellm_params': {
            'model': 'gemini/gemini-2.0-flash',
            'api_key': '${GEMINI_API_KEY}'
        }
    },
    # Groq — GROQ_API_KEY
    {
        'model_name': 'llama-3.3-70b',
        'litellm_params': {
            'model': 'groq/llama-3.3-70b-versatile',
            'api_key': '${GROQ_API_KEY}'
        }
    }
];

"""Manages the LiteLLM proxy server lifecycle and its admin API.

Instantiated once during JacAPIServerCore.postinit() when litellm is enabled.
The singleton is stored on the server instance and accessed by user_manager
for key lifecycle operations.
"""
obj LiteLLMProxyManager {
    has config: dict[str, Any] = {},
        proxy_url: str = "",
        _process: Any = None,
        _config_file: Any = None;

    def postinit -> None;
    def start -> None;
    def stop -> None;
    def is_healthy -> bool;
    def create_user(username: str, limits: dict[str, Any]) -> None;
    def generate_key(username: str, limits: dict[str, Any]) -> str;
    def revoke_key(key: str) -> None;
    def delete_user(username: str) -> None;

    # Internal helpers
    def _is_k8s_mode -> bool;
    def _resolve_models -> list[dict[str, Any]];
    def _build_config_yaml(models: list[dict[str, Any]]) -> str;
    def _convert_env_var_refs(value: str) -> str;
    def _admin_post(path: str, body: dict[str, Any]) -> dict[str, Any];
    def _admin_delete(path: str, body: dict[str, Any]) -> None;
    def _wait_for_health -> None;
}

glob _litellm_proxy_manager_instance: LiteLLMProxyManager | None = None;

"""Return the active LiteLLMProxyManager, or None if litellm is disabled."""
def get_litellm_proxy_manager -> LiteLLMProxyManager | None;

"""Initialize the global LiteLLMProxyManager from current jac.toml config."""
def init_litellm_proxy_manager -> LiteLLMProxyManager | None;
