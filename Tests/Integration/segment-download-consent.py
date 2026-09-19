#!/usr/bin/env python3
"""Check consent types through real transports without invoking a download."""
import http.client
import json
import socket
import subprocess
import sys
import time
from pathlib import Path

OMITTED = object()
INVALID_REASON = "invalid_download_assets"
VALID_REASON = "exactly_one_seed_required"
CASES = [
    (OMITTED, VALID_REASON), (False, VALID_REASON), (True, VALID_REASON),
    (0, INVALID_REASON), (1, INVALID_REASON), (1.0, INVALID_REASON),
    ("true", INVALID_REASON), ("1", INVALID_REASON), (None, INVALID_REASON),
    ([], INVALID_REASON), ({}, INVALID_REASON),
]


def rpc(request_id, consent):
    # A missing seed stops every valid request before image loading or model access.
    arguments = {"format": "json"}
    if consent is not OMITTED:
        arguments["downloadAssets"] = consent
    return {"jsonrpc": "2.0", "id": request_id, "method": "tools/call",
            "params": {"name": "segment", "arguments": arguments}}


def assert_error(error, reason):
    assert error.get("error") == "bad_request", error
    assert error.get("reason") == reason, error


def assert_rpc_error(response, request_id, reason):
    assert response.get("id") == request_id, response
    result = response["result"]
    assert result.get("isError") is True, response
    assert_error(json.loads(result["content"][0]["text"]), reason)


def http_request(port, method, path, body=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        connection.request(method, path, body=body,
                           headers={"Content-Type": "application/json"})
        response = connection.getresponse()
        return response.status, response.read()
    finally:
        connection.close()


def main():
    binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else ".build/release/macvis").resolve())
    requests = [rpc(index, consent) for index, (consent, _) in enumerate(CASES, 1)]
    completed = subprocess.run(
        [binary, "mcp"], input="".join(json.dumps(request) + "\n" for request in requests),
        capture_output=True, text=True, timeout=20, check=True)
    responses = [json.loads(line) for line in completed.stdout.splitlines()]
    assert len(responses) == len(CASES), responses
    for index, (response, (_, reason)) in enumerate(zip(responses, CASES), 1):
        assert_rpc_error(response, index, reason)

    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    server = subprocess.Popen([binary, "serve", "--host", "127.0.0.1", "--port", str(port)],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 10
        while True:
            if server.poll() is not None:
                raise AssertionError(f"HTTP server exited: {server.returncode}")
            try:
                status, _ = http_request(port, "GET", "/mcp")
                assert status == 404, status
                break
            except (OSError, http.client.HTTPException):
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.05)
        for index, (consent, reason) in enumerate(CASES, 1):
            status, body = http_request(port, "POST", "/mcp", json.dumps(rpc(index, consent)))
            assert status == 200, (status, body)
            assert_rpc_error(json.loads(body), index, reason)
        for query, reason in [
            ("", VALID_REASON), ("&downloadAssets=false", VALID_REASON),
            ("&downloadAssets=true", VALID_REASON), ("&downloadAssets=1", INVALID_REASON),
            ("&downloadAssets=1.0", INVALID_REASON), ("&downloadAssets=0", INVALID_REASON),
            ("&downloadAssets=", INVALID_REASON), ("&downloadAssets=yes", INVALID_REASON),
        ]:
            status, body = http_request(port, "QUERY", "/segment?format=json" + query, b"")
            assert status == 400, (status, body)
            assert_error(json.loads(body), reason)
        status, _ = http_request(port, "QUERY", "/unknown?format=json&downloadAssets=1", b"")
        assert status == 404, status
    finally:
        if server.poll() is None:
            server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait(timeout=5)
    print("segment download consent passed: stdio MCP, HTTP MCP, and HTTP QUERY")


if __name__ == "__main__":
    main()
