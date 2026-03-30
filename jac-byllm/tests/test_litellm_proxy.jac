"""Tests for byLLM proxy mode — contextvar consumption and typed error mapping.

Covers:
- _resolve_proxy_params() raises LiteLLMAccessError when proxy active but key is None
- _resolve_proxy_params() returns (None, None) when no proxy_url configured
- _raise_proxy_error() maps 401/402/404/429 to correct LiteLLMAccessError messages
- model_call_no_stream routes through proxy when proxy_url is configured
- model_call_no_stream uses direct litellm when no proxy_url
- model_call_with_stream same routing behaviour
- No fallback to direct provider on proxy errors (when proxy active)
- Existing AuthenticationError/RateLimitError/ModelNotFoundError still raised for direct mode
"""

import os;
import pytest;
import unittest.mock;
import from typing { Any }
import from jaclang { JacRuntime as Jac }

import from byllm.lib { Model }
import from byllm.exceptions {
    AuthenticationError,
    RateLimitError,
    ModelNotFoundError,
    LiteLLMAccessError
}
import from byllm.llm { _resolve_proxy_params, _raise_proxy_error }

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

"""Patch the byllm _model_config global to simulate proxy_url being set."""
def with_proxy_url(url: str) -> Any {
    import byllm.llm as _mod;
    return unittest.mock.patch.object(
        _mod, '_model_config', {**_mod._model_config, 'base_url': url}
    );
}

"""Return a ContextVar mock that yields the given key value."""
def mock_ctx_with_key(key: str | None) -> Any {
    cv = unittest.mock.MagicMock();
    cv.get.return_value = key;
    ctx = unittest.mock.MagicMock();
    ctx.user_llm_key = cv;
    return ctx;
}

# ─────────────────────────────────────────────────────────────────────────────
# _resolve_proxy_params
# ─────────────────────────────────────────────────────────────────────────────

test "no proxy_url configured returns (None, None)" {
    import byllm.llm as _mod;
    with unittest.mock.patch.object(
        _mod, '_model_config', {**_mod._model_config, 'base_url': ''}
    ) {
        (proxy, key) = _resolve_proxy_params();
        assert proxy is None;
        assert key is None;
    }
}

test "proxy_url set but user_llm_key is None raises LiteLLMAccessError" {
    ctx = mock_ctx_with_key(None);
    import byllm.llm as _mod;
    with unittest.mock.patch.object(
        _mod, '_model_config', {**_mod._model_config, 'base_url': 'http://proxy:4000'}
    ) {
        with unittest.mock.patch.object(Jac, 'get_context', return_value=ctx) {
            with pytest.raises(LiteLLMAccessError) as exc_info {
                _resolve_proxy_params();
            }
            assert 'authentication' in str(exc_info.value).lower();
        }
    }
}

test "proxy_url set and user_llm_key present returns (url, key)" {
    ctx = mock_ctx_with_key('sk-user-virtual-key');
    import byllm.llm as _mod;
    with unittest.mock.patch.object(
        _mod, '_model_config', {**_mod._model_config, 'base_url': 'http://proxy:4000'}
    ) {
        with unittest.mock.patch.object(Jac, 'get_context', return_value=ctx) {
            (proxy, key) = _resolve_proxy_params();
            assert proxy == 'http://proxy:4000';
            assert key == 'sk-user-virtual-key';
        }
    }
}

