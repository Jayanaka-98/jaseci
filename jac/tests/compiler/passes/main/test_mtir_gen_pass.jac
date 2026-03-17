"""MTIR generation pass tests – migrated from test_mtir_gen_pass.py."""

import os;
import from pathlib { Path }
import jaclang;
import from jaclang { JacRuntime as Jac }
import from jaclang.jac0core.mtp { ClassInfo, FunctionInfo, MethodInfo, Info }
import from jaclang.jac0core.program { JacProgram }

glob FIXTURES = os.path.join(
         str(Path(jaclang.__file__).parent.parent),
         "tests",
         "compiler",
         "passes",
         "main",
         "fixtures"
     );

"""Get combined MTIR entries from all module maps."""
def get_all_mtir_entries(prog: JacProgram) -> dict[(str, Info)] {
    combined: dict[(str, Info)] = {};
    for mtir_map in prog.mtir_maps.values() {
        combined.update(mtir_map.entries);
    }
    return combined;
}

test "mtir gen basic" {
    prog = JacProgram();
    prog.compile(os.path.join(FIXTURES, "mtir_gen.jac"));
    assert not prog.errors_had , f"Compilation errors: {prog.errors_had}";
    assert Jac.program is not None;
    mtir_map = get_all_mtir_entries(Jac.program);
    assert mtir_map , "MTIR map should not be empty";
    scopes = list(mtir_map.keys());
    assert len(scopes) > 0 , "Should have at least one MTIR entry";
}

test "mtir gen standalone function" {
    prog = JacProgram();
    prog.compile(os.path.join(FIXTURES, "mtir_gen.jac"));
    assert not prog.errors_had;
    assert Jac.program is not None;
    mtir_map = get_all_mtir_entries(Jac.program);
    analyze_person_scope = None;
    for scope in mtir_map {
        if "analyze_person" in scope {
            analyze_person_scope = scope;
            break;
        }
    }
    assert analyze_person_scope is not None , "analyze_person should be in mtir_map";
    func_info = mtir_map[analyze_person_scope];
    assert isinstance(func_info, FunctionInfo);
    assert func_info.name == "analyze_person";
    assert func_info.params is not None;
    assert len(func_info.params) == 2;
    param_names = [p.name for p in func_info.params];
    assert "person" in param_names;
    assert "detail_level" in param_names;
    assert func_info.return_type == "str";
}

test "mtir gen method" {
    prog = JacProgram();
    prog.compile(os.path.join(FIXTURES, "mtir_gen.jac"));
    assert not prog.errors_had;
    assert Jac.program is not None;
    mtir_map = get_all_mtir_entries(Jac.program);
    summarize_scope = None;
    for scope in mtir_map {
        if "summarize" in scope {
            summarize_scope = scope;
            break;
        }
    }
    assert summarize_scope is not None , "Project.summarize should be in mtir_map";
    method_info = mtir_map[summarize_scope];
    assert isinstance(method_info, MethodInfo);
    assert method_info.name == "summarize";
    assert method_info.params is not None;
    param_names = [p.name for p in method_info.params];
    assert "query" in param_names;
    assert method_info.parent_class is not None;
    assert isinstance(method_info.parent_class, ClassInfo);
    assert method_info.parent_class.name == "Project";
}

test "mtir gen complex return type" {
    prog = JacProgram();
    prog.compile(os.path.join(FIXTURES, "mtir_gen.jac"));
    assert not prog.errors_had;
    assert Jac.program is not None;
    mtir_map = get_all_mtir_entries(Jac.program);
    create_team_scope = None;
    for scope in mtir_map {
        if "create_team" in scope {
            create_team_scope = scope;
            break;
        }
    }
    assert create_team_scope is not None , "create_team should be in mtir_map";
    func_info = mtir_map[create_team_scope];
    assert isinstance(func_info, FunctionInfo);
    assert func_info.return_type is not None;
    if isinstance(func_info.return_type, ClassInfo) {
        assert func_info.return_type.name == "Team";
    } elif isinstance(func_info.return_type, str) {
        assert func_info.return_type == "Team";
    }
}

test "mtir gen list return type" {
    prog = JacProgram();
    prog.compile(os.path.join(FIXTURES, "mtir_gen.jac"));
    assert not prog.errors_had;
    assert Jac.program is not None;
    mtir_map = get_all_mtir_entries(Jac.program);
    find_people_scope = None;
    for scope in mtir_map {
        if "find_people" in scope {
            find_people_scope = scope;
            break;
        }
    }
    assert find_people_scope is not None , "find_people should be in mtir_map";
    func_info = mtir_map[find_people_scope];
    assert isinstance(func_info, FunctionInfo);
    assert func_info.return_type is not None;
    if isinstance(func_info.return_type, tuple) {
        assert func_info.return_type[0] == "list";
    }
}

