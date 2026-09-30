"""Lowering a `by llm()` call site onto the System One question protocol.

System One models answer typed questions against a shared state and return
calibrated probability distributions instead of generating text. TypeSafe's Jev
was the first; the open implementations (OpenJev, Laya, Kev) speak the same
`/v1/systemone` wire format, so this module targets the protocol rather than any
one vendor.

Nothing here knows about HTTP. The same lowering serves a hosted endpoint and an
in-process model, which is what keeps a future `LocalSystemOne` cheap.
"""

import from enum { Enum }
import from jaclang.runtime.semantic { EnumInfo, FunctionInfo, VarInfo }
import from jaclang.byllm.mtir { MTRuntime }
import from jaclang.byllm.exceptions { OutputConversionError }

glob CHOICE = "choice",
     NOUL = "noul",
     SCORE = "score";

# Modes are how `assemble` knows what to rebuild. One per lowering rule.
glob MODE_ENUM = "enum",
     MODE_BOOL = "bool";

glob ANSWER_KEY = "value";


"""What one provider's model can actually be asked.

These differ per implementation, not per protocol: Jev holds ~0.87 accuracy at
77 labels where Laya reports 0.425, so the option cap belongs here rather than
in a fixed rule. A call that exceeds the caps is refused by `lower`, which sends
it to the configured fallback instead of off a silent accuracy cliff.
"""
obj ProviderCaps {
    has base_url: str = "",
        key_env: str = "",
        model: str = "",
        max_choice_options: int = 255,
        max_state_chars: int = 120000,
        supports_batch: bool = True;
}


obj Question {
    has kind: str,
        instructions: str,
        criteria: (dict[str, any] | list[any] | None) = None;

    def to_wire -> dict[str, any];
}


obj SystemOneSpec {
    has state: dict[str, any],
        questions: dict[str, Question],
        mode: str,
        resp_type: (type | None) = None;

    def to_payload(model: str) -> dict[str, any];
}


def default_caps -> ProviderCaps;

def enum_info_of(resp_type: (type | None), info: object) -> (EnumInfo | None);

def return_info_of(mt_run: MTRuntime) -> object;

def instructions_of(mt_run: MTRuntime) -> str;

def build_state(mt_run: MTRuntime) -> (dict[str, any] | None);

def lower(
    mt_run: MTRuntime, caps: (ProviderCaps | None) = None
) -> (SystemOneSpec | None);

def assemble(spec: SystemOneSpec, answers: dict[str, any]) -> tuple[object, float];
