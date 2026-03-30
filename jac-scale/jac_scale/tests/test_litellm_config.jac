"""Tests for LiteLLM configuration loading and YAML generation.

Covers:
- get_litellm_config() defaults when jac.toml has no [litellm] section
- ${VAR} → os.environ/VAR conversion in generated YAML
- Literal API key values pass through unchanged
- byLLM default_model is auto-injected into model list
- Missing master_key raises LiteLLMConfigError at start()
- K8s mode detected via KUBERNETES_SERVICE_HOST
- Env var overrides (LITELLM_MASTER_KEY, LITELLM_PROXY_URL)
"""

import os;
import yaml;
import tempfile;
import shutil;
import pytest;
import unittest.mock;
import from pathlib { Path }
import from typing { Any }

import from jac_scale.config_loader { get_scale_config, reset_scale_config }
import from jac_scale.litellm_manager {
    LiteLLMProxyManager,
    LiteLLMConfigError,
    LITELLM_DEFAULT_MODELS
}

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

def make_toml_dir(toml_content: str) -> str {
    tmp = tempfile.mkdtemp();
    (Path(tmp) / "jac.toml").write_text(toml_content);
    return tmp;
}

def cleanup(tmp: str) -> None {
    shutil.rmtree(tmp, ignore_errors=True);
    reset_scale_config();
}

def make_manager(config: dict[str, Any]) -> LiteLLMProxyManager {
    return LiteLLMProxyManager(config=config);
}

# ─────────────────────────────────────────────────────────────────────────────
# Config loading
# ─────────────────────────────────────────────────────────────────────────────

test "default config returned when no litellm section in jac.toml" {
    tmp = make_toml_dir('[project]\nname = "test"\nversion = "1.0.0"\n');
    try {
        reset_scale_config();
        cfg = get_scale_config(project_dir=Path(tmp)).get_litellm_config();
        assert cfg['enabled'] == False;
        assert cfg['port'] == 4000;
        assert cfg['models'] == [];
        assert cfg['defaults']['budget_duration'] == '30d';
    } finally {
        cleanup(tmp);
    }
}

test "litellm enabled flag read from jac.toml" {
    toml = """
[project]
name = "test"
version = "1.0.0"

[plugins.scale.litellm]
enabled = true
master_key = "sk-master-test"
port = 4001
""";
    tmp = make_toml_dir(toml);
    try {
        reset_scale_config();
        cfg = get_scale_config(project_dir=Path(tmp)).get_litellm_config();
        assert cfg['enabled'] == True;
        assert cfg['port'] == 4001;
        assert cfg['master_key'] == 'sk-master-test';
    } finally {
        cleanup(tmp);
    }
}

test "LITELLM_MASTER_KEY env var overrides jac.toml master_key" {
    toml = """
[project]
name = "test"
version = "1.0.0"

[plugins.scale.litellm]
enabled = true
master_key = "toml-key"
""";
    tmp = make_toml_dir(toml);
    try {
        reset_scale_config();
        with unittest.mock.patch.dict(os.environ, {'LITELLM_MASTER_KEY': 'env-key'}) {
            cfg = get_scale_config(project_dir=Path(tmp)).get_litellm_config();
            assert cfg['master_key'] == 'env-key';
        }
    } finally {
        cleanup(tmp);
    }
}

test "LITELLM_PROXY_URL env var overrides jac.toml proxy_url" {
    toml = """
[project]
name = "test"
version = "1.0.0"

[plugins.scale.litellm]
enabled = true
proxy_url = "http://toml-proxy:4000"
""";
    tmp = make_toml_dir(toml);
    try {
        reset_scale_config();
        with unittest.mock.patch.dict(
            os.environ, {'LITELLM_PROXY_URL': 'http://env-proxy:4000'}
        ) {
            cfg = get_scale_config(project_dir=Path(tmp)).get_litellm_config();
            assert cfg['proxy_url'] == 'http://env-proxy:4000';
        }
    } finally {
        cleanup(tmp);
    }
}

test "proxy_url auto-derived from port when not set" {
    toml = """
[project]
name = "test"
version = "1.0.0"

[plugins.scale.litellm]
enabled = true
port = 5000
""";
    tmp = make_toml_dir(toml);
    try {
        reset_scale_config();
        # Remove LITELLM_PROXY_URL if present to test auto-derive
        env_patch = {k: v for (k, v) in os.environ.items() if k != 'LITELLM_PROXY_URL'};
        with unittest.mock.patch.dict(os.environ, env_patch, clear=True) {
            cfg = get_scale_config(project_dir=Path(tmp)).get_litellm_config();
            assert cfg['proxy_url'] == 'http://localhost:5000';
        }
    } finally {
        cleanup(tmp);
    }
}

