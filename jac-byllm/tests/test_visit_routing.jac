"""Tests for the re-architected `visit [-->] by llm(...)` routing mechanism."""

import io;
import os;
import sys;
import from jaclang { JacRuntimeInterface as Jac }

glob jac_import = Jac.jac_import,
     FIXTURE_DIR = os.path.join(os.path.dirname(__file__), "fixtures");


test "routes along edge attribute, not just node" {
    # The two candidate nodes are reachable from the same Desk; the correct
    # target is decided solely by the connecting edge's priority. This is only
    # routable if the prompt surfaces the (edge, node) pair per candidate.
    captured_output = io.StringIO();
    sys.stdout = captured_output;
    jac_import("routing_edge_choice", base_path=FIXTURE_DIR + "/");
    sys.stdout = sys.__stdout__;
    stdout_value = captured_output.getvalue();

    assert "VISITED:beta" in stdout_value;  # high-priority edge target
    assert "VISITED:alpha" not in stdout_value;  # low-priority edge target

    # select=1 means exactly one successor is visited.
    assert stdout_value.count("VISITED:") == 1;
}
