import base64
from types import SimpleNamespace

import httpx
import openai
import pytest

from justpost.model_io import ModelError
from justpost.openai_client import OpenAIVisionModel


def _response(content, output_text):
    return SimpleNamespace(
        output=[SimpleNamespace(type="message", content=content)],
        output_text=output_text,
        model="test-model-2026",
        usage=SimpleNamespace(input_tokens=1200, output_tokens=350),
    )


class FakeResponses:
    def __init__(self, result):
        self.result = result
        self.calls: list[dict] = []

    def create(self, **kwargs):
        self.calls.append(kwargs)
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


def _model_returning(result) -> tuple[OpenAIVisionModel, FakeResponses]:
    model = OpenAIVisionModel(api_key="sk-test", model="test-model")
    responses = FakeResponses(result)
    model._client = SimpleNamespace(responses=responses)
    return model, responses


def test_sends_the_image_inline_and_reads_the_reply():
    text = '{"schemaVersion": 1}'
    model, responses = _model_returning(
        _response([SimpleNamespace(type="output_text", text=text)], text)
    )

    reply = model.respond("Describe it.", "Analyze this slide.", b"webp-bytes")

    assert reply.text == text
    assert reply.model == "test-model-2026"
    assert not reply.refusal
    assert (reply.input_tokens, reply.output_tokens) == (1200, 350)
    call = responses.calls[0]
    assert call["model"] == "test-model"
    assert call["instructions"] == "Describe it."
    assert call["store"] is False
    assert call["input"][0]["content"][0] == {
        "type": "input_text",
        "text": "Analyze this slide.",
    }
    image = call["input"][0]["content"][1]
    expected = "data:image/webp;base64," + base64.b64encode(b"webp-bytes").decode()
    assert image == {"type": "input_image", "image_url": expected, "detail": "high"}


def test_extra_images_follow_the_first_in_order():
    model, responses = _model_returning(
        _response([SimpleNamespace(type="output_text", text="{}")], "{}")
    )

    model.respond("Check it.", "Questions.", b"reference", [b"generated"])

    content = responses.calls[0]["input"][0]["content"]
    assert [part["type"] for part in content] == ["input_text", "input_image", "input_image"]
    assert content[2]["image_url"].endswith(base64.b64encode(b"generated").decode())


def test_refusals_are_flagged():
    model, _ = _model_returning(
        _response([SimpleNamespace(type="refusal", refusal="I can't help with that.")], "")
    )

    reply = model.respond("Describe it.", "Analyze this slide.", b"webp")

    assert reply.refusal
    assert reply.text == "I can't help with that."


def test_api_errors_become_model_errors_without_details():
    request = httpx.Request("POST", "https://api.openai.com/v1/responses")
    model, _ = _model_returning(openai.APIConnectionError(request=request))

    with pytest.raises(ModelError) as error:
        model.respond("Describe it.", "Analyze this slide.", b"webp")
    assert str(error.value) == "APIConnectionError"
