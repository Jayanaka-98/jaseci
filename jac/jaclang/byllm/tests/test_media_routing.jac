"""Tests for return-type-driven media routing (byllm/media_routing.jac).

Covers:
  1.  media_kind maps each Media subclass and stays inert for ordinary types
  2.  resolve_route picks chat vs a dedicated endpoint per model capability
  3.  route_error explains an unsupported route and stays silent for chat
  4.  audio_output_params defaults and per-call overrides
  5.  Audio normalizes paths, bytes, file objects and data URLs
  6.  Audio.to_dict emits the provider `input_audio` block
  7.  _media_from_message lifts images/audio off a completion message
  8.  _parse_output leaves non-media return types on the text path
  9.  media return types suppress the response_format schema
  10. media return types reject tools and streaming up front
"""

import io;
import os;
import base64;
import from jaclang.byllm.types { Audio, Image, Text, Video }
import from jaclang.byllm.media_routing {
    KIND_AUDIO,
    KIND_IMAGE,
    KIND_NONE,
    KIND_VIDEO,
    ROUTE_CHAT,
    ROUTE_IMAGE_ENDPOINT,
    ROUTE_SPEECH_ENDPOINT,
    ROUTE_VIDEO_ENDPOINT,
    audio_output_params,
    media_kind,
    resolve_route,
    route_error
}
import from jaclang.byllm.llm { _media_from_message, _parse_output }
import from jaclang.byllm.mtir { MTRuntime }
import sys;
import from jaclang { JacRuntimeInterface as Jac }

glob FIXTURE_DIR = os.path.join(os.path.dirname(__file__), "fixtures"),
     # 44-byte silent WAV: RIFF header + fmt chunk + empty data chunk.
     WAV_BYTES: bytes = (
         b"RIFF$\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00"
         b"\x40\x1f\x00\x00\x80>\x00\x00\x02\x00\x10\x00data\x00\x00\x00\x00"
     );


obj _Person {
    has name: str;
}


"""Import a fixture module and return everything it printed."""
def _run_fixture(name: str) -> str {
    captured = io.StringIO();
    sys.stdout = captured;
    try {
        Jac.jac_import(name, base_path=FIXTURE_DIR + "/");
    } finally {
        sys.stdout = sys.__stdout__;
    }
    return captured.getvalue();
}


# ---------------------------------------------------------------------------
# 1. media_kind and resolve_route
# ---------------------------------------------------------------------------
test "media_kind maps Media subclasses and stays inert for everything else" {
    # Text is a Media subclass but never something a model is asked to produce.
    cases = [
        (Image, KIND_IMAGE),
        (Audio, KIND_AUDIO),
        (Video, KIND_VIDEO),
        (Text, KIND_NONE),
        (str, KIND_NONE),
        (int, KIND_NONE),
        (None, KIND_NONE),
        (_Person, KIND_NONE)
    ];
    for (ty, want) in cases {
        assert media_kind(ty) == want , f"media_kind({ty}) != {want}";
    }
}


test "resolve_route picks the transport from the return type and the model" {
    cases = [
        # A non-media return type never leaves the chat route.
        (str, "dall-e-3", ROUTE_CHAT),
        (None, "gpt-4o", ROUTE_CHAT),
        # Gemini populates message.images on a chat completion, so it serves
        # an Image return inline.
        (Image, "gemini/gemini-2.5-flash-image", ROUTE_CHAT),
        (Audio, "gpt-audio", ROUTE_CHAT),
        # Dedicated generation models need an endpoint byLLM does not drive yet.
        (Image, "dall-e-3", ROUTE_IMAGE_ENDPOINT),
        (Audio, "gpt-4o", ROUTE_SPEECH_ENDPOINT),
        (Video, "gemini/gemini-2.5-flash-image", ROUTE_VIDEO_ENDPOINT),
        # gpt-5.1 lists `image` output but serves it through the Responses API,
        # so the modality flag alone must not win. Verified live: the chat route
        # returned prose with no picture and exhausted the retries.
        (Image, "gpt-5.1", ROUTE_IMAGE_ENDPOINT),
        # An unknown model carries no capability metadata to prove it cannot,
        # and the caller named the media return type deliberately.
        (Image, "my-proxy/some-vlm", ROUTE_CHAT),
        (Audio, "mockllm", ROUTE_CHAT)
    ];
    for (ty, model, want) in cases {
        assert resolve_route(ty, model) == want , f"{ty} on {model} != {want}";
    }
}


