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
import from jaclang.byllm.systemone { ProviderCaps, SystemOneSpec, assemble, lower }
import from jaclang.runtime.semantic { EnumInfo, FieldInfo, FunctionInfo, ParamInfo }


"""How urgently a support ticket needs a human."""
enum Priority {
    LOW,
    HIGH
}


enum Team { BILLING, SECURITY, PLATFORM }


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
    resp_type: (type | None),
    args: dict[any, any],
    info: (FunctionInfo | None),
    tools: list[any] = [],
    stream: bool = False
) -> MTRuntime {
    return MTRuntime(
        messages=[
            Message(role=MessageRole.SYSTEM, content="You are an agent."),
            Message(role=MessageRole.USER, content="Do the thing.")
        ],
        resp_type=resp_type,
        stream=stream,
        tools=tools,
        call_params={},
        mtir=MTIR(caller=_stub, args=args, call_params={}, ir_info=info)
    );
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
