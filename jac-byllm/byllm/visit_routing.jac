"""LLM-guided `visit [-->] by llm(...)` routing.

Each candidate is normalised into an (edge, node) pair relative to the current
node, rendered alongside the walker's intent and state, and the model's choice is
constrained to a runtime-synthesised handle enum that maps back to nodes to visit.
"""

import enum;
import re;
import from dataclasses { fields, is_dataclass }
import from loguru { logger }


"""Compile-time MTIR ClassInfo (semstr + field/ability semstr) for an archetype
instance, or None. `fetch_mtir` resolves the `<module>.<ClassName>` scope that
mtir_gen_pass registers, so descriptions stay semstr-driven like the rest of byLLM.
"""
def _class_info(arch: object) -> object {
    import from byllm.plugin { fetch_mtir }
    try {
        return fetch_mtir(type(arch));
    } except Exception {
        return None;
    }
}


"""repr() a field value, capped to keep per-candidate descriptions bounded.

Large fields (embedding vectors, long text bodies) would otherwise produce
kilobyte-long candidate strings that overflow the model's context window or
dilute the routing signal. The middle is elided so both ends stay legible.
"""
def _safe_repr(value: object, limit: int = 120) -> str {
    try {
        text = repr(value);
    } except Exception {
        text = f"<{type(value).__name__}>";
    }
    if len(text) <= limit {
        return text;
    }
    keep = (limit - 5) // 2;
    return text[:keep] + " ... " + text[-keep:];
}


"""Prompt-friendly description: MTIR class semstr (or name) + public fields, each
field labelled with its MTIR semstr when present. Field VALUES are read live
(MTIR holds names/semstr only); the class/field semantics come from MTIR.
"""
def _describe_arch(arch: object) -> str {
    if arch is None {
        return "(none)";
    }
    cls = type(arch);
    ci = _class_info(arch);
    head = (ci.semstr if (ci is not None and ci.semstr) else "") or cls.__name__;
    fsem: dict = {};
    if ci is not None {
        for fi in (ci.fields or []) {
            if fi.semstr {
                fsem[fi.name] = fi.semstr;
            }
        }
    }
    parts: list = [];
    if is_dataclass(arch) {
        for f in fields(arch) {
            if f.name.startswith("_") {
                continue;
            }
            val = _safe_repr(getattr(arch, f.name));
            label = f"{f.name} ({fsem[f.name]})" if f.name in fsem else f.name;
            parts.append(f"{label}={val}");
        }
    }
    if parts {
        return head + "(" + ", ".join(parts) + ")";
    }
    return head;
}


"""True if `osf` (a node entry ability) would fire when walker `wkr` visits.

Mirrors kernel dispatch: an untyped ability (trigger None) fires for any walker;
a typed one fires when the walker is an instance of its trigger type.
"""
def _ability_fires(osf: object, wkr: object) -> bool {
    trig = None;
    try {
        trig = osf.trigger;
    } except Exception {
        return False;
    }
    if trig is None {
        return True;
    }
    if wkr is None {
        return False;
    }
    try {
        return isinstance(wkr, trig);
    } except Exception {
        return False;
    }
}


"""What runs if `wkr` is routed to this node: the entry abilities that would fire,
by name + MTIR semstr -- often the real routing signal (the consequence of the
choice). Which abilities fire is a live dispatch question; descriptions are MTIR.
"""
def _node_run_desc(node_arch: object, wkr: object) -> str {
    ci = _class_info(node_arch);
    msem: dict = {};
    if ci is not None {
        for mi in (ci.methods or []) {
            if mi.semstr {
                msem[mi.name] = mi.semstr;
            }
        }
    }
    funcs = type(node_arch)?._jac_entry_funcs_ or [];
    parts: list = [];
    for osf in funcs {
        if not _ability_fires(osf, wkr) {
            continue;
        }
        sem = msem.get(osf.name, "");
        parts.append(osf.name + (f": {sem}" if sem else ""));
    }
    return "; ".join(parts);
}


"""Sanitise text into a valid, readable identifier slug for an enum member."""
def _slugify(text: object) -> str {
    s = re.sub(r"\W+", "_", str(text)).strip("_");
    if not s {
        return "n";
    }
    if not (s[0].isalpha() or s[0] == "_") {
        s = "n_" + s;
    }
    return s;
}


"""First public field value of an archetype, used to disambiguate slugs (or None)."""
def _first_field_value(arch: object) -> object {
    if is_dataclass(arch) {
        for f in fields(arch) {
            if not f.name.startswith("_") {
                return getattr(arch, f.name);
            }
        }
    }
    return None;
}


