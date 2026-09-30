"""Lowering a `by llm()` call site onto the System One protocol, and back.

The lowering reads what the compiler recorded: `FunctionInfo.semstr` for the
question's instructions, and the `FieldInfo.semstr` of each `EnumInfo` member for
its criteria. Both arrive as `mtir.ir_info`.

Under `jac test` a call site declared here gets `ir_info` of None. Measured
side by side with `jac run` on the same declaration: the harness packages the
module as `_jac_test_pkg_N.<file>`, so `JacLLM.fetch_mtir` composes
`_jac_test_pkg_N.<file>.<name>`; `semantic_for_scope` returns None for that
source, and `JacRuntime.program.mtir_map` is empty, while the compiler
registered the ability as `<file>.<name>`. Under `jac run`, `fetch_mtir`
rewrites `__main__` to the file stem, which matches, and the lookup yields a
full FunctionInfo. So these tests build the IR the compiler hands over and
drive `lower` on it directly, rather than asserting through a call site the
harness cannot resolve.
"""

import from jaclang.byllm.llm { BaseLLM }
import from jaclang.byllm.mtir { MTIR, MTRuntime }
import from jaclang.byllm.types { Message, MessageRole }
import from jaclang.byllm.exceptions { OutputConversionError }
import from jaclang.byllm.systemone {
    Decision,
    ProviderCaps,
    ROUTE_SELECT_ATTR,
    SystemOneSpec,
    assemble,
    lower,
    wrap_result
}
import from jaclang.runtime.semantic {
    ClassInfo,
    EnumInfo,
    FieldInfo,
    FunctionInfo,
    ParamInfo,
    TypeForm
}


"""How urgently a support ticket needs a human."""
enum Priority {
    LOW,
    HIGH
}


enum Team { BILLING, SECURITY, PLATFORM }


obj Triage {
    has urgency: Priority,
        needs_human: bool;
}


obj Note {
    has title: str,
        urgency: Priority;
}


def _triage_info -> FunctionInfo {
    return FunctionInfo(
        name="triage",
        semstr="Triage the ticket",
        params=[ParamInfo(name="ticket", semstr=None, type_info="str")],
        return_type=ClassInfo(
            name="Triage",
            semstr=None,
            fields=[
                FieldInfo(
                    name="urgency",
                    semstr="How urgent the ticket is",
                    type_info=_priority_info().return_type
                ),
                FieldInfo(
                    name="needs_human",
                    semstr="Whether a person must look at it",
                    type_info="bool"
                )
            ],
            base_classes=[],
            methods=[]
        )
    );
}


enum Sev { LOW = 1, HIGH = 2, SEVERE = 2 }


def _list_of(base: FunctionInfo, name: str) -> FunctionInfo {
    return FunctionInfo(
        name=name,
        semstr=f"Which apply: {base.name}",
        params=base.params,
        return_type=TypeForm(head="list", args=[base.return_type])
    );
}


def _sev_list_info -> FunctionInfo {
    return FunctionInfo(
        name="severities",
        semstr="Which severities apply",
        params=[ParamInfo(name="ticket", semstr=None, type_info="str")],
        return_type=TypeForm(
            head="list",
            args=[
                EnumInfo(
                    name="Sev",
                    semstr=None,
                    members=[
                        FieldInfo(name="LOW", semstr=None, type_info=None),
                        FieldInfo(name="HIGH", semstr=None, type_info=None),
                        FieldInfo(name="SEVERE", semstr=None, type_info=None)
                    ]
                )
            ]
        )
    );
}


enum Only { ONE }


def _only_list_info -> FunctionInfo {
    return FunctionInfo(
        name="only",
        semstr="Which to visit",
        params=[ParamInfo(name="t", semstr=None, type_info="str")],
        return_type=TypeForm(
            head="list",
            args=[
                EnumInfo(
                    name="Only",
                    semstr=None,
                    members=[FieldInfo(name="ONE", semstr=None, type_info=None)]
                )
            ]
        )
    );
}


def _stub(ticket: str) -> object {
    return None;
}