test "mtir gen semstrings" {
    prog = JacProgram();
    prog.compile(os.path.join(FIXTURES, "mtir_gen.jac"));
    assert not prog.errors_had;
    assert Jac.program is not None;
    mtir_map = get_all_mtir_entries(Jac.program);
    analyze_person_scope = None;
    for scope in mtir_map {
        if "analyze_person" in scope {
            analyze_person_scope = scope;
            break;
        }
    }
    assert analyze_person_scope is not None;
    func_info = mtir_map[analyze_person_scope];
    assert isinstance(func_info, FunctionInfo);
    assert func_info.semstr is not None;
    assert "Analyze" in func_info.semstr;
    assert func_info.params is not None;
    person_param = None;
    for p in func_info.params {
        if p.name == "person" {
            person_param = p;
            break;
        }
    }
    if person_param and person_param.semstr {
        assert "person" in person_param.semstr.lower();
    }
}

test "mtir gen class info extraction" {
    prog = JacProgram();
    prog.compile(os.path.join(FIXTURES, "mtir_gen.jac"));
    assert not prog.errors_had;
    assert Jac.program is not None;
    mtir_map = get_all_mtir_entries(Jac.program);
    analyze_person_scope = None;
    for scope in mtir_map {
        if "analyze_person" in scope {
            analyze_person_scope = scope;
            break;
        }
    }
    assert analyze_person_scope is not None;
    func_info = mtir_map[analyze_person_scope];
    assert isinstance(func_info, FunctionInfo);
    assert func_info.params is not None;
    person_param = None;
    for p in func_info.params {
        if p.name == "person" {
            person_param = p;
            break;
        }
    }
    assert person_param is not None;
    if isinstance(person_param.type_info, ClassInfo) {
        assert person_param.type_info.name == "Person";
        field_names = [f.name for f in person_param.type_info.fields];
        assert "name" in field_names;
        assert "age" in field_names;
    }
}

test "mtir gen all genai abilities captured" {
    prog = JacProgram();
    prog.compile(os.path.join(FIXTURES, "mtir_gen.jac"));
    assert not prog.errors_had;
    assert Jac.program is not None;
    mtir_map = get_all_mtir_entries(Jac.program);
    expected_abilities = ["summarize", "analyze_person", "create_team", "find_people"];
    found_abilities: set = set();
    for scope in mtir_map {
        for ability in expected_abilities {
            if ability in scope {
                found_abilities.add(ability);
            }
        }
    }
    assert len(found_abilities) == len(expected_abilities) , f"Expected all GenAI abilities to be captured. Found: {found_abilities}, Expected: {set(
        expected_abilities
    )}";
}

test "mtir module isolation" {
    import tempfile;
    import shutil;
    import from jaclang.jac0core.jir { get_module_cache_path }
    import from jaclang.jac0core.runtime { JacRuntime }

    def write_jac_file(path: str, semstr: str) -> None {
        with open(path, "w") as f {
            f.write(
                "obj MockLLM { def __call__(**kwargs: dict) -> MockLLM { return self; } }\n"
            );
            f.write("glob llm = MockLLM();\n");
            f.write("obj Item { has val: str; }\n");
            f.write(f'sem Item.val = """{semstr}""";\n');
            f.write("def make_item(x: str) -> Item by llm();\n");
        }
    }

    def get_field_semstr(info: Info, field_name: str) -> str {
        for f in info.return_type.fields {
            if f.name == field_name {
                return f.semstr;
            }
        }
        return "";
    }

    temp_dir = tempfile.mkdtemp();
    try {
        main_jac = os.path.join(temp_dir, "isolation_test.jac");

        write_jac_file(main_jac, "First version.");
        prog1 = JacProgram();
        JacRuntime.program = prog1;
        prog1.compile(main_jac, type_check=False);

        assert main_jac in prog1.mtir_maps , "Module not found in mtir_maps";
        info1 = prog1.mtir_maps[main_jac].get("isolation_test.make_item");
        assert info1 is not None;
        assert "First" in get_field_semstr(info1, "val");

        write_jac_file(main_jac, "Second version.");
        cache_path = get_module_cache_path(main_jac);
        if cache_path.exists() {
            cache_path.unlink();
        }

        prog2 = JacProgram();
        JacRuntime.program = prog2;
        prog2.compile(main_jac, type_check=False);

        assert main_jac in prog2.mtir_maps , "Module not found after recompile";
        info2 = prog2.mtir_maps[main_jac].get("isolation_test.make_item");
        assert info2 is not None;
        assert "Second" in get_field_semstr(info2, "val") , "Stale MTIR - cache isolation failed";
    } finally {
        shutil.rmtree(temp_dir, ignore_errors=True);
    }
}
