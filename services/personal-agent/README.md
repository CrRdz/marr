# Marr Personal Agent — self-hosted service

Users run this service on their own Linux server and connect Marr in **Settings → Work → Personal Agent · Hosting**. Marr does not provide or pay for hosting. A running server executes enabled schedules independently of the Mac; reconnecting downloads results and pending approvals.

## Deploy

Requirements: a Linux VPS with Docker Compose, a hostname pointing at the VPS, inbound ports 80/443, and your own Codex model access. The container runs as a non-root user. Do not expose port 8787 directly to the Internet.

1. Copy this `services/personal-agent` directory to the server. Inside it:

   ```sh
   cp .env.example .env
   chmod 600 .env
   python3 -c 'import secrets; print(secrets.token_urlsafe(32))'
   ```

2. Edit `.env`: set `AGENT_DOMAIN` to your hostname, `MARR_AGENT_TOKEN` to the newly generated random token, and `MARR_AGENT_MODEL` to a model your account can use. The service token authenticates Marr to your server; it is **not** a model-provider key. Keep `.env` private.

3. Build and authorize the runtime on **your server**:

   ```sh
   docker compose build agent
   docker compose run --rm agent codex login --device-auth
   ```

   Complete the displayed sign-in flow in your browser. If your account uses an API key instead, supply it to `docker compose run --rm -T agent codex login --with-api-key` through standard input using your server's secret manager. Do not put a key in a command argument or paste it into a Marr conversation. Runtime credentials are stored in the persistent `agent-data` volume. No credentials are copied from your Mac.

4. Start both containers:

   ```sh
   docker compose up -d
   docker compose ps
   ```

   Caddy obtains and renews the HTTPS certificate. DNS and ports must be correct before certificate issuance can succeed. Agent health checks confirm HTTP availability, not model entitlement.

5. In Marr, open **Settings → Work → Personal Agent · Hosting**, enter `https://your-hostname` and the service access token, then click **Connect**. The token is saved in macOS Keychain. A fresh server has one Marr contact; add other agents with **+ → New agent**. Each has its own conversation, memory and schedules.

6. Send a small test message, verify that the answer completes, then create an enabled routine. Quit Marr and leave the server running; after the routine's scheduled time, reopen Marr and verify its result. If access approval is required, the run waits for your response within its configured time limit.

Marr's **Use this Mac** switches the client back to its local agents. It does **not** stop server routines. To stop cloud work, pause the relevant agents/routines before switching, or run `docker compose stop agent` on the server. `docker compose down` preserves volumes; `down -v` destroys data and credentials.

## State and execution

- SQLite WAL stores profiles, shared skills, schedules, run records, thread IDs and submission markers in `/data/agents.sqlite3`. The `agent-data` volume also contains runtime history/auth in `/data/codex` and per-agent folders in `/data/workspaces`.
- Each chat and each routine has a separate persistent Codex thread. Different agents can execute concurrently (up to four); one agent's runs are serialized. Capacity errors preserve the client's draft; there is no hidden unbounded queue.
- The scheduler checks every 10 seconds. Hourly, daily and weekdays schedules use IANA time zones, including daylight-saving transitions. Missed occurrences coalesce into one; daily run budgets and paused agents are respected. Default limits: 10 minutes/run and 12 routine runs per agent per rolling 24 hours.
- A durable run ID makes message submission idempotent. A repeated ID with different content is rejected. On restart, unsubmitted work is cancelled and previously submitted work is marked uncertain. The service **never automatically replays uncertain work**. Check connection reads the original turn, matching its saved turn ID or the runtime user message's `clientId`.
- Both read-only and agent-folder write policies use `on-request` approvals and `approvalsReviewer: user`. Extra access requires an approval returned to the same run's conversation. Rejected/unsupported host tools are not silently enabled. Schedules and skills are managed by Marr, not by model-generated background jobs.
- Model web search follows the configured runtime/account policy. Apps, plugins, MCP servers, hooks and autonomous child agents are disabled for these sessions.
- Closing the Mac does not stop server execution. Server loss, account expiry, budget exhaustion or unconfirmed runtime termination can still stop progress; the UI reports these states. `NO_UPDATE` results are retained without an unread badge. This version has no mobile push channel.

This is a **single-owner** deployment, not a multi-tenant SaaS. All agents share the owner's container and runtime account. The runtime write sandbox is not a VM or a per-agent confidentiality boundary; read-only does not mean only its own folder is readable. Do not put unrelated host credentials in the container or mount the Docker socket. Instructions about external actions supplement runtime approvals; they are not a separate policy engine.

## Operations

- Change the service token in `.env`, then `docker compose up -d --force-recreate agent` and reconnect Marr with the new token.
- Back up the `agent-data` volume with the agent container stopped (or use SQLite's online backup API). Protect backups as credentials and conversation data. Restore it to exactly one service instance; an exclusive file lock prevents two schedulers sharing the same volume.
- Upgrade deliberately: the image pins Codex CLI `0.146.0`; check protocol compatibility before changing `CODEX_VERSION`. The service refuses unknown archive versions.
- Service health: `GET /health` returns only an availability boolean. All data and mutation APIs require `Authorization: Bearer <token>`. No cross-origin browser access is enabled, and request/prompt/token logging is disabled. Reverse-proxy redirects are refused by the Mac client.
- Runtime errors appear in the chat. Reauthorize on the server if model access expires. For an uncertain run, use **Check connection**; the service does not infer that a lost connection means a successful cancellation.

## Development and verification

Python 3.9+ with IANA time-zone data; no third-party Python packages required:

```sh
python3 -m unittest discover -s services/personal-agent/tests -v
```

Tests use isolated temporary SQLite databases, a loopback HTTP server, and a fake stdio runtime. They cover HTTP auth, CRUD, restart recovery, idempotency, per-agent isolation/concurrency, scheduler behavior, DST, explicit approvals, stop confirmation and reconciliation. They do not bill a model or provision infrastructure.

For a local server smoke test, set `MARR_AGENT_DATA` to an empty directory, `MARR_AGENT_MODEL`, and a random `MARR_AGENT_TOKEN`, then run `python3 server.py`. The default bind address is `127.0.0.1:8787`. Marr permits HTTP only on loopback. Use a separate `CODEX_HOME` if you do not want to reuse your normal local runtime account.

The macOS development environment used for this change has no Docker engine. The Python service and mocked runtime/client integrations are tested locally; container build, Linux sandbox compatibility, real model authorization and public TLS must be verified on the deployment host using the first-run steps above.

Protocol reference: [Codex App Server](https://learn.chatgpt.com/docs/app-server).