def _priority_info(described: bool = True) -> FunctionInfo {
    return FunctionInfo(
        name="rank",
        semstr="Rank how urgent the ticket is",
        params=[ParamInfo(name="ticket", semstr=None, type_info="str")],
        return_type=EnumInfo(
            name="Priority",
            semstr=None,
            members=[
                FieldInfo(
                    name="LOW",
                    semstr="can wait until the next business day"
                        if described
                        else None,
                    type_info=None
                ),
                FieldInfo(
                    name="HIGH",
                    semstr="needs attention right now" if described else None,
                    type_info=None
                )
            ]
        )
    );
}


def _team_info -> FunctionInfo {
    return FunctionInfo(
        name="route",
        semstr="Route the ticket to a team",
        params=[
            ParamInfo(name="subject", semstr=None, type_info="str"),
            ParamInfo(name="body", semstr=None, type_info="str")
        ],
        return_type=EnumInfo(
            name="Team",
            semstr=None,
            members=[
                FieldInfo(name="BILLING", semstr=None, type_info=None),
                FieldInfo(name="SECURITY", semstr=None, type_info=None),
                FieldInfo(name="PLATFORM", semstr=None, type_info=None)
            ]
        )
    );
}


def _bool_info(name: str, semstr: str) -> FunctionInfo {
    return FunctionInfo(
        name=name,
        semstr=semstr,
        params=[ParamInfo(name="subject", semstr=None, type_info="str")],
        return_type="bool"
    );
}


def _mt(
    resp_type: any,
    args: dict[any, any],
    info: (FunctionInfo | None),
    tools: list[any] = [],
    stream: bool = False,
    system: str = "You are an agent.",
    with_ir: bool = True,
    select: any = None
) -> MTRuntime {
    mt = MTRuntime(
        messages=[
            Message(role=MessageRole.SYSTEM, content=system),
            Message(role=MessageRole.USER, content="Do the thing.")
        ],
        resp_type=resp_type,
        stream=stream,
        tools=tools,
        call_params={},
        mtir=MTIR(caller=_stub, args=args, call_params={}, ir_info=info)
            if with_ir
            else None
    );
    if select is not None {
        setattr(mt, ROUTE_SELECT_ATTR, select);
    }
    return mt;
}


"""`lower` for the cases that must succeed, narrowed for the type checker."""
def _lowered(mt_run: MTRuntime, caps: (ProviderCaps | None) = None) -> SystemOneSpec {
    spec = lower(mt_run, caps);
    assert spec is not None , "expected this call site to be eligible";
    return spec;
}


test "an enum return lowers to one choice carrying the EnumInfo member semstrings" {
    spec = _lowered(
        _mt(Priority, {"ticket": "the checkout page is down"}, _priority_info())
    );

    assert spec.mode == "enum" , f"expected enum mode, got {spec.mode!r}";
    assert len(spec.questions) == 1 , f"expected one question, got {spec.questions}";

    q = list(spec.questions.values())[0];
    assert q.kind == "choice" , f"an enum is a choice, got {q.kind!r}";
    assert q.criteria
        == {
            "LOW": "can wait until the next business day",
            "HIGH": "needs attention right now"
        } , f"each member's semstr must become its criteria value, got {q.criteria}";
}


test "FunctionInfo.semstr becomes the question's instructions" {
    spec = _lowered(_mt(Priority, {"ticket": "minor typo"}, _priority_info()));

    q = list(spec.questions.values())[0];
    assert q.instructions == "Rank how urgent the ticket is" , (
        f"the recorded semstr must be the instructions, got {q.instructions!r}"
    );
}


test "a member the compiler recorded without a semstr is offered undescribed" {
    spec = _lowered(
        _mt(Team, {"subject": "invoice", "body": "charged twice"}, _team_info())
    );

    q = list(spec.questions.values())[0];
    assert q.criteria == {"BILLING": None, "SECURITY": None, "PLATFORM": None} , (
        f"labels without a semstr must still be offered, got {q.criteria}"
    );
}


test "positional arguments are named from the recorded ParamInfo" {
    spec = _lowered(
        _mt(
            Team,
            {0: "vulnerability", 1: "one tenant can read another tenant's files"},
            _team_info()
        )
    );

    assert spec.state
        == {
            "subject": "vulnerability",
            "body": "one tenant can read another tenant's files"
        } , f"positional args must be named from ParamInfo, got {spec.state}";
}


