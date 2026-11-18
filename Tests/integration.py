#!/usr/bin/env python3
"""Loopback-only integration checks. No Google, account, or real VPN requests."""
import hashlib
import http.client
import http.server
import json
import os
import pathlib
import queue
import socket
import struct
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = pathlib.Path(os.environ.get("GATEWAY_TEST_BIN", str(ROOT / "dist/Gemini Gateway.app/Contents/MacOS/GeminiGateway")))
SEEN = queue.Queue()


class Upstream(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0)))
        SEEN.put((self.path, dict(self.headers, _method=self.command), body))
        if "streamGenerateContent" in self.path:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for piece in [b'data: {"text":"first"}\n\n', b'data: {"text":"last"}\n\n']:
                self.wfile.write(f"{len(piece):x}\r\n".encode() + piece + b"\r\n")
                self.wfile.flush()
                time.sleep(1)
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
            return
        if body == b"missing":
            code, payload = 404, {"error": {"code": 404, "message": "unknown operation"}}
        elif body == b"region":
            code, payload = 400, {"error": {"code": 400, "message": "User location is not supported for the API use. private-test-prompt secret-test-credential", "status": "INVALID_ARGUMENT"}}
        elif body == b"refuse":
            code, payload = 403, {"error": {"code": 403, "message": "denied"}}
        elif body == b"invalid":
            code, payload = 200, None
        else:
            code, payload = 200, {"ineligibleTiers": [{"tier": {"id": "free-tier"}}], "project": "preserved"}
        data = json.dumps(payload).encode() if payload else b"not-json"
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD": self.wfile.write(data)

    do_GET = do_POST
    do_HEAD = do_POST
    do_PUT = do_POST
    do_PATCH = do_POST
    do_DELETE = do_POST
    do_OPTIONS = do_POST


class RunningGateway:
    def __init__(self, upstream, proxy="direct", resume=None, env=None):
        arguments = [str(BIN), "--serve-test", "--upstream", upstream, "--proxy", proxy]
        if resume: arguments += ["--resume-endpoint", resume]
        self.p = subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        self.endpoint = self.p.stdout.readline().strip()
        if not self.endpoint:
            raise RuntimeError(self.p.stderr.read())
        from urllib.parse import urlparse
        u = urlparse(self.endpoint)
        self.port, self.prefix = u.port, u.path

    def close(self):
        self.p.terminate()
        self.p.wait(timeout=5)
        self.p.stdout.close()
        self.p.stderr.close()


def exact(sock, count):
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise EOFError()
        data += chunk
    return data


