"""Tests for LiteLLMDeployer (Phase 4 — K8s manifest emission).

Covers:
- deploy() creates ConfigMap with correct config.yaml content
- deploy() creates Secret with LITELLM_MASTER_KEY and extracted provider key env vars
- deploy() creates Deployment with correct image, args, volume mount, envFrom
- deploy() creates ClusterIP Service on litellm_port
- deploy() returns the correct in-cluster URL
- destroy() deletes Deployment, Service, ConfigMap, Secret
- destroy() is resilient to k8s 404 errors (resource already gone)
- LiteLLMProxyManager.start() in K8s mode polls health and does not spawn subprocess
- LiteLLMProxyManager.start() in K8s mode raises LiteLLMConfigError on timeout
- KubernetesConfig litellm fields round-trip through to_dict/from_dict
"""

import os;
import unittest.mock;
import pytest;
import from typing { Any }

import from jac_scale.targets.kubernetes.litellm { LiteLLMDeployer }
import from jac_scale.targets.kubernetes.kubernetes_config { KubernetesConfig }
import from jac_scale.litellm_manager { LiteLLMProxyManager, LiteLLMConfigError }

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

"""Build a minimal KubernetesConfig with litellm enabled."""
def make_k8s_config(
    litellm_enabled: bool = True,
    litellm_image: str = 'ghcr.io/berriai/litellm:main-latest',
    litellm_port: int = 4000
) -> KubernetesConfig {
    return KubernetesConfig(
        app_name='testapp',
        namespace='test-ns',
        litellm_enabled=litellm_enabled,
        litellm_image=litellm_image,
        litellm_port=litellm_port
    );
}

"""Build a mock litellm config returned by get_scale_config().get_litellm_config()."""
def make_litellm_config(master_key: str = 'sk-master') -> dict {
    return {
        'enabled': True,
        'master_key': master_key,
        'proxy_url': 'http://localhost:4000',
        'models': [
            {
                'model_name': 'gpt-4o',
                'litellm_params': {
                    'model': 'gpt-4o',
                    'api_key': '${OPENAI_API_KEY}'
                }
            }
        ]
    };
}

"""Build mock k8s API clients."""
def make_k8s_mocks() -> tuple {
    apps_v1 = unittest.mock.MagicMock();
    core_v1 = unittest.mock.MagicMock();
    # Simulate resource not existing (404) so create paths are taken
    import from kubernetes.client.exceptions { ApiException }
    not_found = ApiException(status=404);
    core_v1.read_namespaced_config_map.side_effect = not_found;
    core_v1.read_namespaced_service.side_effect = not_found;
    return (apps_v1, core_v1);
}

# ─────────────────────────────────────────────────────────────────────────────
# KubernetesConfig litellm fields
# ─────────────────────────────────────────────────────────────────────────────

test "KubernetesConfig litellm fields default to disabled" {
    cfg = KubernetesConfig(app_name='app', namespace='ns');
    assert cfg.litellm_enabled == False;
    assert cfg.litellm_port == 4000;
    assert 'litellm' in cfg.litellm_image;
}

test "KubernetesConfig litellm fields round-trip through to_dict and from_dict" {
    cfg = make_k8s_config(litellm_enabled=True, litellm_port=4001);
    d = cfg.to_dict();
    assert d['litellm_enabled'] == True;
    assert d['litellm_port'] == 4001;
    cfg2 = KubernetesConfig.from_dict(KubernetesConfig, d);
    assert cfg2.litellm_enabled == True;
    assert cfg2.litellm_port == 4001;
}

# ─────────────────────────────────────────────────────────────────────────────
# LiteLLMDeployer.deploy()
# ─────────────────────────────────────────────────────────────────────────────

test "deploy creates ConfigMap with config.yaml content" {
    k8s_config = make_k8s_config();
    (apps_v1, core_v1) = make_k8s_mocks();
    litellm_config = make_litellm_config();

    deployer = LiteLLMDeployer(k8s_config=k8s_config, _litellm_config=litellm_config);
    deployer.deploy('testapp', 'test-ns', apps_v1, core_v1);

    call_args = core_v1.create_namespaced_config_map.call_args;
    body = call_args.kwargs.get('body', call_args.args[1] if len(call_args.args) > 1 else {});
    assert body['metadata']['name'] == 'testapp-litellm-config';
    assert 'config.yaml' in body['data'];
    assert 'gpt-4o' in body['data']['config.yaml'];
}

test "deploy creates Secret with LITELLM_MASTER_KEY and provider env vars" {
    k8s_config = make_k8s_config();
    (apps_v1, core_v1) = make_k8s_mocks();
    litellm_config = make_litellm_config(master_key='sk-test-master');

    with unittest.mock.patch.dict(os.environ, {'OPENAI_API_KEY': 'sk-openai-test'}) {
        deployer = LiteLLMDeployer(k8s_config=k8s_config, _litellm_config=litellm_config);
        deployer.deploy('testapp', 'test-ns', apps_v1, core_v1);

        # create_k8s_secret calls core_v1.create_namespaced_secret — verify via that
        secret_calls = [
            c for c in core_v1.create_namespaced_secret.call_args_list
            if 'litellm-secret' in str(c)
        ];
        assert len(secret_calls) > 0;
        body = secret_calls[0].kwargs.get('body', {});
        string_data = body.get('stringData', {});
        assert string_data.get('LITELLM_MASTER_KEY') == 'sk-test-master';
        assert string_data.get('OPENAI_API_KEY') == 'sk-openai-test';
    }
}

