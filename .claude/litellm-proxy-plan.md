# LiteLLM Proxy Integration — Implementation Plan

## Architecture Overview

```
jac.toml
  └── [plugins.scale.litellm]  ← proxy config, model list, budgets
  └── [byllm.model] base_url   ← proxy URL consumed by byLLM

jac scale start
  ├── LiteLLMProxyManager.start()  ← spawns subprocess (local) or connects (K8s)
  ├── UserManager.create_user()    ← creates LiteLLM user + generates virtual key
  └── spawn_walker()               ← injects user's virtual key into ContextVar

byLLM call (any walker dispatch)
  ├── _resolve_proxy_params()  ← reads proxy_url from _model_config, key from ContextVar
  └── routes via OpenAI client → LiteLLM proxy → provider
```

---

## Phase 1 — DONE ✔

### Files changed

| File | Change |
|------|--------|
| `jac-byllm/byllm/exceptions.jac` | Added `LiteLLMAccessError(ByLLMError)` |
| `jac-byllm/byllm/llm.jac` | Import `LiteLLMAccessError` |
| `jac-byllm/byllm/llm.impl/model.impl.jac` | `_resolve_proxy_params()`, `_raise_proxy_error()`, proxy routing in both call methods |
| `jac-scale/jac_scale/config_loader.jac` | `get_litellm_config()` on interface |
| `jac-scale/jac_scale/impl/config_loader.impl.jac` | `get_litellm_config()` impl with defaults, env var overrides |
| `jac-scale/jac_scale/litellm_manager.jac` | NEW — `LiteLLMProxyManager`, `LITELLM_DEFAULT_MODELS`, module functions |
| `jac-scale/jac_scale/impl/litellm_manager.impl.jac` | NEW — full impl: start/stop/health, model resolution, admin API |
| `jac-scale/jac_scale/impl/serve.core.impl.jac` | `postinit` starts proxy, `start` stops it on shutdown |
| `jac/jaclang/runtimelib/context.jac` | `user_llm_key: ContextVar` on base `ExecutionContext` |
| `jac-scale/jac_scale/context.jac` | Removed `user_llm_key` (now inherited from base) |
| `jac/jaclang/runtimelib/impl/server.impl.jac` | `spawn_walker` injects/resets `user_llm_key` ContextVar |
| `jac-scale/jac_scale/tests/test_litellm_config.jac` | NEW — 21 tests |
| `jac-byllm/tests/test_litellm_proxy.jac` | NEW — 15 tests |

### Key design decisions
- `${VAR}` in jac.toml → `os.environ/VAR` in litellm config.yaml (secrets stay in env)
- `requests` not `httpx` (httpx crashes Jac type checker on import)
- `using_proxy` flag guards `_raise_proxy_error` so direct-mode openai errors aren't misidentified
- except clause order: litellm-specific → openai-specific → `openai.APIStatusError` (general last)
- `getattr(ctx, 'user_llm_key', None)` in `spawn_walker` — duck typed, no jac-scale import in jaclang
- `JacRuntime` from `jaclang.jac0core.runtime` used in `_resolve_proxy_params` (patchable in tests)
- `user_llm_key` on base `ExecutionContext` so `jac start` also supports proxy

---

## Phase 2 — User Registration Integration

Goal: when a user registers, create them in LiteLLM and store their virtual key. When deleted, revoke.

### 2a — jac-scale: DB schema

**`jac-scale` uses MongoDB via `JacScaleUserManager._storage`.**

The storage backend is `jac_scale/mongo_storage.jac` + impl. User documents live in a MongoDB collection.

Changes needed:
- Add `litellm_key: str` field to user documents at creation time
- `get_user()` must return `litellm_key` in the result dict (so `spawn_walker` can read it)
- `delete_user()` must revoke the key before removing the document

### 2b — jac-scale: hook LiteLLMProxyManager into user lifecycle

**Where to make the calls:** `JacAPIServerCore.create_user` and `JacAPIServerCore.delete_user` (or inside `JacScaleUserManager` itself if it has a reference to the manager).

Looking at serve.core: `create_user` delegates to `self.user_manager.create_user(username, password)`. The cleanest approach is to pass `self._litellm_manager` down so the user manager can call it, or call it directly in `JacAPIServerCore.create_user` after the user is created.

