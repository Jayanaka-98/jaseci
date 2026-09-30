impl Question.to_wire -> dict[str, any] {
    wire: dict[str, any] = {"type": self.kind, "instructions": self.instructions};
    if self.criteria is not None {
        wire["criteria"] = self.criteria;
    }
    return wire;
}


impl SystemOneSpec.to_payload(model: str) -> dict[str, any] {
    return {
        "model": model,
        "state": self.state,
        "questions": {k: q.to_wire() for (k, q) in self.questions.items()}
    };
}


impl default_caps -> ProviderCaps {
    return ProviderCaps();
}


impl enum_info_of(resp_type: object, info: object) -> (EnumInfo | None) {
    if not (isinstance(resp_type, type) and issubclass(resp_type, Enum)) {
        return None;
    }
    if isinstance(info, EnumInfo) {
        return info;
    }
    if isinstance(info, VarInfo) and isinstance(info.type_info, EnumInfo) {
        return info.type_info;
    }
    return None;
}


impl return_info_of(mt_run: MTRuntime) -> object {
    owner = mt_run.mtir;
    owner_info = owner.ir_info if owner else None;
    return owner_info.return_type if isinstance(owner_info, FunctionInfo) else None;
}


impl instructions_of(mt_run: MTRuntime) -> str {
    owner = mt_run.mtir;
    owner_info = owner.ir_info if owner else None;
    if isinstance(owner_info, FunctionInfo) and owner_info.semstr {
        return owner_info.semstr;
    }
    caller = owner.caller if owner else None;
    doc = caller?.__doc__;
    if isinstance(doc, str) and doc.strip() {
        return doc.strip();
    }
    name = getattr(caller, "__name__", "")
        or (owner_info.name if isinstance(owner_info, FunctionInfo) else "");
    if name {
        return str(name).strip("_").replace("_", " ");
    }
    return "Choose the value the program should receive.";
}


def _state_value(value: object) -> object {
    if value is None or isinstance(value, (str, int, float, bool)) {
        return value;
    }
    if isinstance(value, dict) {
        return {str(k): _state_value(v) for (k, v) in value.items()};
    }
    if isinstance(value, (list, tuple, set)) {
        return [_state_value(v) for v in value];
    }
    return repr(value);
}


def _messages_text(mt_run: MTRuntime) -> str {
    parts: list[str] = [];
    for msg in mt_run.get_msg_list() {
        content = msg.get("content") if isinstance(msg, dict) else None;
        if isinstance(content, str) and content {
            parts.append(content);
        }
    }
    return "\n\n".join(parts);
}


impl build_state(mt_run: MTRuntime) -> (dict[str, any] | None) {
    import from jaclang.byllm.types { Media }

    owner = mt_run.mtir;
    if owner is None {
        text = _messages_text(mt_run);
        return {"context": text} if text else None;
    }

    owner_info = owner.ir_info if isinstance(owner.ir_info, FunctionInfo) else None;
    params = (owner_info.params if owner_info else None) or [];

    state: dict[str, any] = {};
    for (idx, key) in enumerate(list(owner.args.keys())) {
        value = owner.args[key];
        if isinstance(value, Media) {
            return None;
        }
        if isinstance(key, str) {
            name = key;
        } elif idx < len(params) {
            name = params[idx].name;
        } else {
            name = f"arg{idx}";
        }
        state[str(name)] = _state_value(value);
    }
    return state;
}


def _lower_enum(
    resp_type: object,
    enum_info: (EnumInfo | None),
    instructions: str,
    caps: ProviderCaps
) -> (Question | None) {
    described: dict[str, any] = {};
    for member in ((enum_info.members if enum_info else None) or []) {
        described[member.name] = member.semstr or None;
    }
    criteria: dict[str, any] = {};
    for name in getattr(resp_type, "__members__", {}) {
        criteria[name] = described.get(name);
    }
    if len(criteria) < 2 or len(criteria) > caps.max_choice_options {
        return None;
    }
    return Question(kind=CHOICE, instructions=instructions, criteria=criteria);
}


def _lower_bool(instructions: str) -> Question {
    return Question(kind=NOUL, instructions=instructions, criteria=None);
}


impl lower(
    mt_run: MTRuntime, caps: (ProviderCaps | None) = None
) -> (SystemOneSpec | None) {
    import from jaclang.byllm.types { image_resp_kind }

    caps = caps or default_caps();

    if mt_run.tools or mt_run.stream or image_resp_kind(mt_run.resp_type) {
        return None;
    }

    resp_type = mt_run.resp_type;
    if resp_type is None or resp_type is str {
        return None;
    }

    instructions = instructions_of(mt_run);
    question: (Question | None) = None;
    mode = "";

    if resp_type is bool {
        question = _lower_bool(instructions);
        mode = MODE_BOOL;
    } elif isinstance(resp_type, type) and issubclass(resp_type, Enum) {
        question = _lower_enum(
            resp_type,
            enum_info_of(resp_type, return_info_of(mt_run)),
            instructions,
            caps
        );
        mode = MODE_ENUM;
    }

    if question is None {
        return None;
    }

    state = build_state(mt_run);
    if state is None {
        return None;
    }
    if len(repr(state)) > caps.max_state_chars {
        return None;
    }

    return SystemOneSpec(
        state=state,
        questions={ANSWER_KEY: question},
        mode=mode,
        resp_type=mt_run.resp_type
    );
}


impl assemble(spec: SystemOneSpec, answers: dict[str, any]) -> tuple[object, float] {
    answer = answers.get(ANSWER_KEY);
    if not isinstance(answer, dict) {
        raise OutputConversionError(
            f"System One response carried no answer for {ANSWER_KEY!r}"
        );
    }

    if spec.mode == MODE_BOOL {
        p = float(answer.get("noul", 0.0));

        return (p > 0.5, abs(2.0 * p - 1.0));
    }

    if spec.mode == MODE_ENUM {
        name = answer.get("choice");
        members = getattr(spec.resp_type, "__members__", {});
        if name not in members {
            raise OutputConversionError(
                f"System One returned label {name!r}, which is not a member of "
                f"{getattr(spec.resp_type, '__name__', '?')}"
            );
        }
        return (members[name], float(answer.get("confidence", 0.0)));
    }

    raise OutputConversionError(f"unknown System One lowering mode {spec.mode!r}");
}
