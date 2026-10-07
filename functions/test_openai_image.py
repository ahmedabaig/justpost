import base64
from types import SimpleNamespace

import httpx
import openai
import pytest

from justpost.model_io import ModelError, ModelRefusal
from justpost.openai_image import OpenAIImageModel


class FakeImages:
    def __init__(self, result):
        self.result = result
        self.calls: list[dict] = []

    def edit(self, **kwargs):
        self.calls.append(kwargs)
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


def _model_returning(result) -> tuple[OpenAIImageModel, FakeImages]:
    model = OpenAIImageModel(api_key="sk-test", model="gpt-image-test", quality="medium")
    images = FakeImages(result)
    model._client = SimpleNamespace(images=images)
    return model, images


def _bad_request(code: str | None) -> openai.BadRequestError:
    request = httpx.Request("POST", "https://api.openai.com/v1/images/edits")
    body = {"code": code, "message": "details that must not leak"}
    return openai.BadRequestError(
        "rejected", response=httpx.Response(400, request=request), body=body
    )


def test_sends_the_reference_and_decodes_the_image():
    model, images = _model_returning(
        SimpleNamespace(
            data=[SimpleNamespace(b64_json=base64.b64encode(b"png-bytes").decode())],
            usage=SimpleNamespace(input_tokens=500, output_tokens=4000),
        )
    )

    reply = model.edit("Make it.", b"webp-bytes", "704x1536")

    assert reply.image == b"png-bytes"
    assert reply.model == "gpt-image-test"
    assert (reply.input_tokens, reply.output_tokens) == (500, 4000)
    call = images.calls[0]
    assert call["image"] == ("reference.webp", b"webp-bytes", "image/webp")
    assert (call["prompt"], call["size"], call["quality"]) == ("Make it.", "704x1536", "medium")
    assert (call["model"], call["n"], call["output_format"]) == ("gpt-image-test", 1, "png")


def test_missing_usage_is_allowed():
    model, _ = _model_returning(
        SimpleNamespace(data=[SimpleNamespace(b64_json=base64.b64encode(b"x").decode())], usage=None)
    )
    reply = model.edit("Make it.", b"webp", "704x1536")
    assert reply.input_tokens is None


def test_an_empty_reply_is_a_model_error():
    model, _ = _model_returning(SimpleNamespace(data=[], usage=None))
    with pytest.raises(ModelError):
        model.edit("Make it.", b"webp", "704x1536")


def test_moderation_blocks_become_refusals():
    model, _ = _model_returning(_bad_request("moderation_blocked"))
    with pytest.raises(ModelRefusal):
        model.edit("Make it.", b"webp", "704x1536")


def test_other_api_errors_become_model_errors_without_details():
    model, _ = _model_returning(_bad_request("invalid_size"))
    with pytest.raises(ModelError) as error:
        model.edit("Make it.", b"webp", "704x1536")
    assert not isinstance(error.value, ModelRefusal)
    assert str(error.value) == "BadRequestError"