**Recommended approach:** Do it in `JacAPIServerCore.create_user` / `delete_user` (serve.core.impl.jac) since `self._litellm_manager` is available there. This avoids coupling `JacScaleUserManager` to `LiteLLMProxyManager`.

```
JacAPIServerCore.create_user(username, password):
  1. res = self.user_manager.create_user(username, password)  ← existing
  2. if self._litellm_manager is not None:
       self._litellm_manager.create_user(username, limits={})
       litellm_key = self._litellm_manager.generate_key(username, limits={})
       self.user_manager.set_litellm_key(username, litellm_key)  ← new method

JacAPIServerCore.delete_user(username):
  1. if self._litellm_manager is not None:
       user = self.user_manager.get_user(username)
       if user and user.get('litellm_key'):
           self._litellm_manager.revoke_key(user['litellm_key'])
           self._litellm_manager.delete_user(username)
  2. self.user_manager.delete_user(username)  ← existing
```

New method needed: `JacScaleUserManager.set_litellm_key(username: str, key: str) -> None`

### 2c — jac-scale: migrate existing users

Users created before this feature have no `litellm_key`. Options:
- On-demand: in `spawn_walker`, if key is None AND proxy is configured, generate one lazily
- Eager: `jac scale migrate-llm-keys` CLI command

**Recommended:** lazy generation in `spawn_walker`. Avoids needing a migration step for most apps.

In `server.impl.jac` `spawn_walker`:
```jac
if user_llm_key_cv is not None {
    user_data = self.user_manager.get_user(username);
    litellm_key = user_data.get('litellm_key') if user_data else None;
    # Lazy generation for users without a key (migrates existing users on first call)
    if litellm_key is None {
        litellm_key = _ensure_litellm_key_for_user(username, self.user_manager);
    }
    llm_key_token = user_llm_key_cv.set(litellm_key);
}
```

`_ensure_litellm_key_for_user` is a module-level helper that tries to get the proxy manager and generate a key if one doesn't exist. Uses duck-typing / getattr to avoid jac-scale dependency in jaclang.

OR simpler: just leave it as-is (key is None → `LiteLLMAccessError`). Users without keys just can't use the proxy until a new key is provisioned. Explicit is better.

### 2d — jac start (base jaclang): DB schema + key provisioning

The base `UserManager` in `jac/jaclang/runtimelib/impl/server.impl.jac` uses SQLite.

Schema change in `_ensure_connection`:
```sql
CREATE TABLE IF NOT EXISTS users (
    username TEXT PRIMARY KEY,
    password_hash TEXT NOT NULL,
    token TEXT UNIQUE NOT NULL,
    root_id TEXT NOT NULL,
    litellm_key TEXT          ← ADD THIS
);
ALTER TABLE users ADD COLUMN litellm_key TEXT;  ← for existing DBs (run on connect)
```

For key provisioning on `jac start`: check env vars `LITELLM_PROXY_URL` and `LITELLM_MASTER_KEY`. If set, call `/user/new` and `/key/generate` directly via `requests`. No new dependency needed.

Add `UserManager.set_litellm_key(username: str, key: str) -> None` (SQLite version).

`get_user()` must return `litellm_key` field.

### Files to edit for Phase 2

| File | Change |
|------|--------|
| `jac/jaclang/runtimelib/impl/server.impl.jac` | Add `litellm_key TEXT` to schema, `set_litellm_key()`, update `get_user()` to include it, provision key in `create_user` if proxy configured |
| `jac/jaclang/runtimelib/server.jac` | Add `set_litellm_key` to `UserManager` interface |
| `jac-scale/jac_scale/impl/serve.core.impl.jac` | Call `_litellm_manager.create_user()` + `generate_key()` + `set_litellm_key()` after user creation; revoke key in `delete_user` |
| `jac-scale/jac_scale/impl/user_manager.impl.jac` | Add `set_litellm_key()` impl (MongoDB) |
| `jac-scale/jac_scale/user_manager.jac` | Add `set_litellm_key` to `JacScaleUserManager` interface |
| `jac-scale/jac_scale/mongo_storage.jac` + impl | Add `set_litellm_key()` and return `litellm_key` in `get_user()` |
| `jac-scale/jac_scale/tests/test_user_litellm.jac` | NEW — tests for key lifecycle |

