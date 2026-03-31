"""Implementation of LiteLLMProxyManager.

Handles:
- Local mode: generates litellm config.yaml from jac.toml, spawns subprocess,
  health-checks it, and tears down on shutdown.
- K8s mode: skips subprocess; connects to externally-managed proxy at proxy_url.
- Admin API wrappers: /user/new, /key/generate, /key/delete, /user/delete.
- Config YAML generation with ${VAR} -> os.environ/VAR conversion so plaintext
  secrets never land in config files.

Note: requests is imported inline inside methods to avoid httpx/requests module-level
import issues with the Jac type checker.
"""
import os;
import re;
import time;
import yaml;
import tempfile;
import subprocess;
import logging;
import from typing { Any }

glob logger = logging.getLogger(__name__);

# ─────────────────────────────────────────────────────────────────────────────
# postinit
# ─────────────────────────────────────────────────────────────────────────────

"""Initialize proxy_url from config.

If config was not passed directly (e.g. called via init_litellm_proxy_manager),
loads from jac.toml via get_scale_config(). Tests can pass config directly to
bypass the config loader.
"""
impl LiteLLMProxyManager.postinit -> None {
    if not self.config {
        ll_config = get_scale_config().get_litellm_config();
        self.config = ll_config;
    }
    self.proxy_url = self.config.get('proxy_url', 'http://localhost:4000');
}

# ─────────────────────────────────────────────────────────────────────────────
# Lifecycle
# ─────────────────────────────────────────────────────────────────────────────

"""Start the LiteLLM proxy.

In K8s mode: validate proxy_url is set and reachable.
In local mode: generate config.yaml, spawn subprocess, wait for health.
Raises LiteLLMConfigError on any startup failure.
"""
impl LiteLLMProxyManager.start -> None {
    if not self.config.get('enabled', False) {
        return;
    }
    master_key = self.config.get('master_key', '');
    if not master_key {
        master_key = self._load_or_generate_master_key();
        self.config['master_key'] = master_key;
    }
    if self._is_k8s_mode() {
        if not self.config.get('proxy_url', '') {
            raise LiteLLMConfigError(
                "plugins.scale.litellm.proxy_url is required in K8s mode. "
                "Set it in jac.toml or via the LITELLM_PROXY_URL environment variable."
            );
        }
        logger.info(f"LiteLLM proxy (K8s mode): {self.proxy_url}");
        # K8s pods take longer to start — use a generous timeout (default 120s).
        # Configurable via plugins.scale.litellm.k8s_startup_timeout in jac.toml.
        timeout_secs = self.config.get('k8s_startup_timeout', 120);
        interval = 5;
        retries = timeout_secs // interval;
        for attempt in range(retries) {
            if self.is_healthy() {
                logger.info(f"LiteLLM proxy ready at {self.proxy_url}");
                return;
            }
            logger.debug(
                f"Waiting for LiteLLM proxy (K8s)... ({attempt + 1}/{retries})"
            );
            time.sleep(interval);
        }
        raise LiteLLMConfigError(
            f"LiteLLM proxy did not become healthy after {timeout_secs}s "
            f"at {self.proxy_url}/health. "
            "Check that the litellm pod is running: kubectl get pods -n <namespace>"
        );
    }
    # Local mode: spawn subprocess
    try {
        import litellm as _check;
    } except ImportError {
        raise LiteLLMConfigError(
            "litellm package is not installed. Run: pip install 'litellm[proxy]'"
        );
    }
    models = self._resolve_models();
    config_yaml = self._build_config_yaml(models);
    tmp = tempfile.NamedTemporaryFile(
        mode='w', suffix='.yaml', prefix='litellm_config_', delete=False
    );
    tmp.write(config_yaml);
    tmp.flush();
    self._config_file = tmp;
    port = self.config.get('port', 4000);
    cmd = [
        'litellm',
        '--config', tmp.name,
        '--port', str(port)
    ];
    logger.info(f"Starting LiteLLM proxy on port {port} ...");
    proc_env = os.environ.copy();
    proc_env['LITELLM_MASTER_KEY'] = master_key;
    # Configure a local SQLite database for key/user management so that
    # /key/generate and /user/new work without an external Postgres instance.
    # Only set DATABASE_URL if not already provided by the environment.
    self._process = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=proc_env,
        text=True
    );
    self._wait_for_startup_signal();
    logger.info(f"LiteLLM proxy ready at {self.proxy_url}");
}

