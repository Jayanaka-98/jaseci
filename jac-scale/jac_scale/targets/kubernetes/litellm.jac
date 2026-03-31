"""LiteLLM proxy deployer for Kubernetes."""
import os;
import re;
import from typing { Any }
import from kubernetes { client }
import from kubernetes.client.exceptions { ApiException }
import from jac_scale.targets.kubernetes.kubernetes_config { KubernetesConfig }
import from jac_scale.abstractions.logger { Logger }
import from jac_scale.targets.kubernetes.utils.kubernetes_utils {
    create_k8s_secret,
    delete_k8s_secret,
    delete_if_exists
}
import from jac_scale.config_loader { get_scale_config }
import from jac_scale.litellm_manager { LiteLLMProxyManager }

"""Deploys and destroys a LiteLLM proxy pod scoped to an app namespace.

The proxy is exposed as a ClusterIP Service (internal only). External admin
access goes through the Phase 3 reverse proxy at /admin/llm/ (JWT-gated).
LITELLM_PROXY_URL is injected into the main app Deployment so that
LiteLLMProxyManager skips subprocess startup and connects to the in-cluster pod.

Resources created per app:
  - ConfigMap  {app}-litellm-config  : litellm config.yaml (model list + budgets)
  - Secret     {app}-litellm-secret  : LITELLM_MASTER_KEY + provider API keys
  - Deployment {app}-litellm         : ghcr.io/berriai/litellm container
  - Service    {app}-litellm-service : ClusterIP on litellm_port (default 4000)
"""
obj LiteLLMDeployer {
    has k8s_config: KubernetesConfig,
        logger: (Logger | None) = None,
        _litellm_config: (dict | None) = None;

    """Deploy LiteLLM ConfigMap, Secret, Deployment, and Service.

    Reads the litellm config from jac.toml via get_scale_config(), builds the
    config.yaml, extracts provider API key env vars and stores them in a K8s
    Secret so the LiteLLM container can read them.

    Returns the in-cluster service URL:
        http://{app_name}-litellm-service.{namespace}.svc.cluster.local:{port}
    """
    def deploy(app_name: str, namespace: str, apps_v1: Any, core_v1: Any) -> str {
        litellm_config = (
            self._litellm_config
            if self._litellm_config is not None
            else get_scale_config().get_litellm_config()
        );
        master_key = litellm_config.get('master_key', '');

        # Build config YAML via a temporary manager instance
        mgr = LiteLLMProxyManager(config=litellm_config);
        models = mgr._resolve_models();
        config_yaml = mgr._build_config_yaml(models);

        # Extract ${VAR} references from model params so they can be stored in
        # the K8s Secret and read by the LiteLLM container at runtime.
        env_var_pattern = re.compile(r'\$\{([^}]+)\}');
        provider_env_vars: dict[str, str] = {};
        for model in models {
            params = model.get('litellm_params', {});
            for v in params.values() {
                if isinstance(v, str) {
                    for var_name in env_var_pattern.findall(v) {
                        val = os.environ.get(var_name, '');
                        if val {
                            provider_env_vars[var_name] = val;
                        }
                    }
                }
            }
        }

        resource_name = f"{app_name}-litellm";
        config_name = f"{resource_name}-config";
        secret_name = f"{resource_name}-secret";
        service_name = f"{resource_name}-service";
        port = self.k8s_config.litellm_port;
        image = self.k8s_config.litellm_image;
        labels = {'app': resource_name, 'managed': 'jac-scale'};

        # 1. ConfigMap: litellm config.yaml
        configmap = {
            'apiVersion': 'v1',
            'kind': 'ConfigMap',
            'metadata': {'name': config_name, 'namespace': namespace, 'labels': labels},
            'data': {'config.yaml': config_yaml}
        };
        try {
            core_v1.read_namespaced_config_map(name=config_name, namespace=namespace);
            core_v1.replace_namespaced_config_map(
                name=config_name, namespace=namespace, body=configmap
            );
        } except ApiException as e {
            if e.status == 404 {
                core_v1.create_namespaced_config_map(namespace=namespace, body=configmap);
            } else {
                raise;
            }
        }

        # 2. Secret: master key + all referenced provider API keys
        secret_data: dict[str, str] = {'LITELLM_MASTER_KEY': master_key};
        secret_data.update(provider_env_vars);
        create_k8s_secret(core_v1, namespace, secret_name, secret_data);

        # 3. Deployment
        deployment = {
            'apiVersion': 'apps/v1',
            'kind': 'Deployment',
            'metadata': {'name': resource_name, 'namespace': namespace, 'labels': labels},
            'spec': {
                'replicas': 1,
                'selector': {'matchLabels': {'app': resource_name}},
                'template': {
                    'metadata': {'labels': {'app': resource_name}},
                    'spec': {
                        'automountServiceAccountToken': False,
                        'securityContext': {'seccompProfile': {'type': 'RuntimeDefault'}},
                        'containers': [
                            {
                                'name': 'litellm',
                                'image': image,
                                'args': [
                                    '--config', '/app/config.yaml',
                                    '--port', str(port)
                                ],
                                'ports': [{'containerPort': port}],
                                'envFrom': [{'secretRef': {'name': secret_name}}],
                                'volumeMounts': [
                                    {
                                        'name': 'litellm-config',
                                        'mountPath': '/app/config.yaml',
                                        'subPath': 'config.yaml'
                                    }
                                ],
                                'resources': {
                                    'requests': {'cpu': '100m', 'memory': '256Mi'},
                                    'limits': {'cpu': '1', 'memory': '1Gi'}
                                },
                                'readinessProbe': {
                                    'httpGet': {'path': '/health', 'port': port},
                                    'initialDelaySeconds': 10,
                                    'periodSeconds': 10,
                                    'failureThreshold': 6
                                },
                                'livenessProbe': {
                                    'httpGet': {'path': '/health', 'port': port},
                                    'initialDelaySeconds': 30,
                                    'periodSeconds': 30
                                }
                            }
                        ],
                        'volumes': [
                            {
                                'name': 'litellm-config',
                                'configMap': {'name': config_name}
                            }
                        ]
                    }
                }
            }
        };
        delete_if_exists(
            apps_v1.delete_namespaced_deployment, resource_name, namespace, 'Deployment'
        );
        apps_v1.create_namespaced_deployment(namespace=namespace, body=deployment);

        # 4. Service (ClusterIP — internal only)
        service = {
            'apiVersion': 'v1',
            'kind': 'Service',
            'metadata': {'name': service_name, 'namespace': namespace, 'labels': labels},
            'spec': {
                'selector': {'app': resource_name},
                'ports': [{'port': port, 'targetPort': port, 'protocol': 'TCP'}],
                'type': 'ClusterIP'
            }
        };
        try {
            core_v1.read_namespaced_service(name=service_name, namespace=namespace);
            core_v1.replace_namespaced_service(
                name=service_name, namespace=namespace, body=service
            );
        } except ApiException as e {
            if e.status == 404 {
                core_v1.create_namespaced_service(namespace=namespace, body=service);
            } else {
                raise;
            }
        }

        in_cluster_url = (
            f"http://{service_name}.{namespace}.svc.cluster.local:{port}"
        );
        if self.logger {
            self.logger.info(f"LiteLLM proxy deployed: {in_cluster_url}");
        }
        return in_cluster_url;
    }

    """Destroy all LiteLLM K8s resources for the given app."""
    def destroy(app_name: str, namespace: str, apps_v1: Any, core_v1: Any) -> None {
        resource_name = f"{app_name}-litellm";
        try {
            delete_if_exists(
                apps_v1.delete_namespaced_deployment,
                resource_name,
                namespace,
                'Deployment'
            );
            delete_if_exists(
                core_v1.delete_namespaced_service,
                f"{resource_name}-service",
                namespace,
                'Service'
            );
            delete_if_exists(
                core_v1.delete_namespaced_config_map,
                f"{resource_name}-config",
                namespace,
                'ConfigMap'
            );
            delete_k8s_secret(core_v1, namespace, f"{resource_name}-secret");
        } except Exception as e {
            if self.logger {
                self.logger.warning(
                    f"Error destroying LiteLLM resources for '{app_name}': {e}"
                );
            }
        }
    }
}
