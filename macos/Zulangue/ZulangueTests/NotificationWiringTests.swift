// NotificationWiringTests.swift
// 验证应用级事件通知的命名和基本投递。
//
// 1. **静态防御**: NotificationCatalog 列出所有 zulangue* notification name.
//    每个 name 必须在 production source 里既有 post 也有 addObserver / publisher.
//
// 2. **运行时防御**: 这个测试文件 — 验证 notification name 拼写、name uniqueness,
//    以及 addObserver + post 的基本 round-trip 工作正常.
//
// IntegrityChecks 在应用启动时验证运行时配置。

import XCTest
@testable import Zulangue

@MainActor
final class NotificationWiringTests: XCTestCase {

    var observers: [NSObjectProtocol] = []

    override func setUp() async throws {
        try await super.setUp()
        observers = []
    }

    override func tearDown() async throws {
        for o in observers {
            NotificationCenter.default.removeObserver(o)
        }
        observers = []
        try await super.tearDown()
    }

    // MARK: - 所有 zulangue 自定义 notification 都存在 + 名字唯一

    func testAllZulangueNotificationsHaveUniqueNames() {
        let allNames: [Notification.Name] = [
            .zulangueSessionUpdated,
            .zulanguePermissionsMayHaveChanged,
        ]
        let raw = allNames.map(\.rawValue)
        let unique = Set(raw)
        XCTAssertEqual(
            raw.count,
            unique.count,
            "zulangue notification names must be unique, found duplicates: \(raw)"
        )
        // 没空字符串
        for name in raw {
            XCTAssertFalse(name.isEmpty, "notification name should not be empty")
            XCTAssertTrue(
                name.hasPrefix("Zulangue"),
                "notification name should start with Zulangue prefix, got: \(name)"
            )
        }
    }

    // MARK: - addObserver + post round-trip (验证 NotificationCenter 工作)

    func testAddObserverAndPost_zulanguePermissionsMayHaveChanged_roundtrip() {
        var received = false
        let obs = NotificationCenter.default.addObserver(
            forName: .zulanguePermissionsMayHaveChanged,
            object: nil,
            queue: nil
        ) { _ in received = true }
        observers.append(obs)

        NotificationCenter.default.post(name: .zulanguePermissionsMayHaveChanged, object: nil)
        XCTAssertTrue(received)
    }

    func testAddObserverAndPost_zulangueSessionUpdated_carriesObject() {
        var receivedSessionId: String?
        let obs = NotificationCenter.default.addObserver(
            forName: .zulangueSessionUpdated,
            object: nil,
            queue: nil
        ) { note in
            receivedSessionId = note.object as? String
        }
        observers.append(obs)

        NotificationCenter.default.post(
            name: .zulangueSessionUpdated,
            object: "session-abc-123"
        )
        XCTAssertEqual(receivedSessionId, "session-abc-123")
    }

    // MARK: - removeObserver 真的能取消订阅 (内存安全)

    func testRemoveObserver_stopsReceiving() {
        var count = 0
        let obs = NotificationCenter.default.addObserver(
            forName: .zulangueSessionUpdated,
            object: nil,
            queue: nil
        ) { _ in count += 1 }

        NotificationCenter.default.post(name: .zulangueSessionUpdated, object: "session-1")
        XCTAssertEqual(count, 1)

        NotificationCenter.default.removeObserver(obs)
        NotificationCenter.default.post(name: .zulangueSessionUpdated, object: "session-2")
        XCTAssertEqual(count, 1, "removeObserver should stop further deliveries")
    }
}
