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
# Every temporary key this service mints carries this prefix in its
# client_reference_id, which is how billed usage is attributed back to a
# reservation. Usage that lands outside it is this account's other traffic.
USAGE_REFERENCE_PREFIX = "zulangue-community:"
# Soniox keeps usage logs for 91 days and serves at most a 31-day window.
USAGE_MAX_WINDOW_DAYS = 31
USAGE_PAGE_LIMIT = 1000
# Admin panel session: long enough for a working session, short enough that a
# forgotten browser tab stops being a live door into quota and invitations.
ADMIN_COOKIE_NAME = "zulangue_admin"
ADMIN_SESSION_TTL_SECONDS = 8 * 60 * 60
# The panel is reachable from the public internet and its only door is a
# shared token, so guessing must be made slow. These bound an attacker to a
# few tries per quarter hour while leaving an operator who fat-fingers the
# token a couple of immediate retries.
ADMIN_LOGIN_MAX_FAILURES = 5
# The global bucket exists only to catch an attacker spreading attempts across
# forged forwarded addresses. It sits far above the per-address limit on
# purpose: at the same threshold, a handful of failures from anywhere would
# lock the operator out of their own panel.
ADMIN_LOGIN_MAX_FAILURES_GLOBAL = 40
ADMIN_LOGIN_WINDOW_SECONDS = 15 * 60
ADMIN_LOGIN_LOCKOUT_SECONDS = 15 * 60


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def secret_equals(supplied: str, expected: str) -> bool:
    """Constant-time comparison that accepts anything a browser can post.
    hmac.compare_digest rejects non-ASCII str outright, which would turn a
    mistyped token into a crashed request instead of a failed login."""
    return hmac.compare_digest(
        supplied.encode("utf-8", "surrogatepass"),
        expected.encode("utf-8", "surrogatepass"),
    )


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
                -- Billed usage as Soniox reports it. Settled seconds are
                -- client-reported and therefore a claim; these rows are the
                -- account's actual charges, keyed by Soniox's own uuid so
                -- re-running a reconcile can never double-count.
                CREATE TABLE IF NOT EXISTS usage_entries (
                    uuid TEXT PRIMARY KEY,
                    client_reference_id TEXT,
                    session_id TEXT,
                    model TEXT,
                    start_time TEXT,
                    end_time TEXT,
                    audio_ms INTEGER NOT NULL DEFAULT 0,
                    cost_usd REAL NOT NULL DEFAULT 0,
                    recorded_at TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS usage_entries_session
                    ON usage_entries(session_id);
                CREATE INDEX IF NOT EXISTS usage_entries_end_time
                    ON usage_entries(end_time);
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
            # Who an invitation was handed to. The label names the batch it
            # was created in; this is the operator's own note about the person.
            invite_columns = {row["name"] for row in db.execute("PRAGMA table_info(invites)")}
            if "note" not in invite_columns:
                db.execute("ALTER TABLE invites ADD COLUMN note TEXT NOT NULL DEFAULT ''")
            db.executescript(
                """
                -- Quota grants and suspensions are the two ways an operator
                -- can change what an invitation is worth after the fact, so
                -- each one leaves a record. Backend accountability only; the
                -- admin panel does not surface it.
                -- 分享功能的 relay 门禁:登记过的 endpoint 才能用自建中继。
                -- 挡的是陌生人白嫖带宽,不改变隐私(中继流量始终端到端加密)。
                CREATE TABLE IF NOT EXISTS endpoint_enrollment (
                    endpoint_id TEXT PRIMARY KEY,
                    invite_id INTEGER NOT NULL REFERENCES invites(id),
                    created_at TEXT NOT NULL,
                    last_seen_at TEXT
                );
                -- 中继的运营统计,按天一行。
                --
                -- 这张表的**形状本身**就是隐私保证:它只有聚合量,没有 endpoint 列,
                -- 也没有配对列。就算有人想从这里还原「谁在几点连了谁」,数据也不在。
                -- 来源是中继的 Prometheus 全局计数器,那些计数器本身就不含配对信息。
                CREATE TABLE IF NOT EXISTS relay_daily (
                    day TEXT PRIMARY KEY,
                    bytes_sent INTEGER NOT NULL DEFAULT 0,
                    bytes_recv INTEGER NOT NULL DEFAULT 0,
                    connections INTEGER NOT NULL DEFAULT 0,
                    disconnects INTEGER NOT NULL DEFAULT 0,
                    packets_dropped INTEGER NOT NULL DEFAULT 0,
                    ratelimited INTEGER NOT NULL DEFAULT 0,
                    unique_clients_peak INTEGER NOT NULL DEFAULT 0,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS invite_audit (
                    id INTEGER PRIMARY KEY,
                    invite_id INTEGER NOT NULL REFERENCES invites(id),
                    action TEXT NOT NULL,
                    detail TEXT NOT NULL,
                    created_at TEXT NOT NULL
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

    def invite_by_code(self, code: str) -> sqlite3.Row | None:
        with self.connect() as db:
            return db.execute(
                "SELECT * FROM invites WHERE code_hash = ?",
                (digest(code.strip().upper()),),
            ).fetchone()

    # ── 分享:运营统计 ──────────────────────────────────────────────────
    #
    # 中继按天上报增量。累加而不是覆盖:一天内会上报多次,每次带的是自上次以来
    # 的增量。计数器在中继重启后会归零,增量由上报侧负责算好。

    RELAY_STAT_FIELDS = (
        "bytes_sent",
        "bytes_recv",
        "connections",
        "disconnects",
        "packets_dropped",
        "ratelimited",
    )

    def record_relay_stats(self, day: str, deltas: dict, unique_clients: int = 0) -> bool:
        """Accumulate one relay report into the day's row.

        Only the fields in RELAY_STAT_FIELDS are read. Anything else in the
        payload is ignored rather than stored, so a future reporter cannot
        quietly start sending per-endpoint data and have it land in the table.
        """
        if not day or len(day) != 10:
            return False
        clean = {}
        for field in self.RELAY_STAT_FIELDS:
            try:
                value = int(deltas.get(field, 0))
            except (TypeError, ValueError):
                return False
            if value < 0:
                return False
            clean[field] = value
        try:
            peak = max(0, int(unique_clients))
        except (TypeError, ValueError):
            return False

        assignments = ", ".join(f"{f} = {f} + excluded.{f}" for f in self.RELAY_STAT_FIELDS)
        columns = ", ".join(self.RELAY_STAT_FIELDS)
        placeholders = ", ".join("?" for _ in self.RELAY_STAT_FIELDS)
        with self.connect() as db:
            db.execute(
                f"""
                INSERT INTO relay_daily (day, {columns}, unique_clients_peak, updated_at)
                VALUES (?, {placeholders}, ?, ?)
                ON CONFLICT(day) DO UPDATE SET
                    {assignments},
                    unique_clients_peak = MAX(unique_clients_peak, excluded.unique_clients_peak),
                    updated_at = excluded.updated_at
                """,
                (day, *[clean[f] for f in self.RELAY_STAT_FIELDS], peak, now_iso()),
            )
        return True

    def relay_stats(self, limit: int = 30) -> list:
        """Recent daily rows, newest first."""
        with self.connect() as db:
            return [
                dict(row)
                for row in db.execute(
                    "SELECT * FROM relay_daily ORDER BY day DESC LIMIT ?", (limit,)
                )
            ]

    # ── 分享:relay 门禁 ────────────────────────────────────────────────
    #
    # relay 对 /v1/relay-auth 发 POST,请求头带 X-Iroh-Endpoint-Id。返回 200 且
    # 正文为 "true" 才放行。见 docs/architecture/share-p2p.md 第 6 节。

    ENDPOINT_ID_LENGTH = 64

    @staticmethod
    def normalize_endpoint_id(value: str) -> str | None:
        """Return the canonical hex form, or None when it is not an endpoint id.

        iroh endpoint ids are 32-byte ed25519 public keys rendered as 64 hex
        characters. Anything else is refused before it can reach the database,
        so a malformed header cannot become a stored row.
        """
        candidate = (value or "").strip().lower()
        if len(candidate) != Store.ENDPOINT_ID_LENGTH:
            return None
        if any(c not in "0123456789abcdef" for c in candidate):
            return None
        return candidate

    def enroll_endpoint(self, invite_id: int, endpoint_id: str) -> bool:
        """Bind an endpoint id to an invitation. Idempotent."""
        canonical = self.normalize_endpoint_id(endpoint_id)
        if canonical is None:
            return False
        with self.connect() as db:
            db.execute(
                """
                INSERT INTO endpoint_enrollment (endpoint_id, invite_id, created_at)
                VALUES (?, ?, ?)
                ON CONFLICT(endpoint_id) DO UPDATE SET invite_id = excluded.invite_id
                """,
                (canonical, invite_id, now_iso()),
            )
        return True

    def relay_access_allowed(self, endpoint_id: str) -> bool:
        """Whether this endpoint may use the self-hosted relay.

        A paused or withdrawn invitation loses relay access with it, so the
        existing enable/disable control keeps working for the share feature
        without a second switch.
        """
        canonical = self.normalize_endpoint_id(endpoint_id)
        if canonical is None:
            return False
        with self.connect() as db:
            row = db.execute(
                """
                SELECT invites.enabled AS enabled
                FROM endpoint_enrollment
                JOIN invites ON invites.id = endpoint_enrollment.invite_id
                WHERE endpoint_enrollment.endpoint_id = ?
                """,
                (canonical,),
            ).fetchone()
            if row is None or not row["enabled"]:
                return False
            db.execute(
                "UPDATE endpoint_enrollment SET last_seen_at = ? WHERE endpoint_id = ?",
                (now_iso(), canonical),
            )
        return True

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

    def record_usage_entries(self, entries: list[dict]) -> dict:
        """Stores billed usage keyed by Soniox's uuid and attributes each
        entry to the reservation whose key carried the reference id. Entries
        outside this service's prefix are kept unattributed so the admin page
        can show what the account spent beyond invites."""
        stored = 0
        attributed = 0
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            for entry in entries:
                uuid = str(entry.get("uuid", "")).strip()
                if not uuid:
                    continue
                reference = entry.get("client_reference_id") or ""
                session_id = None
                if reference.startswith(USAGE_REFERENCE_PREFIX):
                    candidate = reference[len(USAGE_REFERENCE_PREFIX):]
                    known = db.execute(
                        "SELECT id FROM sessions WHERE id = ?", (candidate,)
                    ).fetchone()
                    if known is not None:
                        session_id = candidate
                cursor = db.execute(
                    """
                    INSERT OR IGNORE INTO usage_entries
                        (uuid, client_reference_id, session_id, model,
                         start_time, end_time, audio_ms, cost_usd, recorded_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        uuid,
                        reference or None,
                        session_id,
                        entry.get("model"),
                        entry.get("start_time"),
                        entry.get("end_time"),
                        int(entry.get("input_audio_duration_ms") or 0),
                        float(entry.get("cost_usd") or 0.0),
                        now_iso(),
                    ),
                )
                if cursor.rowcount:
                    stored += 1
                    if session_id is not None:
                        attributed += 1
        return {
            "seen": len(entries),
            "stored": stored,
            "attributed": attributed,
        }

    def usage_totals(self) -> dict:
        """Billed totals per invite, plus whatever this account spent that no
        invite reservation can account for."""
        with self.connect() as db:
            per_invite = {
                row["invite_id"]: dict(row)
                for row in db.execute(
                    """
                    SELECT sessions.invite_id AS invite_id,
                        SUM(usage_entries.audio_ms) AS audio_ms,
                        SUM(usage_entries.cost_usd) AS cost_usd,
                        COUNT(*) AS entries
                    FROM usage_entries
                    JOIN sessions ON sessions.id = usage_entries.session_id
                    GROUP BY sessions.invite_id
                    """
                )
            }
            unattributed = db.execute(
                """
                SELECT COUNT(*) AS entries,
                    COALESCE(SUM(cost_usd), 0) AS cost_usd,
                    COALESCE(SUM(audio_ms), 0) AS audio_ms
                FROM usage_entries WHERE session_id IS NULL
                """
            ).fetchone()
            return {
                "per_invite": per_invite,
                "unattributed": dict(unattributed),
            }

    def _audit(self, db, invite_id: int, action: str, detail: str) -> None:
        db.execute(
            "INSERT INTO invite_audit (invite_id, action, detail, created_at)"
            " VALUES (?, ?, ?, ?)",
            (invite_id, action, detail, now_iso()),
        )

    def set_invite_note(self, invite_id: int, note: str) -> bool:
        with self.connect() as db:
            cursor = db.execute(
                "UPDATE invites SET note = ? WHERE id = ?", (note[:200], invite_id)
            )
            return cursor.rowcount > 0

    def adjust_invite_quota(self, invite_id: int, delta_seconds: int) -> int | None:
        """Grants or withdraws time. Quota can never fall below what has
        already been spent or is currently held, so withdrawing more than the
        unspent remainder settles at that floor instead of creating an
        invitation that owes time it cannot give back."""
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            invite = db.execute(
                "SELECT * FROM invites WHERE id = ?", (invite_id,)
            ).fetchone()
            if invite is None:
                return None
            floor = invite["used_seconds"] + invite["reserved_seconds"]
            updated = max(floor, invite["quota_seconds"] + delta_seconds)
            db.execute(
                "UPDATE invites SET quota_seconds = ? WHERE id = ?",
                (updated, invite_id),
            )
            self._audit(
                db,
                invite_id,
                "quota",
                f"{invite['quota_seconds']}->{updated} (requested {delta_seconds:+d})",
            )
            return updated

    def set_invite_enabled(self, invite_id: int, enabled: bool) -> bool:
        """Pausing takes effect on the next authorized request: the token
        lookup already filters on enabled, so no new session or key can be
        obtained. A capture already streaming keeps its issued keys until it
        reconnects."""
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            cursor = db.execute(
                "UPDATE invites SET enabled = ? WHERE id = ?",
                (1 if enabled else 0, invite_id),
            )
            if cursor.rowcount == 0:
                return False
            self._audit(
                db, invite_id, "enabled", "resumed" if enabled else "paused"
            )
            return True

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
                     WHERE sessions.invite_id = invites.id) AS keys_issued,
                    (SELECT MAX(created_at) FROM sessions
                     WHERE sessions.invite_id = invites.id) AS last_session_at
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