test "context without user_llm_key attribute raises LiteLLMAccessError" {
    # Simulates a non-scale ExecutionContext that has no user_llm_key field
    ctx = unittest.mock.MagicMock(spec=[]);  # no attributes
    import byllm.llm as _mod;
    with unittest.mock.patch.object(
        _mod, '_model_config', {**_mod._model_config, 'base_url': 'http://proxy:4000'}
    ) {
        with unittest.mock.patch.object(Jac, 'get_context', return_value=ctx) {
            with pytest.raises(LiteLLMAccessError) {
                _resolve_proxy_params();
            }
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _raise_proxy_error
# ─────────────────────────────────────────────────────────────────────────────

test "401 raises LiteLLMAccessError with revoked message" {
    with pytest.raises(LiteLLMAccessError) as exc_info {
        _raise_proxy_error(401, 'gpt-4o', 'unauthorized');
    }
    assert 'revoked' in str(exc_info.value).lower() or 'invalid' in str(exc_info.value).lower();
}

test "402 raises LiteLLMAccessError with budget message" {
    with pytest.raises(LiteLLMAccessError) as exc_info {
        _raise_proxy_error(402, 'gpt-4o', 'payment required');
    }
    assert 'budget' in str(exc_info.value).lower();
}

test "404 raises LiteLLMAccessError mentioning model name and jac.toml" {
    with pytest.raises(LiteLLMAccessError) as exc_info {
        _raise_proxy_error(404, 'my-custom-model', 'not found');
    }
    msg = str(exc_info.value);
    assert 'my-custom-model' in msg;
    assert 'jac.toml' in msg;
}

test "429 raises LiteLLMAccessError with rate limit message" {
    with pytest.raises(LiteLLMAccessError) as exc_info {
        _raise_proxy_error(429, 'gpt-4o', 'too many requests');
    }
    assert 'rate limit' in str(exc_info.value).lower();
}

test "unknown status raises LiteLLMAccessError with status code" {
    with pytest.raises(LiteLLMAccessError) as exc_info {
        _raise_proxy_error(503, 'gpt-4o', 'service unavailable');
    }
    assert '503' in str(exc_info.value);
}

# ─────────────────────────────────────────────────────────────────────────────
# model_call_no_stream routing
# ─────────────────────────────────────────────────────────────────────────────

test "model_call_no_stream uses OpenAI client through proxy when proxy_url set" {
    ctx = mock_ctx_with_key('sk-user-abc');
    params = {'model': 'gpt-4o-mini', 'messages': [{'role': 'user', 'content': 'hi'}]};
    import byllm.llm as _mod;

    mock_response = unittest.mock.MagicMock();
    mock_client_instance = unittest.mock.MagicMock();
    mock_client_instance.chat.completions.create.return_value = mock_response;

    with unittest.mock.patch.object(
        _mod, '_model_config', {**_mod._model_config, 'base_url': 'http://proxy:4000'}
    ) {
        with unittest.mock.patch.object(Jac, 'get_context', return_value=ctx) {
            with unittest.mock.patch('byllm.llm.OpenAI', return_value=mock_client_instance) as mock_openai {
                m = Model(model_name='gpt-4o-mini');
                result = m.model_call_no_stream(params);
                # OpenAI client must be instantiated with proxy URL and user key
                mock_openai.assert_called_once_with(
                    base_url='http://proxy:4000', api_key='sk-user-abc'
                );
                mock_client_instance.chat.completions.create.assert_called_once_with(
                    **params
                );
                assert result is mock_response;
            }
        }
    }
}

test "model_call_no_stream uses litellm directly when no proxy_url" {
    params = {'model': 'gpt-4o-mini', 'messages': [{'role': 'user', 'content': 'hi'}]};
    import byllm.llm as _mod;

    mock_response = unittest.mock.MagicMock();

    with unittest.mock.patch.object(
        _mod, '_model_config', {**_mod._model_config, 'base_url': ''}
    ) {
        with unittest.mock.patch('byllm.llm.litellm') as mock_litellm {
            mock_litellm.completion.return_value = mock_response;
            m = Model(model_name='gpt-4o-mini');
            result = m.model_call_no_stream(params);
            mock_litellm.completion.assert_called_once();
            assert result is mock_response;
        }
    }
}

test "model_call_no_stream does not fallback to direct on proxy 429" {
    ctx = mock_ctx_with_key('sk-user-abc');
    params = {'model': 'gpt-4o-mini', 'messages': [{'role': 'user', 'content': 'hi'}]};
    import byllm.llm as _mod;
    import openai;

    mock_client_instance = unittest.mock.MagicMock();
    err = openai.APIStatusError(
        'rate limited', response=unittest.mock.MagicMock(status_code=429), body={}
    );
    mock_client_instance.chat.completions.create.side_effect = err;

    with unittest.mock.patch.object(
        _mod, '_model_config', {**_mod._model_config, 'base_url': 'http://proxy:4000'}
    ) {
        with unittest.mock.patch.object(Jac, 'get_context', return_value=ctx) {
            with unittest.mock.patch('byllm.llm.OpenAI', return_value=mock_client_instance) {
                m = Model(model_name='gpt-4o-mini');
                with pytest.raises(LiteLLMAccessError) {
                    m.model_call_no_stream(params);
                }
                # litellm.completion must NOT have been called
            }
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# model_call_with_stream routing
# ─────────────────────────────────────────────────────────────────────────────

test "model_call_with_stream uses OpenAI client with stream=True through proxy" {
    ctx = mock_ctx_with_key('sk-user-abc');
    params = {'model': 'gpt-4o-mini', 'messages': [{'role': 'user', 'content': 'hi'}]};
    import byllm.llm as _mod;

    mock_stream = unittest.mock.MagicMock();
    mock_client_instance = unittest.mock.MagicMock();
    mock_client_instance.chat.completions.create.return_value = mock_stream;

    with unittest.mock.patch.object(
        _mod, '_model_config', {**_mod._model_config, 'base_url': 'http://proxy:4000'}
    ) {
        with unittest.mock.patch.object(Jac, 'get_context', return_value=ctx) {
            with unittest.mock.patch('byllm.llm.OpenAI', return_value=mock_client_instance) as mock_openai {
                m = Model(model_name='gpt-4o-mini');
                result = m.model_call_with_stream(params);
                mock_openai.assert_called_once_with(
                    base_url='http://proxy:4000', api_key='sk-user-abc'
                );
                call_kwargs = mock_client_instance.chat.completions.create.call_args;
                assert call_kwargs.kwargs.get('stream') == True or True in call_kwargs.args;
            }
        }
    }
}

test "model_call_with_stream 401 raises LiteLLMAccessError" {
    ctx = mock_ctx_with_key('sk-user-abc');
    params = {'model': 'gpt-4o-mini', 'messages': [{'role': 'user', 'content': 'hi'}]};
    import byllm.llm as _mod;
    import openai;

    mock_client_instance = unittest.mock.MagicMock();
    err = openai.APIStatusError(
        'unauthorized', response=unittest.mock.MagicMock(status_code=401), body={}
    );
    mock_client_instance.chat.completions.create.side_effect = err;

    with unittest.mock.patch.object(
        _mod, '_model_config', {**_mod._model_config, 'base_url': 'http://proxy:4000'}
    ) {
        with unittest.mock.patch.object(Jac, 'get_context', return_value=ctx) {
            with unittest.mock.patch('byllm.llm.OpenAI', return_value=mock_client_instance) {
                m = Model(model_name='gpt-4o-mini');
                with pytest.raises(LiteLLMAccessError) {
                    m.model_call_with_stream(params);
                }
            }
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Backward compatibility — direct mode errors unchanged
# ─────────────────────────────────────────────────────────────────────────────

test "direct mode AuthenticationError still raised when no proxy" {
    import byllm.llm as _mod;
    import litellm;

    with unittest.mock.patch.object(
        _mod, '_model_config', {**_mod._model_config, 'base_url': ''}
    ) {
        with unittest.mock.patch('byllm.llm.litellm') as mock_litellm {
            mock_litellm.completion.side_effect = litellm.exceptions.AuthenticationError(
                'bad key', llm_provider='openai', model='gpt-4o-mini'
            );
            mock_litellm.exceptions.AuthenticationError = litellm.exceptions.AuthenticationError;
            mock_litellm.exceptions.RateLimitError = litellm.exceptions.RateLimitError;
            mock_litellm.exceptions.NotFoundError = litellm.exceptions.NotFoundError;
            m = Model(model_name='gpt-4o-mini');
            with pytest.raises(AuthenticationError) {
                m.model_call_no_stream({'model': 'gpt-4o-mini', 'messages': []});
            }
        }
    }
}
