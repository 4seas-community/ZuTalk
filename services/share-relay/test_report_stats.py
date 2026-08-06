"""上报器的行为测试。

守两件事:计数器重启归零时不能报出负数(服务端会拒,那一整段就丢了),
以及这条路径读不出任何配对信息。
"""
import unittest
import importlib.util
import pathlib

spec = importlib.util.spec_from_file_location(
    "report_stats", pathlib.Path(__file__).parent / "report-stats.py"
)
report_stats = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report_stats)


SAMPLE = """# HELP relayserver_bytes_sent_total bytes
# TYPE relayserver_bytes_sent_total counter
relayserver_bytes_sent_total 5000
relayserver_bytes_recv_total 4000
relayserver_http_connections_total 12
relayserver_disconnects_total 3
relayserver_send_packets_dropped_total 1
relayserver_conns_rx_ratelimited_total 0
relayserver_unique_client_keys_total 7
relayserver_something_we_do_not_read 999
"""


class ScrapeTests(unittest.TestCase):
    def test_reads_only_the_declared_counters(self):
        found = report_stats.scrape(SAMPLE)
        self.assertEqual(found["relayserver_bytes_sent_total"], 5000)
        self.assertEqual(found["relayserver_unique_client_keys_total"], 7)
        self.assertNotIn("relayserver_something_we_do_not_read", found)

    def test_comments_and_junk_are_ignored(self):
        self.assertEqual(report_stats.scrape("# just a comment\ngarbage\n"), {})


class DeltaTests(unittest.TestCase):
    def test_normal_progress_is_differenced(self):
        previous = {"relayserver_bytes_sent_total": 1000}
        current = {"relayserver_bytes_sent_total": 1500}
        self.assertEqual(report_stats.deltas_since(previous, current)["bytes_sent"], 500)

    def test_a_restart_never_yields_a_negative_delta(self):
        """中继重启后计数器归零。报负数会被服务端拒掉,整段区间就丢了。"""
        previous = {"relayserver_bytes_sent_total": 9999}
        current = {"relayserver_bytes_sent_total": 42}
        deltas = report_stats.deltas_since(previous, current)
        self.assertEqual(deltas["bytes_sent"], 42)
        self.assertTrue(all(v >= 0 for v in deltas.values()))

    def test_first_run_reports_everything_so_far(self):
        current = {"relayserver_bytes_sent_total": 800}
        self.assertEqual(report_stats.deltas_since({}, current)["bytes_sent"], 800)

    def test_every_declared_field_is_always_present(self):
        """服务端按固定字段读;缺字段会被当成 0,不如这里就补齐。"""
        deltas = report_stats.deltas_since({}, {})
        self.assertEqual(set(deltas), set(report_stats.COUNTERS))


class PrivacyTests(unittest.TestCase):
    def test_no_counter_carries_pairing_information(self):
        """这条路径读的全是全局计数器 —— 结构上就没有「谁连了谁」可读。"""
        for metric in list(report_stats.COUNTERS.values()) + [report_stats.UNIQUE_CLIENTS]:
            self.assertNotIn("{", metric, f"{metric} 带标签,可能携带 per-peer 维度")
            self.assertTrue(metric.startswith("relayserver_"))


if __name__ == "__main__":
    unittest.main()
