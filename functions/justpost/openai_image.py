"""OpenAI image model behind the `ImageModel` interface in model_io.py."""

from __future__ import annotations

import base64

import openai

from justpost.model_io import ImageReply, ModelError, ModelRefusal

# Must fit inside generate_variation's 300-second timeout, with time to upload.
REQUEST_TIMEOUT_SEC = 240


class OpenAIImageModel:
    def __init__(self, api_key: str, model: str, quality: str):
        # A failed image is retried by the user, not here: each request is paid.
        self._client = openai.OpenAI(
            api_key=api_key, timeout=REQUEST_TIMEOUT_SEC, max_retries=0
        )
        self._model = model
        self._quality = quality

    def edit(self, request: str, reference_webp: bytes, size: str) -> ImageReply:
        try:
            response = self._client.images.edit(
                model=self._model,
                image=("reference.webp", reference_webp, "image/webp"),
                prompt=request,
                size=size,
                quality=self._quality,
                n=1,
                output_format="png",
            )
        except openai.BadRequestError as error:
            if error.code == "moderation_blocked":
                raise ModelRefusal("moderation_blocked") from None
            raise ModelError(type(error).__name__) from None
        except openai.OpenAIError as error:
            raise ModelError(type(error).__name__) from None

        encoded = response.data[0].b64_json if response.data else None
        if not encoded:
            raise ModelError("EmptyImage")
        usage = response.usage
        return ImageReply(
            image=base64.b64decode(encoded),
            model=self._model,
            input_tokens=usage.input_tokens if usage else None,
            output_tokens=usage.output_tokens if usage else None,
        )
