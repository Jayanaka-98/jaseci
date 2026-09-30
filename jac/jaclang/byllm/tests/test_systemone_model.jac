"""SystemOneModel: provider resolution, transport, fallback and escalation.

No network. `_Stub` overrides `_request` so the status and body the endpoint
would return are scripted per call, which also exercises the real status
mapping and retry loop. Call sites are built as IR for the same reason as in
test_systemone.jac; the two fallback tests go through real `by` call sites,
because refusing `-> str` needs no IR.
"""

import asyncio;
import from jaclang.byllm.llm { BaseLLM, Model, SystemOneModel }
import from jaclang.byllm.mtir { MTIR, MTRuntime }
import from jaclang.byllm.types { Message, MessageRole }
import from jaclang.byllm.exceptions {
    AuthenticationError,
    ByLLMError,
    ConfigurationError,
    RateLimitError
}
import from jaclang.byllm.systemone { Decision, ROUTE_SELECT_ATTR, resolve_model_name }
import from jaclang.runtime.semantic {
    EnumInfo,
    FieldInfo,
    FunctionInfo,
    ParamInfo,
    TypeForm
}


enum Priority { LOW, HIGH }


def _stub_fn(ticket: str) -> object {
    return None;
}


def _priority_info -> FunctionInfo {
    return FunctionInfo(
        name="rank",
        semstr="Rank how urgent the ticket is",
        params=[ParamInfo(name="ticket", semstr=None, type_info="str")],
        return_type=EnumInfo(
            name="Priority",
            semstr=None,
            members=[
                FieldInfo(name="LOW", semstr="can wait", type_info=None),
                FieldInfo(name="HIGH", semstr="urgent now", type_info=None)
            ]
        )
    );
}


def _str_info -> FunctionInfo {
    return FunctionInfo(
        name="summarize",
        semstr="Summarize the document",
        params=[ParamInfo(name="text", semstr=None, type_info="str")],
        return_type="str"
    );
}


def _mt(
    resp_type: (type | None), args: dict[any, any], info: (FunctionInfo | None)
) -> MTRuntime {
    return MTRuntime(
        messages=[
            Message(role=MessageRole.SYSTEM, content="You are an agent."),
            Message(role=MessageRole.USER, content="Do the thing.")
        ],
        resp_type=resp_type,
        stream=False,
        tools=[],
        call_params={},
        mtir=MTIR(caller=_stub_fn, args=args, call_params={}, ir_info=info)
    );
}


def _choice(label: str, conf: float, tin: int = 300, tout: int = 40) -> dict[str, any] {
    other = "LOW" if label == "HIGH" else "HIGH";
    return {
        "model": "jev-1.13.0",
        "answers": {
            "value": {
                "type": "choice",
                "choice": label,
                "confidence": conf,
                "probabilities": {label: (1.0 + conf) / 2.0, other: (1.0 - conf) / 2.0}
            }
        },
        "usage": {"input_tokens": tin, "output_tokens": tout}
    };
}


