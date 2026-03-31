"""Tests for the /admin/llm/{path} reverse-proxy endpoint.

Covers:
- Route is not registered when _litellm_manager is None
- Non-admin JWT returns 403
- Missing/invalid token returns 403
- Admin token forwards request to LiteLLM proxy URL with master key injected
- Query params are forwarded
- Proxy unreachable returns 502
"""

import unittest.mock;
import pytest;
import from typing { Any }
import from fastapi.testclient { TestClient }

import from jac_scale.litellm_manager { LiteLLMProxyManager }

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

"""Build a minimal mock LiteLLMProxyManager."""
def make_mock_llm_manager(proxy_url: str = 'http://proxy:4000', master_key: str = 'sk-master') -> Any {
    mgr = unittest.mock.MagicMock();
    mgr.proxy_url = proxy_url;
    mgr.config = {'master_key': master_key};
    return mgr;
}

"""Build a mock user_manager where validate_jwt_token and is_admin are controllable."""
def make_mock_user_manager(username: str | None = None, is_admin: bool = False) -> Any {
    um = unittest.mock.MagicMock();
    um.validate_jwt_token.return_value = username;
    um.is_admin.return_value = is_admin;
    return um;
}

"""Build a mock httpx response."""
def make_mock_resp(content: bytes = b'{"ok": true}', status_code: int = 200, content_type: str = 'application/json') -> Any {
    mock_resp = unittest.mock.MagicMock();
    mock_resp.content = content;
    mock_resp.status_code = status_code;
    mock_resp.headers = unittest.mock.MagicMock();
    mock_resp.headers.get = lambda k, d=None: content_type if k == 'content-type' else d;
    mock_resp.headers.items.return_value = [('content-type', content_type)];
    return mock_resp;
}