### Test plan for Phase 2
- `create_user` with proxy configured → `create_user` + `generate_key` called on proxy manager mock → key stored in DB
- `create_user` with no proxy → no LiteLLM calls, `litellm_key` is None
- `delete_user` with key → `revoke_key` + `delete_user` called on proxy manager
- `delete_user` with no key → no revoke calls
- `get_user` returns `litellm_key` field
- `spawn_walker` reads `litellm_key` from user data → injects into ContextVar

---

## Phase 3 — Admin Dashboard Proxy

Goal: expose LiteLLM's built-in UI at `/admin/llm/` inside the jac-scale server, gated behind admin auth.

### What LiteLLM exposes
LiteLLM proxy ships its own UI (at `http://<proxy_url>/ui`) and a full OpenAPI spec. We reverse-proxy the entire subtree so admins can manage keys, view spend, and configure models without opening the LiteLLM port directly.

### Route pattern
```
GET/POST/PUT/DELETE /admin/llm/{path:path}
  → require admin token
  → strip /admin/llm prefix
  → forward to {litellm_manager.proxy_url}/{path}
  → stream response back
```

### Implementation — one file, one function

**File:** `jac-scale/jac_scale/impl/serve.core.impl.jac`

**Where:** add a new method `register_llm_proxy_endpoint` called from `start()` just before `run_server()`, after `register_admin_endpoints()`, and only when `self._litellm_manager is not None`.

```jac
impl JacAPIServerCore.register_llm_proxy_endpoint -> None {
    import from fastapi { Request }
    import from fastapi.responses { StreamingResponse, Response }
    import httpx;

    litellm_url = self._litellm_manager.proxy_url;
    master_key  = self._litellm_manager.config.get('master_key', '');
    user_manager = self.user_manager;

    async def llm_proxy_handler(request: Request, path: str) -> Response {
        # Admin-only: validate Authorization header
        token = (request.headers.get('Authorization') or '').removeprefix('Bearer ').strip();
        username = user_manager.validate_jwt_token(token) if token else None;
        if not username or not user_manager.is_admin(username) {
            return Response(content='Forbidden', status_code=403);
        }
        # Forward to LiteLLM, inject master key
        target_url = f"{litellm_url}/{path}";
        headers = dict(request.headers);
        headers['Authorization'] = f"Bearer {master_key}";
        headers.pop('host', None);
        body = await request.body();
        async with httpx.AsyncClient() as client {
            resp = await client.request(
                method=request.method,
                url=target_url,
                headers=headers,
                content=body,
                params=dict(request.query_params),
                timeout=30.0
            );
        }
        return Response(
            content=resp.content,
            status_code=resp.status_code,
            headers=dict(resp.headers),
            media_type=resp.headers.get('content-type')
        );
    }

    self.server.app.add_route(
        '/admin/llm/{path:path}', llm_proxy_handler, methods=['GET','POST','PUT','DELETE','PATCH']
    );
}
```

**Notes:**
- `httpx` is imported inline (not at module level) to avoid the Jac type-checker crash
- `httpx.AsyncClient` used (not `requests`) because this is an async FastAPI route handler
- Master key is injected so admins don't need to know it; LiteLLM sees a valid admin request
- `host` header stripped to avoid LiteLLM rejecting mismatched host
- Non-streaming response for simplicity; LiteLLM UI is not a streaming context

### Interface change
Add to `JacAPIServerCore` in `jac-scale/jac_scale/serve.core.jac`:
```jac
def register_llm_proxy_endpoint -> None;
```

### Call site
In `start()` in serve.core.impl.jac, after `self.register_admin_endpoints();`:
```jac
if self._litellm_manager is not None {
    self.register_llm_proxy_endpoint();
}
```

### Auth boundary
The handler validates the JWT and checks `is_admin()` before forwarding. Non-admin tokens get 403. Unauthenticated requests get 403. The LiteLLM port itself does not need to be exposed externally.

### Files to edit

| File | Change |
|------|--------|
| `jac-scale/jac_scale/serve.core.jac` | Add `register_llm_proxy_endpoint` to interface |
| `jac-scale/jac_scale/impl/serve.core.impl.jac` | Implement `register_llm_proxy_endpoint`, call from `start()` |

### Test plan
- No proxy manager → route not registered (confirm `/admin/llm/health` returns 404)
- Non-admin token → 403
- No token → 403
- Admin token → request forwarded to `litellm_url/{path}` (mock httpx, assert call args)
- Query params forwarded correctly
- Master key injected in forwarded headers

---

## Phase 4 — K8s Manifest Emission