"""Scripted endpoint: each call pops the next (status, body)."""
obj _Stub(SystemOneModel) {
    has script: list[any] = [],
        sent: list[any] = [];

    override def _request(payload: dict[str, any]) -> tuple[int, dict[str, any]] {
        self.sent.append(payload);
        (status, body) = self.script.pop(0);
        return (status, body);
    }

    override async def _arequest(
        payload: dict[str, any]
    ) -> tuple[int, dict[str, any]] {
        return self._request(payload);
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

    override async def ainvoke(mt_run: MTRuntime) -> any {
        self.seen.append(mt_run.get_msg_list());
        return self.reply;
    }
}


test "a model name resolves to a provider and a model" {
    assert resolve_model_name("systemone:typesafe/jev-latest")
        == ("typesafe", "jev-latest");
    assert resolve_model_name("systemone:jev-preview") == ("typesafe", "jev-preview") , (
        "no provider means the default provider"
    );
    assert resolve_model_name("systemone:laya") == ("laya", "") , (
        "a bare known provider name selects it and leaves the model to its default"
    );
    assert resolve_model_name("systemone:openjev/some-model")
        == ("openjev", "some-model");
}


test "postinit resolves caps, endpoint and model from the provider" {
    m = _Stub(model_name="systemone:laya");
    assert m.provider == "laya";
    assert m._so1_model == "laya" , f"model must default from caps, got {m._so1_model!r}";
    caps = m._caps;
    assert caps is not None;
    assert caps.max_choice_options == 24 , (
        "laya's option cap must come from its provider used"
    );
    assert m._endpoint() == "http://localhost:8000/v1/systemone" , m._endpoint();

    via_proxy = _Stub(model_name="systemone:litellm/jev-latest", api_key="virtual");
    assert via_proxy._endpoint() == "http://localhost:4000/typesafe/v1/systemone" , (
        via_proxy._endpoint()
    );
    assert via_proxy._headers()["Authorization"] == "Bearer virtual";

    no_key = _Stub(model_name="systemone:openjev/x");
    assert "Authorization" not in no_key._headers() , (
        "a provider with no key must not send an empty bearer"
    );
}


test "an enum call site is served by the endpoint and rebuilt into the member" {
    m = _Stub(model_name="systemone:typesafe/jev-latest", api_key="k");
    m.script = [(200, _choice("HIGH", 0.93))];
    mt = _mt(Priority, {"ticket": "the checkout page is down"}, _priority_info());

    out = m.invoke(mt);

    assert out is Priority.HIGH , f"expected the enum member, got {out!r}";
    assert len(m.sent) == 1;
    payload = m.sent[0];
    assert payload["model"] == "jev-latest";
    assert payload["state"] == {"ticket": "the checkout page is down"};
    assert list(payload["questions"].values())[0]["type"] == "choice";

    used = mt._usage_history[0];
    assert used["call_kind"] == "systemone";
    assert used["prompt_tokens"] == 300 and used["completion_tokens"] == 40;
    assert used["systemone"]["confidence"] == 0.93;
    assert used["systemone"]["provider"] == "typesafe";
    assert abs(getattr(mt, "_so1_confidence", 0.0) - 0.93) < 1e-9;
    assert set(getattr(mt, "_so1_probabilities", {})["value"].keys())
        == {"LOW", "HIGH"};
}


test "an ineligible call goes to the fallback with no request made" {
    rec = _Recorder(reply="a summary");
    m = _Stub(fallback=rec);

    out = m.invoke(_mt(str, {"text": "a long document"}, _str_info()));

    assert out == "a summary";
    assert len(rec.seen) == 1 , "the fallback must be invoked once";
    assert m.sent == [] , "nothing may be sent to the endpoint for a refused call";
}


test "an ineligible call with no fallback is a configuration error" {
    m = _Stub();
    caught = False;
    try {
        m.invoke(_mt(str, {"text": "doc"}, _str_info()));
    } except ConfigurationError as e {
        caught = True;
        assert "fallback" in str(e);
    }
    assert caught;
}


test "low confidence escalates to the fallback; high confidence does not" {
    rec = _Recorder(reply=Priority.LOW);
    m = _Stub(fallback=rec, min_confidence=0.7);
    mt = _mt(Priority, {"ticket": "hmm"}, _priority_info());

    m.script = [(200, _choice("HIGH", 0.4))];
    out = m.invoke(mt);
    assert out is Priority.LOW , "below the threshold the fallback's answer is returned";
    assert len(rec.seen) == 1;

    m.script = [(200, _choice("HIGH", 0.95))];
    out2 = m.invoke(mt);
    assert out2 is Priority.HIGH , "above the threshold the endpoint's answer stands";
    assert len(rec.seen) == 1 , "the fallback must not run when confidence is high";
}


test "endpoint statuses map onto byLLM's exceptions, with retries on 429" {
    mt = _mt(Priority, {"ticket": "x"}, _priority_info());

    m = _Stub();
    m.script = [(401, {"error": "bad key"})];
    caught = "";
    try {
        m.invoke(mt);
    } except AuthenticationError {
        caught = "auth";
    }
    assert caught == "auth";

    m = _Stub();
    m.script = [(422, {"detail": "criteria missing"})];
    caught = "";
    try {
        m.invoke(mt);
    } except ConfigurationError {
        caught = "config";
    }
    assert caught == "config";

    m = _Stub();
    m.script = [(429, {}), (429, {}), (429, {})];
    caught = "";
    try {
        m.invoke(mt);
    } except RateLimitError {
        caught = "rate";
    }
    assert caught == "rate";
    assert len(m.sent) == 3 , f"two retries means three requests, got {len(m.sent)}";

    m = _Stub();
    m.script = [(429, {}), (200, _choice("LOW", 0.9))];
    assert m.invoke(mt) is Priority.LOW , "a 429 followed by a 200 must succeed";

    m = _Stub();
    m.script = [(500, {"raw": "boom"})];
    caught = "";
    try {
        m.invoke(mt);
    } except ByLLMError {
        caught = "byllm";
    }
    assert caught == "byllm";
}


test "Model with a systemone: name delegates to a SystemOneModel" {
    rec = _Recorder(reply="fb");
    mm = Model(model_name="systemone:typesafe/jev-latest", config={"fallback": rec});
    assert isinstance(mm._so1_delegate, SystemOneModel) , (
        "the systemone: prefix must select the delegate"
    );
    assert mm._so1_delegate.fallback is rec , "config fallback must reach the delegate";

    stub = _Stub(model_name="systemone:typesafe/jev-latest");
    stub.script = [(200, _choice("HIGH", 0.9))];
    mm._so1_delegate = stub;
    out = mm.invoke(_mt(Priority, {"ticket": "down"}, _priority_info()));
    assert out is Priority.HIGH , "Model.invoke must route through the delegate";
}


glob _rec_site = _Recorder(reply="from the fallback"),
     _mm_site = Model(
         model_name="systemone:typesafe/jev-latest", config={"fallback": _rec_site}
     );


def _needs_fallback(document: str) -> str by _mm_site();


test "a real by-llm call site that is not closed-set reaches the fallback" {
    out = _needs_fallback("the quarterly report is late again");

    assert out == "from the fallback";
    assert len(_rec_site.seen) == 1;
    assert "quarterly report is late again" in str(_rec_site.seen[0]) , (
        "the fallback must see the argument in the prompt byLLM already built"
    );
}


test "the async path serves and escalates the same way" {
    rec = _Recorder(reply=Priority.LOW);
    m = _Stub(fallback=rec, min_confidence=0.7);
    mt = _mt(Priority, {"ticket": "x"}, _priority_info());

    m.script = [(200, _choice("HIGH", 0.96))];
    out = asyncio.run(m.ainvoke(mt));
    assert out is Priority.HIGH;
    assert len(rec.seen) == 0;

    m.script = [(200, _choice("HIGH", 0.2))];
    out2 = asyncio.run(m.ainvoke(mt));
    assert out2 is Priority.LOW , "low confidence must escalate on the async path too";
    assert len(rec.seen) == 1;
}


test "a Decision[T] call site gets the envelope with the endpoint's confidence" {
    m = _Stub(model_name="systemone:typesafe/jev-latest");
    m.script = [(200, _choice("HIGH", 0.93))];
    dt = Decision.__class_getitem__(Priority);

    out = m.invoke(_mt(dt, {"ticket": "down"}, _priority_info()));

    assert isinstance(out, Decision) , f"expected a Decision, got {out!r}";
    assert out.value is Priority.HIGH;
    assert out.confidence == 0.93;
    assert set(out.probabilities["value"].keys()) == {"LOW", "HIGH"};
}


def _noul_body(ps: dict[str, float]) -> dict[str, any] {
    return {
        "model": "jev-1.13.0",
        "answers": {k: {"type": "noul", "noul": v} for (k, v) in ps.items()},
        "usage": {"input_tokens": 300, "output_tokens": 40}
    };
}


test "an exact select whose Nth pick misses the gate escalates to the fallback" {
    rec = _Recorder(reply=[Priority.LOW]);
    m = _Stub(fallback=rec, min_confidence=0.5);
    base = _priority_info();
    info = FunctionInfo(
        name="rank_all",
        semstr="Which priorities apply",
        params=base.params,
        return_type=TypeForm(head="list", args=[base.return_type])
    );
    mt = _mt(list[Priority], {"ticket": "hmm"}, info);
    setattr(mt, ROUTE_SELECT_ATTR, 2);

    m.script = [(200, _noul_body({"LOW": 0.9, "HIGH": 0.3}))];
    out = m.invoke(mt);
    assert out == [Priority.LOW] , "the short exact-N answer must escalate, got the endpoint's list";
    assert len(rec.seen) == 1;

    m.script = [(200, _noul_body({"LOW": 0.9, "HIGH": 0.8}))];
    out2 = m.invoke(mt);
    assert out2 == [Priority.LOW, Priority.HIGH] , f"both above the gate stands, got {out2!r}";
    assert len(rec.seen) == 1 , "no escalation when the Nth pick clears the gate";
}
