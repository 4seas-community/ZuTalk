#!/usr/bin/env python3
"""把中继的运营量按天报给邀请码服务。

只读中继自己的 Prometheus 全局计数器。那些计数器**不含配对信息**——没有「谁连了
谁」这种数据可读，所以这条路径在结构上就产不出社交图谱，不是靠这个脚本自觉不发。

计数器是单调累加的，服务端要的是增量，所以本地记一份上次的读数做差。中继重启后
计数器归零，此时把当前值整个当作增量——宁可少算一点，也不要报出负数。

用法（由 systemd timer 每 15 分钟调一次）：
    ZULANGUE_RELAY_AUTH_TOKEN=... ./report-stats.py

环境变量：
    ZULANGUE_RELAY_AUTH_TOKEN  与邀请码服务共享的凭据（必需）
    RELAY_METRICS_URL          默认 http://127.0.0.1:9090/metrics
    INVITE_URL                 默认 https://zulangue-invite.exe.xyz
    RELAY_STATE_FILE           默认 ~/zulangue-share-relay/data/last-metrics.json
"""

from __future__ import annotations

import json
import os
import pathlib
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

# 只读这几个。加一个新字段要同时改服务端的 RELAY_STAT_FIELDS，
# 这份重复是刻意的：它逼着任何新增字段被两边同时看见一次。
COUNTERS = {
    "bytes_sent": "relayserver_bytes_sent_total",
    "bytes_recv": "relayserver_bytes_recv_total",
    "connections": "relayserver_http_connections_total",
    "disconnects": "relayserver_disconnects_total",
    "packets_dropped": "relayserver_send_packets_dropped_total",
    "ratelimited": "relayserver_conns_rx_ratelimited_total",
}
UNIQUE_CLIENTS = "relayserver_unique_client_keys_total"

METRICS_URL = os.environ.get("RELAY_METRICS_URL", "http://127.0.0.1:9090/metrics")
INVITE_URL = os.environ.get("INVITE_URL", "https://zulangue-invite.exe.xyz")
STATE_FILE = pathlib.Path(
    os.environ.get(
        "RELAY_STATE_FILE",
        str(pathlib.Path.home() / "zulangue-share-relay" / "data" / "last-metrics.json"),
    )
)


def scrape(text: str) -> dict[str, int]:
    """Pull the counters we care about out of a Prometheus exposition body."""
    wanted = set(COUNTERS.values()) | {UNIQUE_CLIENTS}
    found: dict[str, int] = {}
    for line in text.splitlines():
        if line.startswith("#") or " " not in line:
            continue
        name, _, value = line.partition(" ")
        if name in wanted:
            try:
                found[name] = int(float(value))
            except ValueError:
                continue
    return found


def deltas_since(previous: dict[str, int], current: dict[str, int]) -> dict[str, int]:
    """Difference the counters, treating a reset as "everything since restart".

    A restarted relay starts from zero, so a smaller reading is not a mistake
    and must not become a negative delta — the server refuses those, and a
    refused report would silently lose the whole interval.
    """
    out: dict[str, int] = {}
    for field, metric in COUNTERS.items():
        now = current.get(metric, 0)
        before = previous.get(metric, 0)
        out[field] = now if now < before else now - before
    return out


def main() -> int:
    # 两个名字都认。中继的 service.env 里存的是 IROH_RELAY_HTTP_BEARER_TOKEN
    # (中继自己要用那个名),同一个值。让脚本认它,就不必在 systemd 单元里绕一层
    # shell 去改名 —— 那层 shell 里的变量展开语义正是上一版 401 的原因。
    token = os.environ.get("ZULANGUE_RELAY_AUTH_TOKEN") or os.environ.get(
        "IROH_RELAY_HTTP_BEARER_TOKEN", ""
    )
    if not token:
        print("ZULANGUE_RELAY_AUTH_TOKEN 未设置", file=sys.stderr)
        return 2

    try:
        with urllib.request.urlopen(METRICS_URL, timeout=10) as response:
            current = scrape(response.read().decode())
    except (urllib.error.URLError, OSError) as error:
        print(f"抓取指标失败: {error}", file=sys.stderr)
        return 1

    previous: dict[str, int] = {}
    if STATE_FILE.exists():
        try:
            previous = json.loads(STATE_FILE.read_text())
        except (json.JSONDecodeError, OSError):
            # 状态文件坏了就当第一次跑。少算一个区间，好过一直报不出去。
            previous = {}

    payload = {
        "day": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "deltas": deltas_since(previous, current),
        "unique_clients": current.get(UNIQUE_CLIENTS, 0),
    }

    request = urllib.request.Request(
        f"{INVITE_URL}/v1/relay-stats",
        data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            if response.status != 200:
                print(f"上报被拒: HTTP {response.status}", file=sys.stderr)
                return 1
    except (urllib.error.URLError, OSError) as error:
        # 上报失败时**不写状态文件**，下次跑会把这段区间一起补上。
        print(f"上报失败: {error}", file=sys.stderr)
        return 1

    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(current))
    return 0


if __name__ == "__main__":
    sys.exit(main())