# ---------------------------------------------------------------------------
# 3. route_error
# ---------------------------------------------------------------------------
test "route_error is empty for the chat route" {
    assert route_error(ROUTE_CHAT, Image, "gemini/gemini-2.5-flash-image") == "";
}


test "route_error names the media kind and a model that would work" {
    msg = route_error(ROUTE_IMAGE_ENDPOINT, Image, "dall-e-3");
    assert KIND_IMAGE in msg;
    assert "dall-e-3" in msg;
    assert "gemini/gemini-2.5-flash-image" in msg;
}


# ---------------------------------------------------------------------------
# 4. audio_output_params
# ---------------------------------------------------------------------------
test "audio_output_params defaults to a wav voice turn" {
    params = audio_output_params({});
    assert params["modalities"] == ["text", "audio"];
    assert params["audio"] == {"voice": "alloy", "format": "wav"};
}


test "audio_output_params honours per-call voice and format" {
    params = audio_output_params({"voice": "ash", "audio_format": "mp3"});
    assert params["audio"] == {"voice": "ash", "format": "mp3"};
}


# ---------------------------------------------------------------------------
# 5. Audio input normalization
# ---------------------------------------------------------------------------
test "Audio normalizes every accepted input form to the same payload" {
    b64 = base64.b64encode(WAV_BYTES).decode("utf-8");
    sources = [
        (os.path.join(FIXTURE_DIR, "silence.wav"), "wav"),
        (WAV_BYTES, "wav"),
        (f"data:audio/mp3;base64,{b64}", "mp3")
    ];
    for (src, want_format) in sources {
        clip = Audio(src);
        assert clip.format == want_format , f"{src!r:.40} -> {clip.format}";
        assert base64.b64decode(clip._b64) == WAV_BYTES;
    }
}


test "Audio reads a file-like object without moving the caller's cursor" {
    buf = io.BytesIO(WAV_BYTES);
    buf.seek(4);
    clip = Audio(buf);
    assert base64.b64decode(clip._b64) == WAV_BYTES;
    assert buf.tell() == 4;
}


test "Audio rejects a missing file" {
    raised = False;
    try {
        Audio(os.path.join(FIXTURE_DIR, "definitely-not-here.wav"));
    } except ValueError {
        raised = True;
    }
    assert raised;
}


test "Audio.from_b64 round-trips payload, format and transcript" {
    b64 = base64.b64encode(WAV_BYTES).decode("utf-8");
    clip = Audio.from_b64(b64, "mp3", "hello there");
    assert clip._b64 == b64;
    assert clip.format == "mp3";
    assert clip.transcript == "hello there";
}


# ---------------------------------------------------------------------------
# 6. Audio serialization
# ---------------------------------------------------------------------------
test "Audio.to_dict emits an input_audio block" {
    clip = Audio(WAV_BYTES);
    blocks = clip.to_dict();
    assert len(blocks) == 1;
    assert blocks[0]["type"] == "input_audio";
    assert blocks[0]["input_audio"]["format"] == "wav";
    assert blocks[0]["input_audio"]["data"] == clip._b64;
}


test "Audio.save writes the decoded bytes back out" {
    import tempfile;
    clip = Audio(WAV_BYTES);
    with tempfile.TemporaryDirectory() as tmp {
        out = clip.save(os.path.join(tmp, "out.wav"));
        with open(out, "rb") as fh {
            assert fh.read() == WAV_BYTES;
        }
    }
}


