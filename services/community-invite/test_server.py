import tempfile
import threading
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from server import (
    DEFAULT_GIVES,
    DEFAULT_QUOTA_SECONDS,
    MAX_LANES_PER_SESSION,
    RESERVATION_TTL_SECONDS,
    SESSION_KEY_BUDGET,
    Store,
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


if __name__ == "__main__":
    unittest.main()
