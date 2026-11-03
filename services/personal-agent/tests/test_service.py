import copy
import json
import os
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
import uuid
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from state import State, default_agent, next_time
from server import Service, make_server
from executor import Executor


def uid():
    return str(uuid.uuid4()).upper()


def wait_for(predicate, timeout=4):
    limit = time.monotonic() + timeout
    while time.monotonic() < limit:
        if predicate():
            return
        time.sleep(.01)
    raise AssertionError("Timed out")


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.state = State(self.root / "state.sqlite3")
        self.agent = self.state.archive["agents"][0]

    def tearDown(self):
        self.state.db.close()
        self.temp.cleanup()

    def request(self, **extra):
        return dict(id=uid(), agentID=self.agent["id"], prompt="Hello", **extra)

    def routine(self):
        return dict(id=uid(), agentID=self.agent["id"], name="Morning", instruction="Check", skillIDs=[], isEnabled=True,
            schedule=dict(frequency="daily", hour=9, minute=0, timeZoneID="Asia/Shanghai"))

    def test_durable_idempotency_and_isolated_agent_threads(self):
        request = self.request()
        first, created = self.state.begin(**dict(run_id=request["id"], agent_id=request["agentID"], prompt=request["prompt"]))
        self.assertTrue(created)
        again, created = self.state.begin(request["id"], request["agentID"], request["prompt"])
        self.assertFalse(created)
        self.assertEqual(first, again)
        with self.assertRaises(ValueError):
            self.state.begin(request["id"], request["agentID"], "Different")
        other = default_agent()
        self.state.save("agents", other)
        second, _ = self.state.begin(uid(), other["id"], "Other")
        self.state.update_run(first["id"], threadID="thread-a")
        self.state.update_run(second["id"], threadID="thread-b")
        self.assertEqual(self.state.find("agents", other["id"])["threadID"], "thread-b")
        self.assertEqual(self.agent["threadID"], "thread-a")

    def test_restart_never_replays_submitted_or_unsubmitted_work(self):
        first, _ = self.state.begin(uid(), self.agent["id"], "submitted")
        self.state.update_run(first["id"], submissionAttempted=True)
        second_agent = default_agent()
        self.state.save("agents", second_agent)
        second, _ = self.state.begin(uid(), second_agent["id"], "not submitted")
        restored = State(self.root / "state.sqlite3")
        try:
            self.assertEqual(restored.find("runs", first["id"])["status"], "uncertain")
            self.assertEqual(restored.find("runs", second["id"])["status"], "cancelled")
            with self.assertRaises(ValueError):
                restored.begin(uid(), self.agent["id"], "Do not replay")
        finally:
            restored.db.close()

    def test_routine_coalescing_and_budget(self):
        routine = self.routine()
        self.state.save("routines", routine)
        routine = self.state.find("routines", routine["id"])
        routine["nextRunAt"] = time.time() - 86400 * 5
        self.agent["dailyRoutineLimit"] = 1
        now = time.time()
        run, _ = self.state.begin(uid(), self.agent["id"], "Check", routine["id"], True, now)
        self.assertGreater(routine["nextRunAt"], now)
        self.state.update_run(run["id"], status="succeeded", result="NO_UPDATE")
        self.assertTrue(self.state.find("runs", run["id"])["isRead"])
        with self.assertRaises(ValueError):
            self.state.begin(uid(), self.agent["id"], "Check", routine["id"])

    def test_schedule_dst_gap_repetition_weekends_and_hourly(self):
        schedule = dict(frequency="daily", hour=2, minute=30, timeZoneID="America/New_York")
        after = datetime.fromisoformat("2026-03-08T01:59:00-05:00").timestamp()
        self.assertEqual(next_time(schedule, after), datetime.fromisoformat("2026-03-08T03:00:00-04:00").timestamp())
        schedule.update(hour=1, minute=30)
        after = datetime.fromisoformat("2026-11-01T01:40:00-04:00").timestamp()
        self.assertEqual(next_time(schedule, after), datetime.fromisoformat("2026-11-02T01:30:00-05:00").timestamp())
        schedule.update(frequency="weekdays", hour=9, minute=0)
        after = datetime.fromisoformat("2026-10-30T10:00:00-04:00").timestamp()
        self.assertEqual(next_time(schedule, after), datetime.fromisoformat("2026-11-02T09:00:00-05:00").timestamp())
        schedule.update(frequency="hourly", minute=15, timeZoneID="UTC")
        self.assertEqual(next_time(schedule, 3600 + 900), 7200 + 900)

    def test_invalid_configuration_does_not_mutate_archive(self):
        old = self.state.snapshot()
        for change in ({"maxRunMinutes": 0}, {"access": "danger-full-access"}, {"skillIDs": [uid()]}, {"name": ""}):
            agent = copy.deepcopy(self.agent)
            agent.update(change)
            with self.assertRaises(ValueError):
                self.state.save("agents", agent)
            self.assertEqual(old, self.state.snapshot())

    def test_scheduler_runs_without_clients_and_respects_pause(self):
        finished = threading.Event()
        class Fake:
            def __init__(self, state, run, *_): self.state, self.run = state, run
            def execute(self):
                self.state.update_run(self.run["id"], status="succeeded", result="scheduled")
                finished.set()
        service = Service(self.state, self.root, "fake", factory=Fake)
        routine = self.routine()
        self.state.save("routines", routine)
        self.state.find("routines", routine["id"])["nextRunAt"] = time.time() - 100
        self.agent["isPaused"] = True
        service.tick()
        self.assertEqual(len(self.state.archive["runs"]), 0)
        self.agent["isPaused"] = False
        service.tick()
        self.assertTrue(finished.wait(2))
        service.tick()
        self.assertEqual(len(self.state.archive["runs"]), 1)

    def test_http_authentication_crud_and_protocol(self):
        service = Service(self.state, self.root, "fake")
        token = "a" * 40
        http = make_server(("127.0.0.1", 0), service, token)
        thread = threading.Thread(target=http.serve_forever, daemon=True); thread.start()
        base = f"http://127.0.0.1:{http.server_port}"
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            with self.assertRaises(urllib.error.HTTPError) as error:
                opener.open(base + "/v1/state")
            self.assertEqual(error.exception.code, 401)
            request = urllib.request.Request(base + "/v1/state", headers={"Authorization": "Bearer " + token})
            with opener.open(request) as response:
                result = json.load(response)
            self.assertEqual(result["protocolVersion"], 1)
            self.assertEqual(result["archive"]["agents"][0]["id"], self.agent["id"])
            body = dict(action="save", collection="skills", item=dict(id=uid(), name="Brief", instructions="Cite sources"))
            request = urllib.request.Request(base + "/v1/action", data=json.dumps(body).encode(), headers={"Authorization": "Bearer " + token})
            with opener.open(request) as response:
                result = json.load(response)
            self.assertEqual(result["archive"]["skills"][0]["name"], "Brief")
        finally:
            http.shutdown(); http.server_close(); thread.join()

    def test_different_agents_run_concurrently_and_same_agent_is_serial(self):
        release = threading.Event()
        class Blocking:
            def __init__(self, state, run, *_): self.state, self.run = state, run
            def execute(self):
                release.wait(3)
                self.state.update_run(self.run["id"], status="succeeded")
        other = default_agent()
        self.state.save("agents", other)
        service = Service(self.state, self.root, "fake", workers=2, factory=Blocking)
        request = self.request()
        try:
            service.start(request)
            service.start(dict(id=uid(), agentID=other["id"], prompt="Other agent"))
            self.assertEqual(len(service.active), 2)
            service.start(request)  # Re-delivery is safe even at capacity.
            self.assertEqual(len(self.state.archive["runs"]), 2)
            with self.assertRaises(ValueError):
                service.start(self.request())
        finally:
            release.set()
            wait_for(lambda: len(service.active) == 0)

    def fake_runtime(self):
        path = self.root / "codex-fake"
        path.write_text('#!' + sys.executable + '\n' + '''
import json, os, sys

def emit(message):
    print(json.dumps(message), flush=True)
for line in sys.stdin:
    m = json.loads(line)
    method, p = m.get("method"), m.get("params", {})
    if method == "initialize": result = {}
    elif method == "config/read": result = {"config": {"mcp_servers": {"private": {}}}}
    elif method in ("thread/start", "thread/resume"):
        assert p["approvalPolicy"] == "on-request"
        assert p["config"]["mcp_servers.private.enabled"] is False
        assert "MARR_AGENT_TOKEN" not in os.environ
        result = {"thread": {"id": "test-thread"}}
    elif method == "turn/start":
        assert p["sandboxPolicy"]["type"] == "readOnly"
        emit({"id": m["id"], "result": {"turn": {"id": "test-turn"}}})
        emit({"id": 77, "method": "item/commandExecution/requestApproval", "params": {"threadId": "test-thread", "turnId": "test-turn", "command": "example", "availableDecisions": ["accept", "decline"]}})
        continue
    elif m.get("id") == 77 and "result" in m:
        status = "completed" if m["result"]["decision"] == "accept" else "interrupted"
        emit({"method": "item/agentMessage/delta", "params": {"threadId": "other-thread", "turnId": "test-turn", "delta": "wrong"}})
        emit({"method": "item/agentMessage/delta", "params": {"threadId": "test-thread", "turnId": "test-turn", "delta": "verified answer"}})
        emit({"method": "turn/completed", "params": {"threadId": "test-thread", "turn": {"id": "test-turn", "status": status}}})
        continue
    elif method == "turn/interrupt":
        emit({"method": "turn/completed", "params": {"threadId": "test-thread", "turn": {"id": "test-turn", "status": "interrupted"}}})
        result = {}
    elif method == "thread/read":
        result = {"thread": {"turns": [{"id": "test-turn", "status": "completed", "items": [{"type": "agentMessage", "text": "recovered"}]}]}}
    else: continue
    emit({"id": m["id"], "result": result})
''')
        path.chmod(0o700)
        return str(path)

    def test_stdio_approval_stream_stop_reconcile_and_secret_filter(self):
        executable = self.fake_runtime()
        run, _ = self.state.begin(uid(), self.agent["id"], "Check")
        runner = Executor(self.state, run, self.root, "fake", executable)
        os.environ["MARR_AGENT_TOKEN"] = "must-not-enter-child"
        thread = threading.Thread(target=runner.execute); thread.start()
        try:
            wait_for(lambda: self.state.find("runs", run["id"])["status"] == "needsInput")
            self.assertTrue(thread.is_alive())
            with self.assertRaises(ValueError):
                runner.respond(77, {"decision": "acceptForSession"})
            runner.respond(77, {"decision": "accept"})
            thread.join(4)
            self.assertFalse(thread.is_alive())
            completed = self.state.find("runs", run["id"])
            self.assertEqual(completed["status"], "succeeded")
            self.assertEqual(completed["result"], "verified answer")
            self.assertEqual(self.state.interactions, {})
            self.state.update_run(run["id"], status="uncertain")
            checker = Executor(self.state, dict(completed), self.root, "fake", executable)
            checker.reconcile()
            self.assertEqual(completed["status"], "succeeded")
            self.assertEqual(completed["result"], "recovered")
            self.agent.pop("threadID", None)
            next_run, _ = self.state.begin(uid(), self.agent["id"], "Again")
            runner = Executor(self.state, next_run, self.root, "fake", executable)
            thread = threading.Thread(target=runner.execute); thread.start()
            wait_for(lambda: self.state.find("runs", next_run["id"])["status"] == "needsInput")
            runner.stop(); thread.join(4)
            self.assertEqual(self.state.find("runs", next_run["id"])["status"], "cancelled")
        finally:
            os.environ.pop("MARR_AGENT_TOKEN", None)
            runner.close(); thread.join(4)


if __name__ == "__main__":
    unittest.main()