Goal: when `jac scale deploy` targets a Kubernetes cluster and `[plugins.scale.litellm]` is enabled in jac.toml, automatically deploy a LiteLLM proxy pod alongside the application. The main app Deployment gets `LITELLM_PROXY_URL` injected so `LiteLLMProxyManager` in K8s mode skips the subprocess and connects to the in-cluster service.

---

### Architecture in K8s

```
jac scale deploy
  ├── KubernetesTarget.deploy()
  │   ├── ... (existing steps 1-15)
  │   ├── 15c. LiteLLMDeployer.deploy()       ← NEW
  │   │        ├── Secret: master key + provider keys
  │   │        ├── ConfigMap: litellm config.yaml (model list, budget rules)
  │   │        ├── Deployment: ghcr.io/berriai/litellm:main-latest
  │   │        └── Service: ClusterIP on port 4000
  │   ├── (inject LITELLM_PROXY_URL into app Deployment env)  ← NEW
  │   └── 15b finish_ingress (existing, unchanged)
  └── KubernetesTarget.destroy()
      └── LiteLLMDeployer.destroy()            ← NEW
```

At runtime:
- `LiteLLMProxyManager.start()` detects K8s (env var `KUBERNETES_SERVICE_HOST` present) and skips subprocess — just waits for `GET {proxy_url}/health` to return 200.
- `spawn_walker` injects `user_llm_key` ContextVar as normal — no change to Phase 1 logic.

---

### 4a — New file: `LiteLLMDeployer`

**File:** `jac-scale/jac_scale/targets/kubernetes/litellm.jac`
**Pattern:** mirrors `MonitoringDeployer` (`obj LiteLLMDeployer { has k8s_config, logger; def deploy(...); def destroy(...); }`)

**`deploy(app_name, namespace, apps_v1, core_v1)`:**

1. Build `config.yaml` string from `get_litellm_config()` — same YAML that `build_config_yaml()` generates locally. Provider API key refs stay as `os.environ/VAR` so the container reads them from its own env.
2. Create/patch **ConfigMap** `{app_name}-litellm-config` with `config.yaml` key.
3. Create/patch **Secret** `{app_name}-litellm-secret` containing:
   - `LITELLM_MASTER_KEY` — value of `master_key` from config (or env var ref)
   - All `${VAR}` provider key env vars referenced in the model list (extracted by regex)
   Use `create_k8s_secret()` util (already exists).
4. Create/patch **Deployment** `{app_name}-litellm`:
   - Image: `self.k8s_config.litellm_image` (default `ghcr.io/berriai/litellm:main-latest`)
   - Args: `["--config", "/app/config.yaml", "--port", "4000"]`
   - Volume: ConfigMap → `/app/config.yaml`
   - EnvFrom: Secret `{app_name}-litellm-secret`
   - Resources: `requests: {cpu: "100m", memory: "256Mi"}`, `limits: {cpu: "1", memory: "1Gi"}`
   - ReadinessProbe: `GET /health` on port 4000, `initialDelaySeconds: 10`, `periodSeconds: 10`
   - LivenessProbe: `GET /health` on port 4000, `initialDelaySeconds: 30`, `periodSeconds: 30`
   - `replicas: 1` (LiteLLM is stateful via its DB; multi-replica needs Postgres — out of scope)
5. Create/patch **Service** `{app_name}-litellm-service`:
   - `ClusterIP` (internal only — Phase 3 reverse proxy exposes it behind admin auth)
   - Port 4000 → containerPort 4000
6. Return `f"http://{app_name}-litellm-service.{namespace}.svc.cluster.local:4000"` — the in-cluster proxy URL.

**`destroy(app_name, namespace, apps_v1, core_v1)`:**
- Delete Deployment, Service, ConfigMap, Secret using `delete_if_exists()` util.
- Errors silently swallowed (resource may not exist).

---

### 4b — `KubernetesConfig` changes

**File:** `jac-scale/jac_scale/targets/kubernetes/kubernetes_config.jac`

New fields:
```jac
litellm_enabled: bool = False,
litellm_image: str = 'ghcr.io/berriai/litellm:main-latest',
litellm_port: int = 4000;
```

`litellm_enabled` is set to `True` when `get_litellm_config().get('enabled', False)` is true. Loaded from jac.toml section `[plugins.scale.litellm]` — same config source as `LiteLLMProxyManager`.

