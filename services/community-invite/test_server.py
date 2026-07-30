import tempfile
import unittest
from pathlib import Path

from server import DEFAULT_GIVES, DEFAULT_QUOTA_SECONDS, Store


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


if __name__ == "__main__":
    unittest.main()
