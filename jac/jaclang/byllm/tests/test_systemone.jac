"""Lowering a `by llm()` call site onto the System One protocol, and back.

The lowering is pure: no transport is exercised here. A probe model stands in for
the backend, captures the MTRuntime the compiler handed it, and runs `lower`
against it, so every assertion is about a real compiled call site rather than a
hand-built request.

The declarations have to live in this module. The compiler attaches the
`FunctionInfo` the lowering reads to call sites it compiled here; reached through
an imported fixture module, `mtir.ir_info` comes back as None.
"""

import from jaclang.byllm.llm { BaseLLM }
import from jaclang.byllm.mtir { MTRuntime }
import from jaclang.byllm.exceptions { OutputConversionError }
import from jaclang.byllm.systemone { ProviderCaps, assemble, lower }


obj _Probe(BaseLLM) {
    has model_name: str = "probe",
        specs: list[any] = [],
        infos: list[str] = [],
        reply: any = None,
        caps: (ProviderCaps | None) = None;

    override def invoke(mt_run: MTRuntime) -> any {
        owner = mt_run.mtir;
        info = owner.ir_info if owner else None;
        self.infos.append(
            f"ir_info={type(info).__name__}"
            f" semstr={getattr(info, 'semstr', '<none>')!r}"
            f" return_type={getattr(info, 'return_type', '<none>')!r}"
        );
        self.specs.append(lower(mt_run, self.caps));
        return self.reply;
    }
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


glob _probe = _Probe(),
     _rec = _Recorder(reply="a short summary"),
     _ref = _Refuser(fallback=_rec);


"""How urgently a support ticket needs a human."""
enum Priority {
    LOW,
    HIGH
}

sem Priority.LOW = "can wait until the next business day";
sem Priority.HIGH = "needs attention right now";


enum Team { BILLING, SECURITY, PLATFORM }


def _rank(ticket: str) -> Priority by _probe();

sem _rank = "Rank how urgent the ticket is";


def _route(subject: str, body: str) -> Team by _probe();


def _is_spam(subject: str) -> bool by _probe();

sem _is_spam = "True if this message is unsolicited bulk mail";


def _summarize(text: str) -> str by _probe();


def _reset(reply: any, caps: (ProviderCaps | None) = None) -> _Probe {
    _probe.specs = [];
    _probe.reply = reply;
    _probe.caps = caps;
    return _probe;
}


test "an enum return lowers to one choice carrying the enum's sem strings" {
    p = _reset(Priority.LOW);
    _rank("the checkout page is down");

    spec = p.specs[0];
    assert spec is not None , "an enum return must be eligible";
    assert spec.mode == "enum" , f"expected enum mode, got {spec.mode!r}";
    assert len(spec.questions) == 1 , f"expected one question, got {spec.questions}";

    q = list(spec.questions.values())[0];
    assert q.kind == "choice" , f"an enum is a choice, got {q.kind!r}";
    assert q.criteria
        == {
            "LOW": "can wait until the next business day",
            "HIGH": "needs attention right now"
        } , (
        f"`sem` on each member must become the criteria value, got {q.criteria}"
        f" | {p.infos[0]}"
    );
}


test "the function's sem becomes the question's instructions" {
    p = _reset(Priority.HIGH);
    _rank("minor typo on the pricing page");

    q = list(p.specs[0].questions.values())[0];
    assert q.instructions == "Rank how urgent the ticket is" , (
        f"the function's sem must be the instructions, got {q.instructions!r}"
        f" | {p.infos[0]}"
    );
}


test "a member with no sem is offered as an undescribed label" {
    p = _reset(Team.BILLING);
    _route("invoice", "we were charged twice");

    q = list(p.specs[0].questions.values())[0];
    assert q.criteria == {"BILLING": None, "SECURITY": None, "PLATFORM": None} , (
        f"labels without sem must still be offered, got {q.criteria}"
    );
}


test "call arguments become the state, keyed by parameter name" {
    p = _reset(Team.SECURITY);
    _route("vulnerability", "one tenant can read another tenant's files");

    state = p.specs[0].state;
    assert state
        == {
            "subject": "vulnerability",
            "body": "one tenant can read another tenant's files"
        } , f"state must be the named arguments, got {state}";
}


test "a bool return lowers to a noul" {
    p = _reset(True);
    _is_spam("YOU HAVE WON");

    spec = p.specs[0];
    assert spec.mode == "bool" , f"expected bool mode, got {spec.mode!r}";
    q = list(spec.questions.values())[0];
    assert q.kind == "noul" , f"a bool is a noul, got {q.kind!r}";
    assert q.instructions == "True if this message is unsolicited bulk mail" , (
        f"the function's sem must be the instructions, got {q.instructions!r}"
        f" | {p.infos[0]}"
    );
    assert q.criteria is None , f"a bare bool needs no criteria, got {q.criteria}";
}


test "an open-ended return is refused so it can go to the fallback" {
    p = _reset("a summary");
    _summarize("some long document");

    assert p.specs[0] is None , (
        "`-> str` has no closed option set and must not be lowered"
    );
}


test "a frontier wider than the provider allows is refused, not truncated" {
    p = _reset(Team.PLATFORM, caps=ProviderCaps(max_choice_options=2));
    _route("anything", "at all");

    assert p.specs[0] is None , (
        "three labels must be refused when the provider caps choices at two"
    );
}


test "a chosen label is rebuilt into the declared enum member" {
    p = _reset(Priority.LOW);
    _rank("the checkout page is down");
    spec = p.specs[0];

    (value, conf) = assemble(
        spec, {"value": {"type": "choice", "choice": "HIGH", "confidence": 0.93}}
    );
    assert value is Priority.HIGH , f"expected the enum member, got {value!r}";
    assert conf == 0.93 , f"confidence must survive, got {conf}";
}


test "a noul probability becomes a bool and a two-option confidence" {
    p = _reset(True);
    _is_spam("YOU HAVE WON");
    spec = p.specs[0];

    (value, conf) = assemble(spec, {"value": {"type": "noul", "noul": 0.9}});
    assert value is True , f"0.9 is a yes, got {value!r}";
    assert abs(conf - 0.8) < 1e-9 , f"|2p-1| for p=0.9 is 0.8, got {conf}";

    (value2, conf2) = assemble(spec, {"value": {"type": "noul", "noul": 0.5}});
    assert value2 is False , "0.5 is not a yes";
    assert abs(conf2) < 1e-9 , f"an even split is zero confidence, got {conf2}";
}


test "a label outside the declared enum is an error, not a silent None" {
    p = _reset(Priority.LOW);
    _rank("the checkout page is down");
    spec = p.specs[0];

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
    p = _reset(Priority.LOW);
    _rank("the checkout page is down");

    payload = p.specs[0].to_payload("jev-latest");
    assert payload["model"] == "jev-latest";
    assert payload["state"] == {"ticket": "the checkout page is down"};
    q = list(payload["questions"].values())[0];
    assert q["type"] == "choice" , f"the wire field is `type`, got {q}";
    assert set(q.keys()) == {"type", "instructions", "criteria"} , (
        f"unexpected wire fields: {sorted(q.keys())}"
    );
}


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
