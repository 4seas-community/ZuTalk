"""caption-web 的行为测试:走真实 HTTP,不 mock handler。"""

import json
import os
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

import server
from server import Handler, RoomStore


class CaptionWebTests(unittest.TestCase):
    def setUp(self):
        self.store = RoomStore()
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.httpd.store = self.store
        self.httpd.public_base = "https://captions.example"
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()

    # ------------------------------------------------------------------
    def request(self, method, path, body=None, token=None):
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}{path}", method=method
        )
        if token:
            request.add_header("Authorization", f"Bearer {token}")
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, data=data, timeout=5) as response:
                return response.status, json.loads(response.read() or b"{}")
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read() or b"{}")

    def create_room(self):
        status, payload = self.request("POST", "/v1/rooms")
        self.assertEqual(status, 200)
        return payload

    def open_sse(self, room_id):
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/v1/rooms/{room_id}/events"
        )
        return urllib.request.urlopen(request, timeout=10)

    @staticmethod
    def read_event(stream):
        """读一个完整 SSE 事件(跳过心跳注释)。"""
        event, data = None, None
        while True:
            line = stream.readline().decode().rstrip("\n")
            if line.startswith(":"):
                continue
            if line.startswith("event: "):
                event = line[len("event: "):]
            elif line.startswith("data: "):
                data = json.loads(line[len("data: "):])
            elif line == "" and event is not None:
                return event, data

    # ------------------------------------------------------------------
    def test_room_lifecycle_end_to_end(self):
        room = self.create_room()
        self.assertTrue(room["viewer_url"].startswith("https://captions.example/r/"))

        stream = self.open_sse(room["room_id"])
        event, data = self.read_event(stream)
        self.assertEqual(event, "init")
        self.assertEqual(data["sessions"], [])
        self.assertIsNone(data["frame"])

        # 推一帧 + 一份稿,订阅端按序收到。
        status, _ = self.request(
            "POST",
            f"/v1/rooms/{room['room_id']}/frame",
            body={"preview_revision": 1, "session_id": "s1", "utterances": []},
            token=room["publish_token"],
        )
        self.assertEqual(status, 200)
        event, data = self.read_event(stream)
        self.assertEqual(event, "frame")
        self.assertEqual(data["preview_revision"], 1)

        status, _ = self.request(
            "POST",
            f"/v1/rooms/{room['room_id']}/blocks",
            body={"session_id": "s1", "blocks": [{"id": "b1", "owner": "capture:s1",
                                                  "text": "你好", "lanes": {"en": "hello"}}]},
            token=room["publish_token"],
        )
        self.assertEqual(status, 200)
        event, data = self.read_event(stream)
        self.assertEqual(event, "blocks")
        self.assertEqual(data["blocks"][0]["lanes"]["en"], "hello")

        # 封笔:订阅端收 ended,主播不能再写,但稿留着(见散场后那条测试)。
        status, _ = self.request(
            "DELETE", f"/v1/rooms/{room['room_id']}", token=room["publish_token"]
        )
        self.assertEqual(status, 200)
        event, _ = self.read_event(stream)
        self.assertEqual(event, "ended")
        status, _ = self.request(
            "POST",
            f"/v1/rooms/{room['room_id']}/frame",
            body={"preview_revision": 99},
            token=room["publish_token"],
        )
        self.assertEqual(status, 401, "封笔之后不接受推送")

    def test_late_subscriber_gets_the_transcript_so_far(self):
        room = self.create_room()
        for index in (1, 2):
            self.request(
                "POST",
                f"/v1/rooms/{room['room_id']}/blocks",
                body={"session_id": f"s{index}", "blocks": [
                    {"id": "b", "owner": "capture", "text": f"第{index}场", "lanes": {}}
                ]},
                token=room["publish_token"],
            )
        self.request(
            "POST",
            f"/v1/rooms/{room['room_id']}/frame",
            body={"preview_revision": 9, "session_id": "s2"},
            token=room["publish_token"],
        )

        stream = self.open_sse(room["room_id"])
        event, data = self.read_event(stream)
        self.assertEqual(event, "init")
        # 晚扫码的人拿到此前全部的稿(按出现顺序)与最新一帧。
        self.assertEqual([s["session_id"] for s in data["sessions"]], ["s1", "s2"])
        self.assertEqual(data["frame"]["preview_revision"], 9)

    def test_the_transcript_outlives_the_share(self):
        """散场之后扫码进来的人读到整份稿,不是 404。

        会议散场恰恰是最多人去读稿的时候。从前 DELETE 把房间整个删掉,
        「扫码看字幕」于是缩成「必须现场看完」;而稿本来就已经在服务器
        上了,提前删它不改变明文经过服务器这件事,只让来晚的人白扫一次码。
        """
        room = self.create_room()
        rid, token = room["room_id"], room["publish_token"]
        self.request(
            "POST", f"/v1/rooms/{rid}/blocks",
            body={"session_id": "s1", "blocks": [
                {"id": "b1", "owner": "capture:s1", "text": "讲完了", "lanes": {}}]},
            token=token,
        )
        # 半句推测文本停在屏幕上比没有更坏 —— 封笔时它必须消失。
        self.request(
            "POST", f"/v1/rooms/{rid}/frame",
            body={"preview_revision": 5, "session_id": "s1"}, token=token,
        )
        self.request("DELETE", f"/v1/rooms/{rid}", token=token)

        with urllib.request.urlopen(
            f"http://127.0.0.1:{self.port}/r/{rid}", timeout=5
        ) as page:
            self.assertEqual(page.status, 200, "散场后观看页仍然打得开")

        stream = self.open_sse(rid)
        event, data = self.read_event(stream)
        self.assertEqual(event, "init")
        self.assertEqual([s["session_id"] for s in data["sessions"]], ["s1"])
        self.assertIsNone(data["frame"], "封笔要清掉推测性的半句话")
        self.assertGreater(data["retention_hours"], 0, "网页要说得出链接还能开多久")
        # 全量之后紧跟一条 ended:读到的是完整的稿和一句「已结束」。
        event, _ = self.read_event(stream)
        self.assertEqual(event, "ended")

        # 留存期一到才真的删。
        self.store.rooms[rid].last_activity -= self.store.retention_seconds + 1
        self.assertEqual(self.store.sweep_idle(), 1)
        status, _ = self.request("GET", f"/r/{rid}")
        self.assertEqual(status, 404)

    def test_rooms_survive_a_restart(self):
        """重启不作废会场里的二维码。

        「进程重启即空」读起来像隐私保证,其实不是:明文本来就要在这台
        机器上待满整个留存期。它真正的效果是一次部署、一次 OOM 就让所有
        扫过码的人同时失联,而会还在开。
        """
        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            path = f"{directory}/rooms.json"
            self.store.state_path = path
            room = self.create_room()
            rid, token = room["room_id"], room["publish_token"]
            self.request(
                "POST", f"/v1/rooms/{rid}/blocks",
                body={"session_id": "s1", "blocks": [
                    {"id": "b1", "owner": "capture:s1", "text": "第一句", "lanes": {}}]},
                token=token,
            )
            self.request(
                "POST", f"/v1/rooms/{rid}/segment",
                body={"kind": "started", "session_id": "s1", "at": 1},
                token=token,
            )
            self.request(
                "POST", f"/v1/rooms/{rid}/frame",
                body={"preview_revision": 3, "session_id": "s1"}, token=token,
            )
            self.assertTrue(self.store.flush())
            self.assertFalse(self.store.flush(), "不脏就不写")
            self.assertEqual(oct(os.stat(path).st_mode)[-3:], "600",
                             "文件里有字幕明文和发布口令")

            # 换一个进程的仓库:同一份快照,同一间房。
            revived = RoomStore(state_path=path)
            self.assertEqual(revived.load(), 1)
            room_again = revived.rooms[rid]
            self.assertEqual(room_again.publish_token, token, "主播要能接着推")
            self.assertEqual(room_again.session_order, ["s1"])
            self.assertEqual(room_again.blocks["s1"]["blocks"][0]["text"], "第一句")
            self.assertEqual(room_again.segments[0]["kind"], "started")
            self.assertIsNone(room_again.frame, "帧是推测性的,不落盘")

            # 留存期已满的房间不该复活。
            stale = RoomStore(state_path=path, retention_seconds=0)
            self.assertEqual(stale.load(), 0)

    def test_a_corrupt_snapshot_does_not_block_startup(self):
        """读不懂的快照当作没有房间,而不是让服务起不来。"""
        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            path = f"{directory}/rooms.json"
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("{ not json")
            self.assertEqual(RoomStore(state_path=path).load(), 0)

    def test_publish_requires_the_token(self):
        room = self.create_room()
        status, _ = self.request(
            "POST",
            f"/v1/rooms/{room['room_id']}/frame",
            body={"preview_revision": 1},
            token="wrong-token",
        )
        self.assertEqual(status, 401)
        status, _ = self.request("DELETE", f"/v1/rooms/{room['room_id']}", token="nope")
        self.assertEqual(status, 401)

    def test_viewer_page_serves_inline_html(self):
        room = self.create_room()
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/r/{room['room_id']}"
        )
        with urllib.request.urlopen(request, timeout=5) as response:
            self.assertEqual(response.status, 200)
            page = response.read().decode()
        self.assertIn("EventSource", page)
        # 会议室网络不可预设能出外网:页面必须无外部资源。
        self.assertNotIn("http://", page.split("<body>")[1])
        self.assertNotIn("https://", page.split("<body>")[1])
        # 界面文案三语齐备:观看的人是简中/泰/英背景,英文独占的
        # 「This share has ended」对另外两种人就是谜语。
        self.assertIn("这场分享已结束", page)
        self.assertIn("การแชร์นี้จบแล้ว", page)
        self.assertIn("This share has ended", page)
        for lang in ("zh-Hans", "en", "th"):
            self.assertIn(f'"{lang}"', page)

    def test_live_tail_columns_anchor_to_the_bottom_like_the_app_canvas(self):
        """实时区各栏底端对齐 ——「现在」在底边。

        每栏是自己的一叠 `<p>`,行数天然不等:辅助流断句比 canonical 粗,
        译文栏的句子更长更少。顶端起排时,最新的那一句在三栏里落在三个
        不同高度,读者看到的就是「语言不在同一行」。App 画布早就是底端
        锚定的,网页跟上同一条规矩,两个界面才对同一件事给同一个答案。

        稿区不需要这条:它是按块分行的网格,行对齐由每一行自己保证。
        """
        page = server.VIEWER_PAGE
        self.assertIn("#livetail .row { align-items: end; }", page)
        # 末行的下外边距会把底边顶开,对齐就差那 12px。
        self.assertIn("#livetail p:last-child { margin-bottom: 0; }", page)
        # 稿区保持原样:那里不该被底端对齐改写。
        self.assertNotIn("#transcript .row { align-items", page)

    def test_create_rate_limit_per_ip(self):
        for _ in range(server.MAX_CREATES_PER_MINUTE):
            status, _ = self.request("POST", "/v1/rooms")
            self.assertEqual(status, 200)
        status, payload = self.request("POST", "/v1/rooms")
        self.assertEqual(status, 429)
        self.assertEqual(payload["error"], "room_limit")

    def test_idle_rooms_are_swept(self):
        room = self.create_room()
        stored = self.store.rooms[room["room_id"]]
        stored.last_activity -= self.store.retention_seconds + 1
        removed = self.store.sweep_idle()
        self.assertEqual(removed, 1)
        status, _ = self.request("GET", f"/r/{room['room_id']}")
        self.assertEqual(status, 404)

    def test_pause_marker_stops_the_live_tail_for_late_subscribers(self):
        """暂停即字幕停住 —— 半句推测文本不能挂在屏幕上等下一个人看到。

        房间不散:分割线全部保留在 init 里,晚扫码的人也看得到这场录音
        断过、几点重开的。
        """
        room = self.create_room()
        rid, token = room["room_id"], room["publish_token"]
        self.request("POST", f"/v1/rooms/{rid}/blocks",
                     body={"session_id": "s1", "blocks": [
                         {"id": "b1", "owner": "capture:s1", "text": "第一段", "lanes": {}}]},
                     token=token)
        self.request("POST", f"/v1/rooms/{rid}/frame",
                     body={"preview_revision": 3, "session_id": "s1",
                           "utterances": [{"id": "u9", "session_id": "s1",
                                           "source_text": "说到一半"}]},
                     token=token)
        self.request("POST", f"/v1/rooms/{rid}/segment",
                     body={"kind": "paused", "session_id": "s1", "at": 1000,
                           "after_block_id": "b1"}, token=token)

        stream = self.open_sse(rid)
        event, data = self.read_event(stream)
        self.assertEqual(event, "init")
        self.assertIsNone(data["frame"], "暂停后最后一帧必须清掉")
        self.assertEqual(len(data["segments"]), 1)
        self.assertEqual(data["segments"][0]["kind"], "paused")

        # 房间还活着:恢复录音的线照常追加,带着重开的时间。
        self.request("POST", f"/v1/rooms/{rid}/segment",
                     body={"kind": "started", "session_id": "s1", "at": 2000,
                           "after_block_id": "b1"}, token=token)
        event, data = self.read_event(stream)
        self.assertEqual(event, "segment")
        self.assertEqual(data["kind"], "started")
        self.assertEqual(data["at"], 2000)

    def test_viewer_page_script_parses(self):
        """内联脚本必须是合法 JS。

        页面是 Python 字符串里的一大段 JS —— 一个跑进字符串字面量的
        `\\n` 转义就能让整页脚本 SyntaxError,而服务端毫不知情:HTTP 200、
        HTML 正常,只有浏览器控制台里一句报错,页面全白。生产上真发生过。
        没有 node 时跳过(CI 机器上有)。
        """
        import shutil
        import subprocess
        import tempfile

        node = shutil.which("node")
        if not node:
            self.skipTest("node 不可用,跳过 JS 语法检查")
        script = server.VIEWER_PAGE.split("<script>")[1].split("</script>")[0]
        with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as handle:
            handle.write(script)
            path = handle.name
        result = subprocess.run([node, "--check", path], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_keep_alive_survives_rejected_and_bodyless_reads(self):
        """连接复用下的请求体卫生 —— 生产抓到过的真 bug。

        边缘代理会把多个客户端复用到同一条后端 keep-alive 连接上。任何
        「响应了却没读体」的路径(401、建房忽略体)都会把残字节留在连接
        里,下一个请求被解析成 `{}GET` → 501,而且殃及别人。这里在单条
        连接上连发:带体建房 → 带体的未授权 POST → GET,每一步都必须
        得到正确回答。
        """
        import http.client

        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            # 带体建房(App 的 reqwest .json(&{}) 就是这么发的)。
            conn.request(
                "POST", "/v1/rooms", body="{}",
                headers={"Content-Type": "application/json"},
            )
            response = conn.getresponse()
            self.assertEqual(response.status, 200)
            room = json.loads(response.read())

            # 未授权、带体:必须 401,且不残留字节。
            conn.request(
                "POST", f"/v1/rooms/{room['room_id']}/frame",
                body=json.dumps({"preview_revision": 1}),
                headers={
                    "Authorization": "Bearer wrong",
                    "Content-Type": "application/json",
                },
            )
            response = conn.getresponse()
            self.assertEqual(response.status, 401)
            response.read()

            # 同一条连接的下一个请求:修复前这里是 501 ('{}GET')。
            conn.request("GET", "/healthz")
            response = conn.getresponse()
            self.assertEqual(response.status, 200)
            response.read()
        finally:
            conn.close()

    def test_oversized_payload_is_refused(self):
        room = self.create_room()
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/v1/rooms/{room['room_id']}/frame",
            method="POST",
        )
        request.add_header("Authorization", f"Bearer {room['publish_token']}")
        request.add_header("Content-Type", "application/json")
        huge = b"x" * (server.MAX_BODY_BYTES + 1)
        try:
            with urllib.request.urlopen(request, data=huge, timeout=5) as response:
                status = response.status
        except urllib.error.HTTPError as error:
            status = error.code
            error.read()
        self.assertEqual(status, 413)


if __name__ == "__main__":
    unittest.main()