"""Stop the LiteLLM subprocess (no-op in K8s mode or if not started)."""
impl LiteLLMProxyManager.stop -> None {
    if self._process is not None {
        logger.info("Stopping LiteLLM proxy subprocess...");
        self._process.terminate();
        try {
            self._process.wait(timeout=10);
        } except subprocess.TimeoutExpired {
            self._process.kill();
        }
        self._process = None;
    }
    if self._config_file is not None {
        try {
            os.unlink(self._config_file.name);
        } except Exception {
            # Best-effort cleanup
        }
        self._config_file = None;
    }
}

"""Return True if the proxy /health endpoint responds with 200 or 401.

401 means the proxy is up and enforcing auth — that's healthy.
We use /health/liveliness which doesn't require a key in some litellm versions,
but fall back to /health with the master key header either way.
"""
impl LiteLLMProxyManager.is_healthy -> bool {
    import requests;
    master_key = self.config.get('master_key', '');
    headers = {'Authorization': f"Bearer {master_key}"} if master_key else {};
    try {
        # /health/liveliness just checks if the server process is alive — no model
        # validation. /health validates every configured model and returns 500 if
        # any API keys are missing, which gives a false "unhealthy" signal.
        resp = requests.get(
            f"{self.proxy_url}/health/liveliness", headers=headers, timeout=5.0
        );
        return resp.status_code in (200, 401);
    } except Exception {
        return False;
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Admin API
# ─────────────────────────────────────────────────────────────────────────────

"""Register a user on LiteLLM proxy (POST /user/new)."""
impl LiteLLMProxyManager.create_user(
    username: str, limits: dict[str, Any]
) -> None {
    defaults = self.config.get('defaults', {});
    body: dict[str, Any] = {'user_id': username};
    max_budget = limits.get('max_budget') or defaults.get('max_budget');
    if max_budget is not None {
        body['max_budget'] = float(max_budget);
    }
    budget_duration = (
        limits.get('budget_duration') or defaults.get('budget_duration', '30d')
    );
    body['budget_duration'] = budget_duration;
    self._admin_post('/user/new', body);
}

"""Generate a virtual API key for a user (POST /key/generate).

Returns the 'sk-...' string to store on the user record.
"""
impl LiteLLMProxyManager.generate_key(
    username: str, limits: dict[str, Any]
) -> str {
    defaults = self.config.get('defaults', {});
    body: dict[str, Any] = {'user_id': username};
    rpm_limit = limits.get('rpm_limit') or defaults.get('rpm_limit');
    if rpm_limit is not None {
        body['rpm_limit'] = int(rpm_limit);
    }
    tpm_limit = limits.get('tpm_limit') or defaults.get('tpm_limit');
    if tpm_limit is not None {
        body['tpm_limit'] = int(tpm_limit);
    }
    allowed_models = limits.get('models') or defaults.get('models', []);
    if allowed_models {
        body['models'] = allowed_models;
    }
    result = self._admin_post('/key/generate', body);
    key = result.get('key');
    if not key {
        raise LiteLLMConfigError(
            f"LiteLLM /key/generate response missing 'key' field for user '{username}'. "
            f"Response: {result}"
        );
    }
    return key;
}

"""Revoke a virtual API key (DELETE /key/delete)."""
impl LiteLLMProxyManager.revoke_key(key: str) -> None {
    self._admin_delete('/key/delete', {'keys': [key]});
}

"""Delete a user from LiteLLM (DELETE /user/delete)."""
impl LiteLLMProxyManager.delete_user(username: str) -> None {
    self._admin_delete('/user/delete', {'user_ids': [username]});
}

# ─────────────────────────────────────────────────────────────────────────────
# Internal helpers
# ─────────────────────────────────────────────────────────────────────────────

"""Return True when running inside a Kubernetes pod."""
impl LiteLLMProxyManager._is_k8s_mode -> bool {
    return bool(os.environ.get('KUBERNETES_SERVICE_HOST'));
}

"""Load persisted master key from .jac/data/litellm_master_key, or generate and save one.

The key is generated once and reused across restarts so existing virtual keys
remain valid. Stored in plaintext under .jac/data/ which is already the local
data directory used by jac-scale (same location as anchor_store.db).
"""
impl LiteLLMProxyManager._load_or_generate_master_key -> str {
    import secrets;
    import from pathlib { Path }
    key_file = Path('.jac/data/litellm_master_key');
    key_file.parent.mkdir(parents=True, exist_ok=True);
    if key_file.exists() {
        key = key_file.read_text().strip();
        if key {
            return key;
        }
    }
    key = 'sk-jac-' + secrets.token_hex(32);
    key_file.write_text(key);
    logger.info(
        f"Generated LiteLLM master key and saved to {key_file}. "
        "Add LITELLM_MASTER_KEY to your environment or jac.toml to pin it."
    );
    return key;
}

"""Build the effective model list.

Priority:
  1. [[plugins.scale.litellm.models]] from jac.toml (user's explicit list)
  2. LITELLM_DEFAULT_MODELS (built-in defaults)

Also ensures byLLM's configured default_model is always present.
"""
impl LiteLLMProxyManager._resolve_models -> list[dict[str, Any]] {
    user_models = self.config.get('models', []);
    models = list(user_models) if user_models else list(LITELLM_DEFAULT_MODELS);
    try {
        import from byllm.config_loader { get_byllm_config }
        byllm_default = get_byllm_config().get_model_config().get('default_model', '');
        if byllm_default {
            existing_names = {m.get('model_name') for m in models};
            if byllm_default not in existing_names {
                fallback = next(
                    (m for m in LITELLM_DEFAULT_MODELS
                     if m['model_name'] == byllm_default),
                    None
                );
                if fallback {
                    models.append(fallback);
                } else {
                    models.append({
                        'model_name': byllm_default,
                        'litellm_params': {'model': byllm_default}
                    });
                }
            }
        }
    } except ImportError {
        # byllm not installed, skip default_model injection
    }
    if not models {
        raise LiteLLMConfigError(
            "No LiteLLM models could be configured. "
            "Set at least one provider API key environment variable "
            "(OPENAI_API_KEY, ANTHROPIC_API_KEY, GEMINI_API_KEY, GROQ_API_KEY) "
            "or define [[plugins.scale.litellm.models]] in jac.toml."
        );
    }
    return models;
}

"""Serialize models to a litellm config.yaml string.

Converts ${VAR} to os.environ/VAR so secrets stay in the environment.
"""
impl LiteLLMProxyManager._build_config_yaml(
    models: list[dict[str, Any]]
) -> str {
    import copy;
    converted_models = [];
    for entry in models {
        new_entry = copy.deepcopy(entry);
        params = new_entry.get('litellm_params', {});
        for (k, v) in list(params.items()) {
            if isinstance(v, str) {
                params[k] = self._convert_env_var_refs(v);
            }
        }
        converted_models.append(new_entry);
    }
    config_dict = {
        'model_list': converted_models,
        'general_settings': {
            'master_key': self.config.get('master_key', '')
        }
    };
    return yaml.dump(config_dict, default_flow_style=False);
}

"""Convert ${VAR_NAME} to os.environ/VAR_NAME for litellm config.yaml."""
impl LiteLLMProxyManager._convert_env_var_refs(value: str) -> str {
    return re.sub(r'\$\{([^}]+)\}', r'os.environ/\1', value);
}

"""POST to LiteLLM admin API with master key auth."""
impl LiteLLMProxyManager._admin_post(
    path: str, body: dict[str, Any]
) -> dict[str, Any] {
    import requests;
    master_key = self.config.get('master_key', '');
    url = f"{self.proxy_url}{path}";
    try {
        resp = requests.post(
            url,
            json=body,
            headers={'Authorization': f"Bearer {master_key}"},
            timeout=10.0
        );
    } except requests.exceptions.ConnectionError as e {
        raise LiteLLMConfigError(
            f"LiteLLM proxy unreachable at {url}. "
            f"Check that the proxy is running and proxy_url is correct. ({e})"
        );
    }
    if not resp.ok {
        raise LiteLLMConfigError(
            f"LiteLLM {path} returned {resp.status_code}: {resp.text}"
        );
    }
    return resp.json();
}

"""DELETE to LiteLLM admin API with master key auth."""
impl LiteLLMProxyManager._admin_delete(
    path: str, body: dict[str, Any]
) -> None {
    import requests;
    master_key = self.config.get('master_key', '');
    url = f"{self.proxy_url}{path}";
    try {
        resp = requests.delete(
            url,
            json=body,
            headers={'Authorization': f"Bearer {master_key}"},
            timeout=10.0
        );
    } except requests.exceptions.ConnectionError as e {
        raise LiteLLMConfigError(
            f"LiteLLM proxy unreachable at {url}. ({e})"
        );
    }
    if not resp.ok {
        raise LiteLLMConfigError(
            f"LiteLLM {path} returned {resp.status_code}: {resp.text}"
        );
    }
}

"""Wait for LiteLLM subprocess to emit 'Application startup complete.' on stdout.

Reads lines from the merged stdout/stderr pipe. Unblocks immediately when the
uvicorn ready signal appears — no polling, no arbitrary timeout.
Raises LiteLLMConfigError if the process exits before the signal.
"""
impl LiteLLMProxyManager._wait_for_startup_signal -> None {
    import threading;
    READY_SIGNAL = 'Application startup complete.';
    collected: list[str] = [];

    for line in self._process.stdout {
        stripped = line.rstrip();
        collected.append(stripped);
        logger.debug(f"[litellm] {stripped}");
        if READY_SIGNAL in stripped {
            logger.info(f"LiteLLM proxy ready at {self.proxy_url}");
            return;
        }
        if self._process.poll() is not None {
            output = '\n'.join(collected);
            raise LiteLLMConfigError(
                f"LiteLLM proxy process exited unexpectedly.\n{output}"
            );
        }
    }
    # stdout closed without the signal (process exited)
    output = '\n'.join(collected);
    raise LiteLLMConfigError(
        f"LiteLLM proxy exited before becoming ready.\n{output}"
    );
}

"""Poll /health until proxy is up — used for K8s mode where we don't own the process."""
impl LiteLLMProxyManager._wait_for_health -> None {
    retries = self.config.get('health_check_retries', 30);
    interval = self.config.get('health_check_interval', 3);
    for attempt in range(retries) {
        if self.is_healthy() {
            return;
        }
        logger.debug(f"Waiting for LiteLLM proxy (K8s)... ({attempt + 1}/{retries})");
        time.sleep(interval);
    }
    raise LiteLLMConfigError(
        f"LiteLLM proxy did not become healthy after "
        f"{retries * interval}s at {self.proxy_url}/health"
    );
}

# ─────────────────────────────────────────────────────────────────────────────
# Module-level singletons
# ─────────────────────────────────────────────────────────────────────────────

"""Return the active LiteLLMProxyManager singleton, or None if disabled."""
impl get_litellm_proxy_manager -> LiteLLMProxyManager | None {
    global _litellm_proxy_manager_instance;
    return _litellm_proxy_manager_instance;
}

"""Create, start, and store the global LiteLLMProxyManager.

Returns None if litellm is not enabled in config.
"""
impl init_litellm_proxy_manager -> LiteLLMProxyManager | None {
    global _litellm_proxy_manager_instance;
    ll_config = get_scale_config().get_litellm_config();
    if not ll_config.get('enabled', False) {
        return None;
    }
    manager = LiteLLMProxyManager(config=ll_config);
    manager.start();
    _litellm_proxy_manager_instance = manager;
    return manager;
}