test "a bool return lowers to a noul" {
    spec = _lowered(
        _mt(
            bool,
            {"subject": "YOU HAVE WON"},
            _bool_info("is_spam", "True if this message is unsolicited bulk mail")
        )
    );

    assert spec.mode == "bool" , f"expected bool mode, got {spec.mode!r}";
    q = list(spec.questions.values())[0];
    assert q.kind == "noul" , f"a bool is a noul, got {q.kind!r}";
    assert q.instructions == "True if this message is unsolicited bulk mail";
    assert q.criteria is None , f"a bare bool needs no criteria, got {q.criteria}";
}


test "an open-ended return is refused so it can go to the fallback" {
    info = FunctionInfo(
        name="summarize",
        semstr="Summarize the document",
        params=[ParamInfo(name="text", semstr=None, type_info="str")],
        return_type="str"
    );
    assert lower(_mt(str, {"text": "a long document"}, info)) is None , (
        "`-> str` has no closed option set and must not be lowered"
    );
}


test "a call carrying tools is refused: the protocol answers, it does not act" {
    assert lower(_mt(Priority, {"ticket": "x"}, _priority_info(), tools=["a tool"]))
        is None , "tools must route to the chat backend";
}


test "a streaming call is refused" {
    assert lower(_mt(Priority, {"ticket": "x"}, _priority_info(), stream=True))
        is None , "there is nothing to stream from a distribution";
}


test "a frontier wider than the provider allows is refused, not truncated" {
    spec = lower(
        _mt(Team, {"subject": "a", "body": "b"}, _team_info()),
        ProviderCaps(max_choice_options=2)
    );
    assert spec is None , (
        "three labels must be refused when the provider caps choices at two"
    );
}


test "a chosen label is rebuilt into the declared enum member" {
    spec = _lowered(_mt(Priority, {"ticket": "down"}, _priority_info()));

    (value, conf) = assemble(
        spec, {"value": {"type": "choice", "choice": "HIGH", "confidence": 0.93}}
    );
    assert value is Priority.HIGH , f"expected the enum member, got {value!r}";
    assert conf == 0.93 , f"confidence must survive, got {conf}";
}


test "a noul probability becomes a bool and a two-option confidence" {
    spec = _lowered(_mt(bool, {"subject": "x"}, _bool_info("is_spam", "unsolicited?")));

    (value, conf) = assemble(spec, {"value": {"type": "noul", "noul": 0.9}});
    assert value is True , f"0.9 is a yes, got {value!r}";
    assert abs(conf - 0.8) < 1e-9 , f"|2p-1| for p=0.9 is 0.8, got {conf}";

    (value2, conf2) = assemble(spec, {"value": {"type": "noul", "noul": 0.5}});
    assert value2 is False , "0.5 is not a yes";
    assert abs(conf2) < 1e-9 , f"an even split is zero confidence, got {conf2}";
}


test "a label outside the declared enum is an error, not a silent None" {
    spec = _lowered(_mt(Priority, {"ticket": "down"}, _priority_info()));

    caught = False;
    try {
        assemble(spec, {"value": {"type": "choice", "choice": "URGENT"}});
    } except OutputConversionError as e {
        caught = True;
        assert "URGENT" in str(e) , f"the offending label must be named, got {e}";
    }
    assert caught , "an unknown label must raise OutputConversionError";
}


test "the wire payload is the protocol's shape" {
    spec = _lowered(
        _mt(Priority, {"ticket": "the checkout page is down"}, _priority_info())
    );

    payload = spec.to_payload("jev-latest");
    assert payload["model"] == "jev-latest";
    assert payload["state"] == {"ticket": "the checkout page is down"};
    q = list(payload["questions"].values())[0];
    assert q["type"] == "choice" , f"the wire field is `type`, got {q}";
    assert set(q.keys()) == {"type", "instructions", "criteria"} , (
        f"unexpected wire fields: {sorted(q.keys())}"
    );
}


obj _Recorder(BaseLLM) {
    has model_name: str = "recorder",
        seen: list[any] = [],
        reply: any = None;

    override def invoke(mt_run: MTRuntime) -> any {
        self.seen.append(mt_run.get_msg_list());
        return self.reply;
    }
}