"""Descriptive, unique enum handles for the candidates.

Each handle is the node's class name -- the in-band signal the model conditions
on -- disambiguated by the node's first public field value when classes collide,
then a numeric suffix as a last resort. The handle is both the enum member shown
to the model and the key used to map the choice back to a node.
"""
def _make_handles(recs: list) -> list {
    bases = [_slugify(type(r["node"]).__name__) for r in recs];
    counts: dict = {};
    for b in bases {
        counts[b] = counts.get(b, 0) + 1;
    }
    handles: list = [];
    used = set();
    for (i, r) in enumerate(recs) {
        base = bases[i];
        if counts[base] == 1 {
            cand = base;
        } else {
            disc = _first_field_value(r["node"]);
            cand = base + "_" + _slugify(disc)
                if disc is not None
                else base + "_" + str(i);
        }
        handle = cand;
        k = 2;
        while handle in used {
            handle = cand + "_" + str(k);
            k += 1;
        }
        used.add(handle);
        handles.append(handle);
    }
    return handles;
}


"""Walker archetype + current-node anchor for the innermost active walk."""
def _route_context -> tuple {
    import from jaclang.jac0core.osp_kernel { _current_scope }
    import from jaclang.jac0core.archetype { NodeAnchor, EdgeAnchor, WalkerAnchor }
    scope = _current_scope();
    if scope is None {
        return (None, None);
    }
    # The sv kernel stores the WalkerArchetype directly in scope.wlk, but unwrap
    # defensively in case an anchor is ever passed through.
    wkr = scope.wlk;
    if isinstance(wkr, (NodeAnchor, EdgeAnchor, WalkerAnchor)) {
        wkr = wkr.archetype;
    }
    here_anchor = scope.path[-1] if scope.path else None;
    return (wkr, here_anchor);
}


"""Normalise one candidate into (edge_archetype | None, node_archetype, direction).

Edge candidates carry their edge directly; node candidates reconstruct the
connecting edge from the current node. `direction` is relative to `here`.
"""
def _candidate_for(item: object, here_anchor: object) -> tuple {
    import from jaclang.jac0core.archetype { NodeArchetype, EdgeArchetype }
    if isinstance(item, EdgeArchetype) {
        ea = item.__jac__;
        direction = "out";
        dst_anchor = ea.target;
        if here_anchor is not None and ea.target.archetype is here_anchor.archetype {
            dst_anchor = ea.source;
            direction = "in";
        }
        if ea.is_undirected {
            direction = "undir";
        }
        return (item, dst_anchor.archetype, direction);
    }
    node_arch = item;
    edge_arch = None;
    direction = "out";
    if here_anchor is not None {
        here_arch = here_anchor.archetype;
        for ea in here_anchor.edges {
            other = None;
            dir2 = "out";
            if ea.source.archetype is here_arch {
                other = ea.target;
                dir2 = "out";
            } elif ea.target.archetype is here_arch {
                other = ea.source;
                dir2 = "in";
            }
            if ea.is_undirected {
                dir2 = "undir";
            }
            if other is not None and other.archetype is node_arch {
                edge_arch = ea.archetype;
                direction = dir2;
                break;
            }
        }
    }
    return (edge_arch, node_arch, direction);
}


"""Resolve one model selection (enum member / handle string / int index) to a node."""
def _resolve_choice(item: object, by_handle: dict, recs: list) -> object {
    if isinstance(item, bool) {
        return None;
    }
    if isinstance(item, int) {
        return recs[item]["node"] if 0 <= item < len(recs) else None;
    }
    handle = None;
    if isinstance(item, str) {
        handle = item;
    } elif hasattr(item, "value") {
        handle = item.value;
    }
    if handle is not None and handle in by_handle {
        return by_handle[handle];
    }
    return None;
}