ADMIN_STYLE = """
body{font:14px/1.5 system-ui;margin:2rem;color:#222}
h1{font-size:1.4rem} h2{font-size:1rem;margin:0 0 .6rem}
table{border-collapse:collapse;width:100%;margin-top:1.2rem}
td,th{border:1px solid #d8d8d8;padding:.35rem .5rem;text-align:right;
white-space:nowrap}
td:first-child,th:first-child,td:nth-child(2),th:nth-child(2){text-align:left}
thead th{background:#f4f4f4} tfoot th{background:#fafafa}
tr.paused td{opacity:.5;background:#fbfbfb}
form.inline{display:inline-flex;gap:.3rem;align-items:center;margin:0}
form.inline input[type=number]{width:5rem} input{padding:.2rem .3rem;
border:1px solid #ccc;border-radius:3px;font:inherit}
button{padding:.2rem .55rem;border:1px solid #bbb;border-radius:3px;
background:#fff;font:inherit;cursor:pointer}
button.danger{border-color:#c0392b;color:#c0392b}
button.go{border-color:#1e8449;color:#1e8449}
section.create{margin-top:1.4rem;padding:1rem;border:1px solid #ddd;
border-radius:6px;background:#fafafa}
section.create label{margin-right:.8rem}
.issued{margin:1rem 0;padding:1rem;border:2px solid #1e8449;border-radius:6px}
.issued code{display:block;font-size:1.3rem;margin:.5rem 0;
letter-spacing:.05em;user-select:all}
.notice{padding:.5rem .8rem;background:#eef6ff;border-radius:4px}
.warn{color:#c0392b} .dim{color:#777} .strong{font-weight:600}
"""


