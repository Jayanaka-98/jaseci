"""Tests for LiteLLM key lifecycle on user create/delete.

Covers:
- create_user with proxy active → LiteLLM create_user + generate_key called, key stored
- create_user with no proxy → no LiteLLM calls, litellm_key is None in get_user
- create_user proxy error does not block user creation
- delete_user with key → revoke_key + delete_user called on proxy manager
- delete_user with no key → no revoke call, delete_user still called on proxy manager
- delete_user with no proxy → proceeds cleanly
- delete_user proxy error does not block user deletion
- set_litellm_key / get_user round-trip
"""

import os;
import shutil;
import tempfile;
import unittest.mock;
import pytest;
import from typing { Any }

import from jac_scale.litellm_manager { LiteLLMProxyManager }
import from jac_scale.user_manager { JacScaleUserManager }

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

"""Build a mock LiteLLMProxyManager that returns a fixed virtual key."""
def make_mock_manager(key: str = 'sk-virtual-abc') -> Any {
    mgr = unittest.mock.MagicMock();
    mgr.generate_key.return_value = key;
    return mgr;
}

"""Build a JacScaleUserManager backed by SQLite (no Mongo _storage)."""
def make_user_manager(base_path: str) -> JacScaleUserManager {
    um = JacScaleUserManager(base_path=base_path);
    um._storage = None;
    return um;
}

"""Create a user without triggering LiteLLM provisioning."""
def create_user_no_proxy(um: JacScaleUserManager, username: str) -> None {
    with unittest.mock.patch(
        'jac_scale.litellm_manager.get_litellm_proxy_manager', return_value=None
    ) {
        um.create_user(username, 'pass');
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# create_user
# ─────────────────────────────────────────────────────────────────────────────

test "create_user with proxy active provisions LiteLLM key and stores it" {
    tmp = tempfile.mkdtemp();
    try {
        um = make_user_manager(tmp);
        mock_mgr = make_mock_manager('sk-virtual-new');
        with unittest.mock.patch(
            'jac_scale.litellm_manager.get_litellm_proxy_manager', return_value=mock_mgr
        ) {
            result = um.create_user('alice', 'pass123');
            assert 'error' not in result;
            mock_mgr.create_user.assert_called_once_with('alice', limits={});
            mock_mgr.generate_key.assert_called_once_with('alice', limits={});
            user = um.get_user('alice');
            assert user is not None;
            assert user.get('litellm_key') == 'sk-virtual-new';
        }
    } finally {
        shutil.rmtree(tmp, ignore_errors=True);
    }
}

test "create_user with no proxy creates user without litellm_key" {
    tmp = tempfile.mkdtemp();
    try {
        um = make_user_manager(tmp);
        with unittest.mock.patch(
            'jac_scale.litellm_manager.get_litellm_proxy_manager', return_value=None
        ) {
            result = um.create_user('bob', 'pass456');
            assert 'error' not in result;
            user = um.get_user('bob');
            assert user is not None;
            assert user.get('litellm_key') is None;
        }
    } finally {
        shutil.rmtree(tmp, ignore_errors=True);
    }
}

test "create_user proxy error does not prevent user creation" {
    tmp = tempfile.mkdtemp();
    try {
        um = make_user_manager(tmp);
        mock_mgr = unittest.mock.MagicMock();
        mock_mgr.generate_key.side_effect = Exception('proxy down');
        with unittest.mock.patch(
            'jac_scale.litellm_manager.get_litellm_proxy_manager', return_value=mock_mgr
        ) {
            result = um.create_user('charlie', 'pass789');
            assert 'error' not in result;
            assert um.user_exists('charlie');
        }
    } finally {
        shutil.rmtree(tmp, ignore_errors=True);
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# delete_user
# ─────────────────────────────────────────────────────────────────────────────

test "delete_user with key revokes key and deletes LiteLLM user" {
    tmp = tempfile.mkdtemp();
    try {
        um = make_user_manager(tmp);
        create_user_no_proxy(um, 'dave');
        um.set_litellm_key('dave', 'sk-virtual-dave');
        mock_mgr = make_mock_manager();
        with unittest.mock.patch(
            'jac_scale.litellm_manager.get_litellm_proxy_manager', return_value=mock_mgr
        ) {
            um.delete_user('dave');
            mock_mgr.revoke_key.assert_called_once_with('sk-virtual-dave');
            mock_mgr.delete_user.assert_called_once_with('dave');
        }
    } finally {
        shutil.rmtree(tmp, ignore_errors=True);
    }
}

test "delete_user with no key skips revoke but still calls LiteLLM delete_user" {
    tmp = tempfile.mkdtemp();
    try {
        um = make_user_manager(tmp);
        create_user_no_proxy(um, 'eve');
        mock_mgr = make_mock_manager();
        with unittest.mock.patch(
            'jac_scale.litellm_manager.get_litellm_proxy_manager', return_value=mock_mgr
        ) {
            um.delete_user('eve');
            mock_mgr.revoke_key.assert_not_called();
            mock_mgr.delete_user.assert_called_once_with('eve');
        }
    } finally {
        shutil.rmtree(tmp, ignore_errors=True);
    }
}

test "delete_user with no proxy deletes user cleanly" {
    tmp = tempfile.mkdtemp();
    try {
        um = make_user_manager(tmp);
        create_user_no_proxy(um, 'frank');
        with unittest.mock.patch(
            'jac_scale.litellm_manager.get_litellm_proxy_manager', return_value=None
        ) {
            result = um.delete_user('frank');
            assert 'error' not in result;
            assert not um.user_exists('frank');
        }
    } finally {
        shutil.rmtree(tmp, ignore_errors=True);
    }
}

test "delete_user proxy error does not prevent user deletion" {
    tmp = tempfile.mkdtemp();
    try {
        um = make_user_manager(tmp);
        create_user_no_proxy(um, 'grace');
        um.set_litellm_key('grace', 'sk-virtual-grace');
        mock_mgr = unittest.mock.MagicMock();
        mock_mgr.revoke_key.side_effect = Exception('proxy down');
        with unittest.mock.patch(
            'jac_scale.litellm_manager.get_litellm_proxy_manager', return_value=mock_mgr
        ) {
            result = um.delete_user('grace');
            assert 'error' not in result;
            assert not um.user_exists('grace');
        }
    } finally {
        shutil.rmtree(tmp, ignore_errors=True);
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# set_litellm_key / get_user
# ─────────────────────────────────────────────────────────────────────────────

test "set_litellm_key updates stored key and get_user returns it" {
    tmp = tempfile.mkdtemp();
    try {
        um = make_user_manager(tmp);
        create_user_no_proxy(um, 'heidi');
        um.set_litellm_key('heidi', 'sk-new-key');
        user = um.get_user('heidi');
        assert user.get('litellm_key') == 'sk-new-key';
    } finally {
        shutil.rmtree(tmp, ignore_errors=True);
    }
}

test "get_user returns litellm_key field as None when not set" {
    tmp = tempfile.mkdtemp();
    try {
        um = make_user_manager(tmp);
        create_user_no_proxy(um, 'ivan');
        user = um.get_user('ivan');
        assert 'litellm_key' in user;
        assert user['litellm_key'] is None;
    } finally {
        shutil.rmtree(tmp, ignore_errors=True);
    }
}
