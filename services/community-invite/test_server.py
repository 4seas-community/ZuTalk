import io
import json
import os
import pathlib
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

import server
from server import (
    USAGE_REFERENCE_PREFIX,
    DEFAULT_GIVES,
    DEFAULT_QUOTA_SECONDS,
    MAX_LANES_PER_SESSION,
    RESERVATION_TTL_SECONDS,
    session_key_budget,
    KEYS_PER_LANE,
    SESSION_KEY_FLOOR,
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

        for expected in range(1, session_key_budget(1) + 1):
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

    def test_key_budget_scales_with_lanes_and_never_drops_below_the_floor(self):
        """A four-lane capture spends four keys before a word is spoken and
        needs one more per reconnect. A flat per-session budget gave it the
        same allowance as a single socket, and four ordinary blips ended
        translation for the rest of the recording.

        The budget is a ceiling, not an allocation: keys are minted on demand,
        so a capture on a healthy network uses a couple of dozen and the rest
        is headroom that costs nothing."""
        self.assertEqual(session_key_budget(1), max(SESSION_KEY_FLOOR, KEYS_PER_LANE))
        self.assertEqual(
            session_key_budget(MAX_LANES_PER_SESSION),
            KEYS_PER_LANE * MAX_LANES_PER_SESSION,
        )
        self.assertGreater(
            session_key_budget(MAX_LANES_PER_SESSION),
            session_key_budget(1),
            "more lanes must mean more headroom, not the same",
        )
        self.assertGreaterEqual(session_key_budget(1), SESSION_KEY_FLOOR)
        # Out-of-range lane counts are clamped, not trusted.
        self.assertEqual(session_key_budget(0), session_key_budget(1))
        self.assertEqual(session_key_budget(99), session_key_budget(MAX_LANES_PER_SESSION))

    def test_a_four_lane_session_is_issued_its_larger_budget(self):
        code = self.store.create_invite("partner", DEFAULT_QUOTA_SECONDS)
        token = self.store.redeem(code)["access_token"]
        invite = self.store.invite_for_token(token)
        session = self.store.reserve_session(invite["id"], 3600, MAX_LANES_PER_SESSION)

        self.assertEqual(
            self.store.session_key_headroom(invite["id"], session["session_id"]),
            session_key_budget(MAX_LANES_PER_SESSION),
        )
        # The whole budget is claimable, and then it is a hard stop.
        self.assertIsNotNone(
            self.store.reserve_session_keys(
                invite["id"],
                session["session_id"],
                session_key_budget(MAX_LANES_PER_SESSION),
            )
        )
        self.assertIsNone(
            self.store.issue_session_key(invite["id"], session["session_id"])
        )

    def test_open_lane_total_counts_every_invitation(self):
        """Soniox caps concurrent realtime sockets for the whole account, so
        the number that matters is not per invitation."""
        first_code = self.store.create_invite("a", DEFAULT_QUOTA_SECONDS)
        second_code = self.store.create_invite("b", DEFAULT_QUOTA_SECONDS)
        first = self.store.invite_for_token(self.store.redeem(first_code)["access_token"])
        second = self.store.invite_for_token(self.store.redeem(second_code)["access_token"])

        self.assertEqual(self.store.open_lane_total(), 0)
        a = self.store.reserve_session(first["id"], 3600, MAX_LANES_PER_SESSION)
        self.store.reserve_session(second["id"], 3600, 2)
        self.assertEqual(self.store.open_lane_total(), MAX_LANES_PER_SESSION + 2)

        # Settling gives the lanes back.
        self.store.settle_session(first["id"], a["session_id"], 60)
        self.assertEqual(self.store.open_lane_total(), 2)

    def test_session_key_headroom_shrinks_per_issue_and_gates_batches(self):
        code = self.store.create_invite("partner", DEFAULT_QUOTA_SECONDS)
        token = self.store.redeem(code)["access_token"]
        invite = self.store.invite_for_token(token)
        session = self.store.reserve_session(invite["id"], 3600)

        self.assertEqual(
            self.store.session_key_headroom(invite["id"], session["session_id"]),
            session_key_budget(1),
        )
        # A full 8-lane batch fits, and so does one complete retry of it.
        for _ in range(8):
            self.store.issue_session_key(invite["id"], session["session_id"])
        self.assertEqual(
            self.store.session_key_headroom(invite["id"], session["session_id"]),
            session_key_budget(1) - 8,
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
        self.store.reserve_session_keys(invite["id"], sid, session_key_budget(1) - 7)
        self.assertEqual(
            self.store.session_key_headroom(invite["id"], sid), 3
        )
        # A batch that does not fit claims nothing at all, rather than
        # handing back a short batch the client cannot open every lane with.
        self.assertIsNone(self.store.reserve_session_keys(invite["id"], sid, 4))
        self.assertEqual(self.store.session_key_headroom(invite["id"], sid), 3)
        self.assertEqual(
            self.store.reserve_session_keys(invite["id"], sid, 3),
            session_key_budget(1),
        )
        self.assertIsNone(self.store.reserve_session_keys(invite["id"], sid, 1))

    def test_concurrent_batches_cannot_exceed_the_key_budget(self):
        code = self.store.create_invite("partner", DEFAULT_QUOTA_SECONDS)
        token = self.store.redeem(code)["access_token"]
        invite = self.store.invite_for_token(token)
        session = self.store.reserve_session(invite["id"], 3600)
        sid = session["session_id"]
        # Only one full four-lane batch still fits.
        self.store.reserve_session_keys(invite["id"], sid, session_key_budget(1) - 4)

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
            session_key_budget(1) - 4,
        )
        # An upstream failure delivers nothing, so the whole claim comes back.
        self.store.release_session_keys(sid, 4)
        self.assertEqual(
            self.store.session_key_headroom(invite["id"], sid), session_key_budget(1)
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


class TemporaryKeyResponseTests(unittest.TestCase):
    def create_key_with_response(self, body: bytes):
        with mock.patch.object(
            server.urllib.request, "urlopen", return_value=io.BytesIO(body)
        ):
            return server.create_soniox_temporary_key(
                "test-master-key", "session-1", 60, single_use=True
            )

    def test_valid_object_with_nonempty_api_key_is_accepted(self):
        with mock.patch.object(
            server.urllib.request,
            "urlopen",
            return_value=io.BytesIO(
                b'{"api_key":"temporary-test-key","expires_at":"future"}'
            ),
        ) as open_request:
            result = server.create_soniox_temporary_key(
                "test-master-key", "session-1", 60, single_use=True
            )
        self.assertEqual(result["api_key"], "temporary-test-key")
        self.assertEqual(
            open_request.call_args.kwargs["timeout"],
            server.SONIOX_KEY_CREATE_TIMEOUT_SECONDS,
        )
        self.assertLessEqual(
            server.SONIOX_KEY_MINT_ADMISSION_TIMEOUT_SECONDS
            + server.SONIOX_KEY_CREATE_TIMEOUT_SECONDS,
            10,
            "service-side admission + socket timeout must fit the 12s reconnect request",
        )

    def test_malformed_or_missing_api_key_responses_are_rejected(self):
        for body in (
            b"not-json",
            b"[]",
            b"{}",
            b'{"api_key":""}',
            b'{"api_key":"   "}',
            b'{"api_key":123}',
        ):
            with self.subTest(body=body):
                with self.assertRaisesRegex(
                    ValueError, "invalid temporary key response"
                ):
                    self.create_key_with_response(body)


class SonioxKeyMintBatchTests(unittest.TestCase):
    def test_batch_admission_claims_all_permits_or_none(self):
        admission = server.SonioxKeyMintAdmission(MAX_LANES_PER_SESSION)

        self.assertTrue(admission.acquire(3, 0))
        self.assertEqual(admission.available, 1)
        self.assertFalse(
            admission.acquire(2, 0),
            "a batch must not retain a partial permit while waiting",
        )
        self.assertEqual(admission.available, 1)
        self.assertTrue(admission.acquire(1, 0))
        self.assertEqual(admission.available, 0)

        admission.release(1)
        admission.release(3)
        self.assertEqual(admission.available, MAX_LANES_PER_SESSION)

    def test_mints_overlap_and_results_keep_submission_order(self):
        barrier = threading.Barrier(3)
        lock = threading.Lock()
        active = 0
        maximum_active = 0

        def mint(index):
            nonlocal active, maximum_active
            with lock:
                active += 1
                maximum_active = max(maximum_active, active)
            barrier.wait(timeout=1)
            # Finish in reverse order; the response must still follow the
            # submission indexes rather than completion timing.
            time.sleep((2 - index) * 0.01)
            with lock:
                active -= 1
            return {"api_key": f"key-{index}"}

        keys = server._run_soniox_key_mint_batch(3, mint)

        self.assertEqual(maximum_active, 3, "lane mints must actually overlap")
        self.assertEqual(
            [key["api_key"] for key in keys],
            ["key-0", "key-1", "key-2"],
        )
        self.assertEqual(
            server.SONIOX_KEY_MINT_MAX_CONCURRENCY,
            MAX_LANES_PER_SESSION,
        )

    def test_process_wide_mint_concurrency_never_exceeds_max_lanes(self):
        wave = threading.Barrier(MAX_LANES_PER_SESSION)
        lock = threading.Lock()
        active = 0
        maximum_active = 0

        def mint(index):
            nonlocal active, maximum_active
            with lock:
                active += 1
                maximum_active = max(maximum_active, active)
            wave.wait(timeout=1)
            time.sleep(0.01)
            with lock:
                active -= 1
            return {"api_key": f"key-{index}"}

        keys = server._run_soniox_key_mint_batch(
            MAX_LANES_PER_SESSION * 2, mint
        )

        self.assertEqual(len(keys), MAX_LANES_PER_SESSION * 2)
        self.assertEqual(maximum_active, MAX_LANES_PER_SESSION)


class RealtimeSessionInitialKeyModeTests(unittest.TestCase):
    """The reservation endpoint negotiates the new key shape explicitly.

    This keeps all four upgrade combinations working: new clients get their
    opening single-use batch from a new server, while a request without the
    opt-in field still receives the shared flat key expected by old clients.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.tmp.name) / "invites.db")
        code = self.store.create_invite("partner", DEFAULT_QUOTA_SECONDS)
        self.access_token = self.store.redeem(code)["access_token"]
        self.saved_master_key = os.environ.get("SONIOX_API_KEY")
        os.environ["SONIOX_API_KEY"] = "test-master-key"

        self.httpd = server.ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
        self.httpd.store = self.store
        self.httpd.admin_sessions = {}
        self.httpd.admin_login_failures = {}
        self.httpd.daemon_threads = True
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=2)
        if self.saved_master_key is None:
            os.environ.pop("SONIOX_API_KEY", None)
        else:
            os.environ["SONIOX_API_KEY"] = self.saved_master_key
        self.tmp.cleanup()

    def post(self, path, body):
        host, port = self.httpd.server_address
        request = urllib.request.Request(
            f"http://{host}:{port}{path}",
            data=json.dumps(body).encode(),
            method="POST",
            headers={
                "Authorization": f"Bearer {self.access_token}",
                "Content-Type": "application/json",
            },
        )
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.status, json.load(response)

    def post_session(self, body):
        return self.post("/v1/realtime-session", body)

    def test_opt_in_returns_single_use_opening_batch_without_legacy_mint(self):
        def temporary_key(
            _master_key,
            _session_id,
            _duration_seconds,
            *,
            single_use=False,
            expires_in_seconds=3_600,
        ):
            self.assertTrue(single_use)
            self.assertEqual(expires_in_seconds, server.SINGLE_USE_KEY_EXPIRES_SECONDS)
            return {"api_key": f"lane-key-{mint.call_count}"}

        with mock.patch.object(
            server, "create_soniox_temporary_key", side_effect=temporary_key
        ) as mint:
            status, payload = self.post_session(
                {
                    "requested_seconds": 3_600,
                    "lane_count": 3,
                    "initial_key_mode": server.INITIAL_KEY_MODE_SINGLE_USE_BATCH,
                }
            )

        self.assertEqual(status, 200)
        self.assertEqual(payload["initial_key_mode"], "single_use_batch")
        self.assertEqual(len(payload["keys"]), 3)
        self.assertEqual(payload["keys_issued"], 3)
        self.assertNotIn(
            "api_key", payload, "the unused legacy shared key must not be minted"
        )
        self.assertEqual(
            mint.call_count, 3, "only the three opening lane keys are minted"
        )
        invite = self.store.invite_for_token(self.access_token)
        self.assertEqual(
            self.store.session_key_headroom(invite["id"], payload["session_id"]),
            session_key_budget(3) - 3,
        )

    def test_request_without_opt_in_keeps_the_legacy_flat_key_contract(self):
        with mock.patch.object(
            server,
            "create_soniox_temporary_key",
            return_value={"api_key": "legacy-shared-key"},
        ) as mint:
            status, payload = self.post_session(
                {"requested_seconds": 3_600, "lane_count": 3}
            )

        self.assertEqual(status, 200)
        self.assertEqual(payload["api_key"], "legacy-shared-key")
        self.assertNotIn("keys", payload)
        self.assertEqual(mint.call_count, 1)
        self.assertNotIn("single_use", mint.call_args.kwargs)

    def test_full_batch_makes_second_start_fail_fast_without_database_claims(self):
        self.assertLessEqual(
            server.SONIOX_KEY_MINT_ADMISSION_TIMEOUT_SECONDS,
            2,
            "production admission must fail well before the 20s client timeout",
        )
        all_mints_started = threading.Event()
        release_mints = threading.Event()
        calls_lock = threading.Lock()
        calls = 0
        first_result = []
        first_errors = []

        def temporary_key(*_args, **_kwargs):
            nonlocal calls
            with calls_lock:
                index = calls
                calls += 1
                if calls == MAX_LANES_PER_SESSION:
                    all_mints_started.set()
            if not release_mints.wait(timeout=3):
                raise TimeoutError("test did not release occupied mint permits")
            return {"api_key": f"first-batch-key-{index}"}

        def start_first_batch():
            try:
                first_result.append(
                    self.post_session(
                        {
                            "requested_seconds": 3_600,
                            "lane_count": MAX_LANES_PER_SESSION,
                            "initial_key_mode": (
                                server.INITIAL_KEY_MODE_SINGLE_USE_BATCH
                            ),
                        }
                    )
                )
            except BaseException as error:
                first_errors.append(error)

        with mock.patch.object(
            server, "create_soniox_temporary_key", side_effect=temporary_key
        ), mock.patch.object(
            server, "SONIOX_KEY_MINT_ADMISSION_TIMEOUT_SECONDS", 0.05
        ):
            first_thread = threading.Thread(target=start_first_batch)
            first_thread.start()
            try:
                self.assertTrue(
                    all_mints_started.wait(timeout=1),
                    "the first request must occupy all four mint permits",
                )
                db = self.store.connect()
                try:
                    before = tuple(
                        db.execute(
                            "SELECT "
                            "(SELECT COUNT(*) FROM sessions), "
                            "(SELECT COUNT(*) FROM session_keys)"
                        ).fetchone()
                    )
                finally:
                    db.close()
                self.assertEqual(before, (1, MAX_LANES_PER_SESSION))

                started_at = time.monotonic()
                with self.assertRaises(urllib.error.HTTPError) as raised:
                    self.post_session(
                        {
                            "requested_seconds": 3_600,
                            "lane_count": MAX_LANES_PER_SESSION,
                            "initial_key_mode": (
                                server.INITIAL_KEY_MODE_SINGLE_USE_BATCH
                            ),
                        }
                    )
                elapsed = time.monotonic() - started_at
                response_error = raised.exception
                try:
                    self.assertEqual(response_error.code, 503)
                    self.assertEqual(
                        json.load(response_error), {"error": "key_mint_busy"}
                    )
                finally:
                    response_error.close()
                self.assertLess(
                    elapsed,
                    1,
                    "busy admission must beat the 20s client timeout",
                )

                db = self.store.connect()
                try:
                    after = tuple(
                        db.execute(
                            "SELECT "
                            "(SELECT COUNT(*) FROM sessions), "
                            "(SELECT COUNT(*) FROM session_keys)"
                        ).fetchone()
                    )
                finally:
                    db.close()
                self.assertEqual(
                    after,
                    before,
                    (
                        "a rejected start must create neither a reservation "
                        "nor key claims"
                    ),
                )
            finally:
                release_mints.set()
                first_thread.join(timeout=2)

        self.assertFalse(first_thread.is_alive())
        self.assertEqual(first_errors, [])
        self.assertEqual(first_result[0][0], 200)

    def test_busy_legacy_start_does_not_create_a_reservation_or_key_claim(self):
        with server.soniox_key_mint_admission(
            MAX_LANES_PER_SESSION, timeout_seconds=0
        ) as occupied:
            self.assertTrue(occupied)
            with mock.patch.object(
                server, "SONIOX_KEY_MINT_ADMISSION_TIMEOUT_SECONDS", 0.01
            ), mock.patch.object(server, "create_soniox_temporary_key") as mint:
                with self.assertRaises(urllib.error.HTTPError) as raised:
                    self.post_session(
                        {"requested_seconds": 3_600, "lane_count": 1}
                    )

        response_error = raised.exception
        try:
            self.assertEqual(response_error.code, 503)
            self.assertEqual(
                json.load(response_error), {"error": "key_mint_busy"}
            )
        finally:
            response_error.close()
        mint.assert_not_called()
        db = self.store.connect()
        try:
            counts = tuple(
                db.execute(
                    "SELECT "
                    "(SELECT COUNT(*) FROM sessions), "
                    "(SELECT COUNT(*) FROM session_keys)"
                ).fetchone()
            )
        finally:
            db.close()
        self.assertEqual(counts, (0, 0))

    def test_busy_key_and_renew_requests_do_not_burn_key_budget(self):
        invite = self.store.invite_for_token(self.access_token)
        session = self.store.reserve_session(invite["id"], 3_600, 3)
        initial_headroom = self.store.session_key_headroom(
            invite["id"], session["session_id"]
        )

        with server.soniox_key_mint_admission(
            MAX_LANES_PER_SESSION, timeout_seconds=0
        ) as occupied:
            self.assertTrue(occupied)
            with mock.patch.object(
                server, "SONIOX_KEY_MINT_ADMISSION_TIMEOUT_SECONDS", 0.01
            ), mock.patch.object(server, "create_soniox_temporary_key") as mint:
                for path, body in (
                    (
                        "/v1/realtime-session/key",
                        {"session_id": session["session_id"], "count": 3},
                    ),
                    (
                        "/v1/realtime-session/renew-key",
                        {"session_id": session["session_id"]},
                    ),
                ):
                    with self.subTest(path=path):
                        with self.assertRaises(urllib.error.HTTPError) as raised:
                            self.post(path, body)
                        response_error = raised.exception
                        try:
                            self.assertEqual(response_error.code, 503)
                            self.assertEqual(
                                json.load(response_error),
                                {"error": "key_mint_busy"},
                            )
                        finally:
                            response_error.close()

        mint.assert_not_called()
        self.assertEqual(
            self.store.session_key_headroom(invite["id"], session["session_id"]),
            initial_headroom,
        )
        self.assertIsNotNone(
            self.store.open_session(invite["id"], session["session_id"])
        )

    def test_legacy_bad_response_releases_key_claim_and_reservation(self):
        with mock.patch.object(
            server,
            "create_soniox_temporary_key",
            side_effect=ValueError("invalid temporary key response"),
        ):
            with self.assertRaises(urllib.error.HTTPError) as raised:
                self.post_session({"requested_seconds": 3_600, "lane_count": 1})

        response_error = raised.exception
        try:
            self.assertEqual(response_error.code, 502)
            self.assertEqual(
                json.load(response_error), {"error": "upstream_unavailable"}
            )
        finally:
            response_error.close()
        invite = self.store.invite_for_token(self.access_token)
        self.assertEqual(invite["reserved_seconds"], 0)
        db = self.store.connect()
        try:
            session = db.execute(
                "SELECT settled_seconds FROM sessions"
            ).fetchone()
            key_count = db.execute(
                "SELECT COUNT(*) AS n FROM session_keys"
            ).fetchone()["n"]
        finally:
            db.close()
        self.assertEqual(session["settled_seconds"], 0)
        self.assertEqual(key_count, 0)

    def test_key_endpoint_bad_response_releases_claim_but_keeps_session(self):
        invite = self.store.invite_for_token(self.access_token)
        session = self.store.reserve_session(invite["id"], 3_600, 3)
        initial_headroom = self.store.session_key_headroom(
            invite["id"], session["session_id"]
        )
        with mock.patch.object(
            server,
            "create_soniox_temporary_key",
            side_effect=ValueError("invalid temporary key response"),
        ):
            with self.assertRaises(urllib.error.HTTPError) as raised:
                self.post(
                    "/v1/realtime-session/key",
                    {"session_id": session["session_id"], "count": 3},
                )

        response_error = raised.exception
        try:
            self.assertEqual(response_error.code, 502)
            self.assertEqual(
                json.load(response_error), {"error": "upstream_unavailable"}
            )
        finally:
            response_error.close()
        self.assertEqual(
            self.store.session_key_headroom(invite["id"], session["session_id"]),
            initial_headroom,
        )
        self.assertIsNotNone(
            self.store.open_session(invite["id"], session["session_id"]),
            "a reconnect-key outage must not settle an active recording",
        )

    def test_key_batch_and_legacy_renewal_response_shapes_stay_unchanged(self):
        invite = self.store.invite_for_token(self.access_token)
        session = self.store.reserve_session(invite["id"], 3_600, 3)
        with mock.patch.object(
            server,
            "create_soniox_temporary_key",
            side_effect=[
                {"api_key": "lane-0"},
                {"api_key": "lane-1"},
                {"api_key": "lane-2"},
            ],
        ) as batch_mint:
            status, payload = self.post(
                "/v1/realtime-session/key",
                {"session_id": session["session_id"], "count": 3},
            )

        self.assertEqual(status, 200)
        self.assertEqual(payload["session_id"], session["session_id"])
        self.assertEqual(payload["keys_issued"], 3)
        self.assertEqual(len(payload["keys"]), 3)
        self.assertNotIn("api_key", payload)
        self.assertEqual(batch_mint.call_count, 3)
        self.assertTrue(
            all(call.kwargs["single_use"] for call in batch_mint.call_args_list)
        )

        with mock.patch.object(
            server,
            "create_soniox_temporary_key",
            return_value={"api_key": "renewed-shared-key"},
        ) as renew_mint:
            status, renewed = self.post(
                "/v1/realtime-session/renew-key",
                {"session_id": session["session_id"]},
            )

        self.assertEqual(status, 200)
        self.assertEqual(renewed["api_key"], "renewed-shared-key")
        self.assertEqual(renewed["keys"], [{"api_key": "renewed-shared-key"}])
        self.assertEqual(renewed["keys_issued"], 4)
        self.assertEqual(renew_mint.call_count, 1)
        self.assertFalse(renew_mint.call_args.kwargs["single_use"])

    def test_mid_batch_bad_response_waits_then_rolls_back_and_releases(self):
        calls = 0
        calls_lock = threading.Lock()
        all_started = threading.Barrier(3)
        slow_sibling_finished = threading.Event()
        claim_was_visible_until_siblings_finished = threading.Event()

        def temporary_key(*_args, **_kwargs):
            nonlocal calls
            with calls_lock:
                index = calls
                calls += 1
            # This barrier both proves the endpoint is using concurrent mints
            # and makes the failure happen while another task is still alive.
            all_started.wait(timeout=1)
            if index == 1:
                raise ValueError("invalid temporary key response")
            if index == 2:
                time.sleep(0.05)
                db = self.store.connect()
                try:
                    claimed = db.execute(
                        "SELECT COUNT(*) AS n FROM session_keys"
                    ).fetchone()["n"]
                finally:
                    db.close()
                if claimed == 3:
                    claim_was_visible_until_siblings_finished.set()
                slow_sibling_finished.set()
            return {"api_key": f"never-delivered-key-{index}"}

        with mock.patch.object(
            server, "create_soniox_temporary_key", side_effect=temporary_key
        ):
            with self.assertRaises(urllib.error.HTTPError) as raised:
                self.post_session(
                    {
                        "requested_seconds": 3_600,
                        "lane_count": 3,
                        "initial_key_mode": server.INITIAL_KEY_MODE_SINGLE_USE_BATCH,
                    }
                )

        response_error = raised.exception
        try:
            self.assertEqual(response_error.code, 502)
            self.assertEqual(
                json.load(response_error), {"error": "upstream_unavailable"}
            )
        finally:
            response_error.close()
        self.assertEqual(calls, 3)
        self.assertTrue(
            slow_sibling_finished.is_set(),
            "the handler must join every mint before returning 502",
        )
        self.assertTrue(
            claim_was_visible_until_siblings_finished.is_set(),
            "rollback must happen after the last sibling settles",
        )
        db = self.store.connect()
        try:
            session = db.execute(
                "SELECT id, settled_seconds FROM sessions"
            ).fetchone()
            key_count = db.execute(
                "SELECT COUNT(*) AS n FROM session_keys WHERE session_id = ?",
                (session["id"],),
            ).fetchone()["n"]
        finally:
            db.close()
        self.assertEqual(key_count, 0, "the full batch budget claim must be returned")
        self.assertEqual(session["settled_seconds"], 0)
        invite = self.store.invite_for_token(self.access_token)
        self.assertEqual(invite["reserved_seconds"], 0)


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


class RelayAccessTest(unittest.TestCase):
    """分享功能的 relay 门禁。

    这道门禁挡的是陌生人白嫖自建中继的带宽,不改变隐私 —— 中继流量始终端到端
    加密。见 docs/architecture/share-p2p.md 第 6 节。
    """

    ENDPOINT = "a" * 64

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.tmp.name) / "invites.db")
        code = self.store.create_invite("partner", DEFAULT_QUOTA_SECONDS)
        self.invite_id = self.store.invite_by_code(code)["id"]

    def tearDown(self):
        self.tmp.cleanup()

    def test_unenrolled_endpoint_is_denied(self):
        self.assertFalse(self.store.relay_access_allowed(self.ENDPOINT))

    def test_enrolled_endpoint_is_allowed(self):
        self.assertTrue(self.store.enroll_endpoint(self.invite_id, self.ENDPOINT))
        self.assertTrue(self.store.relay_access_allowed(self.ENDPOINT))

    def test_enrollment_is_idempotent(self):
        self.assertTrue(self.store.enroll_endpoint(self.invite_id, self.ENDPOINT))
        self.assertTrue(self.store.enroll_endpoint(self.invite_id, self.ENDPOINT))
        self.assertTrue(self.store.relay_access_allowed(self.ENDPOINT))

    def test_case_and_whitespace_are_normalized(self):
        self.store.enroll_endpoint(self.invite_id, "  " + self.ENDPOINT.upper() + "\n")
        self.assertTrue(self.store.relay_access_allowed(self.ENDPOINT))

    def test_malformed_endpoint_ids_are_refused_before_storage(self):
        for bad in ["", "short", "z" * 64, "a" * 63, "a" * 65, "../../etc/passwd"]:
            with self.subTest(bad=bad):
                self.assertFalse(self.store.enroll_endpoint(self.invite_id, bad))
                self.assertFalse(self.store.relay_access_allowed(bad))

    def test_pausing_an_invitation_revokes_relay_access(self):
        """暂停邀请码就该同时断掉中继,不需要第二个开关。"""
        self.store.enroll_endpoint(self.invite_id, self.ENDPOINT)
        self.assertTrue(self.store.relay_access_allowed(self.ENDPOINT))
        self.store.set_invite_enabled(self.invite_id, False)
        self.assertFalse(self.store.relay_access_allowed(self.ENDPOINT))
        self.store.set_invite_enabled(self.invite_id, True)
        self.assertTrue(self.store.relay_access_allowed(self.ENDPOINT))

    def test_last_seen_is_recorded_for_allowed_endpoints(self):
        self.store.enroll_endpoint(self.invite_id, self.ENDPOINT)
        self.store.relay_access_allowed(self.ENDPOINT)
        with self.store.connect() as db:
            row = db.execute(
                "SELECT last_seen_at FROM endpoint_enrollment WHERE endpoint_id = ?",
                (self.ENDPOINT,),
            ).fetchone()
        self.assertIsNotNone(row["last_seen_at"])


class RelayHeaderNameTest(unittest.TestCase):
    """中继送的头名字是 `X-Iroh-NodeId`,不是文档写的 `X-Iroh-Endpoint-Id`。

    iroh-relay 1.0.3 的源码里那个常量叫 X_IROH_ENDPOINT_ID,值却仍是
    X-Iroh-NodeId —— 1.0 把 NodeId 改名时头名字没跟着改。只认文档里那个名字,
    线上会把所有人都拒掉,而两边日志都显示正常:服务返回 200,中继只说正文不是
    "true"。这条测试把两个名字都钉住。
    """

    def _handler_source(self):
        return pathlib.Path(server.__file__).read_text(encoding="utf-8")

    def test_both_header_spellings_are_accepted(self):
        source = self._handler_source()
        self.assertIn('"X-Iroh-NodeId"', source, "必须接受中继实际发送的头名")
        self.assertIn('"X-Iroh-Endpoint-Id"', source, "也要接受文档里的头名,便于上游修复后继续可用")

    def test_relay_auth_route_reads_the_header_not_the_body(self):
        """endpoint id 只能来自请求头 —— 中继不发请求体。"""
        source = self._handler_source()
        route = source.split('if self.path == "/v1/relay-auth":', 1)[1].split("if self.path ==", 1)[0]
        self.assertNotIn("read_json", route, "relay-auth 不该尝试读请求体")
        self.assertIn("relay_access_allowed", route)


class RelayStatsTest(unittest.TestCase):
    """中继运营统计:只存聚合量。

    这组测试真正守的不是「数字对不对」,而是**这张表存不下配对数据**——
    上报里夹带 endpoint 信息也不会落库。见 docs/architecture/share-p2p.md。
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.tmp.name) / "invites.db")

    def tearDown(self):
        self.tmp.cleanup()

    DAY = "2026-08-06"

    def test_a_report_lands_as_one_daily_row(self):
        self.assertTrue(
            self.store.record_relay_stats(self.DAY, {"bytes_sent": 100, "connections": 2}, 3)
        )
        rows = self.store.relay_stats()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["day"], self.DAY)
        self.assertEqual(rows[0]["bytes_sent"], 100)
        self.assertEqual(rows[0]["unique_clients_peak"], 3)

    def test_reports_accumulate_within_a_day(self):
        """一天内多次上报,带的是增量,应当累加而不是覆盖。"""
        self.store.record_relay_stats(self.DAY, {"bytes_sent": 100, "connections": 1})
        self.store.record_relay_stats(self.DAY, {"bytes_sent": 250, "connections": 4})
        row = self.store.relay_stats()[0]
        self.assertEqual(row["bytes_sent"], 350)
        self.assertEqual(row["connections"], 5)

    def test_unique_clients_keeps_the_peak_not_the_sum(self):
        """去重数不是增量,累加它会得出荒谬的数字。"""
        self.store.record_relay_stats(self.DAY, {}, 7)
        self.store.record_relay_stats(self.DAY, {}, 3)
        self.assertEqual(self.store.relay_stats()[0]["unique_clients_peak"], 7)

    def test_days_stay_separate(self):
        self.store.record_relay_stats("2026-08-06", {"bytes_sent": 10})
        self.store.record_relay_stats("2026-08-07", {"bytes_sent": 20})
        rows = self.store.relay_stats()
        self.assertEqual([r["day"] for r in rows], ["2026-08-07", "2026-08-06"])

    def test_endpoint_data_in_a_report_is_never_stored(self):
        """**核心断言。** 上报里夹带配对信息,一个字节都不该落库。"""
        self.store.record_relay_stats(
            self.DAY,
            {
                "bytes_sent": 5,
                "endpoint_id": "a" * 64,
                "peer_pairs": [["a" * 64, "b" * 64]],
                "connected_at": "2026-08-06T10:00:00Z",
            },
            1,
        )
        with self.store.connect() as db:
            columns = {r[1] for r in db.execute("PRAGMA table_info(relay_daily)")}
            dumped = str(list(db.execute("SELECT * FROM relay_daily")))
        self.assertNotIn("endpoint_id", columns, "表里不该有 endpoint 列")
        self.assertNotIn("peer_pairs", columns, "表里不该有配对列")
        self.assertNotIn("a" * 64, dumped, "endpoint id 不该出现在任何一行里")

    def test_malformed_reports_are_refused(self):
        for day, deltas in [
            ("", {}),
            ("not-a-day", {}),
            (self.DAY, {"bytes_sent": -1}),
            (self.DAY, {"bytes_sent": "lots"}),
        ]:
            with self.subTest(day=day, deltas=deltas):
                self.assertFalse(self.store.record_relay_stats(day, deltas))

    def test_nothing_is_stored_when_a_report_is_refused(self):
        self.store.record_relay_stats(self.DAY, {"bytes_sent": -5})
        self.assertEqual(self.store.relay_stats(), [])


