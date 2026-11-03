"""Self-hosted Marr agent service; no Marr-managed account or hosting required."""
import copy
import fcntl
import hmac
import json
import os
import signal
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from executor import Executor
from state import State


class Service:
    def __init__(self, state, root, model, workers=4, factory=Executor):
        self.state, self.root, self.model = state, root, model
        self.workers, self.factory = workers, factory
        self.active = {}
        self.closing = threading.Event()
        self.lock = threading.RLock()

    def start(self, payload, scheduled=False):
        with self.lock:
            run_id = payload["id"]
            with self.state.lock:
                old = self.state.find("runs", run_id)
                if not old and len(self.active) >= self.workers:
                    raise ValueError("All workers are busy. Try again shortly.")
                run, created = self.state.begin(run_id, payload["agentID"], payload["prompt"], payload.get("routineID"), scheduled)
            if created:
                runner = self.factory(self.state, run, self.root, self.model)
                self.active[run["id"]] = runner
                threading.Thread(target=self.work, args=(runner, run["id"]), daemon=True).start()
            return run

    def work(self, runner, run_id):
        try:
            runner.execute()
        except Exception as error:
            with self.state.lock:
                run = self.state.find("runs", run_id)
                self.state.update_run(run_id, status="uncertain" if run.get("submissionAttempted") else "failed", detail=str(error))
        finally:
            with self.lock:
                self.active.pop(run_id, None)

    def tick(self):
        with self.state.lock:
            due = [copy.deepcopy(r) for r in self.state.archive["routines"] if r["isEnabled"] and (r.get("nextRunAt") or 0) <= time.time()]
        for routine in due:
            try:
                self.start(dict(id=str(uuid.uuid4()).upper(), agentID=routine["agentID"], prompt=routine["instruction"], routineID=routine["id"]), scheduled=True)
            except ValueError:
                continue  # Paused/busy/budget-limited agents wait; no backlog replay.

    def schedule(self):
        while not self.closing.is_set():
            try:
                self.tick()
            except Exception:
                # Do not silently lose the scheduler after transient disk/runtime errors.
                print("Agent scheduler could not persist or start work; retrying in 10 seconds.", file=sys.stderr, flush=True)
            self.closing.wait(10)

    def action(self, body):
        action = body["action"]
        if action == "send":
            self.start(body)
        elif action in ("save", "delete"):
            collection = body["collection"]
            if collection not in ("agents", "routines", "skills"):
                raise ValueError("Unknown collection")
            if action == "save":
                self.state.save(collection, body["item"])
            else:
                self.state.delete(collection, body["id"])
        elif action == "read":
            with self.state.lock:
                if not self.state.find("runs", body["id"]):
                    raise ValueError("Unknown run")
                self.state.update_run(body["id"], isRead=True)
        elif action in ("respond", "stop"):
            with self.lock:
                runner = self.active.get(body["runID"])
                if not runner:
                    raise ValueError("Run is no longer active")
                if action == "stop":
                    runner.stop()
                else:
                    runner.respond(body["id"], body["result"])
        elif action == "check":
            with self.lock:
                if body["runID"] in self.active or len(self.active) >= self.workers:
                    raise ValueError("Run is active or workers are busy")
                with self.state.lock:
                    run = copy.deepcopy(self.state.find("runs", body["runID"]))
                if not run or run["status"] != "uncertain":
                    raise ValueError("Run does not need reconciliation")
                runner = self.factory(self.state, run, self.root, self.model)
                self.active[run["id"]] = runner
                def check():
                    try:
                        runner.reconcile(body.get("stopIfRunning", False))
                    finally:
                        with self.lock:
                            self.active.pop(run["id"], None)
                threading.Thread(target=check, daemon=True).start()
        else:
            raise ValueError("Unknown action")
        return self.state.snapshot()

    def close(self):
        self.closing.set()
        with self.lock:
            for run_id, runner in list(self.active.items()):
                self.state.update_run(run_id, status="uncertain", detail="Server is shutting down; run was not replayed.")
                runner.close()


class Handler(BaseHTTPRequestHandler):
    server_version = "MarrAgent/1"

    def setup(self):
        super().setup()
        self.connection.settimeout(15)

    def log_message(self, *args):
        pass  # Never log prompts, tokens or query strings.

    def reply(self, status, data):
        data = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authenticated(self):
        provided = self.headers.get("Authorization", "")
        return hmac.compare_digest(provided.encode(), ("Bearer " + self.server.token).encode())

    def do_GET(self):
        if self.path == "/health":
            return self.reply(200, {"ok": True})
        if not self.authenticated():
            return self.reply(401, {"error": "Authentication required"})
        if self.path == "/v1/state":
            return self.reply(200, self.server.service.state.snapshot())
        self.reply(404, {"error": "Not found"})

    def do_POST(self):
        if not self.authenticated():
            return self.reply(401, {"error": "Authentication required"})
        if self.path != "/v1/action":
            return self.reply(404, {"error": "Not found"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 1048576:
                return self.reply(413, {"error": "Invalid request size"})
            self.connection.settimeout(15)
            body = json.loads(self.rfile.read(length))
            result = self.server.service.action(body)
        except (ValueError, KeyError, TypeError) as error:
            return self.reply(400, {"error": str(error)})
        except Exception:
            return self.reply(500, {"error": "Service operation failed; check server configuration"})
        self.reply(200, result)


def make_server(address, service, token):
    if len(token) < 32 or any(c.isspace() for c in token):
        raise ValueError("MARR_AGENT_TOKEN must contain at least 32 non-whitespace characters")
    server = ThreadingHTTPServer(address, Handler)
    server.daemon_threads = True
    server.service, server.token = service, token
    return server


def main():
    os.umask(0o077)
    root = Path(os.environ.get("MARR_AGENT_DATA", "/data"))
    root.mkdir(parents=True, exist_ok=True)
    lock_file = (root / "service.lock").open("w")
    fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    state = State(root / "agents.sqlite3")
    service = Service(state, root, os.environ["MARR_AGENT_MODEL"])
    server = make_server((os.environ.get("MARR_AGENT_BIND", "127.0.0.1"), int(os.environ.get("PORT", "8787"))), service, os.environ["MARR_AGENT_TOKEN"])
    def stop(*_):
        service.closing.set()
        threading.Thread(target=server.shutdown, daemon=True).start()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    threading.Thread(target=service.schedule, daemon=True).start()
    try:
        server.serve_forever()
    finally:
        service.close()
        server.server_close()


if __name__ == "__main__":
    main()
