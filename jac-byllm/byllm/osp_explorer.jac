"""OSP Graph Explorer for byLLM.

Provides automatic graph schema discovery and LLM-accessible traversal
tools for Object Spatial Programming (OSP) graphs in Jac.

The GraphExplorer scans the Jac runtime type registry at construction
time (no graph walk required) to build a complete picture of all node
and edge types, then exposes that schema plus traversal tools to a
byLLM ReAct agent via the query_graph() method.

Typical usage — manual tool injection:
    import from byllm.osp_explorer { GraphExplorer }
    glob explorer = GraphExplorer();
    def my_agent(question: str) -> str by llm(tools=[explorer.query_graph]);

Preferred usage — zero-boilerplate via useGraph flag:
    def my_agent(question: str) -> str by llm(useGraph=True, tools=[...]);
"""
import from dataclasses { is_dataclass }
import from jaclang.jac0core.archetype { NodeArchetype, NodeAnchor, EdgeAnchor, EdgeArchetype, GenericEdge }
import from jaclang.jac0core.runtime { JacRuntime as _JacLangRuntime }
import json;
import inspect;


def _safe_serialize(val: object) -> object {
    try {
        json.dumps(val);
        return val;
    } except Exception {
        return str(val);
    }
}


def _node_to_dict(nd: object) -> dict {
    result: dict = {"_id": str(jid(nd)), "_type": type(nd).__name__};
    if is_dataclass(nd) {
        for (fname, fval) in vars(nd).items() {
            if not fname.startswith("_") {
                result[fname] = _safe_serialize(fval);
            }
        }
    }
    return result;
}


"""Return all outgoing neighbor archetypes from a node via __jac__ edges."""
def _iter_outgoing(nd: NodeArchetype) -> list[NodeArchetype];

"""Return filtered outgoing neighbor archetypes, optionally by edge and target type names."""
def _iter_outgoing_filtered(
    nd: NodeArchetype,
    edge_type_name: (str | None),
    target_type_name: (str | None)
) -> list[NodeArchetype];


obj GraphExplorer {
    has module_name: str = "__main__",
        _node_schema: dict = {},
        _edge_schema: dict = {},
        _topology_desc: str = "",
        _id_to_node: dict = {},
        _node_index: dict = {},
        _data_indexed: bool = False;

    def postinit -> None {
        self._scan_type_schema();
        self._topology_desc = self._build_topology_desc();
    }

    """Scan runtime type registry to populate node/edge schemas (Phase 1)."""
    def _scan_type_schema -> None;

    """Build the topology description string from the discovered schemas."""
    def _build_topology_desc -> str;

    """Return the [Graph Context] block for injection into outer agent system prompt."""
    def graph_context_block -> str {
        return (
            "[Graph Context]\n"
            "Your application manages data in an OSP graph with the following structure:\n\n"
            + self._topology_desc
            + "\n\nUse the query_graph tool when the question requires fetching or "
            + "reasoning over stored graph entities and their relationships."
        );
    }

    """Lazily build the node/ID lookup index from the live graph."""
    def _ensure_data_index -> None;

    """Returns the graph schema: all node types with their fields and all edge types."""
    def get_topology -> str {
        return self._topology_desc;
    }

    """Returns all graph nodes of the given type_name as dicts with _id, _type, and field values."""
    def list_nodes(type_name: str) -> list[dict] {
        self._ensure_data_index();
        items: list = self._node_index.get(type_name, []);
        results: list = [];
        for item in items {
            results.append(_node_to_dict(item));
        }
        return results;
    }

    """Returns the fields of a specific node by its _id string. Returns None if not found."""
    def get_node(node_id: str) -> (dict | None) {
        self._ensure_data_index();
        nd = self._id_to_node.get(node_id);
        if nd is not None {
            return _node_to_dict(nd);
        }
        return None;
    }

    """Traverse outgoing edges from a node. Optionally filter by edge_type and/or target_type."""
    def traverse(
        from_node_id: str,
        edge_type: (str | None) = None,
        target_type: (str | None) = None
    ) -> list[dict] {
        self._ensure_data_index();
        nd = self._id_to_node.get(from_node_id);
        if nd is None {
            return [];
        }
        results: list = [];
        for neighbor in _iter_outgoing_filtered(nd, edge_type, target_type) {
            results.append(_node_to_dict(neighbor));
        }
        return results;
    }

    """Find nodes of type_name where field_name matches value (string comparison)."""
    def find_nodes(type_name: str, field_name: str, value: str) -> list[dict] {
        self._ensure_data_index();
        items: list = self._node_index.get(type_name, []);
        results: list = [];
        for item in items {
            if str(getattr(item, field_name, None)) == value {
                results.append(_node_to_dict(item));
            }
        }
        return results;
    }

    """Returns the traversal tools list for direct use in byLLM tools=[...] parameter."""
    def get_tools -> list {
        return [self.get_topology, self.list_nodes, self.get_node, self.traverse, self.find_nodes];
    }

    """Answers a natural language question by autonomously traversing the application OSP data graph."""
    def query_graph(question: str) -> str by llm(
        tools=[self.get_topology, self.list_nodes, self.get_node, self.traverse, self.find_nodes],
        incl_info={"graph_schema": self._topology_desc}
    );
}

sem GraphExplorer = "An OSP graph explorer agent that traverses and queries Jac graph data using byLLM.";
sem GraphExplorer.module_name = "The Jac module name to scan for node and edge types. Defaults to '__main__'.";
sem GraphExplorer.get_topology = "Returns the complete graph schema: all node types with their fields and all edge types.";
sem GraphExplorer.list_nodes = "Lists all currently stored nodes of a specific type.";
sem GraphExplorer.list_nodes.type_name = "The exact node type name to list (e.g. 'Person', 'Product', 'Order').";
sem GraphExplorer.get_node = "Retrieves a specific node by its unique _id string.";
sem GraphExplorer.get_node.node_id = "The _id string of the node to retrieve (obtained from list_nodes or traverse).";
sem GraphExplorer.traverse = "Follows outgoing edges from a node to reach its connected neighbors.";
sem GraphExplorer.traverse.from_node_id = "The _id of the node to start traversal from.";
sem GraphExplorer.traverse.edge_type = "Optional: only follow edges of this type (e.g. 'GenericEdge', 'Friend', 'Owns').";
sem GraphExplorer.traverse.target_type = "Optional: only return neighbors of this node type.";
sem GraphExplorer.find_nodes = "Searches for nodes of a specific type where a field equals a given value.";
sem GraphExplorer.find_nodes.type_name = "The node type to search within.";
sem GraphExplorer.find_nodes.field_name = "The field name to filter on.";
sem GraphExplorer.find_nodes.value = "The value to match (compared as strings).";
sem GraphExplorer.query_graph = "Answers a natural language question by autonomously traversing the application OSP data graph. Use this when the question requires fetching stored entities, relationships, or application state.";
sem GraphExplorer.query_graph.question = "The natural language question to answer using the graph data.";