obj _Refuser(BaseLLM) {
    has model_name: str = "refuser",
        fallback: any = None,
        refused: bool = False;

    override def invoke(mt_run: MTRuntime) -> any {
        if lower(mt_run) is None {
            self.refused = True;
            return self.fallback.invoke(mt_run);
        }
        return None;
    }
}


glob _rec = _Recorder(reply="a short summary"),
     _ref = _Refuser(fallback=_rec);


def _needs_fallback(document: str) -> str by _ref();


test "an ineligible call reaches the fallback with the prompt already built" {
    out = _needs_fallback("the quarterly report is late again");

    assert _ref.refused , "`-> str` must be refused by the lowering";
    assert out == "a short summary" , (
        f"the fallback's value must be returned, got {out!r}"
    );
    assert len(_rec.seen) == 1 , (
        f"the fallback must be invoked once, got {len(_rec.seen)}"
    );

    blob = str(_rec.seen[0]);
    assert "quarterly report is late again" in blob , (
        f"the fallback must receive the argument in its prompt: {blob[:300]}"
    );
    assert len(_rec.seen[0]) >= 2 , (
        f"expected a system and a user message, got {_rec.seen[0]}"
    );
}


def _priority_list_info -> FunctionInfo {
    base = _priority_info();
    return FunctionInfo(
        name="rank_all",
        semstr="Which priorities apply to the ticket",
        params=base.params,
        return_type=TypeForm(head="list", args=[base.return_type])
    );
}


test "list[E] lowers to one noul per member, carrying each member's semstr" {
    spec = _lowered(_mt(list[Priority], {"ticket": "x"}, _priority_list_info()));

    assert spec.mode == "enum_list" , f"got {spec.mode!r}";
    assert set(spec.questions.keys()) == {"LOW", "HIGH"} , (
        f"one question per member, keyed by name: {spec.questions.keys()}"
    );
    q = spec.questions["LOW"];
    assert q.kind == "noul";
    assert q.criteria["true"] == "LOW: can wait until the next business day" , q.criteria;
    assert q.instructions.startswith("Which priorities apply to the ticket") , q.instructions;
    assert spec.resp_type is Priority , "the spec must carry the inner enum for reassembly";
}


test "list[E] assembles the members above 0.5, most probable first, at the least certain confidence" {
    spec = _lowered(_mt(list[Priority], {"ticket": "x"}, _priority_list_info()));

    (value, conf) = assemble(
        spec,
        {"LOW": {"type": "noul", "noul": 0.6}, "HIGH": {"type": "noul", "noul": 0.9}}
    );
    assert value == [Priority.HIGH, Priority.LOW] , f"most probable first, got {value!r}";
    assert abs(conf - 0.2) < 1e-9 , f"min(|2p-1|) over members is 0.2, got {conf}";

    (value2, conf2) = assemble(
        spec,
        {"LOW": {"type": "noul", "noul": 0.3}, "HIGH": {"type": "noul", "noul": 0.8}}
    );
    assert value2 == [Priority.HIGH] , f"only members above 0.5, got {value2!r}";
    assert abs(conf2 - 0.4) < 1e-9 , conf2;
}


test "select=1 pinned by route_visit asks a single choice and returns a one-element list" {
    spec = _lowered(
        _mt(list[Priority], {"ticket": "x"}, _priority_list_info(), select=1)
    );

    assert spec.mode == "enum" and spec.as_list , (
        f"select=1 must lower to one choice, got mode={spec.mode!r} as_list={spec.as_list}"
    );
    assert list(spec.questions.values())[0].kind == "choice";
    (value, conf) = assemble(
        spec, {"value": {"type": "choice", "choice": "HIGH", "confidence": 0.8}}
    );
    assert value == [Priority.HIGH] , f"got {value!r}";
    assert conf == 0.8;
}


test "with no IR the system prompt is the instruction and the messages are the state" {
    spec = _lowered(
        _mt(
            list[Priority],
            {},
            None,
            system="You are routing a graph walker. Choose by handle.",
            with_ir=False
        )
    );

    q = spec.questions["LOW"];
    assert q.instructions.startswith("You are routing a graph walker") , q.instructions;
    assert "context" in spec.state and "Do the thing." in spec.state["context"] , spec.state;
    assert q.criteria["true"] == "LOW" , "no IR means labels only, no descriptions";
}


