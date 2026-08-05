#!/usr/bin/env python3
"""Minimal community-invite service for Zulangue.

The public contract is deliberately about time, not money:
- one invite grants 30 hours;
- every processed audio second consumes one quota second;
- Soniox billing and credentials stay server-side.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import html
import json
import os
import secrets
import sqlite3
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

DEFAULT_QUOTA_SECONDS = 30 * 60 * 60
SECONDS_PER_GIVE = 6 * 60 * 60
DEFAULT_GIVES = 5
MAX_SESSION_SECONDS = 5 * 60 * 60
# A reservation that was never settled (client crash, network loss) must not
# hold invite quota forever. Anything older than this settles at zero seconds.
RESERVATION_TTL_SECONDS = 6 * 60 * 60
# One partner records on one machine; a small allowance covers a second
# device or a crashed session waiting for its TTL. Anything beyond that is
# a shared or scripted token.
MAX_OPEN_SESSIONS_PER_INVITE = 2
# A capture selects at most three target languages, which the core turns
# into one canonical lane plus one translation lane per language. Everything
# the server derives per lane is bounded by this.
MAX_LANES_PER_SESSION = 4
# Per-session key budget: a full four-lane start, one complete retry of it,
# and renewal headroom for a five-hour recording. Key issuance is the
# server's stream-count lever, so the budget is deliberately finite.
SESSION_KEY_BUDGET = 16
# One batch request covers a full multi-language capture start: canonical
# plus every translation lane.
MAX_KEYS_PER_REQUEST = MAX_LANES_PER_SESSION
# Single-use keys are fetched right before a connection opens, so they only
# need to stay redeemable for a moment. A short expiry keeps a leaked but
# unused key nearly worthless.
SINGLE_USE_KEY_EXPIRES_SECONDS = 300
# Soniox realtime list price per lane-hour; used only for the admin page's
# local cost estimate. Ground truth is GET /v1/usage-logs.
REALTIME_USD_PER_LANE_HOUR = 0.12


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


class Store:
    def __init__(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        self.path = path
        self.migrate()

    def connect(self) -> sqlite3.Connection:
        db = sqlite3.connect(self.path)
        db.row_factory = sqlite3.Row
        return db

    def migrate(self) -> None:
        with self.connect() as db:
            db.executescript(
                """
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS invites (
                    id INTEGER PRIMARY KEY,
                    code_hash TEXT NOT NULL UNIQUE,
                    label TEXT NOT NULL,
                    quota_seconds INTEGER NOT NULL,
                    used_seconds INTEGER NOT NULL DEFAULT 0,
                    reserved_seconds INTEGER NOT NULL DEFAULT 0,
                    enabled INTEGER NOT NULL DEFAULT 1,
                    created_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS access_tokens (
                    token_hash TEXT PRIMARY KEY,
                    invite_id INTEGER NOT NULL REFERENCES invites(id),
                    created_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS sessions (
                    id TEXT PRIMARY KEY,
                    invite_id INTEGER NOT NULL REFERENCES invites(id),
                    reserved_seconds INTEGER NOT NULL,
                    settled_seconds INTEGER,
                    created_at TEXT NOT NULL,
                    settled_at TEXT
                );
                CREATE TABLE IF NOT EXISTS session_keys (
                    id INTEGER PRIMARY KEY,
                    session_id TEXT NOT NULL REFERENCES sessions(id),
                    issued_at TEXT NOT NULL
                );
                """
            )
            # Reservations are counted in lane-seconds, so the wall-clock
            # bound handed to Soniox needs the lane count that produced them.
            # Sessions predating this column were single-lane.
            columns = {row["name"] for row in db.execute("PRAGMA table_info(sessions)")}
            if "lane_count" not in columns:
                db.execute(
                    "ALTER TABLE sessions ADD COLUMN lane_count INTEGER NOT NULL DEFAULT 1"
                )

    def create_invite(self, label: str, quota_seconds: int) -> str:
        code = "ZL-" + secrets.token_hex(8).upper()
        with self.connect() as db:
            db.execute(
                """
                INSERT INTO invites
                    (code_hash, label, quota_seconds, created_at)
                VALUES (?, ?, ?, ?)
                """,
                (digest(code), label, quota_seconds, now_iso()),
            )
        return code

    def redeem(self, code: str) -> dict | None:
        with self.connect() as db:
            invite = db.execute(
                "SELECT * FROM invites WHERE code_hash = ? AND enabled = 1",
                (digest(code.strip().upper()),),
            ).fetchone()
            if invite is None:
                return None
            token = secrets.token_urlsafe(32)
            db.execute(
                "INSERT INTO access_tokens (token_hash, invite_id, created_at) VALUES (?, ?, ?)",
                (digest(token), invite["id"], now_iso()),
            )
            return {"access_token": token, **quota_payload(invite)}

    def expire_stale_reservations(self) -> None:
        cutoff = (
            datetime.now(timezone.utc) - timedelta(seconds=RESERVATION_TTL_SECONDS)
        ).isoformat()
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            stale = db.execute(
                "SELECT * FROM sessions WHERE settled_seconds IS NULL AND created_at < ?",
                (cutoff,),
            ).fetchall()
            for session in stale:
                db.execute(
                    "UPDATE sessions SET settled_seconds = 0, settled_at = ? WHERE id = ?",
                    (now_iso(), session["id"]),
                )
                db.execute(
                    "UPDATE invites SET reserved_seconds = reserved_seconds - ? WHERE id = ?",
                    (session["reserved_seconds"], session["invite_id"]),
                )

    def invite_for_token(self, token: str) -> sqlite3.Row | None:
        self.expire_stale_reservations()
        with self.connect() as db:
            return db.execute(
                """
                SELECT invites.*
                FROM access_tokens
                JOIN invites ON invites.id = access_tokens.invite_id
                WHERE access_tokens.token_hash = ? AND invites.enabled = 1
                """,
                (digest(token),),
            ).fetchone()

    def reserve_session(
        self, invite_id: int, requested_seconds: int, lane_count: int = 1
    ) -> dict | None:
        requested = max(1, min(requested_seconds, MAX_SESSION_SECONDS))
        lanes = max(1, min(lane_count, MAX_LANES_PER_SESSION))
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            invite = db.execute(
                "SELECT * FROM invites WHERE id = ? AND enabled = 1",
                (invite_id,),
            ).fetchone()
            if invite is None:
                return None
            remaining = (
                invite["quota_seconds"]
                - invite["used_seconds"]
                - invite["reserved_seconds"]
            )
            reserved = min(requested, remaining)
            if reserved <= 0:
                return None
            session_id = secrets.token_urlsafe(18)
            db.execute(
                """
                INSERT INTO sessions
                    (id, invite_id, reserved_seconds, lane_count, created_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                (session_id, invite_id, reserved, lanes, now_iso()),
            )
            db.execute(
                "UPDATE invites SET reserved_seconds = reserved_seconds + ? WHERE id = ?",
                (reserved, invite_id),
            )
            return {
                "session_id": session_id,
                "reserved_seconds": reserved,
                "lane_count": lanes,
            }

    def open_session(self, invite_id: int, session_id: str) -> sqlite3.Row | None:
        with self.connect() as db:
            return db.execute(
                """
                SELECT * FROM sessions
                WHERE id = ? AND invite_id = ? AND settled_seconds IS NULL
                """,
                (session_id, invite_id),
            ).fetchone()

    def count_open_sessions(self, invite_id: int) -> int:
        with self.connect() as db:
            return db.execute(
                """
                SELECT COUNT(*) AS n FROM sessions
                WHERE invite_id = ? AND settled_seconds IS NULL
                """,
                (invite_id,),
            ).fetchone()["n"]

    def session_key_headroom(self, invite_id: int, session_id: str) -> int | None:
        """Remaining key budget for an open session, or None when the
        session is unknown, foreign, or already settled. Read-only: callers
        that are about to mint must use reserve_session_keys instead, which
        checks and claims in one transaction."""
        with self.connect() as db:
            session = db.execute(
                """
                SELECT id FROM sessions
                WHERE id = ? AND invite_id = ? AND settled_seconds IS NULL
                """,
                (session_id, invite_id),
            ).fetchone()
            if session is None:
                return None
            issued = db.execute(
                "SELECT COUNT(*) AS n FROM session_keys WHERE session_id = ?",
                (session_id,),
            ).fetchone()["n"]
            return max(0, SESSION_KEY_BUDGET - issued)

    def reserve_session_keys(
        self, invite_id: int, session_id: str, count: int
    ) -> int | None:
        """Claims `count` slots of the session's finite key budget in one
        transaction and returns the running issued total, or None when the
        session is not open or the whole batch does not fit. Every Soniox key
        minted for a session must be claimed here first — checking headroom
        and inserting separately lets concurrent requests both pass the check
        and mint past the budget, which is what bounds stream count."""
        if count < 1:
            return None
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            session = db.execute(
                """
                SELECT id FROM sessions
                WHERE id = ? AND invite_id = ? AND settled_seconds IS NULL
                """,
                (session_id, invite_id),
            ).fetchone()
            if session is None:
                return None
            issued = db.execute(
                "SELECT COUNT(*) AS n FROM session_keys WHERE session_id = ?",
                (session_id,),
            ).fetchone()["n"]
            # All-or-nothing: a partially granted batch would leave the
            # client with fewer keys than it has lanes to open.
            if issued + count > SESSION_KEY_BUDGET:
                return None
            stamp = now_iso()
            db.executemany(
                "INSERT INTO session_keys (session_id, issued_at) VALUES (?, ?)",
                [(session_id, stamp)] * count,
            )
            return issued + count

    def issue_session_key(self, invite_id: int, session_id: str) -> int | None:
        """Claims exactly one slot. Thin wrapper over reserve_session_keys."""
        return self.reserve_session_keys(invite_id, session_id, 1)

    def release_session_keys(self, session_id: str, count: int) -> None:
        """Gives back slots claimed for keys that were never minted, so an
        upstream failure mid-batch does not silently burn the budget."""
        if count < 1:
            return
        with self.connect() as db:
            db.execute(
                """
                DELETE FROM session_keys WHERE id IN (
                    SELECT id FROM session_keys WHERE session_id = ?
                    ORDER BY id DESC LIMIT ?
                )
                """,
                (session_id, count),
            )

    def admin_overview(self) -> list[dict]:
        with self.connect() as db:
            rows = db.execute(
                """
                SELECT invites.*,
                    (SELECT COUNT(*) FROM sessions
                     WHERE sessions.invite_id = invites.id
                       AND sessions.settled_seconds IS NULL) AS open_sessions,
                    (SELECT COUNT(*) FROM sessions
                     WHERE sessions.invite_id = invites.id) AS total_sessions,
                    (SELECT COUNT(*) FROM session_keys
                     JOIN sessions ON sessions.id = session_keys.session_id
                     WHERE sessions.invite_id = invites.id) AS keys_issued
                FROM invites
                ORDER BY invites.id
                """
            ).fetchall()
            return [dict(row) for row in rows]

    def settle_session(self, invite_id: int, session_id: str, used_seconds: int) -> dict | None:
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            session = db.execute(
                """
                SELECT * FROM sessions
                WHERE id = ? AND invite_id = ? AND settled_seconds IS NULL
                """,
                (session_id, invite_id),
            ).fetchone()
            if session is None:
                return None
            charged = max(0, min(used_seconds, session["reserved_seconds"]))
            db.execute(
                """
                UPDATE sessions
                SET settled_seconds = ?, settled_at = ?
                WHERE id = ?
                """,
                (charged, now_iso(), session_id),
            )
            db.execute(
                """
                UPDATE invites
                SET used_seconds = used_seconds + ?,
                    reserved_seconds = reserved_seconds - ?
                WHERE id = ?
                """,
                (charged, session["reserved_seconds"], invite_id),
            )
            invite = db.execute(
                "SELECT * FROM invites WHERE id = ?", (invite_id,)
            ).fetchone()
            return quota_payload(invite)


def quota_payload(invite: sqlite3.Row) -> dict:
    remaining = max(
        0,
        invite["quota_seconds"] - invite["used_seconds"] - invite["reserved_seconds"],
    )
    return {
        "total_gives": round(invite["quota_seconds"] / SECONDS_PER_GIVE, 2),
        "remaining_gives": round(remaining / SECONDS_PER_GIVE, 2),
        "quota_seconds": invite["quota_seconds"],
        "used_seconds": invite["used_seconds"],
        "remaining_seconds": remaining,
    }


def stream_duration_seconds(session: sqlite3.Row | dict) -> int:
    """Soniox bounds each WebSocket by wall-clock seconds, but a reservation
    is counted in lane-seconds: a four-lane capture spends four seconds of
    quota per second of audio. Handing the raw reservation to Soniox would
    let every lane run the full reservation on its own, overshooting the
    quota by the lane count. Divide it back down to wall clock."""
    lanes = max(1, min(int(session["lane_count"] or 1), MAX_LANES_PER_SESSION))
    return max(1, int(session["reserved_seconds"]) // lanes)


def create_soniox_temporary_key(
    master_key: str,
    session_id: str,
    duration_seconds: int,
    *,
    single_use: bool = False,
    expires_in_seconds: int = 3_600,
) -> dict:
    # Two key shapes share this call. The legacy shared key is NOT
    # single_use: one capture opens several concurrent WebSocket lanes with
    # the same key and mid-session reconnects reuse it. The per-connection
    # key IS single_use with a short expiry: clients fetch it right before
    # opening one stream, so a leaked key is worth at most one stream for a
    # few minutes.
    payload: dict = {
        "usage_type": "transcribe_websocket",
        "expires_in_seconds": expires_in_seconds,
        "client_reference_id": f"zulangue-community:{session_id}",
        "max_session_duration_seconds": duration_seconds,
    }
    if single_use:
        payload["single_use"] = True
    body = json.dumps(payload).encode()
    request = urllib.request.Request(
        "https://api.soniox.com/v1/auth/temporary-api-key",
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {master_key}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(request, timeout=15) as response:
        return json.load(response)


class Handler(BaseHTTPRequestHandler):
    server_version = "ZulangueCommunityInvite/1"

    @property
    def store(self) -> Store:
        return self.server.store  # type: ignore[attr-defined]

    def do_GET(self) -> None:
        if self.path == "/healthz":
            self.send_json(200, {"status": "ok"})
            return
        if self.path == "/v1/quota":
            invite = self.authorized_invite()
            if invite is not None:
                self.send_json(200, quota_payload(invite))
            return
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path == "/admin":
            self.render_admin(parsed)
            return
        self.send_json(404, {"error": "not_found"})

    def render_admin(self, parsed: urllib.parse.SplitResult) -> None:
        configured = os.environ.get("ZULANGUE_ADMIN_TOKEN", "")
        if not configured:
            # Without a configured token the page does not exist at all.
            self.send_json(404, {"error": "not_found"})
            return
        supplied = ""
        query = urllib.parse.parse_qs(parsed.query)
        if query.get("token"):
            supplied = query["token"][0]
        header = self.headers.get("Authorization", "")
        if header.startswith("Bearer "):
            supplied = header.removeprefix("Bearer ").strip()
        if not hmac.compare_digest(supplied, configured):
            self.send_json(401, {"error": "unauthorized"})
            return
        self.store.expire_stale_reservations()
        rows = []
        totals = {"used": 0, "reserved": 0, "cost": 0.0}
        for invite in self.store.admin_overview():
            used_hours = invite["used_seconds"] / 3600
            cost = used_hours * REALTIME_USD_PER_LANE_HOUR
            totals["used"] += invite["used_seconds"]
            totals["reserved"] += invite["reserved_seconds"]
            totals["cost"] += cost
            remaining = max(
                0,
                invite["quota_seconds"]
                - invite["used_seconds"]
                - invite["reserved_seconds"],
            )
            rows.append(
                "<tr>"
                f"<td>{html.escape(invite['label'])}</td>"
                f"<td>{'yes' if invite['enabled'] else 'no'}</td>"
                f"<td>{invite['quota_seconds'] / 3600:.1f}</td>"
                f"<td>{used_hours:.2f}</td>"
                f"<td>{invite['reserved_seconds'] / 3600:.2f}</td>"
                f"<td>{remaining / 3600:.2f}</td>"
                f"<td>{invite['open_sessions']}/{invite['total_sessions']}</td>"
                f"<td>{invite['keys_issued']}</td>"
                f"<td>${cost:.2f}</td>"
                "</tr>"
            )
        page = (
            "<!doctype html><meta charset='utf-8'>"
            "<title>Zulangue community invites</title>"
            "<style>body{font:14px system-ui;margin:2rem}"
            "table{border-collapse:collapse}"
            "td,th{border:1px solid #ccc;padding:.4rem .6rem;text-align:right}"
            "td:first-child,th:first-child{text-align:left}</style>"
            "<h1>Community invites</h1>"
            "<table><tr><th>Label</th><th>Enabled</th><th>Quota h</th>"
            "<th>Used lane-h</th><th>Reserved lane-h</th><th>Remaining h</th>"
            "<th>Sessions open/total</th><th>Keys issued</th>"
            "<th>Est. cost</th></tr>"
            + "".join(rows)
            + "<tr><th>Total</th><th></th><th></th>"
            f"<th>{totals['used'] / 3600:.2f}</th>"
            f"<th>{totals['reserved'] / 3600:.2f}</th><th></th><th></th><th></th>"
            f"<th>${totals['cost']:.2f}</th></tr>"
            "</table>"
            "<p>Used seconds are settled lane-seconds as reported by clients; "
            "the estimate multiplies them by the Soniox realtime list price. "
            "Ground truth per session: <code>GET /v1/usage-logs</code> on "
            "Soniox filtered by <code>client_reference_id</code> prefix "
            "<code>zulangue-community:</code>.</p>"
        )
        body = page.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:
        if self.path == "/v1/redeem":
            body = self.read_json()
            result = self.store.redeem(str(body.get("code", "")))
            if result is None:
                self.send_json(404, {"error": "invalid_invite"})
            else:
                self.send_json(200, result)
            return

        invite = self.authorized_invite()
        if invite is None:
            return
        body = self.read_json()

        if self.path == "/v1/realtime-session":
            if (
                self.store.count_open_sessions(invite["id"])
                >= MAX_OPEN_SESSIONS_PER_INVITE
            ):
                self.send_json(409, {"error": "too_many_open_sessions"})
                return
            requested = int(body.get("requested_seconds", MAX_SESSION_SECONDS))
            session = self.store.reserve_session(
                invite["id"], requested, int(body.get("lane_count", 1))
            )
            if session is None:
                self.send_json(409, {"error": "quota_exhausted"})
                return
            master_key = os.environ.get("SONIOX_API_KEY", "")
            if not master_key:
                self.store.settle_session(invite["id"], session["session_id"], 0)
                self.send_json(503, {"error": "service_not_configured"})
                return
            # The initial shared key draws from the same budget as renewals
            # and per-connection keys; a fresh session can never be over it.
            self.store.issue_session_key(invite["id"], session["session_id"])
            try:
                temporary = create_soniox_temporary_key(
                    master_key,
                    session["session_id"],
                    stream_duration_seconds(session),
                )
            except (urllib.error.URLError, TimeoutError):
                self.store.settle_session(invite["id"], session["session_id"], 0)
                self.send_json(502, {"error": "upstream_unavailable"})
                return
            self.send_json(200, {**session, **temporary})
            return

        if self.path == "/v1/realtime-session/renew-key":
            # Soniox temporary keys expire after at most one hour, which is
            # shorter than a reservation. Renewal issues a fresh key against
            # the same open reservation without touching quota, so recordings
            # longer than an hour keep a valid key for reconnects and lanes.
            # Renewals draw from the same finite key budget as
            # per-connection keys, so a leaked access token cannot mint keys
            # forever.
            self.mint_session_key(invite, body, single_use=False)
            return

        if self.path == "/v1/realtime-session/key":
            # Per-connection credential for the single_use client path: one
            # key opens exactly one WebSocket lane and stays redeemable only
            # briefly, so stream count per session is bounded by the key
            # budget rather than by trust in the client.
            self.mint_session_key(invite, body, single_use=True)
            return

        if self.path == "/v1/realtime-session/settle":
            result = self.store.settle_session(
                invite["id"],
                str(body.get("session_id", "")),
                int(body.get("used_seconds", 0)),
            )
            if result is None:
                self.send_json(404, {"error": "session_not_found"})
            else:
                self.send_json(200, result)
            return

        self.send_json(404, {"error": "not_found"})

    def mint_session_key(
        self, invite: sqlite3.Row, body: dict, *, single_use: bool
    ) -> None:
        session = self.store.open_session(
            invite["id"], str(body.get("session_id", ""))
        )
        if session is None:
            self.send_json(404, {"error": "session_not_found"})
            return
        master_key = os.environ.get("SONIOX_API_KEY", "")
        if not master_key:
            self.send_json(503, {"error": "service_not_configured"})
            return
        # A multi-language capture start fetches one key per lane in a
        # single request. Renewals of the legacy shared key stay single.
        count = 1
        if single_use:
            count = max(1, min(int(body.get("count", 1)), MAX_KEYS_PER_REQUEST))
        # Claim the whole batch before minting anything. Checking headroom
        # and counting afterwards lets two concurrent requests both pass the
        # check and hand out keys the budget never covered.
        issued = self.store.reserve_session_keys(invite["id"], session["id"], count)
        if issued is None:
            self.send_json(429, {"error": "key_budget_exhausted"})
            return
        keys: list[dict] = []
        for _ in range(count):
            try:
                temporary = create_soniox_temporary_key(
                    master_key,
                    session["id"],
                    stream_duration_seconds(session),
                    single_use=single_use,
                    expires_in_seconds=(
                        SINGLE_USE_KEY_EXPIRES_SECONDS if single_use else 3_600
                    ),
                )
            except (urllib.error.URLError, TimeoutError):
                # The client sees no keys at all, so nothing minted in this
                # batch can ever be redeemed. Give the whole claim back
                # instead of burning budget on dead credentials.
                self.store.release_session_keys(session["id"], count)
                self.send_json(502, {"error": "upstream_unavailable"})
                return
            keys.append(temporary)
        response = {
            "session_id": session["id"],
            "reserved_seconds": session["reserved_seconds"],
            "keys_issued": issued,
            "keys": keys,
        }
        if count == 1:
            # Single-key callers (the renew path today) read flat fields.
            response.update(keys[0])
        self.send_json(200, response)

    def authorized_invite(self) -> sqlite3.Row | None:
        value = self.headers.get("Authorization", "")
        if not value.startswith("Bearer "):
            self.send_json(401, {"error": "unauthorized"})
            return None
        invite = self.store.invite_for_token(value.removeprefix("Bearer ").strip())
        if invite is None:
            self.send_json(401, {"error": "unauthorized"})
        return invite

    def read_json(self) -> dict:
        length = min(int(self.headers.get("Content-Length", "0")), 16_384)
        try:
            return json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            return {}

    def send_json(self, status: int, value: dict) -> None:
        payload = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt: str, *args: object) -> None:
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", default=os.environ.get("ZULANGUE_INVITE_DB", "data/invites.db"))
    sub = parser.add_subparsers(dest="command", required=True)
    serve = sub.add_parser("serve")
    serve.add_argument("--host", default="127.0.0.1")
    serve.add_argument("--port", type=int, default=8000)
    create = sub.add_parser("create-invite")
    create.add_argument("--label", required=True)
    create.add_argument("--gives", type=int, default=DEFAULT_GIVES)
    args = parser.parse_args()

    store = Store(Path(args.db))
    if args.command == "create-invite":
        print(store.create_invite(args.label, args.gives * SECONDS_PER_GIVE))
        return
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.store = store  # type: ignore[attr-defined]
    server.serve_forever()


if __name__ == "__main__":
    main()
