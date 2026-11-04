"""Durable, single-owner agent state. All transitions commit before execution."""
import copy
import json
import sqlite3
import threading
import time
import uuid
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

ACTIVE = {"running", "needsInput", "uncertain"}


def identifier(value):
    return str(uuid.UUID(value)).upper()


def next_time(schedule, after):
    zone = ZoneInfo(schedule["timeZoneID"])
    frequency = schedule["frequency"]
    hour, minute = schedule["hour"], schedule["minute"]
    if frequency not in ("hourly", "daily", "weekdays") or not 0 <= hour < 24 or not 0 <= minute < 60:
        raise ValueError("Invalid schedule")
    # UTC iteration handles DST gaps; nonexistent wall times advance to the first
    # available minute, repeated wall times use the first occurrence only.
    cursor = datetime.fromtimestamp(after, timezone.utc).replace(second=0, microsecond=0) + timedelta(minutes=1)
    for _ in range(8 * 24 * 60):
        local = cursor.astimezone(zone)
        if frequency == "hourly":
            match = local.minute == minute
        else:
            target = local.replace(hour=hour, minute=minute, second=0, fold=0)
            normalized = target.astimezone(timezone.utc).astimezone(zone)
            if (normalized.hour, normalized.minute) != (hour, minute):
                # Foundation Calendar .nextTime uses the start of the next valid hour.
                normalized = normalized.replace(minute=0)
            match = (local.hour, local.minute) == (normalized.hour, normalized.minute) and not local.fold
            if frequency == "weekdays" and local.weekday() >= 5:
                match = False
        if match:
            return cursor.timestamp()
        cursor += timedelta(minutes=1)
    raise ValueError("No next occurrence")


def default_agent():
    return dict(id=str(uuid.uuid4()).upper(), name="Marr", role="Your personal assistant",
                instructions="Help me finish useful work. Verify results and report what needs my attention.",
                memory="", access="readOnly", skillIDs=[], isPaused=False, tint=0,
                maxRunMinutes=10, dailyRoutineLimit=12, createdAt=time.time())