test "a closed-set obj lowers to one question per field in a single request" {
    spec = _lowered(_mt(Triage, {"ticket": "the site is down"}, _triage_info()));

    assert spec.mode == "record" , spec.mode;
    assert set(spec.questions.keys()) == {"urgency", "needs_human"} , (
        spec.questions.keys()
    );
    assert spec.questions["urgency"].kind == "choice";
    assert spec.questions["urgency"].instructions == "How urgent the ticket is" , (
        "the field's semstr is that question's instruction"
    );
    assert spec.questions["urgency"].criteria["HIGH"] == "needs attention right now" , (
        "member semstrs reach the criteria through the field's EnumInfo"
    );
    assert spec.questions["needs_human"].kind == "noul";
    assert spec.questions["needs_human"].instructions
        == "Whether a person must look at it";
}


test "the per-field answers are rebuilt into the declared obj at the least certain confidence" {
    spec = _lowered(_mt(Triage, {"ticket": "x"}, _triage_info()));

    (value, conf) = assemble(
        spec,
        {
            "urgency": {"type": "choice", "choice": "HIGH", "confidence": 0.9},
            "needs_human": {"type": "noul", "noul": 0.8}
        }
    );
    assert isinstance(value, Triage) , f"expected a Triage, got {value!r}";
    assert value.urgency is Priority.HIGH and value.needs_human is True , value;
    assert abs(conf - 0.6) < 1e-9 , f"min(0.9, |2*0.8-1|=0.6) is 0.6, got {conf}";
}


test "an obj with an open-ended field is refused whole, not partially asked" {
    info = FunctionInfo(
        name="note", semstr="Make a note", params=[], return_type="Note"
    );
    assert lower(_mt(Note, {}, info)) is None , (
        "a str field cannot be asked, so the whole object goes to the fallback"
    );
}


test "Decision[T] lowers T and marks the spec so the model wraps the answer" {
    dt = Decision.__class_getitem__(Priority);
    info = FunctionInfo(
        name="rank",
        semstr="Rank how urgent the ticket is",
        params=[ParamInfo(name="ticket", semstr=None, type_info="str")],
        return_type=TypeForm(head="Decision", args=[_priority_info().return_type])
    );
    spec = _lowered(_mt(dt, {"ticket": "x"}, info));

    assert spec.mode == "enum" and spec.wrap_decision , (spec.mode, spec.wrap_decision);
    q = list(spec.questions.values())[0];
    assert q.criteria["LOW"] == "can wait until the next business day" , (
        "the inner EnumInfo is unwrapped from the Decision TypeForm"
    );

    (value, conf) = assemble(
        spec, {"value": {"type": "choice", "choice": "HIGH", "confidence": 0.93}}
    );
    wrapped = wrap_result(spec, value, conf, {"value": {"HIGH": 0.965, "LOW": 0.035}});
    assert isinstance(wrapped, Decision) , f"got {wrapped!r}";
    assert wrapped.value is Priority.HIGH and wrapped.confidence == 0.93;
    assert wrapped.probabilities["value"]["HIGH"] == 0.965;
}


test "Decision[T] is one class per T, and a bare Decision is refused" {
    assert Decision.__class_getitem__(Priority) is Decision.__class_getitem__(Priority);
    assert Decision.__class_getitem__(Priority) is not Decision.__class_getitem__(Team);
    assert lower(_mt(Decision, {"ticket": "x"}, _priority_info())) is None , (
        "Decision without a type parameter cannot be lowered"
    );
}


def _nouls(ps: dict[str, float]) -> dict[str, any] {
    return {k: {"type": "noul", "noul": v} for (k, v) in ps.items()};
}


test "select=all with zero positives is an empty list at the boundary confidence" {
    spec = _lowered(
        _mt(list[Priority], {"ticket": "x"}, _priority_list_info(), select="all")
    );
    (value, conf) = assemble(spec, _nouls({"LOW": 0.1, "HIGH": 0.05}));
    assert value == [] , f"nothing cleared the gate, got {value!r}";
    assert abs(conf - 0.8) < 1e-9 , f"min(|2p-1|) over members is 0.8, got {conf}";
}