class ServiceCredentialNameTests(unittest.TestCase):
    """Credentials are read under one name only, and it is the pre-rename one.

    `ZULANGUE_*` is what `service.env` on each machine already holds, so the
    0.4.0 rename deliberately stops at this boundary. There is no second name
    to fall back to: a drift between code and machine reads empty and gets the
    request refused — never a service that accepts whatever it is handed."""

    def setUp(self):
        self._saved = {
            key: os.environ.get(key)
            for key in ("ZULANGUE_ADMIN_TOKEN", "ZULANGUE_RELAY_AUTH_TOKEN")
        }
        for key in self._saved:
            os.environ.pop(key, None)

    def tearDown(self):
        for key, value in self._saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def test_current_name_is_read(self):
        os.environ["ZULANGUE_ADMIN_TOKEN"] = "set-on-the-machines"
        self.assertEqual(server.env_secret("ADMIN_TOKEN"), "set-on-the-machines")

    def test_renamed_name_is_not_honoured(self):
        # Deliberate, and this direction is the one worth pinning: a future
        # rename to ZUTALK_ has to change the machines in the same step, so it
        # must not be able to start working here on its own first.
        os.environ["ZUTALK_ADMIN_TOKEN"] = "not-on-the-machines"
        try:
            self.assertEqual(server.env_secret("ADMIN_TOKEN"), "")
        finally:
            os.environ.pop("ZUTALK_ADMIN_TOKEN", None)

    def test_absent_reads_empty_rather_than_raising(self):
        # An empty secret is refused by the callers; a KeyError here would
        # take the whole request handler down instead.
        self.assertEqual(server.env_secret("ADMIN_TOKEN"), "")