"""LLM-guided successor selection for `visit [-->] by llm(...)`.

`model.call_params` may carry:
  - `select`: 1 | int | (min, max) | "all" (default) | -1 (alias for "all") --
    cardinality of the result
  - `intent`: free-text goal shown to the model
  - `incl_info`: extra context dict (legacy escape hatch, still honoured)
"""
def route_visit(candidates: list, model: object) -> list {
    import from byllm.mtir { MTRuntime }
    import from byllm.types { Message, MessageRole }

    # Nothing to route to: skip the model call entirely (no candidates means no
    # valid handles, so the LLM has nothing to choose from).
    if not candidates {
        return [];
    }

    call_params = model?.call_params or {};
    select = call_params.get("select", "all");
    # A non-positive integer (notably -1) means "no cap": treat it as "all". This
    # also avoids a negative slice (e.g. `chosen[:-1]` would drop the last node)
    # and a nonsensical "Choose exactly -1" instruction to the model.
    if isinstance(select, int) and not isinstance(select, bool) and (select < 1) {
        select = "all";
    }
    intent = call_params.get("intent");
    incl_info = call_params.get("incl_info");

    (wkr, here_anchor) = _route_context();

    recs: list = [];
    for item in candidates {
        (edge_arch, node_arch, direction) = _candidate_for(item, here_anchor);
        recs.append(
            {"handle": "", "edge": edge_arch, "node": node_arch, "dir": direction}
        );
    }
    for (i, handle) in enumerate(_make_handles(recs)) {
        recs[i]["handle"] = handle;
    }

    lines: list = [];
    for r in recs {
        edge_txt = _describe_arch(r["edge"]) if r["edge"] is not None else "(direct)";
        if r["dir"] == "in" {
            arrow = f"<--({edge_txt})--";
        } elif r["dir"] == "undir" {
            arrow = f"<-({edge_txt})->";
        } else {
            arrow = f"--({edge_txt})-->";
        }
        node_txt = _describe_arch(r["node"]);
        runs = _node_run_desc(r["node"], wkr);
        if runs {
            node_txt = node_txt + f" [runs: {runs}]";
        }
        lines.append(f"{r['handle']}) here {arrow} {node_txt}");
    }
    candidates_block = "\n".join(lines);

    user_parts: list = [];
    if intent {
        user_parts.append(f"Goal: {intent}");
    }
    if wkr is not None {
        user_parts.append(f"Walker:\n{_describe_arch(wkr)}");
    }
    if here_anchor is not None {
        user_parts.append(f"Current node:\n{_describe_arch(here_anchor.archetype)}");
    }
    user_parts.append(f"Candidates (choose by handle):\n{candidates_block}");
    if incl_info and isinstance(incl_info, dict) {
        user_parts.append("\n".join([f"{k} = {v}" for (k, v) in incl_info.items()]));
    }

    sys_txt = "You are routing a graph walker. Choose which candidate node(s) the " + "walker should visit next, by handle. Return only valid handles.";
    if select == 1 {
        sys_txt += " Choose exactly one.";
    } elif isinstance(select, int) and not isinstance(select, bool) {
        sys_txt += f" Choose exactly {select}.";
    } elif isinstance(select, tuple) and len(select) == 2 {
        sys_txt += f" Choose between {select[0]} and {select[1]} (inclusive).";
    }

    handles = [r["handle"] for r in recs];
    # Handles are already unique, valid identifiers (see _make_handles), so use
    # each verbatim as the enum member name -- uppercasing could collide two
    # case-distinct handles into one member and silently drop a candidate.
    Choice = enum.Enum("RouteChoice", {h: h for h in handles}) if handles else None;
    resp_type = list[Choice] if Choice is not None else list;

    mt_run = MTRuntime(
        messages=[
            Message(role=MessageRole.SYSTEM, content=sys_txt),
            Message(role=MessageRole.USER, content="\n\n".join(user_parts)),

        ],
        resp_type=resp_type,
        stream=bool(call_params.get("stream", False)),
        tools=[],
        call_params=call_params,
        mtir=None,
    );

    raw = model.invoke(mt_run=mt_run);

    selected = raw if isinstance(raw, list) else [raw];
    by_handle = {r["handle"]: r["node"] for r in recs};
    chosen: list = [];
    for item in selected {
        picked = _resolve_choice(item, by_handle, recs);
        if picked is not None and picked not in chosen {
            chosen.append(picked);
        }
    }

    if select == 1 {
        chosen = chosen[:1];
    } elif isinstance(select, int) and not isinstance(select, bool) {
        chosen = chosen[:select];
    } elif isinstance(select, tuple) and len(select) == 2 {
        # `select[1]` is a hard cap (we never visit more than the max). `select[0]`
        # is a floor we ask the model to honor in the prompt, but it cannot be
        # enforced post-hoc -- we can't visit candidates the model didn't pick, and
        # there may be fewer than `min` candidates to begin with. Surface a warning
        # rather than silently returning fewer than requested.
        chosen = chosen[:select[1]];
        if len(chosen) < select[0] {
            logger.warning(
                f"visit-by routing: requested at least {select[0]} node(s) (select={select}) but the model selected {len(
                    chosen
                )} from {len(recs)} candidate(s)."
            );
        }
    }
    return chosen;
}
