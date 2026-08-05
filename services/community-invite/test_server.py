import tempfile
import threading
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from server import (
    USAGE_REFERENCE_PREFIX,
    DEFAULT_GIVES,
    DEFAULT_QUOTA_SECONDS,
    MAX_LANES_PER_SESSION,
    RESERVATION_TTL_SECONDS,
    SESSION_KEY_BUDGET,
    Store,
    secret_equals,
    stream_duration_seconds,
)


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.tmp.name) / "invites.db")

    def tearDown(self):
        self.tmp.cleanup()

    def test_invite_grants_thirty_hours(self):
        code = self.store.create_invite("partner", DEFAULT_QUOTA_SECONDS)
        redeemed = self.store.redeem(code)
        self.assertIsNotNone(redeemed)
        self.assertEqual(redeemed["remaining_seconds"], 30 * 60 * 60)
        self.assertEqual(redeemed["remaining_gives"], DEFAULT_GIVES)

    def test_all_modes_share_audio_time_quota(self):
        code = self.store.create_invite("partner", DEFAULT_QUOTA_SECONDS)
        token = self.store.redeem(code)["access_token"]
        invite = self.store.invite_for_token(token)
        session = self.store.reserve_session(invite["id"], 3600)
        quota = self.store.settle_session(invite["id"], session["session_id"], 900)
        self.assertEqual(quota["used_seconds"], 900)
        self.assertEqual(quota["remaining_seconds"], DEFAULT_QUOTA_SECONDS - 900)

    def test_concurrent_reservations_cannot_exceed_quota(self):
        code = self.store.create_invite("small", 10)
        token = self.store.redeem(code)["access_token"]
        invite = self.store.invite_for_token(token)
        first = self.store.reserve_session(invite["id"], 8)
        second = self.store.reserve_session(invite["id"], 8)
        self.assertEqual(first["reserved_seconds"], 8)
        self.assertEqual(second["reserved_seconds"], 2)
        self.assertIsNone(self.store.reserve_session(invite["id"], 1))

    def test_stale_reservation_is_released_after_ttl(self):
        code = self.store.create_invite("partner", DEFAULT_QUOTA_SECONDS)
        token = self.store.redeem(code)["access_token"]
        invite = self.store.invite_for_token(token)
        session = self.store.reserve_session(invite["id"], 3600)

        stale_created_at = (
            datetime.now(timezone.utc)
            - timedelta(seconds=RESERVATION_TTL_SECONDS + 60)
        ).isoformat()
        with self.store.connect() as db:
            db.execute(
                "UPDATE sessions SET created_at = ? WHERE id = ?",
                (stale_created_at, session["session_id"]),
            )

        # Any authorized request (token lookup) releases stale reservations.
        refreshed = self.store.invite_for_token(token)
        self.assertEqual(refreshed["reserved_seconds"], 0)
        self.assertEqual(refreshed["used_seconds"], 0)
        # A late settle of the expired session no longer double-charges.
        self.assertIsNone(
            self.store.settle_session(invite["id"], session["session_id"], 900)
        )

    def test_fresh_reservation_survives_expiry_sweep(self):
        code = self.store.create_invite("partner", DEFAULT_QUOTA_SECONDS)
        token = self.store.redeem(code)["access_token"]
        invite = self.store.invite_for_token(token)
        session = self.store.reserve_session(invite["id"], 3600)
        refreshed = self.store.invite_for_token(token)
        self.assertEqual(refreshed["reserved_seconds"], 3600)
        quota = self.store.settle_session(invite["id"], session["session_id"], 900)
        self.assertEqual(quota["used_seconds"], 900)

    def test_key_renewal_targets_only_open_sessions_without_new_charges(self):
        code = self.store.create_invite("partner", DEFAULT_QUOTA_SECONDS)
        token = self.store.redeem(code)["access_token"]
        invite = self.store.invite_for_token(token)
        session = self.store.reserve_session(invite["id"], 3600)

        open_session = self.store.open_session(invite["id"], session["session_id"])
        self.assertIsNotNone(open_session)
        self.assertEqual(open_session["reserved_seconds"], 3600)

        # Renewal lookups never touch quota accounting.
        refreshed = self.store.invite_for_token(token)
        self.assertEqual(refreshed["reserved_seconds"], 3600)
        self.assertEqual(refreshed["used_seconds"], 0)

        # Another invite's session and unknown ids are invisible.
        other_code = self.store.create_invite("other", DEFAULT_QUOTA_SECONDS)
        other_token = self.store.redeem(other_code)["access_token"]
        other = self.store.invite_for_token(other_token)
        self.assertIsNone(self.store.open_session(other["id"], session["session_id"]))
        self.assertIsNone(self.store.open_session(invite["id"], "missing"))

        # Settled sessions can no longer mint keys.
        self.store.settle_session(invite["id"], session["session_id"], 900)
        self.assertIsNone(self.store.open_session(invite["id"], session["session_id"]))

    def test_open_session_count_tracks_only_unsettled_sessions(self):
        code = self.store.create_invite("partner", DEFAULT_QUOTA_SECONDS)
        token = self.store.redeem(code)["access_token"]
        invite = self.store.invite_for_token(token)
        first = self.store.reserve_session(invite["id"], 3600)
        self.store.reserve_session(invite["id"], 3600)
        self.assertEqual(self.store.count_open_sessions(invite["id"]), 2)
        self.store.settle_session(invite["id"], first["session_id"], 60)
        self.assertEqual(self.store.count_open_sessions(invite["id"]), 1)

    def test_session_key_budget_is_finite_and_scoped_to_open_sessions(self):
        code = self.store.create_invite("partner", DEFAULT_QUOTA_SECONDS)
        token = self.store.redeem(code)["access_token"]
        invite = self.store.invite_for_token(token)
        session = self.store.reserve_session(invite["id"], 3600)

        for expected in range(1, SESSION_KEY_BUDGET + 1):
            self.assertEqual(
                self.store.issue_session_key(invite["id"], session["session_id"]),
                expected,
            )
        # The budget is a hard stop: a leaked token cannot mint keys forever.
        self.assertIsNone(
            self.store.issue_session_key(invite["id"], session["session_id"])
        )

        # Settled and foreign sessions issue nothing at all.
        other = self.store.reserve_session(invite["id"], 3600)
        self.store.settle_session(invite["id"], other["session_id"], 0)
        self.assertIsNone(
            self.store.issue_session_key(invite["id"], other["session_id"])
        )
        self.assertIsNone(self.store.issue_session_key(invite["id"], "missing"))

    def test_session_key_headroom_shrinks_per_issue_and_gates_batches(self):
        code = self.store.create_invite("partner", DEFAULT_QUOTA_SECONDS)
        token = self.store.redeem(code)["access_token"]
        invite = self.store.invite_for_token(token)
        session = self.store.reserve_session(invite["id"], 3600)

        self.assertEqual(
            self.store.session_key_headroom(invite["id"], session["session_id"]),
            SESSION_KEY_BUDGET,
        )
        # A full 8-lane batch fits, and so does one complete retry of it.
        for _ in range(8):
            self.store.issue_session_key(invite["id"], session["session_id"])
        self.assertEqual(
            self.store.session_key_headroom(invite["id"], session["session_id"]),
            SESSION_KEY_BUDGET - 8,
        )
        self.assertIsNone(self.store.session_key_headroom(invite["id"], "missing"))
        self.store.settle_session(invite["id"], session["session_id"], 0)
        self.assertIsNone(
            self.store.session_key_headroom(invite["id"], session["session_id"])
        )

    def test_admin_overview_aggregates_sessions_and_keys_per_invite(self):
        code = self.store.create_invite("partner", DEFAULT_QUOTA_SECONDS)
        token = self.store.redeem(code)["access_token"]
        invite = self.store.invite_for_token(token)
        session = self.store.reserve_session(invite["id"], 3600)
        self.store.issue_session_key(invite["id"], session["session_id"])
        self.store.issue_session_key(invite["id"], session["session_id"])
        self.store.settle_session(invite["id"], session["session_id"], 900)
        self.store.reserve_session(invite["id"], 3600)

        overview = self.store.admin_overview()
        self.assertEqual(len(overview), 1)
        row = overview[0]
        self.assertEqual(row["label"], "partner")
        self.assertEqual(row["used_seconds"], 900)
        self.assertEqual(row["open_sessions"], 1)
        self.assertEqual(row["total_sessions"], 2)
        self.assertEqual(row["keys_issued"], 2)

    def test_batch_key_claim_is_all_or_nothing(self):
        code = self.store.create_invite("partner", DEFAULT_QUOTA_SECONDS)
        token = self.store.redeem(code)["access_token"]
        invite = self.store.invite_for_token(token)
        session = self.store.reserve_session(invite["id"], 3600)
        sid = session["session_id"]

        self.assertEqual(self.store.reserve_session_keys(invite["id"], sid, 4), 4)
        # Leave room for exactly three more.
        self.store.reserve_session_keys(invite["id"], sid, SESSION_KEY_BUDGET - 7)
        self.assertEqual(
            self.store.session_key_headroom(invite["id"], sid), 3
        )
        # A batch that does not fit claims nothing at all, rather than
        # handing back a short batch the client cannot open every lane with.
        self.assertIsNone(self.store.reserve_session_keys(invite["id"], sid, 4))
        self.assertEqual(self.store.session_key_headroom(invite["id"], sid), 3)
        self.assertEqual(
            self.store.reserve_session_keys(invite["id"], sid, 3),
            SESSION_KEY_BUDGET,
        )
        self.assertIsNone(self.store.reserve_session_keys(invite["id"], sid, 1))

    def test_concurrent_batches_cannot_exceed_the_key_budget(self):
        code = self.store.create_invite("partner", DEFAULT_QUOTA_SECONDS)
        token = self.store.redeem(code)["access_token"]
        invite = self.store.invite_for_token(token)
        session = self.store.reserve_session(invite["id"], 3600)
        sid = session["session_id"]
        # Only one full four-lane batch still fits.
        self.store.reserve_session_keys(invite["id"], sid, SESSION_KEY_BUDGET - 4)

        granted: list[int | None] = []
        lock = threading.Lock()
        barrier = threading.Barrier(4)

        def claim():
            barrier.wait()
            result = self.store.reserve_session_keys(invite["id"], sid, 4)
            with lock:
                granted.append(result)

        threads = [threading.Thread(target=claim) for _ in range(4)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()

        # Exactly one batch wins; the budget is the stream-count lever, so a
        # race must not mint keys it never covered.
        self.assertEqual(len(granted), 4, "every claim must return a verdict")
        self.assertEqual(len([g for g in granted if g is not None]), 1)
        self.assertEqual(self.store.session_key_headroom(invite["id"], sid), 0)

    def test_released_key_slots_return_to_the_budget(self):
        code = self.store.create_invite("partner", DEFAULT_QUOTA_SECONDS)
        token = self.store.redeem(code)["access_token"]
        invite = self.store.invite_for_token(token)
        session = self.store.reserve_session(invite["id"], 3600)
        sid = session["session_id"]

        self.store.reserve_session_keys(invite["id"], sid, 4)
        self.assertEqual(
            self.store.session_key_headroom(invite["id"], sid),
            SESSION_KEY_BUDGET - 4,
        )
        # An upstream failure delivers nothing, so the whole claim comes back.
        self.store.release_session_keys(sid, 4)
        self.assertEqual(
            self.store.session_key_headroom(invite["id"], sid), SESSION_KEY_BUDGET
        )

    def test_stream_duration_divides_lane_seconds_back_to_wall_clock(self):
        code = self.store.create_invite("partner", DEFAULT_QUOTA_SECONDS)
        token = self.store.redeem(code)["access_token"]
        invite = self.store.invite_for_token(token)

        # Three target languages open one canonical lane plus three
        # translation lanes, and the reservation is counted per lane.
        four_lane = self.store.reserve_session(invite["id"], 18_000, 4)
        self.assertEqual(four_lane["lane_count"], 4)
        # Each Soniox stream may run the wall-clock time the quota buys,
        # not the whole lane-second reservation.
        self.assertEqual(stream_duration_seconds(four_lane), 4_500)

        single = self.store.reserve_session(invite["id"], 3_600, 1)
        self.assertEqual(stream_duration_seconds(single), 3_600)

        # Lane counts beyond the capture ceiling cannot stretch the bound.
        clamped = self.store.reserve_session(invite["id"], 3_600, 99)
        self.assertEqual(clamped["lane_count"], MAX_LANES_PER_SESSION)
        self.assertEqual(stream_duration_seconds(clamped), 900)

    def test_open_session_carries_its_lane_count(self):
        code = self.store.create_invite("partner", DEFAULT_QUOTA_SECONDS)
        token = self.store.redeem(code)["access_token"]
        invite = self.store.invite_for_token(token)
        session = self.store.reserve_session(invite["id"], 18_000, 4)

        # Renewals and per-connection keys re-derive the same bound.
        reopened = self.store.open_session(invite["id"], session["session_id"])
        self.assertEqual(reopened["lane_count"], 4)
        self.assertEqual(stream_duration_seconds(reopened), 4_500)


class UsageReconciliationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.tmp.name) / "invites.db")
        code = self.store.create_invite("partner", DEFAULT_QUOTA_SECONDS)
        token = self.store.redeem(code)["access_token"]
        self.invite = self.store.invite_for_token(token)
        self.session = self.store.reserve_session(self.invite["id"], 3600)

    def tearDown(self):
        self.tmp.cleanup()

    def entry(self, uuid: str, reference: str | None, ms: int, cost: float) -> dict:
        return {
            "uuid": uuid,
            "client_reference_id": reference,
            "model": "stt-rt-v5",
            "start_time": "2026-08-05T10:00:00Z",
            "end_time": "2026-08-05T10:30:00Z",
            "input_audio_duration_ms": ms,
            "cost_usd": cost,
        }

    def test_usage_attributes_by_reference_prefix_and_ignores_foreign_traffic(self):
        session_id = self.session["session_id"]
        result = self.store.record_usage_entries(
            [
                self.entry("u1", f"{USAGE_REFERENCE_PREFIX}{session_id}", 1_800_000, 0.06),
                self.entry("u2", f"{USAGE_REFERENCE_PREFIX}{session_id}", 1_800_000, 0.06),
                # The account's own key, and a stale reference for a session
                # this database never issued: both stay unattributed.
                self.entry("u3", None, 3_600_000, 0.12),
                self.entry("u4", f"{USAGE_REFERENCE_PREFIX}gone", 600_000, 0.02),
            ]
        )
        self.assertEqual(result, {"seen": 4, "stored": 4, "attributed": 2})

        totals = self.store.usage_totals()
        billed = totals["per_invite"][self.invite["id"]]
        self.assertEqual(billed["audio_ms"], 3_600_000)
        self.assertAlmostEqual(billed["cost_usd"], 0.12)
        self.assertEqual(totals["unattributed"]["entries"], 2)
        self.assertAlmostEqual(totals["unattributed"]["cost_usd"], 0.14)

    def test_reconciling_an_overlapping_window_never_double_counts(self):
        session_id = self.session["session_id"]
        rows = [self.entry("u1", f"{USAGE_REFERENCE_PREFIX}{session_id}", 1_800_000, 0.06)]
        self.assertEqual(self.store.record_usage_entries(rows)["stored"], 1)
        # A second run over a window that overlaps the first sees the same
        # Soniox uuid and must record nothing new.
        again = self.store.record_usage_entries(
            rows + [self.entry("u2", f"{USAGE_REFERENCE_PREFIX}{session_id}", 600_000, 0.02)]
        )
        self.assertEqual(again, {"seen": 2, "stored": 1, "attributed": 1})
        billed = self.store.usage_totals()["per_invite"][self.invite["id"]]
        self.assertEqual(billed["audio_ms"], 2_400_000)

    def test_billed_usage_survives_settlement_and_exposes_under_reporting(self):
        session_id = self.session["session_id"]
        # The client claims one minute; Soniox billed a full hour.
        self.store.settle_session(self.invite["id"], session_id, 60)
        self.store.record_usage_entries(
            [self.entry("u1", f"{USAGE_REFERENCE_PREFIX}{session_id}", 3_600_000, 0.12)]
        )
        invite = self.store.admin_overview()[0]
        billed = self.store.usage_totals()["per_invite"][invite["id"]]
        self.assertEqual(invite["used_seconds"], 60)
        self.assertEqual(billed["audio_ms"], 3_600_000)


class AdminPanelStoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.tmp.name) / "invites.db")
        self.code = self.store.create_invite("partner", DEFAULT_QUOTA_SECONDS)
        self.invite = self.store.invite_by_code(self.code)

    def tearDown(self):
        self.tmp.cleanup()

    def test_quota_can_be_granted_and_withdrawn(self):
        self.assertEqual(
            self.store.adjust_invite_quota(self.invite["id"], 6 * 3600),
            DEFAULT_QUOTA_SECONDS + 6 * 3600,
        )
        self.assertEqual(
            self.store.adjust_invite_quota(self.invite["id"], -6 * 3600),
            DEFAULT_QUOTA_SECONDS,
        )
        self.assertIsNone(self.store.adjust_invite_quota(9999, 3600))

    def test_quota_never_falls_below_what_is_already_spent_or_held(self):
        token = self.store.redeem(self.code)["access_token"]
        invite = self.store.invite_for_token(token)
        session = self.store.reserve_session(invite["id"], 3600)
        self.store.settle_session(invite["id"], session["session_id"], 1800)
        held = self.store.reserve_session(invite["id"], 3600)

        # Withdrawing everything settles at used + reserved, so an invitation
        # can never owe back time it has already spent or is streaming on.
        floor = 1800 + held["reserved_seconds"]
        self.assertEqual(
            self.store.adjust_invite_quota(invite["id"], -DEFAULT_QUOTA_SECONDS * 2),
            floor,
        )

    def test_pausing_an_invitation_stops_redemption_and_token_lookups(self):
        token = self.store.redeem(self.code)["access_token"]
        self.assertIsNotNone(self.store.invite_for_token(token))

        self.assertTrue(self.store.set_invite_enabled(self.invite["id"], False))
        # Both doors close: an unused code cannot be redeemed, and a token
        # already handed out stops resolving, so no new session or key.
        self.assertIsNone(self.store.redeem(self.code))
        self.assertIsNone(self.store.invite_for_token(token))

        self.store.set_invite_enabled(self.invite["id"], True)
        self.assertIsNotNone(self.store.invite_for_token(token))

    def test_notes_are_stored_and_surfaced_in_the_overview(self):
        self.assertTrue(self.store.set_invite_note(self.invite["id"], "Alice at ACME"))
        self.assertEqual(self.store.admin_overview()[0]["note"], "Alice at ACME")
        self.assertFalse(self.store.set_invite_note(9999, "nobody"))

    def test_quota_and_access_changes_leave_an_audit_trail(self):
        self.store.adjust_invite_quota(self.invite["id"], 3600)
        self.store.set_invite_enabled(self.invite["id"], False)
        with self.store.connect() as db:
            actions = [
                row["action"]
                for row in db.execute(
                    "SELECT action FROM invite_audit WHERE invite_id = ? ORDER BY id",
                    (self.invite["id"],),
                )
            ]
        self.assertEqual(actions, ["quota", "enabled"])
        # Renaming leaves no audit row: it changes nothing an invitation can spend.
        self.store.set_invite_note(self.invite["id"], "renamed")
        with self.store.connect() as db:
            self.assertEqual(
                db.execute("SELECT COUNT(*) AS n FROM invite_audit").fetchone()["n"], 2
            )


class AdminSecretComparisonTests(unittest.TestCase):
    def test_non_ascii_input_fails_the_comparison_instead_of_raising(self):
        # A mistyped token used to crash the request handler outright, which
        # the edge reported to the operator as a 503 outage.
        self.assertFalse(secret_equals("中文密码", "expected-token"))
        self.assertFalse(secret_equals("🔑", "expected-token"))
        self.assertFalse(secret_equals("", "expected-token"))
        self.assertTrue(secret_equals("expected-token", "expected-token"))
        self.assertTrue(secret_equals("中文密码", "中文密码"))


if __name__ == "__main__":
    unittest.main()
