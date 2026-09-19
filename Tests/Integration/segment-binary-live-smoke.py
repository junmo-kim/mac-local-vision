#!/usr/bin/env python3
"""Verify installed segmentation assets in fresh processes; never request downloads.

Usage: python3 Tests/Integration/segment-binary-live-smoke.py [macvis-binary]
Missing assets are a failure, not a skipped test. Requires a macOS 27 live session.
"""

import base64
from contextlib import contextmanager
import http.client
import json
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time
import zlib


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
INPUT_WIDTH, INPUT_HEIGHT = 300, 200
CENTER_X, CENTER_Y = 90, 60
TIMEOUT = 120


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def chunk(kind, data):
    return (struct.pack(">I", len(data)) + kind + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))


def fixture_png():
    rows = bytearray()
    for y in range(INPUT_HEIGHT):
        rows.append(0)
        for x in range(INPUT_WIDTH):
            inside = ((x - CENTER_X) ** 2 * 30 ** 2
                      + (y - CENTER_Y) ** 2 * 40 ** 2 <= 40 ** 2 * 30 ** 2)
            rows.extend((230, 25, 25) if inside else (245, 245, 245))
    header = struct.pack(">IIBBBBB", INPUT_WIDTH, INPUT_HEIGHT, 8, 2, 0, 0, 0)
    return (PNG_SIGNATURE + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def paeth(left, above, upper_left):
    prediction = left + above - upper_left
    distances = (abs(prediction - left), abs(prediction - above),
                 abs(prediction - upper_left))
    if distances[0] <= distances[1] and distances[0] <= distances[2]:
        return left
    if distances[1] <= distances[2]:
        return above
    return upper_left


def decode_gray_png(data):
    require(data.startswith(PNG_SIGNATURE), "mask is not a PNG")
    offset, header, compressed, ended = 8, None, bytearray(), False
    while offset < len(data):
        require(offset + 12 <= len(data), "truncated PNG chunk")
        length = struct.unpack_from(">I", data, offset)[0]
        kind = data[offset + 4:offset + 8]
        end = offset + 12 + length
        require(end <= len(data), "truncated PNG chunk data")
        payload = data[offset + 8:offset + 8 + length]
        crc = struct.unpack_from(">I", data, offset + 8 + length)[0]
        require(crc == zlib.crc32(kind + payload) & 0xFFFFFFFF,
                f"invalid PNG CRC for {kind!r}")
        if header is None:
            require(kind == b"IHDR" and length == 13, "PNG must start with IHDR")
            header = struct.unpack(">IIBBBBB", payload)
        elif kind == b"IHDR":
            raise AssertionError("duplicate PNG IHDR")
        elif kind == b"IDAT":
            compressed.extend(payload)
        elif kind == b"IEND":
            require(length == 0 and end == len(data), "invalid PNG end")
            ended = True
            break
        offset = end
    require(header is not None and ended and compressed, "incomplete PNG")
    width, height, depth, color, compression, filtering, interlace = header
    require(0 < width <= 8192 and 0 < height <= 8192, "invalid mask dimensions")
    require((depth, color, compression, filtering, interlace) == (8, 0, 0, 0, 0),
            f"expected noninterlaced grayscale 8-bit PNG, got {header!r}")
    raw = zlib.decompress(compressed)
    require(len(raw) == height * (width + 1), "invalid PNG raster size")
    pixels = bytearray()
    previous = bytearray(width)
    for y in range(height):
        start = y * (width + 1)
        filter_type = raw[start]
        require(0 <= filter_type <= 4, f"unknown PNG filter {filter_type}")
        row = bytearray(raw[start + 1:start + 1 + width])
        for x in range(width):
            left = row[x - 1] if x else 0
            above = previous[x]
            upper_left = previous[x - 1] if x else 0
            if filter_type == 1:
                prediction = left
            elif filter_type == 2:
                prediction = above
            elif filter_type == 3:
                prediction = (left + above) // 2
            elif filter_type == 4:
                prediction = paeth(left, above, upper_left)
            else:
                prediction = 0
            row[x] = (row[x] + prediction) & 0xFF
        pixels.extend(row)
        previous = row
    return width, height, pixels


def validate_mask(result, out_path=None):
    require(isinstance(result, dict), "segment response must be a JSON object")
    require(result.get("found") is True, f"expected found=true, got {result!r}")
    require("error" not in result, "segment returned an error")
    require((result.get("image_width"), result.get("image_height"))
            == (INPUT_WIDTH, INPUT_HEIGHT), "input raster dimensions are missing or incorrect")
    for key in ("width", "height"):
        require(type(result.get(key)) is int and result[key] > 0,
                f"{key} must be a positive integer")
    if out_path is not None:
        require(result.get("path") == str(out_path), "output path does not match request")
        require("image_data" not in result, "path output must not contain image_data")
        data = out_path.read_bytes()
    else:
        require("path" not in result, "inline output must not contain path")
        encoded = result.get("image_data")
        require(isinstance(encoded, str) and encoded, "missing base64 image_data")
        data = base64.b64decode(encoded, validate=True)
    width, height, pixels = decode_gray_png(data)
    require((width, height) == (result["width"], result["height"]),
            "JSON dimensions disagree with PNG dimensions")

    def sample(x, y):
        column = min(width - 1, int(x / INPUT_WIDTH * width))
        row = min(height - 1, int(y / INPUT_HEIGHT * height))
        return pixels[row * width + column]

    foreground = sample(CENTER_X, CENTER_Y)
    background = sample(285, 190)
    require(foreground >= 224, f"foreground must be white, got {foreground}")
    require(background <= 31, f"background must be black, got {background}")
    return f"{width}x{height}, foreground={foreground}, background={background}"


def communicate(binary, args, input_text=None):
    # No download option is passed. Each invocation starts a new process.
    process = subprocess.Popen([str(binary), *args], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        stdout, stderr = process.communicate(input=input_text, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        process.kill()
        stdout, stderr = process.communicate()
        raise AssertionError(f"{args[0]} timed out after {TIMEOUT}s; {stderr[:1500]}")
    require(process.returncode == 0,
            f"{args[0]} exited {process.returncode}; "
            f"stdout={stdout[:1500]!r}; stderr={stderr[:1500]!r}")
    return stdout


def cli_case(binary, fixture, seed, quality, out_path=None):
    args = ["segment", str(fixture), *seed, "--quality", quality, "--format", "json"]
    if out_path is not None:
        args.extend(["--out", str(out_path)])
    return validate_mask(json.loads(communicate(binary, args)), out_path)


def mcp_case(binary, png):
    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2024-11-05", "capabilities": {},
            "clientInfo": {"name": "segment-live-smoke", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {
            "name": "segment", "arguments": {
                "data": base64.b64encode(png).decode("ascii"),
                "point": [CENTER_X, CENTER_Y], "quality": "balanced", "format": "json"}}},
    ]
    lines = "".join(json.dumps(request) + "\n" for request in requests)
    responses = [json.loads(line) for line in communicate(binary, ["mcp"], lines).splitlines()]
    require(len(responses) == 2, "expected exactly initialize and tools/call responses")
    for response, request_id in zip(responses, (1, 2)):
        require(isinstance(response, dict) and response.get("jsonrpc") == "2.0"
                and type(response.get("id")) is int and response["id"] == request_id
                and "error" not in response, f"invalid JSON-RPC response: {response!r}")
    initialized = responses[0].get("result")
    require(isinstance(initialized, dict)
            and initialized.get("protocolVersion") == "2024-11-05"
            and isinstance(initialized.get("capabilities"), dict)
            and isinstance(initialized.get("serverInfo"), dict), "invalid initialize result")
    return validate_mcp_mask(responses[1], 2)


def validate_mcp_mask(response, request_id):
    require(isinstance(response, dict) and response.get("jsonrpc") == "2.0"
            and type(response.get("id")) is int and response["id"] == request_id
            and "error" not in response, f"invalid JSON-RPC response: {str(response)[:1500]}")
    result = response.get("result")
    require(isinstance(result, dict) and result.get("isError") is False,
            f"MCP segment failed: {str(result)[:1500]}")
    content = result.get("content")
    require(isinstance(content, list) and len(content) == 1
            and isinstance(content[0], dict) and content[0].get("type") == "text"
            and isinstance(content[0].get("text"), str), "invalid MCP text content")
    return validate_mask(json.loads(content[0]["text"]))


def http_request(port, method, path, body=None, content_type="application/json", timeout=TIMEOUT):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        connection.request(method, path, body=body, headers={"Content-Type": content_type})
        response = connection.getresponse()
        return response.status, response.getheader("Content-Type", ""), response.read()
    finally:
        connection.close()


@contextmanager
def live_server(binary):
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    # A file avoids pipe backpressure when native diagnostics are verbose.
    with tempfile.TemporaryFile() as log:
        server = subprocess.Popen(
            [str(binary), "serve", "--host", "127.0.0.1", "--port", str(port)],
            stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 10
            while True:
                if server.poll() is not None:
                    log.seek(0)
                    raise AssertionError(f"HTTP server exited {server.returncode}; "
                                         f"log={log.read(1500).decode('utf-8', errors='replace')}")
                remaining = deadline - time.monotonic()
                require(remaining > 0, "HTTP server was not ready within 10s")
                try:
                    status, _, _ = http_request(port, "GET", "/mcp", timeout=min(1, remaining))
                    require(status == 404, f"readiness GET /mcp expected 404, got {status}")
                    require(server.poll() is None, "HTTP server died during readiness check")
                    break
                except (OSError, http.client.HTTPException):
                    time.sleep(min(0.05, max(0, deadline - time.monotonic())))
            yield port
        finally:
            if server.poll() is None:
                server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait(timeout=5)


def http_query_case(port, png):
    # Consent is omitted; the request body is the raw PNG, not base64 or a path.
    status, content_type, body = http_request(
        port, "QUERY", "/segment?point=90,60&quality=fast&format=json", png, "image/png")
    require(status == 200, f"HTTP QUERY returned {status}: {body[:1500]!r}")
    require(content_type.split(";", 1)[0] == "application/json", "HTTP QUERY must return JSON")
    return validate_mask(json.loads(body))


def http_mcp_case(port, png):
    initialize = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2024-11-05", "capabilities": {},
        "clientInfo": {"name": "segment-live-smoke", "version": "1"}}}
    status, content_type, body = http_request(port, "POST", "/mcp", json.dumps(initialize))
    require(status == 200 and content_type.split(";", 1)[0] == "application/json",
            f"HTTP MCP initialize returned {status}: {body[:1500]!r}")
    response = json.loads(body)
    require(isinstance(response, dict) and response.get("jsonrpc") == "2.0"
            and type(response.get("id")) is int and response["id"] == 1
            and "error" not in response and isinstance(response.get("result"), dict)
            and response["result"].get("protocolVersion") == "2024-11-05",
            f"invalid HTTP MCP initialize response: {response!r}")
    request = {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {
        "name": "segment", "arguments": {
            "data": base64.b64encode(png).decode("ascii"), "box": [50, 30, 80, 60],
            "quality": "accurate", "format": "json", "downloadAssets": False}}}
    status, content_type, body = http_request(port, "POST", "/mcp", json.dumps(request))
    require(status == 200 and content_type.split(";", 1)[0] == "application/json",
            f"HTTP MCP segment returned {status}: {body[:1500]!r}")
    return validate_mcp_mask(json.loads(body), 2)


def main():
    require(len(sys.argv) <= 2, "usage: segment-binary-live-smoke.py [macvis-binary]")
    binary = Path(sys.argv[1] if len(sys.argv) == 2 else ".build/release/macvis").resolve()
    require(binary.is_file(), f"binary does not exist: {binary}")
    failures = []

    def run_case(name, run):
        try:
            print(f"PASS {name}: {run()}", flush=True)
        except (AssertionError, OSError, ValueError, KeyError, TypeError,
                struct.error, zlib.error, http.client.HTTPException) as error:
            failures.append(name)
            print(f"FAIL {name}: {error}", file=sys.stderr, flush=True)

    with tempfile.TemporaryDirectory(prefix="macvis-segment-live-") as directory:
        root = Path(directory)
        png = fixture_png()
        fixture = root / "off-center-ellipse.png"
        fixture.write_bytes(png)
        cases = [
            ("CLI point fast, path output", lambda: cli_case(
                binary, fixture, ["--point", "90,60"], "fast", root / "fast-mask.png")),
            ("CLI point balanced, base64 output", lambda: cli_case(
                binary, fixture, ["--point", "90,60"], "balanced")),
            ("CLI box accurate, base64 output", lambda: cli_case(
                binary, fixture, ["--box", "50,30,80,60"], "accurate")),
            ("MCP base64 input, point balanced", lambda: mcp_case(binary, png)),
        ]
        for name, run in cases:
            run_case(name, run)
        http_names = ("HTTP QUERY raw PNG, point fast", "HTTP MCP base64 input, box accurate")
        try:
            with live_server(binary) as port:
                run_case(http_names[0], lambda: http_query_case(port, png))
                run_case(http_names[1], lambda: http_mcp_case(port, png))
        except (AssertionError, OSError, subprocess.TimeoutExpired) as error:
            for name in http_names:
                if name not in failures:
                    failures.append(name)
                print(f"FAIL {name}: HTTP server lifecycle: {error}", file=sys.stderr, flush=True)
    count = len(cases) + len(http_names)
    require(not failures, f"{len(failures)}/{count} live segmentation cases failed")
    print(f"PASS {count} live segmentation cases; no download requested")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError) as error:
        print(f"segment live smoke failed: {error}", file=sys.stderr)
        sys.exit(1)
