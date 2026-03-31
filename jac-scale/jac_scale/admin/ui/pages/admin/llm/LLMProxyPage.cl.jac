"""LLM Proxy management pages — Virtual Keys, Users & Budgets, Spend, Providers."""

cl {
    import from react { useEffect }
    import from ....components.common.Button { Button }
    import from ....components.common.Input { Input }
    import from ....context.AuthContext { useAuth }
    import from ....services.llmProxyService {
        getLLMProxyKeys,
        createLLMProxyKey,
        revokeLLMProxyKey,
        getLLMProxyUsers,
        updateLLMProxyUser,
        getLLMProxySpend,
        setLLMProviderKey
    }

    def fmtBudget(spend: any, maxBudget: any) -> str {
        s = "$" + str(Math.round((spend or 0) * 10000) / 10000);
        if maxBudget {
            return s + " / $" + str(Math.round(maxBudget * 100) / 100);
        }
        return s + " / ∞";
    }

    def fmtLimit(val: any) -> str {
        return str(val) if val else "∞";
    }

    def maskKey(key: any) -> str {
        k = key or "";
        if k.length < 12 {
            return k or "—";
        }
        return k.substring(0, 10) + "···" + k.substring(k.length - 4);
    }

    # ─── Virtual Keys ────────────────────────────────────────────────────────

    def:pub LLMKeysPage -> JsxElement {
        has keys: list = [],
            loading: bool = True,
            errorMsg: str = "",
            showCreate: bool = False,
            newUserId: str = "",
            newMaxBudget: str = "",
            newRpm: str = "",
            newTpm: str = "",
            creating: bool = False,
            successMsg: str = "";

        auth = useAuth();

        async def loadKeys -> None {
            loading = True;
            result = await getLLMProxyKeys(auth["authToken"]);
            if result["ok"] {
                keys = result["data"]["keys"] or [];
                errorMsg = "";
            } else {
                errorMsg = (result["error"]["message"] or "Failed to load keys");
            }
            loading = False;
        }

        useEffect(lambda -> None { loadKeys();}, []);

        async def handleCreate -> None {
            if not newUserId {
                return;
            }
            creating = True;
            successMsg = "";
            body: dict = {"user_id": newUserId};
            if newMaxBudget {
                body["max_budget"] = parseFloat(newMaxBudget);
            }
            if newRpm {
                body["rpm_limit"] = parseInt(newRpm);
            }
            if newTpm {
                body["tpm_limit"] = parseInt(newTpm);
            }
            result = await createLLMProxyKey(auth["authToken"], body);
            if result["ok"] {
                successMsg = "Key created for " + newUserId;
                showCreate = False;
                newUserId = "";
                newMaxBudget = "";
                newRpm = "";
                newTpm = "";
                loadKeys();
            } else {
                errorMsg = (result["error"]["message"] or "Failed to create key");
            }
            creating = False;
        }

        async def handleRevoke(k: str) -> None {
            result = await revokeLLMProxyKey(auth["authToken"], k);
            if result["ok"] {
                successMsg = "Key revoked";
                loadKeys();
            } else {
                errorMsg = (result["error"]["message"] or "Failed to revoke key");
            }
        }

        def makeRevokeHandler(k: str) -> any {
            return lambda e: any -> None { handleRevoke(k);};
        }

        return
            <div className="space-y-4">
                <div className="flex items-center justify-between">
                    <h2 className="text-xl font-bold text-white">
                        Virtual Keys
                    </h2>
                    <Button
                        onClick={lambda -> None { showCreate = not showCreate; errorMsg = ""; successMsg = "";}}
                        variant={showCreate and "secondary" or "primary"}
                    >
                        {showCreate and "Cancel" or "Generate Key"}
                    </Button>
                </div>
                {successMsg and
                    <div className="px-4 py-2 bg-emerald-900/40 border border-emerald-700 rounded text-emerald-300 text-sm">
                        {successMsg}
                    </div>
                }
                {errorMsg and
                    <div className="px-4 py-2 bg-red-900/40 border border-red-700 rounded text-red-300 text-sm">
                        {errorMsg}
                    </div>
                }
                {showCreate and
                    <div className="bg-slate-900 border border-slate-700 rounded-lg p-5 space-y-4">
                        <h3 className="text-sm font-semibold text-white">
                            Generate New Virtual Key
                        </h3>
                        <div className="grid grid-cols-2 gap-4">
                            <Input
                                label="User ID *"
                                value={newUserId}
                                onChange={lambda e: any -> None { newUserId = e.target.value;}}
                                placeholder="username"
                            />
                            <Input
                                label="Max Budget ($)"
                                value={newMaxBudget}
                                onChange={lambda e: any -> None { newMaxBudget = e.target.value;}}
                                placeholder="e.g. 5.00  (blank = unlimited)"
                            />
                            <Input
                                label="RPM Limit"
                                value={newRpm}
                                onChange={lambda e: any -> None { newRpm = e.target.value;}}
                                placeholder="e.g. 60  (blank = unlimited)"
                            />
                            <Input
                                label="TPM Limit"
                                value={newTpm}
                                onChange={lambda e: any -> None { newTpm = e.target.value;}}
                                placeholder="e.g. 100000  (blank = unlimited)"
                            />
                        </div>
                        <div className="flex justify-end">
                            <Button
                                onClick={lambda -> None { handleCreate();}}
                                disabled={creating or not newUserId}
                            >
                                {creating and "Creating..." or "Create Key"}
                            </Button>
                        </div>
                    </div>
                }
                {loading and
                    <div className="text-center py-16 text-slate-500">
                        Loading keys...
                    </div>
                }
                {not loading and
                    <div className="bg-slate-900 border border-slate-800 rounded-lg overflow-hidden">
                        {keys.length == 0 and
                            <div className="text-center py-16 text-slate-500">
                                No virtual keys yet
                            </div>
                        }
                        {keys.length > 0 and
                            <div className="overflow-x-auto">
                                <table className="w-full text-sm">
                                    <thead>
                                        <tr className="text-slate-400 text-xs uppercase border-b border-slate-700">
                                            <th className="text-left px-4 py-3">
                                                Key
                                            </th>
                                            <th className="text-left px-4 py-3">
                                                User
                                            </th>
                                            <th className="text-right px-4 py-3">
                                                Spend / Budget
                                            </th>
                                            <th className="text-right px-4 py-3">
                                                RPM
                                            </th>
                                            <th className="text-right px-4 py-3">
                                                TPM
                                            </th>
                                            <th className="px-4 py-3"></th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {[
                                            <tr
                                                key={k["token"] or k["key"] or k["user_id"] or "k"}
                                                className="border-b border-slate-800 hover:bg-slate-800/40"
                                            >
                                                <td className="px-4 py-3 font-mono text-xs text-teal-300">
                                                    {maskKey(k["key"] or k["token"])}
                                                </td>
                                                <td className="px-4 py-3 text-slate-300">
                                                    {k["user_id"] or "—"}
                                                </td>
                                                <td className="px-4 py-3 text-right text-amber-400">
                                                    {fmtBudget(k["spend"], k["max_budget"])}
                                                </td>
                                                <td className="px-4 py-3 text-right text-slate-400">
                                                    {fmtLimit(k["rpm_limit"])}
                                                </td>
                                                <td className="px-4 py-3 text-right text-slate-400">
                                                    {fmtLimit(k["tpm_limit"])}
                                                </td>
                                                <td className="px-4 py-3 text-right">
                                                    <button
                                                        onClick={makeRevokeHandler(k["key"] or k["token"] or "")}
                                                        className="text-xs text-red-400 hover:text-red-300 transition-colors"
                                                    >
                                                        Revoke
                                                    </button>
                                                </td>
                                            </tr> for k in keys
                                        ]}
                                    </tbody>
                                </table>
                            </div>
                        }
                    </div>
                }
            </div>;
    }

    # ─── Users & Budgets ─────────────────────────────────────────────────────

    def:pub LLMUsersPage -> JsxElement {
        has users: list = [],
            loading: bool = True,
            errorMsg: str = "",
            successMsg: str = "",
            editingUser: str = "",
            editMaxBudget: str = "",
            editDuration: str = "",
            editRpm: str = "",
            editTpm: str = "",
            saving: bool = False;

        auth = useAuth();

        async def loadUsers -> None {
            loading = True;
            result = await getLLMProxyUsers(auth["authToken"]);
            if result["ok"] {
                raw = result["data"];
                users = (
                    raw["users"] if raw and raw["users"]
                    else (raw if Array.isArray(raw) else [])
                );
                errorMsg = "";
            } else {
                errorMsg = (result["error"]["message"] or "Failed to load users");
            }
            loading = False;
        }

        useEffect(lambda -> None { loadUsers();}, []);

        def makeEditHandler(u: dict) -> any {
            return lambda e: any -> None {
                editingUser = u["user_id"] or "";
                editMaxBudget = str(u["max_budget"]) if u["max_budget"] else "";
                editDuration = u["budget_duration"] or "30d";
                editRpm = str(u["rpm_limit"]) if u["rpm_limit"] else "";
                editTpm = str(u["tpm_limit"]) if u["tpm_limit"] else "";
                successMsg = "";
                errorMsg = "";
            };
        }

        async def handleSave -> None {
            if not editingUser {
                return;
            }
            saving = True;
            body: dict = {"user_id": editingUser};
            if editMaxBudget {
                body["max_budget"] = parseFloat(editMaxBudget);
            }
            if editDuration {
                body["budget_duration"] = editDuration;
            }
            if editRpm {
                body["rpm_limit"] = parseInt(editRpm);
            }
            if editTpm {
                body["tpm_limit"] = parseInt(editTpm);
            }
            result = await updateLLMProxyUser(auth["authToken"], body);
            if result["ok"] {
                successMsg = "Updated " + editingUser;
                editingUser = "";
                loadUsers();
            } else {
                errorMsg = (result["error"]["message"] or "Failed to update user");
            }
            saving = False;
        }

        return
            <div className="space-y-4">
                <div className="flex items-center justify-between">
                    <h2 className="text-xl font-bold text-white">
                        Users & Budgets
                    </h2>
                    <Button onClick={lambda -> None { loadUsers();}} variant="secondary">
                        Refresh
                    </Button>
                </div>
                {successMsg and
                    <div className="px-4 py-2 bg-emerald-900/40 border border-emerald-700 rounded text-emerald-300 text-sm">
                        {successMsg}
                    </div>
                }
                {errorMsg and
                    <div className="px-4 py-2 bg-red-900/40 border border-red-700 rounded text-red-300 text-sm">
                        {errorMsg}
                    </div>
                }
                {editingUser and
                    <div className="bg-slate-900 border border-violet-700/50 rounded-lg p-5 space-y-4">
                        <h3 className="text-sm font-semibold text-violet-300">
                            {"Editing limits for: " + editingUser}
                        </h3>
                        <div className="grid grid-cols-2 gap-4">
                            <Input
                                label="Max Budget ($)"
                                value={editMaxBudget}
                                onChange={lambda e: any -> None { editMaxBudget = e.target.value;}}
                                placeholder="e.g. 5.00  (blank = unlimited)"
                            />
                            <Input
                                label="Budget Duration"
                                value={editDuration}
                                onChange={lambda e: any -> None { editDuration = e.target.value;}}
                                placeholder="e.g. 30d, 7d, 1mo"
                            />
                            <Input
                                label="RPM Limit"
                                value={editRpm}
                                onChange={lambda e: any -> None { editRpm = e.target.value;}}
                                placeholder="e.g. 60  (blank = unlimited)"
                            />
                            <Input
                                label="TPM Limit"
                                value={editTpm}
                                onChange={lambda e: any -> None { editTpm = e.target.value;}}
                                placeholder="e.g. 100000  (blank = unlimited)"
                            />
                        </div>
                        <div className="flex justify-end gap-2">
                            <Button
                                onClick={lambda -> None { editingUser = "";}}
                                variant="secondary"
                            >
                                Cancel
                            </Button>
                            <Button
                                onClick={lambda -> None { handleSave();}}
                                disabled={saving}
                            >
                                {saving and "Saving..." or "Save Changes"}
                            </Button>
                        </div>
                    </div>
                }
                {loading and
                    <div className="text-center py-16 text-slate-500">
                        Loading users...
                    </div>
                }
                {not loading and
                    <div className="bg-slate-900 border border-slate-800 rounded-lg overflow-hidden">
                        {users.length == 0 and
                            <div className="text-center py-16 text-slate-500">
                                No users found
                            </div>
                        }
                        {users.length > 0 and
                            <div className="overflow-x-auto">
                                <table className="w-full text-sm">
                                    <thead>
                                        <tr className="text-slate-400 text-xs uppercase border-b border-slate-700">
                                            <th className="text-left px-4 py-3">
                                                User ID
                                            </th>
                                            <th className="text-right px-4 py-3">
                                                Spend / Budget
                                            </th>
                                            <th className="text-right px-4 py-3">
                                                Duration
                                            </th>
                                            <th className="text-right px-4 py-3">
                                                RPM
                                            </th>
                                            <th className="text-right px-4 py-3">
                                                TPM
                                            </th>
                                            <th className="px-4 py-3"></th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {[
                                            <tr
                                                key={u["user_id"] or u["email"] or "u"}
                                                className="border-b border-slate-800 hover:bg-slate-800/40"
                                            >
                                                <td className="px-4 py-3 font-mono text-xs text-purple-300">
                                                    {u["user_id"] or "—"}
                                                </td>
                                                <td className="px-4 py-3 text-right text-amber-400">
                                                    {fmtBudget(u["spend"], u["max_budget"])}
                                                </td>
                                                <td className="px-4 py-3 text-right text-slate-400">
                                                    {u["budget_duration"] or "—"}
                                                </td>
                                                <td className="px-4 py-3 text-right text-slate-400">
                                                    {fmtLimit(u["rpm_limit"])}
                                                </td>
                                                <td className="px-4 py-3 text-right text-slate-400">
                                                    {fmtLimit(u["tpm_limit"])}
                                                </td>
                                                <td className="px-4 py-3 text-right">
                                                    <button
                                                        onClick={makeEditHandler(u)}
                                                        className="text-xs text-violet-400 hover:text-violet-300 transition-colors"
                                                    >
                                                        Edit
                                                    </button>
                                                </td>
                                            </tr> for u in users
                                        ]}
                                    </tbody>
                                </table>
                            </div>
                        }
                    </div>
                }
            </div>;
    }

    # ─── Spend Overview ───────────────────────────────────────────────────────

    def:pub LLMSpendPage -> JsxElement {
        has spendData: dict = {},
            loading: bool = True,
            errorMsg: str = "";

        auth = useAuth();

        async def loadSpend -> None {
            loading = True;
            result = await getLLMProxySpend(auth["authToken"]);
            if result["ok"] {
                spendData = result["data"] or {};
                errorMsg = "";
            } else {
                errorMsg = (result["error"]["message"] or "Failed to load spend data");
            }
            loading = False;
        }

        useEffect(lambda -> None { loadSpend();}, []);

        usersRaw = spendData["users"] or {};
        keysRaw = spendData["keys"] or {};
        userList = (
            usersRaw["users"] if usersRaw and usersRaw["users"]
            else (usersRaw if Array.isArray(usersRaw) else [])
        );
        keyList = (
            keysRaw["keys"] if keysRaw and keysRaw["keys"]
            else (keysRaw if Array.isArray(keysRaw) else [])
        );

        sortedUsers = userList.slice().sort(lambda a: any, b: any -> any {
            return (b["spend"] or 0) - (a["spend"] or 0);
        });
        sortedKeys = keyList.slice().sort(lambda a: any, b: any -> any {
            return (b["spend"] or 0) - (a["spend"] or 0);
        });

        return
            <div className="space-y-6">
                <div className="flex items-center justify-between">
                    <h2 className="text-xl font-bold text-white">
                        Spend Overview
                    </h2>
                    <Button onClick={lambda -> None { loadSpend();}} variant="secondary">
                        Refresh
                    </Button>
                </div>
                {errorMsg and
                    <div className="px-4 py-2 bg-red-900/40 border border-red-700 rounded text-red-300 text-sm">
                        {errorMsg}
                    </div>
                }
                {loading and
                    <div className="text-center py-16 text-slate-500">
                        Loading spend data...
                    </div>
                }
                {not loading and
                    <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
                        <div className="bg-slate-900 border border-slate-800 rounded-lg overflow-hidden">
                            <div className="px-4 py-3 border-b border-slate-800">
                                <h3 className="text-sm font-semibold text-white">
                                    Spend by User
                                </h3>
                            </div>
                            {sortedUsers.length == 0 and
                                <div className="text-center py-10 text-slate-500 text-sm">
                                    No user spend data
                                </div>
                            }
                            {sortedUsers.length > 0 and
                                <table className="w-full text-sm">
                                    <thead>
                                        <tr className="text-slate-400 text-xs uppercase border-b border-slate-700">
                                            <th className="text-left px-4 py-3">
                                                User
                                            </th>
                                            <th className="text-right px-4 py-3">
                                                Spend
                                            </th>
                                            <th className="text-right px-4 py-3">
                                                Budget
                                            </th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {[
                                            <tr
                                                key={u["user_id"] or u["email"] or "u"}
                                                className="border-b border-slate-800"
                                            >
                                                <td className="px-4 py-3 font-mono text-xs text-purple-300">
                                                    {u["user_id"] or "—"}
                                                </td>
                                                <td className="px-4 py-3 text-right text-amber-400">
                                                    {"$" + str(Math.round((u["spend"] or 0) * 10000) / 10000)}
                                                </td>
                                                <td className="px-4 py-3 text-right text-slate-400">
                                                    {u["max_budget"] and ("$" + str(u["max_budget"])) or "∞"}
                                                </td>
                                            </tr> for u in sortedUsers
                                        ]}
                                    </tbody>
                                </table>
                            }
                        </div>
                        <div className="bg-slate-900 border border-slate-800 rounded-lg overflow-hidden">
                            <div className="px-4 py-3 border-b border-slate-800">
                                <h3 className="text-sm font-semibold text-white">
                                    Spend by Key
                                </h3>
                            </div>
                            {sortedKeys.length == 0 and
                                <div className="text-center py-10 text-slate-500 text-sm">
                                    No key spend data
                                </div>
                            }
                            {sortedKeys.length > 0 and
                                <table className="w-full text-sm">
                                    <thead>
                                        <tr className="text-slate-400 text-xs uppercase border-b border-slate-700">
                                            <th className="text-left px-4 py-3">
                                                Key
                                            </th>
                                            <th className="text-left px-4 py-3">
                                                User
                                            </th>
                                            <th className="text-right px-4 py-3">
                                                Spend
                                            </th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {[
                                            <tr
                                                key={k["token"] or k["key"] or k["user_id"] or "k"}
                                                className="border-b border-slate-800"
                                            >
                                                <td className="px-4 py-3 font-mono text-xs text-teal-300">
                                                    {maskKey(k["key"] or k["token"])}
                                                </td>
                                                <td className="px-4 py-3 text-slate-400 text-xs">
                                                    {k["user_id"] or "—"}
                                                </td>
                                                <td className="px-4 py-3 text-right text-amber-400">
                                                    {"$" + str(Math.round((k["spend"] or 0) * 10000) / 10000)}
                                                </td>
                                            </tr> for k in sortedKeys
                                        ]}
                                    </tbody>
                                </table>
                            }
                        </div>
                    </div>
                }
            </div>;
    }

    # ─── Provider API Keys ────────────────────────────────────────────────────

    def:pub LLMProvidersPage -> JsxElement {
        has values: dict = {},
            saving: str = "",
            results: dict = {};

        auth = useAuth();

        providers = [
            {"key": "OPENAI_API_KEY", "label": "OpenAI", "placeholder": "sk-..."},
            {"key": "ANTHROPIC_API_KEY", "label": "Anthropic", "placeholder": "sk-ant-..."},
            {"key": "GEMINI_API_KEY", "label": "Google Gemini", "placeholder": "AIza..."},
            {"key": "GROQ_API_KEY", "label": "Groq", "placeholder": "gsk_..."},
            {"key": "AZURE_API_KEY", "label": "Azure OpenAI", "placeholder": "..."},
            {"key": "COHERE_API_KEY", "label": "Cohere", "placeholder": "..."}
        ];

        def makeSetHandler(providerKey: str) -> any {
            return lambda e: any -> None { handleSet(providerKey);};
        }

        def makeChangeHandler(providerKey: str) -> any {
            return lambda e: any -> None {
                values[providerKey] = e.target.value;
                results[providerKey] = "";
            };
        }

        async def handleSet(providerKey: str) -> None {
            val = values[providerKey] or "";
            if not val {
                return;
            }
            saving = providerKey;
            result = await setLLMProviderKey(auth["authToken"], providerKey, val);
            if result["ok"] {
                results[providerKey] = "ok";
                values[providerKey] = "";
            } else {
                results[providerKey] = (result["error"]["message"] or "Failed");
            }
            saving = "";
        }

        return
            <div className="space-y-4">
                <div>
                    <h2 className="text-xl font-bold text-white">
                        Provider API Keys
                    </h2>
                    <p className="text-sm text-slate-500 mt-1">
                        Keys are applied to the running process only and not persisted to disk. Restart will require re-entry.
                    </p>
                </div>
                <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                    {[
                        <div
                            key={p["key"]}
                            className="bg-slate-900 border border-slate-800 rounded-lg p-4 space-y-3"
                        >
                            <div className="flex items-center justify-between">
                                <span className="text-sm font-medium text-white">
                                    {p["label"]}
                                </span>
                                {results[p["key"]] == "ok" and
                                    <span className="text-xs text-emerald-400">
                                        Set
                                    </span>
                                }
                                {results[p["key"]] and results[p["key"]] != "ok" and
                                    <span className="text-xs text-red-400">
                                        {results[p["key"]]}
                                    </span>
                                }
                            </div>
                            <p className="text-xs text-slate-500 font-mono">
                                {p["key"]}
                            </p>
                            <div className="flex gap-2">
                                <input
                                    type="password"
                                    value={values[p["key"]] or ""}
                                    onChange={makeChangeHandler(p["key"])}
                                    placeholder={p["placeholder"]}
                                    className="flex-1 px-3 py-1.5 bg-slate-950 border border-slate-700 rounded text-white text-sm focus:outline-none focus:border-teal-500"
                                />
                                <button
                                    onClick={makeSetHandler(p["key"])}
                                    disabled={saving == p["key"] or not (values[p["key"]] or "")}
                                    className="px-3 py-1.5 bg-teal-700 hover:bg-teal-600 disabled:opacity-40 text-white text-xs rounded transition-colors"
                                >
                                    {saving == p["key"] and "..." or "Set"}
                                </button>
                            </div>
                        </div> for p in providers
                    ]}
                </div>
            </div>;
    }
}
