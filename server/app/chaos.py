"""
CHAOS mode middleware for testing client resilience.
When CHAOS=1 is set, randomly introduces:
1. Tampered payload (altered JSON)
2. Incorrect checksum (wrong SHA-256 header / body)
3. Truncated response (cut off mid-body)
4. HTTP 500 server error
"""

import os
import random
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response


class ChaosMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        chaos_enabled = os.environ.get("CHAOS") == "1"
        force_chaos_type = request.headers.get("X-Force-Chaos")

        # Only apply chaos to /v1/manifest and /v1/datasets
        path = request.url.path
        is_target_path = path.startswith("/v1/manifest") or path.startswith("/v1/datasets")

        if not (chaos_enabled or force_chaos_type) or not is_target_path:
            return await call_next(request)

        # Decide whether to trigger chaos
        # If force_chaos_type is specified, trigger 100%; otherwise 25% chance
        trigger = (force_chaos_type is not None) or (random.random() < 0.25)
        if not trigger:
            return await call_next(request)

        # Choose chaos type
        chaos_type = force_chaos_type or random.choice(["tampered", "bad_checksum", "truncated", "server_error"])

        if chaos_type == "server_error":
            return Response(
                content=b'{"error": "CHAOS simulation: 500 Internal Server Error"}',
                status_code=500,
                media_type="application/json"
            )

        # Execute original response first
        response = await call_next(request)
        if response.status_code != 200:
            return response

        # Read response body
        body = [chunk async for chunk in response.body_iterator]
        body_bytes = b"".join(body)

        if chaos_type == "tampered":
            # Mutate body by replacing characters or injecting corruption
            tampered = body_bytes.replace(b"50", b"99999", 1)
            if tampered == body_bytes:
                tampered = body_bytes + b" CORRUPTED_DATA"
            headers = dict(response.headers)
            headers["content-length"] = str(len(tampered))
            return Response(content=tampered, status_code=200, headers=headers, media_type="application/json")

        elif chaos_type == "bad_checksum":
            # Valid body, but wrong SHA256 header
            headers = dict(response.headers)
            headers["x-sha256"] = "0000000000000000000000000000000000000000000000000000000000000000"
            headers["x-signature"] = "deadbeef" * 16
            return Response(content=body_bytes, status_code=200, headers=headers, media_type="application/json")

        elif chaos_type == "truncated":
            # Cut off response body halfway
            truncated = body_bytes[:max(1, len(body_bytes) // 2)]
            headers = dict(response.headers)
            headers["content-length"] = str(len(truncated))
            return Response(content=truncated, status_code=200, headers=headers, media_type="application/json")

        return response
