import from jaclang.byllm._optdeps.litellm { litellm, HAS_LITELLM }
import from jaclang.byllm.types { Audio, DEFAULT_AUDIO_FORMAT, Image, Video }

glob ROUTE_CHAT = "chat",
     ROUTE_IMAGE_ENDPOINT = "image_endpoint",
     ROUTE_SPEECH_ENDPOINT = "speech_endpoint",
     ROUTE_VIDEO_ENDPOINT = "video_endpoint";

glob KIND_NONE = "",
     KIND_IMAGE = "image",
     KIND_AUDIO = "audio",
     KIND_VIDEO = "video";

glob DEFAULT_VOICE = "alloy";


def model_entry(model_name: str) -> dict {
    if not HAS_LITELLM or not model_name {
        return {};
    }
    try {
        cost_map: any = litellm.model_cost;
    } except Exception {
        return {};
    }
    found = cost_map.get(model_name);
    if isinstance(found, dict) {
        return found;
    }

    if "/" in model_name {
        found = cost_map.get(model_name.split("/", 1)[1]);
        if isinstance(found, dict) {
            return found;
        }
    }
    return {};
}


def output_modalities(model_name: str) -> list[str] {
    mods = model_entry(model_name).get("supported_output_modalities");
    return [str(m) for m in mods] if isinstance(mods, list) else [];
}


def is_known_model(model_name: str) -> bool {
    return bool(model_entry(model_name));
}


def media_kind(resp_type: type | None) -> str {
    if resp_type is None or not isinstance(resp_type, type) {
        return KIND_NONE;
    }
    if issubclass(resp_type, Image) {
        return KIND_IMAGE;
    }
    if issubclass(resp_type, Audio) {
        return KIND_AUDIO;
    }
    if issubclass(resp_type, Video) {
        return KIND_VIDEO;
    }
    return KIND_NONE;
}


def chat_emits_audio(model_name: str) -> bool {
    if not HAS_LITELLM {
        return False;
    }
    try {
        return bool(litellm.supports_audio_output(model_name));
    } except Exception {
        return False;
    }
}


glob _INLINE_IMAGE_PROVIDERS: tuple = ("gemini", "vertex_ai");


def chat_emits_image(model_name: str) -> bool {
    if KIND_IMAGE not in output_modalities(model_name) {
        return False;
    }
    lowered = model_name.lower();
    return any(p in lowered for p in _INLINE_IMAGE_PROVIDERS);
}


def resolve_route(resp_type: type | None, model_name: str) -> str {
    kind = media_kind(resp_type);
    if kind == KIND_NONE {
        return ROUTE_CHAT;
    }
    if kind == KIND_VIDEO {
        return ROUTE_VIDEO_ENDPOINT;
    }
    if kind == KIND_IMAGE {
        if chat_emits_image(model_name) or not is_known_model(model_name) {
            return ROUTE_CHAT;
        }
        return ROUTE_IMAGE_ENDPOINT;
    }
    if chat_emits_audio(model_name) or not is_known_model(model_name) {
        return ROUTE_CHAT;
    }
    return ROUTE_SPEECH_ENDPOINT;
}


def route_error(route: str, resp_type: type | None, model_name: str) -> str {
    if route == ROUTE_CHAT {
        return "";
    }
    kind = media_kind(resp_type);
    mode = str(model_entry(model_name).get("mode") or "chat");
    hint = {
        ROUTE_IMAGE_ENDPOINT: "an image-capable chat model such as "
        "'gemini/gemini-2.5-flash-image'",
        ROUTE_SPEECH_ENDPOINT: "an audio-capable chat model such as " "'gpt-audio'",
        ROUTE_VIDEO_ENDPOINT: "no chat model emits video",

    }.get(
        route, ""
    );

    endpoint = route.removesuffix("_endpoint");
    return (
        f"Returning {kind} from `by llm()` needs the dedicated "
        f"`{endpoint}` endpoint, which byLLM does not route to yet "
        f"(model `{model_name}` has mode `{mode}`). Use {hint}."
    );
}


def audio_output_params(call_params: dict) -> dict {
    return {
        "modalities": ["text", KIND_AUDIO],
        "audio": {
            "voice": str(call_params.get("voice") or DEFAULT_VOICE),
            "format": str(call_params.get("audio_format") or DEFAULT_AUDIO_FORMAT),

        },

    };
}