Add to `to_dict()` and `from_dict()` / constructor (same pattern as `monitoring_enabled`).

---

### 4c — `KubernetesTarget.deploy()` changes

**File:** `jac-scale/jac_scale/targets/kubernetes/kubernetes_target.jac`

**Step 15c** — after existing monitoring step (line ~1436), before `finish_ingress`:

```jac
# 15c. Deploy LiteLLM proxy pod if enabled
if self.k8s_config.litellm_enabled {
    import from jac_scale.targets.kubernetes.litellm { LiteLLMDeployer }
    litellm_deployer = LiteLLMDeployer(self.k8s_config, self.logger);
    litellm_url = litellm_deployer.deploy(app_name, namespace, apps_v1, core_v1);
    # Inject LITELLM_PROXY_URL into the main app deployment via env patch
    _patch_deployment_env(app_name, namespace, apps_v1, {
        'LITELLM_PROXY_URL': litellm_url,
        'LITELLM_MASTER_KEY': self.k8s_config.litellm_master_key  # from Secret ref ideally
    });
    details["deploy_litellm"] = "Successful";
}
```

`_patch_deployment_env` is a new private helper that does `apps_v1.patch_namespaced_deployment(name=app_name, namespace=namespace, body=patch)` where `patch` updates the `env` list.

**Alternatively** (simpler): pass the env vars at Deployment creation time in `_deploy_code_server`. Add a `_extra_env: dict` param. This avoids a second patch call.

**Recommended:** Pass via `_deploy_code_server` — but this requires computing the LiteLLM URL before the main Deployment is created. Order change needed: deploy LiteLLM **before** the main app Deployment (move to step ~8 after databases, before code-server). URL is deterministic (`{app_name}-litellm-service.{namespace}.svc.cluster.local:4000`) so it can be computed without waiting for the pod.

**Destroy:** In `KubernetesTarget.destroy()` (called ~line 1904/1959), add:
```jac
if self.k8s_config.litellm_enabled {
    import from jac_scale.targets.kubernetes.litellm { LiteLLMDeployer }
    LiteLLMDeployer(self.k8s_config, self.logger).destroy(app_name, namespace, apps_v1, core_v1);
}
```

---

### 4d — `LiteLLMProxyManager.start()` K8s health wait

**File:** `jac-scale/jac_scale/impl/litellm_manager.impl.jac`

In `start()`, the K8s branch currently raises `LiteLLMConfigError` if `proxy_url` is not set (Phase 1). Extend it to wait for readiness:

```jac
if self._is_k8s {
    if not self.proxy_url {
        raise LiteLLMConfigError("K8s mode requires LITELLM_PROXY_URL to be set");
    }
    # Wait for in-cluster LiteLLM pod to be ready (it may still be starting)
    self._wait_for_proxy_health(timeout_secs=120);
    logger.info(f"LiteLLM proxy ready at {self.proxy_url}");
    return;
}
```

`_wait_for_proxy_health(timeout_secs)` — polls `GET {proxy_url}/health` via `requests` every 5s until 200 or timeout. Raises `LiteLLMConfigError("LiteLLM proxy did not become ready in time")` on timeout.

---

### 4e — Template files

**`jac-scale/jac_scale/targets/kubernetes/templates/litellm/deployment.yaml`** — reference template (not used directly, Deployer builds the dict inline like `MonitoringDeployer`):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: APP_NAME-litellm
spec:
  replicas: 1
  selector:
    matchLabels:
      app: APP_NAME-litellm
  template:
    spec:
      containers:
        - name: litellm
          image: ghcr.io/berriai/litellm:main-latest
          args: ["--config", "/app/config.yaml", "--port", "4000"]
          ports:
            - containerPort: 4000
          volumeMounts:
            - name: config
              mountPath: /app/config.yaml
              subPath: config.yaml
          envFrom:
            - secretRef:
                name: APP_NAME-litellm-secret
          resources:
            requests: {cpu: "100m", memory: "256Mi"}
            limits: {cpu: "1", memory: "1Gi"}
          readinessProbe:
            httpGet: {path: /health, port: 4000}
            initialDelaySeconds: 10
            periodSeconds: 10
      volumes:
        - name: config
          configMap:
            name: APP_NAME-litellm-config
