#!/usr/bin/env python3
"""Local WebSocket protocol fixture. No models, credentials or external traffic.

Started by test-marr.sh or as an isolated child of the runtime lifecycle tests. Each UUID path owns an isolated scenario and counters.
"""
import argparse
import base64
import hashlib
import json
import pathlib
import socket
import socketserver
import struct
import threading
import zlib
from urllib.parse import urlsplit


class FixtureServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, port=0):
        super().__init__(("127.0.0.1", port), FixtureHandler)
        self.lock = threading.Lock()
        self.sessions = {}


class FixtureHandler(socketserver.BaseRequestHandler):
    def read_exact(self, length):
        while len(self.buffer) < length:
            chunk = self.request.recv(max(4096, length - len(self.buffer)))
            if not chunk:
                raise EOFError()
            self.buffer += chunk
        result, self.buffer = self.buffer[:length], self.buffer[length:]
        return result

    def send_frame(self, payload, opcode=1, final=True):
        header = bytes([(0x80 if final else 0) | opcode])
        length = len(payload)
        if length < 126:
            header += bytes([length])
        elif length < 65536:
            header += bytes([126]) + struct.pack("!H", length)
        else:
            header += bytes([127]) + struct.pack("!Q", length)
        # Exercise TCP segmentation independently of WebSocket fragmentation.
        wire = header + payload
        chunk_size = 16384 if len(wire) > 65536 else 7
        for offset in range(0, len(wire), chunk_size):
            self.request.sendall(wire[offset:offset + chunk_size])

    def send_json(self, value, extra=None, fragmented=False):
        payload = json.dumps(value, ensure_ascii=False).encode()
        if extra is not None:
            payload += b"\n" + json.dumps(extra, ensure_ascii=False).encode()
        if fragmented:
            split = max(1, len(payload) // 2)
            self.send_frame(payload[:split], final=False)
            self.send_frame(payload[split:], opcode=0)
        else:
            self.send_frame(payload)

    def receive_json(self):
        fragments = b""
        while True:
            first, second = self.read_exact(2)
            length = second & 0x7f
            if length == 126:
                length = struct.unpack("!H", self.read_exact(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self.read_exact(8))[0]
            if length > 1_000_000:
                raise ValueError("Fixture message too large")
            mask = self.read_exact(4) if second & 0x80 else None
            data = self.read_exact(length)
            if mask:
                data = bytes(byte ^ mask[index % 4] for index, byte in enumerate(data))
            opcode = first & 0x0f
            if opcode == 8:
                raise EOFError()
            if opcode == 9:
                self.send_frame(data, opcode=10)
                continue
            if opcode == 10:
                continue
            fragments += data
            if first & 0x80:
                return json.loads(fragments)

    def handle(self):
        self.request.settimeout(20)
        self.request.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.buffer = b""
        try:
            while b"\r\n\r\n" not in self.buffer:
                chunk = self.request.recv(4096)
                if not chunk:
                    return
                self.buffer += chunk
                if len(self.buffer) > 65536:
                    return
            header, self.buffer = self.buffer.split(b"\r\n\r\n", 1)
            lines = header.decode("ascii").split("\r\n")
            path = urlsplit(lines[0].split()[1]).path
            headers = dict(line.split(":", 1) for line in lines[1:] if ":" in line)
            headers = {key.lower(): value.strip() for key, value in headers.items()}
            if path == "/readyz":
                self.request.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                return
            if path.startswith("/history-images/"):
                name = path.split("/")[-1]
                def png_chunk(kind, data):
                    return struct.pack("!I", len(data)) + kind + data + struct.pack("!I", zlib.crc32(kind + data))
                png = b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", struct.pack("!IIBBBBB", 1, 1, 8, 2, 0, 0, 0)) + png_chunk(b"IDAT", zlib.compress(b"\0\xff\xff\xff")) + png_chunk(b"IEND", b"")
                body = png if name == "0" * 64 else b"invalid image"
                length = 50_000_000 if name == "2" * 64 else len(body)
                self.request.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nConnection: close\r\nContent-Length: " + str(length).encode() + b"\r\n\r\n" + body)
                return
            if path.startswith("/metrics/"):
                with self.server.lock:
                    counts = dict(self.server.sessions.get(path.split("/")[-1], {}).get("counts", {}))
                body = json.dumps(counts).encode()
                self.request.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
                return
            parts = ["fragments", "managed-child"] if path == "/" else path.strip("/").split("/")
            if len(parts) != 2 or parts[0] not in {"fragments", "disconnect", "timeout", "large-history"}:
                return
            scenario, token = parts
            key = headers.get("sec-websocket-key")
            if not key:
                return
            accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
            self.request.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
            with self.server.lock:
                state = self.server.sessions.setdefault(token, {"counts": {}, "cwd": "/tmp", "accepted": False})
            while True:
                message = self.receive_json()
                method = message.get("method", "client-response")
                with self.server.lock:
                    state["counts"][method] = state["counts"].get(method, 0) + 1
                if "id" not in message:
                    continue
                params = message.get("params", {})
                result = {}
                if method == "initialize":
                    result = {"userAgent": "Marr loopback fixture"}
                elif method == "model/list":
                    result = {"data": [{"model": "fixture-model", "displayName": "模型 分片", "defaultReasoningEffort": "low", "supportedReasoningEfforts": [{"reasoningEffort": "low"}]}]}
                elif method in {"skills/list", "collaborationMode/list"}:
                    result = {"data": []}
                elif method == "thread/start":
                    state["cwd"] = params.get("cwd", "/tmp")
                    result = {"thread": self.thread(token, state), "model": "fixture-model"}
                elif method == "turn/start":
                    state["accepted"] = True
                    if scenario == "disconnect":
                        self.request.shutdown(socket.SHUT_RDWR)
                        return
                    if scenario == "timeout":
                        continue  # Keep socket open, deliberately omit the ACK.
                    result = {"turn": {"id": "fixture-turn"}}
                elif method == "thread/read":
                    result = {"thread": self.thread(token, state)}
                    result["thread"]["id"] = params.get("threadId", result["thread"]["id"])
                    if scenario == "large-history":
                        result["thread"]["turns"] = [{"id": "large-turn", "status": "completed", "items": [
                            {"id": "user", "type": "userMessage", "content": [{"type": "text", "text": "Read long history"}]},
                            {"id": "tool", "type": "commandExecution", "command": "fixture", "exitCode": 0,
                             "aggregatedOutput": "Historical output\n" * 120000},
                            {"id": "answer", "type": "agentMessage", "text": "Large history tail received"}
                        ]}]
                else:
                    self.send_json({"id": message["id"], "error": {"code": -32601, "message": "Unsupported fixture method"}})
                    continue
                extra = {"method": "warning", "params": {"message": "fixture 分片 decoded"}} if scenario == "fragments" and method == "model/list" else None
                self.send_json({"id": message["id"], "result": result}, extra=extra, fragmented=scenario == "fragments")
        except (EOFError, OSError, ValueError, UnicodeError):
            return

    @staticmethod
    def thread(token, state):
        turns = [{"id": "fixture-turn", "status": "completed", "items": [{"id": "answer", "type": "agentMessage", "text": "Fixture completed"}]}] if state["accepted"] else []
        return {"id": "fixture-" + token, "cwd": state["cwd"], "status": {"type": "idle"}, "turns": turns}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("command", nargs="?")
    parser.add_argument("--codex-child", action="store_true")
    parser.add_argument("--listen")
    parser.add_argument("--ready-file")
    arguments = parser.parse_args()
    if arguments.codex_child:
        assert arguments.command == "app-server"
        endpoint = urlsplit(arguments.listen)
        assert endpoint.hostname == "127.0.0.1"
        port = endpoint.port
    else:
        assert arguments.ready_file
        port = 0
    with FixtureServer(port) as server:
        if arguments.ready_file:
            pathlib.Path(arguments.ready_file).write_text("ws://127.0.0.1:" + str(server.server_address[1]))
        server.serve_forever(poll_interval=0.1)
