"""OpenAI vision model behind the `VisionModel` interface in model_io.py."""

from __future__ import annotations

import base64

import openai

from justpost.model_io import ModelError, ModelReply

# Two attempts must fit inside analyze_asset's 120-second timeout.
REQUEST_TIMEOUT_SEC = 50
MAX_OUTPUT_TOKENS = 8_000


class OpenAIVisionModel:
    def __init__(self, api_key: str, model: str):
        # model_io.run_attempts does its own retrying, with feedback between attempts.
        self._client = openai.OpenAI(
            api_key=api_key, timeout=REQUEST_TIMEOUT_SEC, max_retries=0
        )
        self._model = model

    def respond(self, instructions: str, user_text: str, image_webp: bytes) -> ModelReply:
        image_url = "data:image/webp;base64," + base64.b64encode(image_webp).decode()
        try:
            response = self._client.responses.create(
                model=self._model,
                instructions=instructions,
                input=[
                    {
                        "role": "user",
                        "content": [
                            {"type": "input_text", "text": user_text},
                            {"type": "input_image", "image_url": image_url, "detail": "high"},
                        ],
                    }
                ],
                max_output_tokens=MAX_OUTPUT_TOKENS,
                store=False,
            )
        except openai.OpenAIError as error:
            raise ModelError(type(error).__name__) from None

        refusals = [
            content.refusal
            for item in response.output
            if item.type == "message"
            for content in item.content
            if content.type == "refusal"
        ]
        usage = response.usage
        return ModelReply(
            text=response.output_text or "\n".join(refusals),
            model=response.model,
            refusal=bool(refusals) and not response.output_text,
            input_tokens=usage.input_tokens if usage else None,
            output_tokens=usage.output_tokens if usage else None,
        )