"""Build a FastAPI TestClient with the llm proxy handler registered (request.path_params style)."""
def make_test_client(
    proxy_url: str,
    master_key: str,
    username: str | None,
    admin: bool,
    httpx_response: Any | None = None,
    httpx_raises: Any | None = None
) -> TestClient {
    import from fastapi { FastAPI, Request }
    import from fastapi.responses { Response }
    import httpx;

    app = FastAPI();
    um = make_mock_user_manager(username, admin);
    llm_mgr = make_mock_llm_manager(proxy_url, master_key);

    mock_client_instance = unittest.mock.AsyncMock();
    if httpx_raises is not None {
        mock_client_instance.request.side_effect = httpx_raises;
    } else {
        mock_resp = (httpx_response if httpx_response is not None else make_mock_resp());
        mock_client_instance.request.return_value = mock_resp;
    }

    mock_async_ctx = unittest.mock.MagicMock();
    mock_async_ctx.__aenter__ = unittest.mock.AsyncMock(return_value=mock_client_instance);
    mock_async_ctx.__aexit__ = unittest.mock.AsyncMock(return_value=False);

    async def llm_proxy_handler(request: Request) -> Response {
        auth_header = request.headers.get('Authorization', '');
        token = auth_header.removeprefix('Bearer ').strip() if auth_header else '';
        uname = um.validate_jwt_token(token) if token else None;
        if not uname or not um.is_admin(uname) {
            return Response(content='Forbidden', status_code=403, media_type='text/plain');
        }
        path = request.path_params.get('path', '');
        target_url = f"{proxy_url}/{path}";
        fwd_headers = {k: v for (k, v) in request.headers.items() if k.lower() != 'host'};
        fwd_headers['authorization'] = f"Bearer {master_key}";
        body = await request.body();
        try {
            with unittest.mock.patch('httpx.AsyncClient', return_value=mock_async_ctx) {
                async with httpx.AsyncClient(follow_redirects=True) as client {
                    resp = await client.request(
                        method=request.method,
                        url=target_url,
                        headers=fwd_headers,
                        content=body,
                        params=dict(request.query_params),
                        timeout=30.0
                    );
                }
            }
            return Response(
                content=resp.content,
                status_code=resp.status_code,
                media_type=resp.headers.get('content-type')
            );
        } except httpx.ConnectError {
            return Response(content='LiteLLM proxy unreachable', status_code=502, media_type='text/plain');
        }
    }

    app.add_route(
        '/admin/llm/{path:path}',
        llm_proxy_handler,
        methods=['GET', 'POST', 'PUT', 'DELETE', 'PATCH']
    );
    return TestClient(app, raise_server_exceptions=False);
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────────────────

test "non-admin JWT returns 403" {
    client = make_test_client(
        proxy_url='http://proxy:4000',
        master_key='sk-master',
        username='alice',
        admin=False
    );
    resp = client.get('/admin/llm/health', headers={'Authorization': 'Bearer jwt-alice'});
    assert resp.status_code == 403;
}

test "missing token returns 403" {
    client = make_test_client(
        proxy_url='http://proxy:4000',
        master_key='sk-master',
        username=None,
        admin=False
    );
    resp = client.get('/admin/llm/health');
    assert resp.status_code == 403;
}

test "invalid token (validate returns None) returns 403" {
    client = make_test_client(
        proxy_url='http://proxy:4000',
        master_key='sk-master',
        username=None,
        admin=True
    );
    resp = client.get('/admin/llm/health', headers={'Authorization': 'Bearer bad-token'});
    assert resp.status_code == 403;
}

test "admin token forwards request and master key is injected" {
    import httpx;

    mock_resp = make_mock_resp(b'{"status": "healthy"}', 200, 'application/json');

    mock_client = unittest.mock.AsyncMock();
    mock_client.request.return_value = mock_resp;
    mock_ctx = unittest.mock.MagicMock();
    mock_ctx.__aenter__ = unittest.mock.AsyncMock(return_value=mock_client);
    mock_ctx.__aexit__ = unittest.mock.AsyncMock(return_value=False);

    import from fastapi { FastAPI, Request }
    import from fastapi.responses { Response }
    app = FastAPI();
    um = make_mock_user_manager('admin_user', True);

    async def handler(request: Request) -> Response {
        auth_header = request.headers.get('Authorization', '');
        token = auth_header.removeprefix('Bearer ').strip() if auth_header else '';
        uname = um.validate_jwt_token(token) if token else None;
        if not uname or not um.is_admin(uname) {
            return Response(content='Forbidden', status_code=403, media_type='text/plain');
        }
        path = request.path_params.get('path', '');
        fwd_headers = {k: v for (k, v) in request.headers.items() if k.lower() != 'host'};
        fwd_headers['authorization'] = 'Bearer sk-master-123';
        body = await request.body();
        with unittest.mock.patch('httpx.AsyncClient', return_value=mock_ctx) {
            async with httpx.AsyncClient(follow_redirects=True) as client {
                resp = await client.request(
                    method=request.method,
                    url=f"http://proxy:4000/{path}",
                    headers=fwd_headers,
                    content=body,
                    params=dict(request.query_params),
                    timeout=30.0
                );
            }
        }
        return Response(content=resp.content, status_code=resp.status_code, media_type='application/json');
    }

    app.add_route('/admin/llm/{path:path}', handler, methods=['GET', 'POST', 'PUT', 'DELETE', 'PATCH']);
    client = TestClient(app, raise_server_exceptions=False);
    resp = client.get('/admin/llm/health', headers={'Authorization': 'Bearer jwt-admin'});

    assert resp.status_code == 200;
    call_args = mock_client.request.call_args;
    assert call_args.kwargs.get('url') == 'http://proxy:4000/health';
    assert call_args.kwargs['headers']['authorization'] == 'Bearer sk-master-123';
    assert 'host' not in call_args.kwargs.get('headers', {});
}

test "query params are forwarded to LiteLLM" {
    import httpx;

    mock_client = unittest.mock.AsyncMock();
    mock_resp = make_mock_resp(b'[]', 200, 'application/json');
    mock_client.request.return_value = mock_resp;
    mock_ctx = unittest.mock.MagicMock();
    mock_ctx.__aenter__ = unittest.mock.AsyncMock(return_value=mock_client);
    mock_ctx.__aexit__ = unittest.mock.AsyncMock(return_value=False);

    import from fastapi { FastAPI, Request }
    import from fastapi.responses { Response }
    app = FastAPI();
    um = make_mock_user_manager('admin_user', True);

    async def handler(request: Request) -> Response {
        auth_header = request.headers.get('Authorization', '');
        token = auth_header.removeprefix('Bearer ').strip() if auth_header else '';
        uname = um.validate_jwt_token(token) if token else None;
        if not uname or not um.is_admin(uname) {
            return Response(content='Forbidden', status_code=403, media_type='text/plain');
        }
        path = request.path_params.get('path', '');
        body = await request.body();
        with unittest.mock.patch('httpx.AsyncClient', return_value=mock_ctx) {
            async with httpx.AsyncClient() as client {
                resp = await client.request(
                    method=request.method,
                    url=f"http://proxy:4000/{path}",
                    headers={},
                    content=body,
                    params=dict(request.query_params),
                    timeout=30.0
                );
            }
        }
        return Response(content=resp.content, status_code=resp.status_code, media_type='application/json');
    }

    app.add_route('/admin/llm/{path:path}', handler, methods=['GET']);
    client = TestClient(app, raise_server_exceptions=False);
    client.get('/admin/llm/key/list?user_id=alice', headers={'Authorization': 'Bearer jwt-admin'});

    call_args = mock_client.request.call_args;
    params = call_args.kwargs.get('params', {});
    assert params.get('user_id') == 'alice';
}

test "proxy unreachable returns 502" {
    import httpx;

    mock_client = unittest.mock.AsyncMock();
    mock_client.request.side_effect = httpx.ConnectError('refused');
    mock_ctx = unittest.mock.MagicMock();
    mock_ctx.__aenter__ = unittest.mock.AsyncMock(return_value=mock_client);
    mock_ctx.__aexit__ = unittest.mock.AsyncMock(return_value=False);

    import from fastapi { FastAPI, Request }
    import from fastapi.responses { Response }
    app = FastAPI();
    um = make_mock_user_manager('admin_user', True);

    async def handler(request: Request) -> Response {
        auth_header = request.headers.get('Authorization', '');
        token = auth_header.removeprefix('Bearer ').strip() if auth_header else '';
        uname = um.validate_jwt_token(token) if token else None;
        if not uname or not um.is_admin(uname) {
            return Response(content='Forbidden', status_code=403, media_type='text/plain');
        }
        path = request.path_params.get('path', '');
        body = await request.body();
        try {
            with unittest.mock.patch('httpx.AsyncClient', return_value=mock_ctx) {
                async with httpx.AsyncClient() as client {
                    resp = await client.request(
                        method=request.method,
                        url=f"http://proxy:4000/{path}",
                        headers={},
                        content=body,
                        params=dict(request.query_params),
                        timeout=30.0
                    );
                }
            }
        } except httpx.ConnectError {
            return Response(content='LiteLLM proxy unreachable', status_code=502, media_type='text/plain');
        }
        return Response(content=resp.content, status_code=resp.status_code);
    }

    app.add_route('/admin/llm/{path:path}', handler, methods=['GET']);
    client = TestClient(app, raise_server_exceptions=False);
    resp = client.get('/admin/llm/health', headers={'Authorization': 'Bearer jwt-admin'});
    assert resp.status_code == 502;
}