```

**`jac-scale/jac_scale/targets/kubernetes/templates/litellm/service.yaml`** — reference template:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: APP_NAME-litellm-service
spec:
  selector:
    app: APP_NAME-litellm
  ports:
    - port: 4000
      targetPort: 4000
  type: ClusterIP
```

---

### Files to edit for Phase 4

| File | Change |
|------|--------|
| `jac-scale/jac_scale/targets/kubernetes/litellm.jac` | NEW — `LiteLLMDeployer` obj with `deploy()` + `destroy()` |
| `jac-scale/jac_scale/targets/kubernetes/kubernetes_config.jac` | Add `litellm_enabled`, `litellm_image`, `litellm_port` fields |
| `jac-scale/jac_scale/targets/kubernetes/kubernetes_target.jac` | Call `LiteLLMDeployer.deploy()` / `destroy()`, inject env var into app Deployment |
| `jac-scale/jac_scale/impl/litellm_manager.impl.jac` | Add `_wait_for_proxy_health()`, extend K8s branch of `start()` |
| `jac-scale/jac_scale/targets/kubernetes/templates/litellm/deployment.yaml` | NEW — reference template |
| `jac-scale/jac_scale/targets/kubernetes/templates/litellm/service.yaml` | NEW — reference template |
| `jac-scale/jac_scale/tests/test_litellm_k8s_deployer.jac` | NEW — unit tests for `LiteLLMDeployer` |

---

### Test plan for Phase 4

- `LiteLLMDeployer.deploy()` with mock k8s clients → ConfigMap created with correct `config.yaml` content
- `LiteLLMDeployer.deploy()` → Secret created with `LITELLM_MASTER_KEY` and extracted provider key env var names
- `LiteLLMDeployer.deploy()` → Deployment body has correct image, args, volume mount, envFrom
- `LiteLLMDeployer.deploy()` → Service is ClusterIP on port 4000
- `LiteLLMDeployer.deploy()` → returns correct in-cluster URL `http://{app_name}-litellm-service.{namespace}.svc.cluster.local:4000`
- `LiteLLMDeployer.destroy()` → all four resources deleted via `delete_if_exists`
- `LiteLLMDeployer.destroy()` with k8s 404 errors → does not raise
- `LiteLLMProxyManager.start()` in K8s mode → calls `_wait_for_proxy_health`, does not spawn subprocess
- `LiteLLMProxyManager._wait_for_proxy_health()` → succeeds when `/health` returns 200
- `LiteLLMProxyManager._wait_for_proxy_health()` timeout → raises `LiteLLMConfigError`
- `KubernetesConfig` with `litellm_enabled=True` → `LiteLLMDeployer` called during deploy

---

### Key design decisions

- **ClusterIP only**: LiteLLM is not exposed externally. All external access goes through the Phase 3 reverse proxy at `/admin/llm/` (admin-gated). Users reach it via their virtual keys injected at walker dispatch.
- **Deterministic URL**: `{app_name}-litellm-service.{namespace}.svc.cluster.local:4000` is known before the pod exists, so it can be injected into the main app Deployment at creation time without a second patch.
- **ConfigMap for config.yaml**: Avoids baking secrets into the image. Provider API keys stay in the K8s Secret and are read by LiteLLM via `os.environ/VAR` refs already in the config YAML.
- **Single replica**: LiteLLM's spend/budget DB is SQLite by default. Multi-replica requires Postgres (out of scope for Phase 4). If needed, Phase 5 can add a `LITELLM_DATABASE_URL` pointing to the existing MongoDB.
- **No ingress rule for LiteLLM**: Phase 3 already provides admin access. Direct LiteLLM UI exposure is unnecessary and a security risk.

---

## Key invariants to preserve

1. **No fallback on proxy errors** — if proxy is active and returns 4xx, raise `LiteLLMAccessError`. Never retry via direct litellm.
2. **Unauthenticated walkers get no LLM access** — `user_llm_key` ContextVar is None → `LiteLLMAccessError` if proxy configured.
3. **`jac start` compatibility** — `user_llm_key` is on base `ExecutionContext`, `spawn_walker` uses duck typing. No jac-scale import in jaclang.
4. **Secrets never in config files** — `${VAR}` → `os.environ/VAR` in litellm config.yaml.
5. **Proxy startup failure is loud** — `LiteLLMConfigError` at server boot, not on first LLM call.
6. **Tests run in scale-first order** — `pytest jac-scale/... jac-byllm/...` (byllm-first causes module reload issue due to scale importing byllm internally).
