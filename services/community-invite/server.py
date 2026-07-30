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
import json
import os
import secrets
import sqlite3
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

DEFAULT_QUOTA_SECONDS = 30 * 60 * 60
SECONDS_PER_GIVE = 6 * 60 * 60
DEFAULT_GIVES = 5
MAX_SESSION_SECONDS = 5 * 60 * 60


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
                """
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

    def invite_for_token(self, token: str) -> sqlite3.Row | None:
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

    def reserve_session(self, invite_id: int, requested_seconds: int) -> dict | None:
        requested = max(1, min(requested_seconds, MAX_SESSION_SECONDS))
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
                    (id, invite_id, reserved_seconds, created_at)
                VALUES (?, ?, ?, ?)
                """,
                (session_id, invite_id, reserved, now_iso()),
            )
            db.execute(
                "UPDATE invites SET reserved_seconds = reserved_seconds + ? WHERE id = ?",
                (reserved, invite_id),
            )
            return {"session_id": session_id, "reserved_seconds": reserved}

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


def create_soniox_temporary_key(
    master_key: str, session_id: str, duration_seconds: int
) -> dict:
    body = json.dumps(
        {
            "usage_type": "transcribe_websocket",
            "expires_in_seconds": 3_600,
            "client_reference_id": f"zulangue-community:{session_id}",
            "single_use": True,
            "max_session_duration_seconds": duration_seconds,
        }
    ).encode()
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
        self.send_json(404, {"error": "not_found"})

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
            requested = int(body.get("requested_seconds", MAX_SESSION_SECONDS))
            session = self.store.reserve_session(invite["id"], requested)
            if session is None:
                self.send_json(409, {"error": "quota_exhausted"})
                return
            master_key = os.environ.get("SONIOX_API_KEY", "")
            if not master_key:
                self.store.settle_session(invite["id"], session["session_id"], 0)
                self.send_json(503, {"error": "service_not_configured"})
                return
            try:
                temporary = create_soniox_temporary_key(
                    master_key,
                    session["session_id"],
                    session["reserved_seconds"],
                )
            except (urllib.error.URLError, TimeoutError):
                self.store.settle_session(invite["id"], session["session_id"], 0)
                self.send_json(502, {"error": "upstream_unavailable"})
                return
            self.send_json(200, {**session, **temporary})
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