test "deploy creates Deployment with correct image args and volume mount" {
    k8s_config = make_k8s_config(litellm_image='ghcr.io/berriai/litellm:v1.0');
    (apps_v1, core_v1) = make_k8s_mocks();
    litellm_config = make_litellm_config();

    deployer = LiteLLMDeployer(k8s_config=k8s_config, _litellm_config=litellm_config);
    deployer.deploy('testapp', 'test-ns', apps_v1, core_v1);

    call_args = apps_v1.create_namespaced_deployment.call_args;
    body = call_args.kwargs.get('body', call_args.args[1] if len(call_args.args) > 1 else {});
    container = body['spec']['template']['spec']['containers'][0];
    assert container['image'] == 'ghcr.io/berriai/litellm:v1.0';
    assert '--config' in container['args'];
    assert '/app/config.yaml' in container['args'];
    assert container['volumeMounts'][0]['mountPath'] == '/app/config.yaml';
    assert container['envFrom'][0]['secretRef']['name'] == 'testapp-litellm-secret';
}

test "deploy creates ClusterIP Service on litellm_port" {
    k8s_config = make_k8s_config(litellm_port=4001);
    (apps_v1, core_v1) = make_k8s_mocks();
    litellm_config = make_litellm_config();

    deployer = LiteLLMDeployer(k8s_config=k8s_config, _litellm_config=litellm_config);
    deployer.deploy('testapp', 'test-ns', apps_v1, core_v1);

    call_args = core_v1.create_namespaced_service.call_args;
    body = call_args.kwargs.get('body', call_args.args[1] if len(call_args.args) > 1 else {});
    assert body['spec']['type'] == 'ClusterIP';
    assert body['spec']['ports'][0]['port'] == 4001;
    assert body['metadata']['name'] == 'testapp-litellm-service';
}

test "deploy returns correct in-cluster URL" {
    k8s_config = make_k8s_config(litellm_port=4000);
    (apps_v1, core_v1) = make_k8s_mocks();
    litellm_config = make_litellm_config();

    deployer = LiteLLMDeployer(k8s_config=k8s_config, _litellm_config=litellm_config);
    url = deployer.deploy('testapp', 'test-ns', apps_v1, core_v1);
    assert url == 'http://testapp-litellm-service.test-ns.svc.cluster.local:4000';
}

# ─────────────────────────────────────────────────────────────────────────────
# LiteLLMDeployer.destroy()
# ─────────────────────────────────────────────────────────────────────────────

test "destroy deletes Deployment Service ConfigMap and Secret" {
    k8s_config = make_k8s_config();
    apps_v1 = unittest.mock.MagicMock();
    core_v1 = unittest.mock.MagicMock();

    deployer = LiteLLMDeployer(k8s_config=k8s_config);
    deployer.destroy('testapp', 'test-ns', apps_v1, core_v1);

    # delete_if_exists calls the delete_func(name, namespace) — verify via the mocks
    deploy_names = [c.args[0] for c in apps_v1.delete_namespaced_deployment.call_args_list];
    assert 'testapp-litellm' in deploy_names;

    svc_names = [c.args[0] for c in core_v1.delete_namespaced_service.call_args_list];
    assert 'testapp-litellm-service' in svc_names;

    cm_names = [c.args[0] for c in core_v1.delete_namespaced_config_map.call_args_list];
    assert 'testapp-litellm-config' in cm_names;

    # delete_k8s_secret calls core_v1.delete_namespaced_secret(name=..., namespace=...)
    secret_names = [c.kwargs.get('name', '') for c in core_v1.delete_namespaced_secret.call_args_list];
    assert 'testapp-litellm-secret' in secret_names;
}

test "destroy does not raise when resources already gone" {
    k8s_config = make_k8s_config();
    apps_v1 = unittest.mock.MagicMock();
    core_v1 = unittest.mock.MagicMock();

    with unittest.mock.patch(
        'jac_scale.targets.kubernetes.litellm.delete_if_exists',
        side_effect=Exception('not found')
    ) {
        deployer = LiteLLMDeployer(k8s_config=k8s_config);
        # Should not raise — errors are swallowed with a warning
        deployer.destroy('testapp', 'test-ns', apps_v1, core_v1);
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# LiteLLMProxyManager.start() in K8s mode
# ─────────────────────────────────────────────────────────────────────────────

test "start in K8s mode does not spawn subprocess and polls health" {
    config = {
        'enabled': True,
        'master_key': 'sk-master',
        'proxy_url': 'http://litellm-service:4000',
        'k8s_startup_timeout': 10
    };
    mgr = LiteLLMProxyManager(config=config);

    with unittest.mock.patch.dict(os.environ, {'KUBERNETES_SERVICE_HOST': '10.0.0.1'}) {
        with unittest.mock.patch.object(mgr, 'is_healthy', return_value=True) {
            mgr.start();
            assert mgr._process is None;
        }
    }
}

test "start in K8s mode raises LiteLLMConfigError when proxy stays unhealthy" {
    # k8s_startup_timeout=0 -> retries = 0 // 5 = 0 -> loop skipped -> immediate raise
    config = {
        'enabled': True,
        'master_key': 'sk-master',
        'proxy_url': 'http://litellm-service:4000',
        'k8s_startup_timeout': 0
    };
    mgr = LiteLLMProxyManager(config=config);

    with unittest.mock.patch.dict(os.environ, {'KUBERNETES_SERVICE_HOST': '10.0.0.1'}) {
        with unittest.mock.patch.object(mgr, 'is_healthy', return_value=False) {
            with pytest.raises(LiteLLMConfigError) {
                mgr.start();
            }
        }
    }
}