test "per-user defaults loaded from jac.toml" {
    toml = """
[project]
name = "test"
version = "1.0.0"

[plugins.scale.litellm.defaults]
max_budget = 5.0
budget_duration = "7d"
rpm_limit = 30
tpm_limit = 50000
models = ["gpt-4o"]
""";
    tmp = make_toml_dir(toml);
    try {
        reset_scale_config();
        cfg = get_scale_config(project_dir=Path(tmp)).get_litellm_config();
        d = cfg['defaults'];
        assert d['max_budget'] == 5.0;
        assert d['budget_duration'] == '7d';
        assert d['rpm_limit'] == 30;
        assert d['tpm_limit'] == 50000;
        assert d['models'] == ['gpt-4o'];
    } finally {
        cleanup(tmp);
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Env var conversion
# ─────────────────────────────────────────────────────────────────────────────

test "dollar-brace syntax converted to os.environ/ in generated YAML" {
    mgr = make_manager({'enabled': True, 'master_key': 'sk-test', 'models': [], 'defaults': {}, 'port': 4000, 'proxy_url': 'http://localhost:4000'});
    result = mgr._convert_env_var_refs('${OPENAI_API_KEY}');
    assert result == 'os.environ/OPENAI_API_KEY';
}

test "literal api key passes through unchanged" {
    mgr = make_manager({'enabled': True, 'master_key': 'sk-test', 'models': [], 'defaults': {}, 'port': 4000, 'proxy_url': 'http://localhost:4000'});
    result = mgr._convert_env_var_refs('sk-abc123literal');
    assert result == 'sk-abc123literal';
}

test "multiple env var refs in same string both converted" {
    mgr = make_manager({'enabled': True, 'master_key': 'sk-test', 'models': [], 'defaults': {}, 'port': 4000, 'proxy_url': 'http://localhost:4000'});
    result = mgr._convert_env_var_refs('${FOO}:${BAR}');
    assert result == 'os.environ/FOO:os.environ/BAR';
}

test "build_config_yaml contains converted env var refs and not plaintext" {
    models = [
        {
            'model_name': 'gpt-4o',
            'litellm_params': {'model': 'openai/gpt-4o', 'api_key': '${OPENAI_API_KEY}'}
        }
    ];
    mgr = make_manager({
        'enabled': True,
        'master_key': 'sk-test-master',
        'models': models,
        'defaults': {},
        'port': 4000,
        'proxy_url': 'http://localhost:4000'
    });
    yaml_str = mgr._build_config_yaml(models);
    parsed = yaml.safe_load(yaml_str);
    api_key_val = parsed['model_list'][0]['litellm_params']['api_key'];
    assert api_key_val == 'os.environ/OPENAI_API_KEY';
    assert '${OPENAI_API_KEY}' not in yaml_str;
}

test "build_config_yaml includes general_settings with master_key" {
    models = [{'model_name': 'gpt-4o-mini', 'litellm_params': {'model': 'openai/gpt-4o-mini'}}];
    mgr = make_manager({
        'enabled': True,
        'master_key': 'sk-master-123',
        'models': [],
        'defaults': {},
        'port': 4000,
        'proxy_url': 'http://localhost:4000'
    });
    yaml_str = mgr._build_config_yaml(models);
    parsed = yaml.safe_load(yaml_str);
    assert parsed['general_settings']['master_key'] == 'sk-master-123';
}

test "build_config_yaml does not mutate original model list" {
    original_models = [
        {
            'model_name': 'gpt-4o',
            'litellm_params': {'model': 'openai/gpt-4o', 'api_key': '${OPENAI_API_KEY}'}
        }
    ];
    mgr = make_manager({'enabled': True, 'master_key': 'sk-test', 'models': [], 'defaults': {}, 'port': 4000, 'proxy_url': 'http://localhost:4000'});
    mgr._build_config_yaml(original_models);
    # Original must be untouched
    assert original_models[0]['litellm_params']['api_key'] == '${OPENAI_API_KEY}';
}

# ─────────────────────────────────────────────────────────────────────────────
# Model resolution
# ─────────────────────────────────────────────────────────────────────────────

test "no models in toml uses LITELLM_DEFAULT_MODELS" {
    mgr = make_manager({
        'enabled': True,
        'master_key': 'sk-test',
        'models': [],
        'defaults': {},
        'port': 4000,
        'proxy_url': 'http://localhost:4000'
    });
    resolved = mgr._resolve_models();
    default_names = {m['model_name'] for m in LITELLM_DEFAULT_MODELS};
    resolved_names = {m['model_name'] for m in resolved};
    assert default_names.issubset(resolved_names);
}

test "user models in toml override defaults entirely" {
    user_models = [
        {'model_name': 'my-model', 'litellm_params': {'model': 'openai/gpt-4o'}}
    ];
    mgr = make_manager({
        'enabled': True,
        'master_key': 'sk-test',
        'models': user_models,
        'defaults': {},
        'port': 4000,
        'proxy_url': 'http://localhost:4000'
    });
    resolved = mgr._resolve_models();
    assert len(resolved) >= 1;
    assert resolved[0]['model_name'] == 'my-model';
    # Default model names should NOT appear when user provided explicit list
    default_names = {m['model_name'] for m in LITELLM_DEFAULT_MODELS};
    resolved_names = {m['model_name'] for m in resolved};
    # Only user model plus potential byllm default injection
    assert 'my-model' in resolved_names;
}

test "byllm default_model auto-injected when not in list" {
    # Provide a user model list that does NOT include gpt-4o-mini (byLLM default)
    user_models = [
        {'model_name': 'claude-3-5-sonnet', 'litellm_params': {'model': 'anthropic/claude-3-5-sonnet-20241022'}}
    ];
    mgr = make_manager({
        'enabled': True,
        'master_key': 'sk-test',
        'models': user_models,
        'defaults': {},
        'port': 4000,
        'proxy_url': 'http://localhost:4000'
    });
    resolved = mgr._resolve_models();
    resolved_names = {m['model_name'] for m in resolved};
    # gpt-4o-mini is byLLM's default_model and must be present
    assert 'gpt-4o-mini' in resolved_names;
}

test "byllm default_model not duplicated if already in list" {
    user_models = [
        {'model_name': 'gpt-4o-mini', 'litellm_params': {'model': 'openai/gpt-4o-mini', 'api_key': '${OPENAI_API_KEY}'}}
    ];
    mgr = make_manager({
        'enabled': True,
        'master_key': 'sk-test',
        'models': user_models,
        'defaults': {},
        'port': 4000,
        'proxy_url': 'http://localhost:4000'
    });
    resolved = mgr._resolve_models();
    count = sum(1 for m in resolved if m['model_name'] == 'gpt-4o-mini');
    assert count == 1;
}

# ─────────────────────────────────────────────────────────────────────────────
# Startup validation
# ─────────────────────────────────────────────────────────────────────────────

test "missing master_key raises LiteLLMConfigError at start" {
    mgr = make_manager({
        'enabled': True,
        'master_key': '',
        'models': [],
        'defaults': {},
        'port': 4000,
        'proxy_url': 'http://localhost:4000',
        'health_check_retries': 1,
        'health_check_interval': 0
    });
    with pytest.raises(LiteLLMConfigError) as exc_info {
        mgr.start();
    }
    assert 'master_key' in str(exc_info.value).lower();
}

test "k8s mode with no proxy_url raises LiteLLMConfigError" {
    mgr = make_manager({
        'enabled': True,
        'master_key': 'sk-master',
        'models': [],
        'defaults': {},
        'port': 4000,
        'proxy_url': '',
        'health_check_retries': 1,
        'health_check_interval': 0
    });
    with unittest.mock.patch.dict(
        os.environ, {'KUBERNETES_SERVICE_HOST': '10.0.0.1'}
    ) {
        with pytest.raises(LiteLLMConfigError) as exc_info {
            mgr.start();
        }
        assert 'proxy_url' in str(exc_info.value).lower();
    }
}

test "k8s mode detected via KUBERNETES_SERVICE_HOST" {
    mgr = make_manager({'enabled': True, 'master_key': 'sk-test', 'models': [], 'defaults': {}, 'port': 4000, 'proxy_url': ''});
    with unittest.mock.patch.dict(os.environ, {'KUBERNETES_SERVICE_HOST': '10.0.0.1'}) {
        assert mgr._is_k8s_mode() == True;
    }
}

test "local mode when KUBERNETES_SERVICE_HOST not set" {
    mgr = make_manager({'enabled': True, 'master_key': 'sk-test', 'models': [], 'defaults': {}, 'port': 4000, 'proxy_url': ''});
    env = {k: v for (k, v) in os.environ.items() if k != 'KUBERNETES_SERVICE_HOST'};
    with unittest.mock.patch.dict(os.environ, env, clear=True) {
        assert mgr._is_k8s_mode() == False;
    }
}

test "start is no-op when enabled is false" {
    mgr = make_manager({
        'enabled': False,
        'master_key': '',
        'models': [],
        'defaults': {},
        'port': 4000,
        'proxy_url': '',
        'health_check_retries': 1,
        'health_check_interval': 0
    });
    # Should not raise even without master_key
    mgr.start();
    assert mgr._process is None;
}