# ---------------------------------------------------------------------------
# 7. Lifting media off a completion message
# ---------------------------------------------------------------------------
test "_media_from_message lifts an inline generated image" {
    message = {
        "role": "assistant",
        "content": "here you go",
        "images": [
            {
                "type": "image_url",
                "image_url": {"url": "data:image/png;base64,AAAA"},
                "index": 0
            }
        ]
    };
    out = _media_from_message(message, KIND_IMAGE, {});
    assert isinstance(out, Image);
    assert out.url == "data:image/png;base64,AAAA";
}


test "_media_from_message lifts returned audio with its transcript" {
    b64 = base64.b64encode(WAV_BYTES).decode("utf-8");
    message = {
        "role": "assistant",
        "content": "",
        "audio": {"id": "a1", "data": b64, "transcript": "spoken words"}
    };
    out = _media_from_message(message, KIND_AUDIO, {"audio_format": "wav"});
    assert isinstance(out, Audio);
    assert out.transcript == "spoken words";
    assert base64.b64decode(out._b64) == WAV_BYTES;
}


test "_media_from_message returns None when the model sent no media" {
    message = {"role": "assistant", "content": "I cannot draw that."};
    # None is what drives the typed-output retry loop to ask again.
    assert _media_from_message(message, KIND_IMAGE, {}) is None;
    assert _media_from_message(message, KIND_AUDIO, {}) is None;
}


# ---------------------------------------------------------------------------
# 8. _parse_output keeps ordinary return types on the text path
# ---------------------------------------------------------------------------
test "_parse_output leaves a str return type to the text parser" {
    mt_run = MTRuntime(
        messages=[], resp_type=str, stream=False, tools=[], call_params={}
    );
    message = {"role": "assistant", "content": "plain answer"};
    assert _parse_output(mt_run, message, "plain answer") == "plain answer";
}


test "_parse_output reads media off the message, not the content text" {
    mt_run = MTRuntime(
        messages=[], resp_type=Image, stream=False, tools=[], call_params={}
    );
    message = {
        "role": "assistant",
        "content": "ignore me",
        "images": [
            {"type": "image_url", "image_url": {"url": "https://example.com/a.png"}}
        ]
    };
    out = _parse_output(mt_run, message, "ignore me");
    assert isinstance(out, Image);
    assert out.url == "https://example.com/a.png";
}


# ---------------------------------------------------------------------------
# 9. Media return types suppress the JSON response schema
# ---------------------------------------------------------------------------
test "a media return type emits no response_format schema" {
    # Otherwise the model would be asked to fill in an Image's url/mime_type
    # fields as JSON instead of producing a picture.
    for ty in [Image, Audio] {
        mt_run = MTRuntime(
            messages=[], resp_type=ty, stream=False, tools=[], call_params={}
        );
        assert mt_run.get_typed_output_schema() is None;
        assert mt_run.get_output_schema() is None;
    }
}


test "a structured return type still emits its schema" {
    mt_run = MTRuntime(
        messages=[], resp_type=_Person, stream=False, tools=[], call_params={}
    );
    assert mt_run.get_typed_output_schema() is not None;
}


# ---------------------------------------------------------------------------
# 10. End-to-end: audio input and the media-return guards
# ---------------------------------------------------------------------------
test "an Audio argument reaches the provider payload as an input_audio block" {
    stdout = _run_fixture("audio_input");
    assert "ANSWER:a short beep" in stdout;
    # Text prelude carrying the semstring, then the audio itself.
    assert 'BLOCK_KINDS:["text", "input_audio"]' in stdout;
    assert "AUDIO_FORMAT:wav" in stdout;
    assert "AUDIO_HAS_DATA:True" in stdout;
    assert "SEMSTRING_PRESENT:True" in stdout;
}


test "a media return type rejects tools, streaming and an incapable model" {
    stdout = _run_fixture("media_return_guards");
    assert "TOOLS_GUARD_PASS:True" in stdout;
    assert "STREAM_GUARD_PASS:True" in stdout;
    assert "ROUTE_GUARD_PASS:True" in stdout;
}