class Integration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
        cls.server.daemon_threads = True
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.gateway = RunningGateway(f"http://127.0.0.1:{cls.server.server_port}")

    @classmethod
    def tearDownClass(cls):
        cls.gateway.close()
        cls.server.shutdown()
        cls.server.server_close()

    def request(self, body=b"{}", path="/v1internal:loadCodeAssist", headers=None):
        c = http.client.HTTPConnection("127.0.0.1", self.gateway.port, timeout=8)
        c.request("POST", self.gateway.prefix + path, body, headers or {})
        r = c.getresponse()
        status, data = r.status, r.read()
        c.close()
        return status, data

    def test_eligibility_patch_and_authorization_forwarding(self):
        while not SEEN.empty(): SEEN.get_nowait()
        code, data = self.request(headers={"Authorization": "Bearer test-only-token", "X-Test": "preserved"})
        self.assertEqual(code, 200)
        value = json.loads(data)
        self.assertNotIn("ineligibleTiers", value)
        self.assertEqual(value["currentTier"]["id"], "free-tier")
        self.assertEqual(value["project"], "preserved")
        path, headers, body = SEEN.get(timeout=2)
        self.assertEqual(headers["Authorization"], "Bearer test-only-token")
        self.assertEqual(headers["X-Test"], "preserved")
        self.assertEqual(body, b"{}")

    def test_error_status_not_forged(self):
        code, data = self.request(b"refuse")
        self.assertEqual(code, 403)
        self.assertEqual(json.loads(data)["error"]["message"], "denied")

    def test_rest_paths_and_standard_methods_are_forwarded(self):
        cases = [("POST", "/v1internal/log"), ("GET", "/v1internal/agentPlugins"), ("PUT", "/v1/resources"), ("PATCH", "/v1beta/models:countTokens"), ("DELETE", "/v1internal/agentPlugins"), ("OPTIONS", "/telemetry")]
        for method, path in cases:
            while not SEEN.empty(): SEEN.get_nowait()
            body = b"{}" if method in ["POST", "PUT", "PATCH"] else b""
            c = http.client.HTTPConnection("127.0.0.1", self.gateway.port, timeout=4)
            c.request(method, self.gateway.prefix + path, body, {"Authorization": "Bearer fixture-auth"})
            r = c.getresponse(); self.assertEqual(r.status, 200, (method, path)); value = json.loads(r.read()); c.close()
            self.assertIn("ineligibleTiers", value, "Unrelated REST response was modified")
            observed_path, headers, observed_body = SEEN.get(timeout=1)
            self.assertEqual(observed_path, path)
            self.assertEqual(headers["_method"], method)
            self.assertEqual(headers["Authorization"], "Bearer fixture-auth")
            self.assertEqual(observed_body, body)

    def test_head_preserves_metadata_without_forwarding_a_body_or_hanging(self):
        with socket.create_connection(("127.0.0.1", self.gateway.port), timeout=3) as s:
            s.sendall(f"HEAD {self.gateway.prefix}/v1internal:loadCodeAssist HTTP/1.1\r\nHost: 127.0.0.1:{self.gateway.port}\r\n\r\n".encode())
            response = b""
            while True:
                chunk = s.recv(65536)
                if not chunk: break
                response += chunk
        headers, body = response.split(b"\r\n\r\n", 1)
        self.assertTrue(headers.startswith(b"HTTP/1.1 200"))
        self.assertIn(b"Content-Length:", headers)
        self.assertEqual(body, b"")

    def test_rest_diagnostics_hide_query_arguments_and_resource_ids(self):
        path = "/v1internal/log?api_key=private-query-secret"
        self.assertEqual(self.request(b"private-prompt", path=path, headers={"Authorization": "Bearer private-auth"})[0], 200)
        self.assertEqual(self.request(path="/v1/projects/privateResourceName/locations")[0], 200)
        c = http.client.HTTPConnection("127.0.0.1", self.gateway.port, timeout=3)
        c.request("GET", self.gateway.prefix + "/diagnostics")
        r = c.getresponse(); data = r.read(); c.close()
        self.assertIn("/v1internal/log: Google HTTP 200 (POST)", "\n".join(json.loads(data)["events"]))
        for secret in [b"private-query-secret", b"private-prompt", b"private-auth", b"privateResourceName", self.gateway.prefix.encode()]: self.assertNotIn(secret, data)

    def test_invalid_targets_and_unsupported_methods_still_rejected(self):
        for path in ["/../secret", "//evil.invalid/path", "/%2e%2e/secret", "/v1internal/%2e%2e/secret", "/v1internal/%5csecret", "/https://evil.invalid/path"]:
            c = http.client.HTTPConnection("127.0.0.1", self.gateway.port, timeout=3)
            c.request("GET", self.gateway.prefix + path)
            r = c.getresponse(); self.assertEqual(r.status, 404, path); r.read(); c.close()
        c = http.client.HTTPConnection("127.0.0.1", self.gateway.port, timeout=3)
        c.request("TRACE", self.gateway.prefix + "/v1internal/log")
        r = c.getresponse(); self.assertEqual(r.status, 405); r.read(); c.close()

    def test_upstream_rest_404_is_preserved_and_identified_as_google_response(self):
        code, data = self.request(b"missing", path="/v1internal/log")
        self.assertEqual(code, 404)
        self.assertEqual(json.loads(data)["error"]["message"], "unknown operation")
        c = http.client.HTTPConnection("127.0.0.1", self.gateway.port, timeout=3)
        c.request("GET", self.gateway.prefix + "/diagnostics")
        r = c.getresponse(); data = r.read(); c.close()
        self.assertIn("/v1internal/log: Google HTTP 404", "\n".join(json.loads(data)["events"]))

    def test_diagnostics_do_not_contain_credentials_or_prompt(self):
        self.request(b"private-test-prompt", headers={"Authorization": "Bearer secret-test-credential"})
        c = http.client.HTTPConnection("127.0.0.1", self.gateway.port, timeout=3)
        c.request("GET", self.gateway.prefix + "/diagnostics")
        r = c.getresponse(); self.assertEqual(r.status, 200); data = r.read(); c.close()
        self.assertIn(b"loadCodeAssist: Google HTTP 200", data)
        self.assertNotIn(b"private-test-prompt", data)
        self.assertNotIn(b"secret-test-credential", data)

    def test_region_error_is_explained_without_logging_server_text(self):
        self.assertEqual(self.request(b"region")[0], 400)
        c = http.client.HTTPConnection("127.0.0.1", self.gateway.port, timeout=3)
        c.request("GET", self.gateway.prefix + "/diagnostics")
        r = c.getresponse(); data = r.read(); c.close()
        events = json.loads(data)["events"]
        self.assertTrue(any("Google отклонил регион" in e for e in events))
        self.assertNotIn(b"private-test-prompt", data)
        self.assertNotIn(b"secret-test-credential", data)

    def test_invalid_json_passes_through(self):
        self.assertEqual(self.request(b"invalid"), (200, b"not-json"))

    def test_streaming_first_chunk_before_completion(self):
        c = http.client.HTTPConnection("127.0.0.1", self.gateway.port, timeout=8)
        started = time.monotonic()
        c.request("POST", self.gateway.prefix + "/v1internal:streamGenerateContent?alt=sse", b"{}")
        r = c.getresponse()
        first = r.readline()
        self.assertIn(b"first", first)
        self.assertLess(time.monotonic() - started, .9, "Gateway buffered the stream")
        rest = r.read()
        self.assertIn(b"last", rest)
        self.assertNotIn(b"\r\n0\r\n", rest)
        c.close()

    def test_chunked_request_and_large_body(self):
        while not SEEN.empty(): SEEN.get_nowait()
        body = b"sample" * 100000
        c = http.client.HTTPConnection("127.0.0.1", self.gateway.port, timeout=8)
        c.request("POST", self.gateway.prefix + "/v1internal:loadCodeAssist", iter([body[:2000], body[2000:]]), encode_chunked=True)
        r = c.getresponse(); self.assertEqual(r.status, 200); r.read(); c.close()
        self.assertEqual(SEEN.get(timeout=2)[2], body)

    def test_browser_host_and_path_restrictions(self):
        for path, headers, expected in [
            (self.gateway.prefix + "/v1internal:loadCodeAssist", {"Origin": "https://evil.invalid"}, 403),
            (self.gateway.prefix + "/health", {"Host": "evil.invalid"}, 403),
            ("/v1internal:loadCodeAssist", {}, 404),
            (self.gateway.prefix + "/../secret", {}, 404),
        ]:
            c = http.client.HTTPConnection("127.0.0.1", self.gateway.port, timeout=3)
            c.request("GET", path, headers=headers)
            r = c.getresponse(); self.assertEqual(r.status, expected); r.read(); c.close()

    def test_ambiguous_length_and_invalid_chunk_rejected(self):
        for extra, body in [(b"Content-Length: 4\r\nTransfer-Encoding: chunked\r\n", b"0\r\n\r\n"), (b"Transfer-Encoding: chunked\r\n", b";bad\r\n")]:
            with socket.create_connection(("127.0.0.1", self.gateway.port), timeout=3) as s:
                s.sendall(f"POST {self.gateway.prefix}/v1internal:loadCodeAssist HTTP/1.1\r\nHost: 127.0.0.1:{self.gateway.port}\r\n".encode() + extra + b"\r\n" + body)
                self.assertIn(b"400", s.recv(1024))
        self.assertEqual(self.request()[0], 200)

    def test_connect_restrictions(self):
        for target in ["127.0.0.1:443", "evil.invalid:80", "local.local:443"]:
            with socket.create_connection(("127.0.0.1", self.gateway.port), timeout=3) as s:
                s.sendall(f"CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n".encode())
                self.assertIn(b"403", s.recv(1024))

    def test_client_launch_removes_electron_node_environment(self):
        environment = dict(os.environ, ELECTRON_RUN_AS_NODE="1", NODE_OPTIONS="--inspect", NODE_PATH="/invalid", VSCODE_IPC_HOOK_CLI="/invalid")
        script = 'test -z "${ELECTRON_RUN_AS_NODE+x}" && test -z "${NODE_OPTIONS+x}" && test -z "${NODE_PATH+x}" && test -z "${VSCODE_IPC_HOOK_CLI+x}" || exit 9; exec /bin/sleep 5'
        result = subprocess.run([str(BIN), "--client-start-test", "/bin/sh", "-c", script], env=environment, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), b"running")

    def test_client_that_exits_immediately_is_not_reported_as_started(self):
        result = subprocess.run([str(BIN), "--client-start-test", "/bin/sh", "-c", "exit 9"], capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 3)
        self.assertEqual(result.stdout.strip(), b"failed")

    def test_system_route_ignores_broken_happ_proxy_environment(self):
        environment = dict(os.environ, HTTP_PROXY="http://127.0.0.1:1", HTTPS_PROXY="http://127.0.0.1:1", ALL_PROXY="socks5://127.0.0.1:1", http_proxy="http://127.0.0.1:1")
        g = RunningGateway(f"http://127.0.0.1:{self.server.server_port}", env=environment)
        try:
            c = http.client.HTTPConnection("127.0.0.1", g.port, timeout=5)
            c.request("POST", g.prefix + "/v1internal:loadCodeAssist", b"{}")
            r = c.getresponse(); self.assertEqual(r.status, 200); r.read(); c.close()
        finally: g.close()

    def test_missing_vpn_interface_never_falls_back_to_system_connection(self):
        listener = socket.socket(); listener.bind(("127.0.0.1", 0)); listener.listen(); listener.settimeout(.2)
        try:
            result = subprocess.run([str(BIN), "--socket-bind-test", str(listener.getsockname()[1]), "missingvpn999"], capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 3)
            with self.assertRaises(socket.timeout): listener.accept()
        finally: listener.close()

    def test_amnezia_status_rejects_other_vpns_and_disconnected_tunnels(self):
        uid = "00000000-1111-4222-8333-444444444444"
        connected = f'* (Connected) {uid} VPN (org.amnezia.awg) "test" [VPN:org.amnezia.awg]'
        status = "Connected\nIPv4 : {\n ExcludedRoutes : { InterfaceName : en0 }\n InterfaceName : utun4\n}\n"
        cases = [(connected, status, 0), (connected.replace("Connected", "Disconnected"), status, 3), (connected.replace("org.amnezia.awg", "com.wireguard.macos"), status, 3), (connected, status.replace("Connected", "Disconnected"), 3), (connected, "Connected\nInterfaceName : en0\n", 3)]
        with tempfile.TemporaryDirectory() as directory:
            listing = pathlib.Path(directory) / "list.txt"; state = pathlib.Path(directory) / "status.txt"
            for text, output, expected in cases:
                listing.write_text(text); state.write_text(output)
                result = subprocess.run([str(BIN), "--vpn-status-test", str(listing), str(state)], capture_output=True, timeout=5)
                self.assertEqual(result.returncode, expected)
                if expected == 0: self.assertEqual(result.stdout.strip(), b"utun4")

    def test_client_endpoint_survives_gateway_restart(self):
        upstream = f"http://127.0.0.1:{self.server.server_port}"
        first = RunningGateway(upstream)
        endpoint = first.endpoint
        stale_port, stale_path = first.port, first.prefix
        first.close()
        recovered = RunningGateway(upstream, resume=endpoint)
        try:
            self.assertEqual(recovered.endpoint, endpoint)
            # Simulate the old client: it keeps both its previous port and URL prefix.
            c = http.client.HTTPConnection("127.0.0.1", stale_port, timeout=3)
            c.request("GET", stale_path + "/health")
            r = c.getresponse(); self.assertEqual(r.status, 200); r.read(); c.close()
        finally: recovered.close()

    def test_resume_cannot_silently_move_to_a_different_port(self):
        listener = socket.socket(); listener.bind(("127.0.0.1", 0)); listener.listen()
        port = listener.getsockname()[1]
        try:
            result = subprocess.run([str(BIN), "--serve-test", "--upstream", f"http://127.0.0.1:{self.server.server_port}", "--resume-endpoint", f"http://127.0.0.1:{port}/0123456789"], capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 3)
            self.assertEqual(result.stdout, b"")
        finally: listener.close()

    def test_proxy_tunnels_socks5_and_http(self):
        for mode in ["socks5", "http"]:
            listener = socket.socket(); listener.bind(("127.0.0.1", 0)); listener.listen()
            errors = []
            def fake_proxy():
                try:
                    with listener.accept()[0] as s:
                        s.settimeout(4)
                        if mode == "socks5":
                            self.assertEqual(exact(s, 3), b"\x05\x01\x00")
                            s.sendall(b"\x05\x00")
                            h = exact(s, 5); self.assertEqual(h[:4], b"\x05\x01\x00\x03")
                            self.assertEqual(exact(s, h[4]), b"www.google.com")
                            self.assertEqual(exact(s, 2), b"\x01\xbb")
                            s.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x01")
                        else:
                            request = b""
                            while not request.endswith(b"\r\n\r\n"): request += exact(s, 1)
                            self.assertTrue(request.startswith(b"CONNECT www.google.com:443 HTTP/1.1"))
                            s.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                        self.assertEqual(exact(s, 4), b"ping")
                        s.sendall(b"pong")
                except Exception as e: errors.append(e)
            thread = threading.Thread(target=fake_proxy, daemon=True); thread.start()
            g = RunningGateway(f"http://127.0.0.1:{self.server.server_port}", f"{mode}://127.0.0.1:{listener.getsockname()[1]}")
            try:
                with socket.create_connection(("127.0.0.1", g.port), timeout=4) as s:
                    s.sendall(b"CONNECT www.google.com:443 HTTP/1.1\r\nHost: www.google.com:443\r\n\r\n")
                    response = b""
                    while not response.endswith(b"\r\n\r\n"): response += exact(s, 1)
                    self.assertIn(b"200", response)
                    s.sendall(b"ping"); self.assertEqual(exact(s, 4), b"pong")
                thread.join(timeout=5)
                self.assertFalse(errors, errors)
            finally: g.close(); listener.close()

    def test_asar_integrity_and_original_unchanged(self):
        content = b"exports.LS_CLOUD_CODE_ENDPOINT = 'https://daily-cloudcode-pa.googleapis.com';"
        other = b"must-stay-identical"
        sha = hashlib.sha256(content).hexdigest()
        tree = {"files": {"dist": {"files": {"lsDefaults.js": {"size": len(content), "offset": "0", "integrity": {"algorithm": "SHA256", "hash": sha, "blockSize": 4194304, "blocks": [sha]}}}}, "other.txt": {"size": len(other), "offset": str(len(content))}}}
        header = json.dumps(tree, separators=(",", ":")).encode(); padding = (-len(header)) % 4
        archive = struct.pack("<IIII", 4, 8 + len(header) + padding, 4 + len(header) + padding, len(header)) + header + b"\0" * padding + content + other
        with tempfile.TemporaryDirectory() as directory:
            source = pathlib.Path(directory) / "in.asar"; dest = pathlib.Path(directory) / "out.asar"
            source.write_bytes(archive)
            endpoint = "http://127.0.0.1:55555/abcdefghij"
            digest = subprocess.check_output([str(BIN), "--patch-asar-test", str(source), str(dest), endpoint], text=True).strip()
            result = dest.read_bytes(); _, size, _, json_size = struct.unpack("<IIII", result[:16])
            self.assertEqual(source.read_bytes(), archive)
            parsed = json.loads(result[16:16 + json_size]); entry = parsed["files"]["dist"]["files"]["lsDefaults.js"]
            patched = result[size + 8:size + 8 + len(content)]
            self.assertIn(endpoint.encode(), patched)
            self.assertEqual(len(patched), len(content))
            self.assertEqual(entry["integrity"]["hash"], hashlib.sha256(patched).hexdigest())
            self.assertEqual(entry["integrity"]["blocks"], [entry["integrity"]["hash"]])
            self.assertEqual(digest, hashlib.sha256(result[16:16 + json_size]).hexdigest())
            self.assertTrue(result.endswith(other))


if __name__ == "__main__": unittest.main(verbosity=2)
