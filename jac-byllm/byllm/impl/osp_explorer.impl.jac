"""Implementation of OSP Graph Explorer helpers and GraphExplorer methods.

All Python-internal attribute access (.__jac__, .edges, .source, .target,
.archetype, .id, .is_populated) lives here, typed through NodeArchetype /
NodeAnchor / EdgeAnchor so the Jac type checker is satisfied.
"""
import from dataclasses { is_dataclass }
import from jaclang.jac0core.archetype {
    NodeArchetype, NodeAnchor, EdgeAnchor, EdgeArchetype, GenericEdge
}
import from jaclang.jac0core.runtime { JacRuntime as _JacLangRuntime }
import inspect;


impl _iter_outgoing(nd: NodeArchetype) -> list[NodeArchetype] {
    result: list[NodeArchetype] = [];
    try {
        anchor: NodeAnchor = nd.__jac__;
        for ea in anchor.edges {
            ea_typed: EdgeAnchor = ea;
            try {
                if not ea_typed.is_populated() {
                    continue;
                }
                if ea_typed.source.is_populated() and ea_typed.source.id != anchor.id {
                    continue;
                }
                if not ea_typed.target.is_populated() {
                    continue;
                }
                arch: NodeArchetype = ea_typed.target.archetype;
                result.append(arch);
            } except Exception {
                continue;
            }
        }
    } except Exception {
        ;
    }
    return result;
}


impl _iter_outgoing_filtered(
    nd: NodeArchetype,
    edge_type_name: (str | None),
    target_type_name: (str | None)
) -> list[NodeArchetype] {
    result: list[NodeArchetype] = [];
    try {
        anchor: NodeAnchor = nd.__jac__;
        for ea in anchor.edges {
            ea_typed: EdgeAnchor = ea;
            try {
                if not ea_typed.is_populated() {
                    continue;
                }
                if ea_typed.source.is_populated() and ea_typed.source.id != anchor.id {
                    continue;
                }
                e_type = type(ea_typed.archetype).__name__;
                if edge_type_name is not None and e_type != edge_type_name {
                    continue;
                }
                if not ea_typed.target.is_populated() {
                    continue;
                }
                t_arch: NodeArchetype = ea_typed.target.archetype;
                t_type = type(t_arch).__name__;
                if target_type_name is not None and t_type != target_type_name {
                    continue;
                }
                result.append(t_arch);
            } except Exception {
                continue;
            }
        }
    } except Exception {
        ;
    }
    return result;
}


impl GraphExplorer._scan_type_schema -> None {
    self._node_schema = {};
    self._edge_schema = {};
    mod = _JacLangRuntime.loaded_modules.get(self.module_name);
    if mod is None {
        return;
    }
    for (name, `obj) in inspect.getmembers(mod, inspect.isclass) {
        if not isinstance(`obj, `type) {
            continue;
        }
        if `obj.__module__ != self.module_name {  # type: ignore
            continue;
        }
        if issubclass(`obj, NodeArchetype) {  # type: ignore
            fields_info: dict = {};
            if is_dataclass(`obj) {  # type: ignore
                for (fname, fval) in vars(`obj).items() {  # type: ignore
                    if not fname.startswith("_") {
                        fields_info[fname] = type(fval).__name__;
                    }
                }
            }
            self._node_schema[name] = {"cls": `obj, "fields": fields_info};
        } elif issubclass(`obj, EdgeArchetype) {  # type: ignore
            fields_info: dict = {};
            if is_dataclass(`obj) {  # type: ignore
                for (fname, fval) in vars(`obj).items() {  # type: ignore
                    if not fname.startswith("_") {
                        fields_info[fname] = type(fval).__name__;
                    }
                }
            }
            self._edge_schema[name] = {"cls": `obj, "fields": fields_info};
        }
    }
    if "GenericEdge" not in self._edge_schema {
        self._edge_schema["GenericEdge"] = {"cls": GenericEdge, "fields": {}};
    }
}


impl GraphExplorer._build_topology_desc -> str {
    lines: list = ["=== OSP Graph Schema ==="];
    lines.append(f"\nNode Types ({len(self._node_schema)} found):");
    for type_name in self._node_schema {
        schema: dict = self._node_schema[type_name];
        fields: dict = schema["fields"];
        if fields {
            field_strs: list = [];
            for (k, v) in fields.items() {
                field_strs.append(f"{k}: {v}");
            }
            lines.append(f"  {type_name}  [{', '.join(field_strs)}]");
        } else {
            lines.append(f"  {type_name}  (no fields)");
        }
    }
    lines.append(f"\nEdge Types ({len(self._edge_schema)} found):");
    for type_name in self._edge_schema {
        schema: dict = self._edge_schema[type_name];
        fields: dict = schema["fields"];
        if fields {
            field_strs: list = [];
            for (k, v) in fields.items() {
                field_strs.append(f"{k}: {v}");
            }
            lines.append(f"  {type_name}  [{', '.join(field_strs)}]");
        } else {
            lines.append(f"  {type_name}  (no fields)");
        }
    }
    lines.append("\nNote: 'Root' is the graph entry point. 'GenericEdge' is the default edge (used with ++>).");
    return "\n".join(lines);
}


impl GraphExplorer._ensure_data_index -> None {
    if self._data_indexed {
        return;
    }
    visited: set = set();
    queue: list = [root()];
    self._id_to_node = {};
    self._node_index = {};
    while queue {
        curr: NodeArchetype = queue.pop(0);
        curr_id = str(jid(curr));
        if curr_id in visited {
            continue;
        }
        visited.add(curr_id);
        curr_type = type(curr).__name__;
        if curr_type not in self._node_index {
            self._node_index[curr_type] = [];
        }
        self._node_index[curr_type].append(curr);
        self._id_to_node[curr_id] = curr;
        for neighbor in _iter_outgoing(curr) {
            neighbor_id = str(jid(neighbor));
            if neighbor_id not in visited {
                queue.append(neighbor);
            }
        }
    }
    self._data_indexed = True;
}