def admin_document(body: str) -> str:
    return (
        "<!doctype html><html lang='en'><meta charset='utf-8'>"
        "<meta name='viewport' content='width=device-width,initial-scale=1'>"
        "<meta name='robots' content='noindex,nofollow'>"
        "<title>Zulangue invites</title>"
        f"<style>{ADMIN_STYLE}</style><body>{body}</body></html>"
    )


def fetch_usage_logs(
    master_key: str, start_time: str, end_time: str
) -> list[dict]:
    """Pages through Soniox usage logs for a window. Raises on transport or
    HTTP failure so a reconcile run fails loudly instead of silently
    recording a partial window as if it were complete."""
    entries: list[dict] = []
    cursor: str | None = None
    while True:
        params = {
            "start_time": start_time,
            "end_time": end_time,
            "limit": str(USAGE_PAGE_LIMIT),
            "sort": "end_time_asc",
        }
        if cursor:
            params["cursor"] = cursor
        request = urllib.request.Request(
            "https://api.soniox.com/v1/usage-logs?" + urllib.parse.urlencode(params),
            method="GET",
            headers={"Authorization": f"Bearer {master_key}"},
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.load(response)
        page = payload.get("entries") or payload.get("usage_logs") or []
        entries.extend(page)
        cursor = payload.get("next_page_cursor") or payload.get("cursor")
        if not cursor or not page:
            return entries


def reconcile_usage(store: Store, master_key: str, hours: int) -> dict:
    """Pulls the trailing window of billed usage and records it. Idempotent:
    entries already stored under their Soniox uuid are ignored, so overlapping
    windows are safe and a cron can simply re-run it."""
    window = min(max(1, hours), USAGE_MAX_WINDOW_DAYS * 24)
    end = datetime.now(timezone.utc)
    start = end - timedelta(hours=window)
    entries = fetch_usage_logs(
        master_key,
        start.strftime("%Y-%m-%dT%H:%M:%SZ"),
        end.strftime("%Y-%m-%dT%H:%M:%SZ"),
    )
    result = store.record_usage_entries(entries)
    result["window_hours"] = window
    return result


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

    # --- admin panel -----------------------------------------------------
    #
    # Reading the panel was safe with a token in the query string. Granting
    # quota, pausing an invitation, and minting codes are not: a URL carrying
    # the admin token ends up in browser history, bookmarks, and referrers.
    # The token is therefore exchanged once for a session cookie, and every
    # mutation carries a CSRF token bound to that session.

    def admin_token(self) -> str:
        return os.environ.get("ZULANGUE_ADMIN_TOKEN", "")

    def admin_session(self) -> str | None:
        """Returns the caller's live admin session id, or None."""
        cookie = self.headers.get("Cookie", "")
        for part in cookie.split(";"):
            name, _, value = part.strip().partition("=")
            if name == ADMIN_COOKIE_NAME and value:
                sessions = self.server.admin_sessions  # type: ignore[attr-defined]
                expires = sessions.get(value)
                if expires is None:
                    return None
                if expires < datetime.now(timezone.utc):
                    sessions.pop(value, None)
                    return None
                return value
        return None

    def login_client_key(self) -> str:
        """Identifies the caller for rate limiting. Behind the TLS terminator
        every peer is loopback, so the forwarded address is used when present.
        A client can forge that header, which is why the counter below also
        keeps a global bucket that no amount of forging can sidestep."""
        forwarded = self.headers.get("X-Forwarded-For", "")
        if forwarded:
            return forwarded.split(",")[0].strip()[:64]
        return self.client_address[0]

    def login_lockout_seconds(self) -> int:
        failures = self.server.admin_login_failures  # type: ignore[attr-defined]
        now = datetime.now(timezone.utc)
        longest = 0
        limits = (
            (self.login_client_key(), ADMIN_LOGIN_MAX_FAILURES),
            ("*", ADMIN_LOGIN_MAX_FAILURES_GLOBAL),
        )
        for key, limit in limits:
            attempts = [
                at
                for at in failures.get(key, [])
                if (now - at).total_seconds() < ADMIN_LOGIN_WINDOW_SECONDS
            ]
            failures[key] = attempts
            if len(attempts) >= limit:
                elapsed = (now - attempts[-1]).total_seconds()
                longest = max(longest, int(ADMIN_LOGIN_LOCKOUT_SECONDS - elapsed))
        return max(0, longest)

    def record_login_failure(self) -> None:
        failures = self.server.admin_login_failures  # type: ignore[attr-defined]
        now = datetime.now(timezone.utc)
        for key in (self.login_client_key(), "*"):
            failures.setdefault(key, []).append(now)

    def clear_login_failures(self) -> None:
        failures = self.server.admin_login_failures  # type: ignore[attr-defined]
        failures.pop(self.login_client_key(), None)
        failures.pop("*", None)

    def csrf_token(self, session: str) -> str:
        return hmac.new(session.encode(), b"csrf", hashlib.sha256).hexdigest()

    def render_admin(self, parsed: urllib.parse.SplitResult) -> None:
        if not self.admin_token():
            # Without a configured token the page does not exist at all.
            self.send_json(404, {"error": "not_found"})
            return
        session = self.admin_session()
        if session is None:
            self.send_admin_login()
            return
        query = urllib.parse.parse_qs(parsed.query)
        self.send_admin_page(
            session,
            issued_code=(query.get("code") or [""])[0],
            notice=(query.get("notice") or [""])[0],
        )

    def send_admin_login(self, message: str = "") -> None:
        body = (
            "<h1>Zulangue invites</h1>"
            + (f"<p class='warn'>{html.escape(message)}</p>" if message else "")
            + "<form method='post' action='/admin/login'>"
            "<label>Admin token<br><input type='password' name='token' "
            "autofocus autocomplete='current-password'></label> "
            "<button type='submit'>Sign in</button></form>"
        )
        self.send_html(200, admin_document(body))

    def send_admin_page(
        self, session: str, issued_code: str = "", notice: str = ""
    ) -> None:
        self.store.expire_stale_reservations()
        usage = self.store.usage_totals()
        csrf = self.csrf_token(session)
        rows = []
        totals = {"used": 0, "reserved": 0, "billed": 0.0}

        for invite in self.store.admin_overview():
            invite_id = invite["id"]
            used_hours = invite["used_seconds"] / 3600
            billed = usage["per_invite"].get(invite_id, {})
            billed_cost = float(billed.get("cost_usd") or 0.0)
            totals["used"] += invite["used_seconds"]
            totals["reserved"] += invite["reserved_seconds"]
            totals["billed"] += billed_cost
            remaining = max(
                0,
                invite["quota_seconds"]
                - invite["used_seconds"]
                - invite["reserved_seconds"],
            )
            enabled = bool(invite["enabled"])
            last_seen = (invite["last_session_at"] or "")[:16].replace("T", " ")
            hidden = (
                f"<input type='hidden' name='csrf' value='{csrf}'>"
                f"<input type='hidden' name='invite_id' value='{invite_id}'>"
            )
            rows.append(
                "<tr class='" + ("" if enabled else "paused") + "'>"
                f"<td>{html.escape(invite['label'])}</td>"
                "<td><form method='post' action='/admin/note' class='inline'>"
                f"{hidden}"
                f"<input name='note' value='{html.escape(invite['note'] or '')}' "
                "placeholder='who is this for'>"
                "<button type='submit'>Save</button></form></td>"
                f"<td>{invite['quota_seconds'] / 3600:.1f}</td>"
                f"<td>{used_hours:.2f}</td>"
                f"<td>{invite['reserved_seconds'] / 3600:.2f}</td>"
                f"<td class='strong'>{remaining / 3600:.2f}</td>"
                f"<td>{invite['open_sessions']}/{invite['total_sessions']}</td>"
                f"<td>{invite['keys_issued']}</td>"
                f"<td>${billed_cost:.2f}</td>"
                f"<td class='dim'>{html.escape(last_seen) or '—'}</td>"
                "<td><form method='post' action='/admin/quota' class='inline'>"
                f"{hidden}"
                "<input name='hours' type='number' step='0.5' value='6' "
                "aria-label='hours'>"
                "<button type='submit' name='direction' value='add'>+</button>"
                "<button type='submit' name='direction' value='remove'>−</button>"
                "</form></td>"
                "<td><form method='post' action='/admin/enabled' class='inline'>"
                f"{hidden}"
                f"<input type='hidden' name='enabled' value='{0 if enabled else 1}'>"
                f"<button type='submit' class='{'danger' if enabled else 'go'}'>"
                f"{'Pause' if enabled else 'Resume'}</button>"
                "</form></td>"
                "</tr>"
            )

        banner = ""
        if issued_code:
            banner = (
                "<div class='issued'><strong>New invitation code</strong>"
                f"<code>{html.escape(issued_code)}</code>"
                "<p>Copy it now. Only its hash is stored, so this code cannot "
                "be shown again.</p></div>"
            )
        elif notice:
            banner = f"<p class='notice'>{html.escape(notice)}</p>"

        unattributed = usage["unattributed"]
        body = (
            "<h1>Zulangue invites</h1>"
            + banner
            + "<section class='create'><h2>Generate an invitation</h2>"
            "<form method='post' action='/admin/create' class='inline'>"
            f"<input type='hidden' name='csrf' value='{csrf}'>"
            "<label>Label <input name='label' required placeholder='partner-name'>"
            "</label>"
            "<label>Note <input name='note' placeholder='who is this for'></label>"
            f"<label>Gives <input name='gives' type='number' min='1' value='{DEFAULT_GIVES}'>"
            "</label>"
            "<button type='submit'>Generate</button></form>"
            f"<p class='dim'>One Give is {SECONDS_PER_GIVE // 3600} hours of "
            "lane time.</p></section>"
            "<table><thead><tr>"
            "<th>Label</th><th>Note</th><th>Quota h</th><th>Used lane-h</th>"
            "<th>Reserved</th><th>Remaining h</th><th>Sessions</th>"
            "<th>Keys</th><th>Billed</th><th>Last used</th>"
            "<th>Adjust hours</th><th>Access</th>"
            "</tr></thead><tbody>"
            + ("".join(rows) or "<tr><td colspan='12'>No invitations yet.</td></tr>")
            + "</tbody><tfoot><tr>"
            "<th>Total</th><th></th><th></th>"
            f"<th>{totals['used'] / 3600:.2f}</th>"
            f"<th>{totals['reserved'] / 3600:.2f}</th>"
            "<th></th><th></th><th></th>"
            f"<th>${totals['billed']:.2f}</th><th></th><th></th><th></th>"
            "</tr></tfoot></table>"
            "<p class='dim'>Used lane-hours are what clients reported at settle "
            "time; Billed is what Soniox charged, recorded by "
            "<code>server.py reconcile</code>. Usage this account cannot "
            f"attribute to any invitation: {int(unattributed['entries'])} entries, "
            f"${float(unattributed['cost_usd']):.2f}.</p>"
        )
        self.send_html(200, admin_document(body))

    def handle_admin_post(self, path: str) -> None:
        if not self.admin_token():
            self.send_json(404, {"error": "not_found"})
            return
        form = self.read_form()

        if path == "/admin/login":
            blocked_for = self.login_lockout_seconds()
            if blocked_for > 0:
                self.send_admin_login(
                    f"Too many failed attempts. Try again in "
                    f"{blocked_for // 60 + 1} minutes."
                )
                return
            if not secret_equals(form.get("token", ""), self.admin_token()):
                self.record_login_failure()
                self.send_admin_login("That token was not accepted.")
                return
            self.clear_login_failures()
            session = secrets.token_urlsafe(32)
            sessions = self.server.admin_sessions  # type: ignore[attr-defined]
            sessions[session] = datetime.now(timezone.utc) + timedelta(
                seconds=ADMIN_SESSION_TTL_SECONDS
            )
            self.send_response(303)
            self.send_header("Location", "/admin")
            # SameSite=Strict keeps another site from driving these forms, and
            # HttpOnly keeps the session out of page scripts.
            self.send_header(
                "Set-Cookie",
                f"{ADMIN_COOKIE_NAME}={session}; HttpOnly; SameSite=Strict; "
                f"Path=/admin; Max-Age={ADMIN_SESSION_TTL_SECONDS}",
            )
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        session = self.admin_session()
        if session is None:
            self.send_admin_login("Your session expired.")
            return
        if not secret_equals(form.get("csrf", ""), self.csrf_token(session)):
            self.send_admin_login("That form was stale. Sign in and try again.")
            return

        if path == "/admin/create":
            gives = max(1, int(form.get("gives") or DEFAULT_GIVES))
            code = self.store.create_invite(
                form.get("label", "").strip() or "partner", gives * SECONDS_PER_GIVE
            )
            invite = self.store.invite_by_code(code)
            note = form.get("note", "").strip()
            if invite is not None and note:
                self.store.set_invite_note(invite["id"], note)
            self.redirect_admin(code=code)
            return

        invite_id = int(form.get("invite_id") or 0)
        if path == "/admin/note":
            self.store.set_invite_note(invite_id, form.get("note", "").strip())
            self.redirect_admin(notice="Note saved.")
            return
        if path == "/admin/quota":
            hours = float(form.get("hours") or 0)
            sign = -1 if form.get("direction") == "remove" else 1
            updated = self.store.adjust_invite_quota(
                invite_id, sign * int(hours * 3600)
            )
            if updated is None:
                self.redirect_admin(notice="That invitation no longer exists.")
            else:
                self.redirect_admin(notice=f"Quota is now {updated / 3600:.1f} h.")
            return
        if path == "/admin/enabled":
            enabled = form.get("enabled") == "1"
            self.store.set_invite_enabled(invite_id, enabled)
            self.redirect_admin(
                notice="Access resumed." if enabled else "Access paused."
            )
            return

        self.send_json(404, {"error": "not_found"})

    def redirect_admin(self, code: str = "", notice: str = "") -> None:
        query = {}
        if code:
            query["code"] = code
        if notice:
            query["notice"] = notice
        target = "/admin"
        if query:
            target += "?" + urllib.parse.urlencode(query)
        self.send_response(303)
        self.send_header("Location", target)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def read_form(self) -> dict:
        length = min(int(self.headers.get("Content-Length", "0")), 16_384)
        raw = self.rfile.read(length).decode("utf-8", "replace")
        return {
            key: values[0]
            for key, values in urllib.parse.parse_qs(raw, keep_blank_values=True).items()
        }

    def send_html(self, status: int, page: str) -> None:
        body = page.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:
        if self.path.startswith("/admin"):
            self.handle_admin_post(urllib.parse.urlsplit(self.path).path)
            return
        if self.path == "/v1/relay-auth":
            # relay 自己调用这个端点,它不带邀请码,只带 endpoint id。
            # 服务间凭据走 IROH_RELAY_HTTP_BEARER_TOKEN,不落配置文件。
            expected = os.environ.get("ZULANGUE_RELAY_AUTH_TOKEN", "")
            presented = self.headers.get("Authorization", "").removeprefix("Bearer ").strip()
            if not expected or not hmac.compare_digest(presented, expected):
                self.send_json(401, {"error": "unauthorized"})
                return
            # 两个名字都收。
            #
            # iroh-relay 1.0.3 的文档说这个头是 `X-Iroh-Endpoint-Id`,但源码里
            # 那个常量的**值**是 `X-Iroh-NodeId` —— 1.0 把 NodeId 改名成
            # EndpointId 时头名字没跟着改。只认文档里那个名字,线上会把所有人
            # 都拒掉,而两边日志都显示一切正常(服务返回 200,中继只说正文不是
            # "true")。上游哪天修了,这里也不用再动。
            endpoint_id = self.headers.get("X-Iroh-NodeId") or self.headers.get(
                "X-Iroh-Endpoint-Id", ""
            )
            allowed = self.store.relay_access_allowed(endpoint_id)
            # relay 只认「200 且正文为 true」,其余一律视为拒绝。
            body = b"true" if allowed else b"false"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/v1/relay-stats":
            # 中继上报,凭据与门禁同一把。
            expected = os.environ.get("ZULANGUE_RELAY_AUTH_TOKEN", "")
            presented = self.headers.get("Authorization", "").removeprefix("Bearer ").strip()
            if not expected or not hmac.compare_digest(presented, expected):
                self.send_json(401, {"error": "unauthorized"})
                return
            body = self.read_json()
            ok = self.store.record_relay_stats(
                str(body.get("day", "")),
                body.get("deltas") or {},
                body.get("unique_clients", 0),
            )
            self.send_json(200 if ok else 400, {"status": "recorded"} if ok else {"error": "invalid_report"})
            return

        if self.path == "/v1/share-endpoint":
            # App 用邀请码把自己的 endpoint id 登记上来。
            invite = self.authorized_invite()
            if invite is None:
                return
            body = self.read_json()
            if not self.store.enroll_endpoint(invite["id"], str(body.get("endpoint_id", ""))):
                self.send_json(400, {"error": "invalid_endpoint_id"})
                return
            self.send_json(200, {"status": "enrolled"})
            return

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
    reconcile = sub.add_parser("reconcile")
    reconcile.add_argument("--hours", type=int, default=24)
    args = parser.parse_args()

    store = Store(Path(args.db))
    if args.command == "create-invite":
        print(store.create_invite(args.label, args.gives * SECONDS_PER_GIVE))
        return
    if args.command == "reconcile":
        master_key = os.environ.get("SONIOX_API_KEY", "")
        if not master_key:
            print("SONIOX_API_KEY is not set", file=sys.stderr)
            raise SystemExit(1)
        print(json.dumps(reconcile_usage(store, master_key, args.hours)))
        return
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.store = store  # type: ignore[attr-defined]
    # Admin sessions live in memory only: a restart signs the operator out,
    # which is the right default for a panel that can grant quota.
    server.admin_sessions = {}  # type: ignore[attr-defined]
    server.admin_login_failures = {}  # type: ignore[attr-defined]
    server.serve_forever()


if __name__ == "__main__":
    main()
