// LegacyIdentityMigration.swift
// 0.3.x 以 Zulangue 之名发布，改名成 ZuTalk 动了两处用户看不见却依赖着的身份：
//
//   - 数据目录 ~/Library/Application Support/Zulangue → ZuTalk。不搬，录音、
//     笔记、编辑器文档、邀请 token 全部凭空消失 —— 文件还在，app 不再看它。
//   - bundle ID xyz.voice.zulangue → xyz.voice.zutalk。偏好设置按 bundle ID
//     分域存放，换了 ID 就是换了一个 plist：窗口位置、字幕样式、引导完成标记、
//     邀请开关一起回到出厂值。
//
// 所以这两件事必须在核心打开数据目录之前发生，也就是 ZuTalkApp.init() 的第一行。
// 全过程幂等：搬过一次之后每次启动都会走到，但每一步都先确认「新的还不存在」。

import Foundation

enum LegacyIdentityMigration {
    /// 老 bundle ID。这是历史事实，不随产品改名而变 —— 它指的是磁盘上那个
    /// 已经写好的 plist 域，改掉它就等于放弃老用户的全部偏好设置。
    static let legacyBundleID = "xyz.voice.zulangue"

    private static let legacyDirectoryName = "Zulangue"
    private static let currentDirectoryName = "ZuTalk"
    private static let legacyLockName = ".zulangue-core.lock"
    private static let legacyDatabaseStem = "zulangue.db"
    private static let currentDatabaseStem = "zutalk.db"
    private static let importMarkerKey = "zutalk.migration.legacyIdentityImported"

    private static var hasRun = false

    /// 启动时调用一次。测试环境跳过：单元测试用临时数据目录，UI 测试要的是
    /// 出厂状态，两者都不该被真实用户的老数据污染。
    static func runIfNeeded() {
        guard TestEnvironment.isAnyTestMode == false else { return }
        guard hasRun == false else { return }
        hasRun = true

        migrateDataDirectory()
        migrateUserDefaults()
    }

    // MARK: - 数据目录

    private static func migrateDataDirectory() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }

        let legacy = appSupport.appendingPathComponent(legacyDirectoryName, isDirectory: true)
        let current = appSupport.appendingPathComponent(currentDirectoryName, isDirectory: true)

        var legacyIsDirectory: ObjCBool = false
        guard fm.fileExists(atPath: legacy.path, isDirectory: &legacyIsDirectory),
              legacyIsDirectory.boolValue
        else { return }

        // 老 app 可能正开着 —— 改了 bundle ID 之后新旧两个 app 在 macOS 眼里是
        // 两个程序，能同时运行。此时搬目录会让两个进程各自持有一个锁文件、
        // 却写同一个库。宁可这次不搬。
        guard legacyDataDirectoryIsIdle(legacy) else { return }

        var currentIsDirectory: ObjCBool = false
        if fm.fileExists(atPath: current.path, isDirectory: &currentIsDirectory) {
            guard currentIsDirectory.boolValue else { return }
            // 新目录里已经有东西，说明用户在新版里录过了。老数据不该覆盖它。
            let contents = (try? fm.contentsOfDirectory(atPath: current.path)) ?? []
            guard contents.isEmpty else { return }
            try? fm.removeItem(at: current)
        }

        do {
            try fm.moveItem(at: legacy, to: current)
        } catch {
            return
        }
        renameLegacyFiles(in: current)
    }

    /// 老数据目录是否无人持有。锁文件不存在（老版本没跑过或已清理）也算无人。
    private static func legacyDataDirectoryIsIdle(_ directory: URL) -> Bool {
        let lock = directory.appendingPathComponent(legacyLockName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: lock.path) else { return true }

        let descriptor = open(lock.path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        // 拿得到独占锁，就说明写锁的那个进程已经退出。
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        flock(descriptor, LOCK_UN)
        return true
    }

    private static func renameLegacyFiles(in directory: URL) {
        let fm = FileManager.default

        // -wal / -shm 必须跟主库同名一起改：SQLite 靠文件名找它们，落下一个
        // 就等于丢掉尚未 checkpoint 的那批写入。
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let old = directory.appendingPathComponent(legacyDatabaseStem + suffix, isDirectory: false)
            let new = directory.appendingPathComponent(currentDatabaseStem + suffix, isDirectory: false)
            guard fm.fileExists(atPath: old.path),
                  fm.fileExists(atPath: new.path) == false
            else { continue }
            try? fm.moveItem(at: old, to: new)
        }

        // 上面已确认它无主，留着只会让人以为还有别的进程占着数据目录。
        try? fm.removeItem(at: directory.appendingPathComponent(legacyLockName, isDirectory: false))
    }

    // MARK: - 偏好设置

    private static func migrateUserDefaults() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: importMarkerKey) == false else { return }

        let legacyDomain = legacyBundleID as CFString
        let keys = CFPreferencesCopyKeyList(
            legacyDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String]

        for key in keys ?? [] {
            guard let value = CFPreferencesCopyAppValue(key as CFString, legacyDomain) else {
                continue
            }
            // 键名本身也带着旧名字（zutalk.subtitleOverlay.* 这些），要一起改。
            let renamed = rename(key)
            // 新域里已经有值，说明用户在新版里设过了 —— 老值不覆盖。
            guard defaults.object(forKey: renamed) == nil else { continue }
            defaults.set(value, forKey: renamed)
        }

        defaults.set(true, forKey: importMarkerKey)
    }

    /// 与仓库改名同一套大小写映射，用在偏好设置的键名上。
    private static func rename(_ text: String) -> String {
        var renamed = text
        for (old, new) in [
            ("ZULANGUE", "ZUTALK"),
            ("ZuLangue", "ZuTalk"),
            ("Zulangue", "ZuTalk"),
            ("zulangue", "zutalk"),
        ] {
            renamed = renamed.replacingOccurrences(of: old, with: new)
        }
        return renamed
    }
}