class State:
    def __init__(self, path):
        self.lock = threading.RLock()
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY, body TEXT NOT NULL)")
        row = self.db.execute("SELECT body FROM state WHERE id=1").fetchone()
        self.data = json.loads(row[0]) if row else dict(protocolVersion=1, serviceID=str(uuid.uuid4()), revision=0,
            archive=dict(version=1, agents=[default_agent()], routines=[], skills=[], runs=[]))
        if self.data.get("protocolVersion") != 1 or self.data.get("archive", {}).get("version") != 1:
            raise ValueError("Unsupported archive version; database was not modified")
        self.interactions = {}
        for run in self.data["archive"]["runs"]:
            if run["status"] in ("running", "needsInput"):
                run["status"] = "uncertain" if run.get("submissionAttempted") else "cancelled"
                run["detail"] = "Server restarted. This run was not replayed."
        self.commit()

    def commit(self):
        self.data["revision"] += 1
        try:
            with self.db:
                self.db.execute("INSERT OR REPLACE INTO state VALUES (1, ?)", (json.dumps(self.data, allow_nan=False),))
        except Exception:
            row = self.db.execute("SELECT body FROM state WHERE id=1").fetchone()
            if row:
                self.data = json.loads(row[0])
            raise

    def snapshot(self):
        with self.lock:
            result = copy.deepcopy(self.data)
            result["interactions"] = copy.deepcopy(list(self.interactions.values()))
            return result

    @property
    def archive(self):
        return self.data["archive"]

    def find(self, collection, item_id):
        return next((x for x in self.archive[collection] if x["id"] == item_id), None)

    def busy(self, agent_id=None):
        return any(r["status"] in ACTIVE and (agent_id is None or r["agentID"] == agent_id) for r in self.archive["runs"])

    def save(self, collection, item):
        with self.lock:
            item = copy.deepcopy(item)
            item["id"] = identifier(item["id"])
            old = self.find(collection, item["id"])
            agent_id = item["id"] if collection == "agents" else item.get("agentID")
            if self.busy(agent_id) or (old and collection == "routines" and self.busy(old["agentID"])):
                raise ValueError("Finish or resolve the active run before editing")
            if not isinstance(item.get("name"), str) or not item["name"].strip():
                raise ValueError("Name is required")
            item.pop("threadID", None)  # A client cannot attach arbitrary runtime threads.
            if old and old.get("threadID"):
                item["threadID"] = old["threadID"]
            if collection == "agents":
                if not item.get("instructions", "").strip() or item.get("access") not in ("readOnly", "workspace"):
                    raise ValueError("Instructions and valid file access are required")
                if not 1 <= item["maxRunMinutes"] <= 60 or not 1 <= item["dailyRoutineLimit"] <= 100:
                    raise ValueError("Invalid execution limits")
                for key in ("role", "memory"):
                    if not isinstance(item.get(key), str):
                        raise ValueError("Invalid agent fields")
                if not isinstance(item.get("isPaused"), bool) or not isinstance(item.get("tint"), int):
                    raise ValueError("Invalid agent fields")
            elif collection == "routines":
                if not self.find("agents", item["agentID"]) or not item.get("instruction", "").strip():
                    raise ValueError("A valid agent and instruction are required")
                due = next_time(item["schedule"], time.time())
                changed = not old or any(item.get(k) != old.get(k) for k in ("schedule", "isEnabled", "agentID"))
                if old and item["agentID"] != old["agentID"]:
                    item.pop("threadID", None)
                item["nextRunAt"] = (due if changed else old.get("nextRunAt", due)) if item["isEnabled"] else None
            elif not item.get("instructions", "").strip():
                raise ValueError("Skill instructions are required")
            if collection != "skills":
                if not isinstance(item.get("skillIDs"), list) or any(not self.find("skills", x) for x in item["skillIDs"]):
                    raise ValueError("Unknown skill")
            if old:
                self.archive[collection].remove(old)
            self.archive[collection].append(item)
            self.commit()

    def delete(self, collection, item_id):
        with self.lock:
            item = self.find(collection, item_id)
            if not item:
                return
            owner = item_id if collection == "agents" else item.get("agentID")
            if self.busy(owner):
                raise ValueError("Finish or resolve the active run before deleting")
            self.archive[collection].remove(item)
            if collection == "agents":
                self.archive["routines"] = [r for r in self.archive["routines"] if r["agentID"] != item_id]
            if collection == "skills":
                for obj in self.archive["agents"] + self.archive["routines"]:
                    obj["skillIDs"] = [x for x in obj["skillIDs"] if x != item_id]
            self.commit()

    def begin(self, run_id, agent_id, prompt, routine_id=None, scheduled=False, now=None):
        with self.lock:
            run_id = identifier(run_id)
            old = self.find("runs", run_id)
            if old:
                if (old["agentID"], old["prompt"], old.get("routineID")) != (agent_id, prompt, routine_id):
                    raise ValueError("Request ID was already used")
                return old, False
            now = time.time() if now is None else now
            agent = self.find("agents", agent_id)
            if not agent or agent["isPaused"] or self.busy(agent_id):
                raise ValueError("Agent is paused, unavailable or already working")
            if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 100000:
                raise ValueError("A message of 1–100000 characters is required")
            routine = self.find("routines", routine_id) if routine_id else None
            if routine_id and (not routine or routine["agentID"] != agent_id):
                raise ValueError("Unknown routine")
            if routine:
                count = sum(r["agentID"] == agent_id and r.get("routineID") is not None and r["startedAt"] > now - 86400 for r in self.archive["runs"])
                if count >= agent["dailyRoutineLimit"]:
                    raise ValueError("Daily routine limit reached")
                if scheduled:
                    if not routine["isEnabled"] or routine.get("nextRunAt", now + 1) > now:
                        raise ValueError("Routine is not due")
                    routine["nextRunAt"] = next_time(routine["schedule"], now)
            run = dict(id=run_id, agentID=agent_id, prompt=prompt.strip(), status="running", startedAt=now,
                       submissionAttempted=False, result="", detail="", trace=[], isRead=False)
            if routine_id:
                run["routineID"] = routine_id
            thread = (routine or agent).get("threadID")
            if thread:
                run["threadID"] = thread
            self.archive["runs"].append(run)
            self.commit()
            return copy.deepcopy(run), True

    def update_run(self, run_id, **fields):
        with self.lock:
            run = self.find("runs", run_id)
            run.update(fields)
            if fields.get("threadID"):
                owner = self.find("routines", run.get("routineID")) if run.get("routineID") else self.find("agents", run["agentID"])
                if owner:
                    owner["threadID"] = fields["threadID"]
            if fields.get("status") not in (None, "running", "needsInput", "uncertain"):
                run["finishedAt"] = time.time()
                run["isRead"] = bool(run.get("routineID") and run["status"] == "succeeded" and run["result"].strip() == "NO_UPDATE")
            self.commit()

    def trace(self, run_id, title, detail):
        with self.lock:
            run = self.find("runs", run_id)
            run["trace"] = (run["trace"] + [dict(id=str(uuid.uuid4()), title=title, detail=detail[:8000], date=time.time())])[-100:]
            self.commit()