test "an exact select=N fills to N by rank and reports the weakest pick's confidence" {
    spec = _lowered(
        _mt(list[Priority], {"ticket": "x"}, _priority_list_info(), select=2)
    );

    (value, conf) = assemble(spec, _nouls({"LOW": 0.9, "HIGH": 0.3}));
    assert value == [Priority.LOW, Priority.HIGH] , (
        f"exact N must not come back short, got {value!r}"
    );
    assert conf == 0.0 , f"a below-gate Nth pick is zero confidence, got {conf}";

    (value2, conf2) = assemble(spec, _nouls({"LOW": 0.9, "HIGH": 0.7}));
    assert value2 == [Priority.LOW, Priority.HIGH];
    assert abs(conf2 - 0.4) < 1e-9 , f"2*0.7-1 for the weakest pick, got {conf2}";
}


test "ties resolve in declaration order" {
    spec = _lowered(
        _mt(list[Priority], {"ticket": "x"}, _priority_list_info(), select="all")
    );
    (value, _c) = assemble(spec, _nouls({"LOW": 0.8, "HIGH": 0.8}));
    assert value == [Priority.LOW, Priority.HIGH] , f"got {value!r}";
}


test "a select larger than the candidate set returns every candidate, ranked" {
    spec = _lowered(
        _mt(list[Priority], {"ticket": "x"}, _priority_list_info(), select=5)
    );
    (value, conf) = assemble(spec, _nouls({"LOW": 0.6, "HIGH": 0.9}));
    assert value == [Priority.HIGH, Priority.LOW] , f"got {value!r}";
    assert abs(conf - 0.2) < 1e-9 , f"weakest of what could be given, got {conf}";
}


test "a (lo, hi) select fills to lo and cuts to hi" {
    info = _list_of(_team_info(), "teams");
    spec = _lowered(
        _mt(list[Team], {"subject": "a", "body": "b"}, info, select=(1, 2))
    );

    (value, conf) = assemble(
        spec, _nouls({"BILLING": 0.7, "SECURITY": 0.9, "PLATFORM": 0.8})
    );
    assert value == [Team.SECURITY, Team.PLATFORM] , f"cut to hi=2 by rank, got {value!r}";
    assert abs(conf - 0.6) < 1e-9 , conf;

    (value2, conf2) = assemble(
        spec, _nouls({"BILLING": 0.2, "SECURITY": 0.1, "PLATFORM": 0.3})
    );
    assert value2 == [Team.PLATFORM] , f"filled to lo=1 from the ranked rest, got {value2!r}";
    assert conf2 == 0.0 , "a filled pick below the gate is zero confidence";
}


test "an enum alias is asked once and returned once" {
    spec = _lowered(_mt(list[Sev], {"ticket": "x"}, _sev_list_info(), select="all"));
    assert set(spec.questions.keys()) == {"LOW", "HIGH"} , (
        f"SEVERE aliases HIGH and must not be a separate question: {spec.questions.keys()}"
    );
    (value, _c) = assemble(spec, _nouls({"LOW": 0.9, "HIGH": 0.9}));
    assert value == [Sev.LOW, Sev.HIGH] , f"no duplicates, got {value!r}";
}


test "select=1 on a single-candidate frontier asks one noul instead of refusing" {
    spec = _lowered(_mt(list[Only], {"t": "x"}, _only_list_info(), select=1));

    assert spec.mode == "enum_list" , f"one candidate cannot be a choice, got {spec.mode!r}";
    assert list(spec.questions.keys()) == ["ONE"];
    assert spec.questions["ONE"].kind == "noul";

    (value, conf) = assemble(spec, _nouls({"ONE": 0.9}));
    assert value == [Only.ONE] and abs(conf - 0.8) < 1e-9 , (value, conf);

    (value2, conf2) = assemble(spec, _nouls({"ONE": 0.2}));
    assert value2 == [Only.ONE] and conf2 == 0.0 , (
        "exact 1 still returns the only candidate, at zero confidence"
    );
}
