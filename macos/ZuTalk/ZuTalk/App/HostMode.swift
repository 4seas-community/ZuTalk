// HostMode.swift
// 「我在主持活动」:一个按场合说的开关。
//
// ZuTalk 有两种用的人。大多数人只要录、看、停、把字贴走;主持一场活动的人
// 还要给观众看字幕、把文字稿交到城的档案馆。后一种的入口摆给所有人看,前一种
// 人就得先弄懂它们才敢按开始。所以这些入口只在这个开关打开时出现
// (docs/product/interface-layers.md)。
//
// 开关问的是场合,不是水平:人不用判断自己算不算「高级用户」。
//
// 两条规矩:
//   - 人还没碰过开关时,登录了城的身份就算开着 —— 那个人已经在用这些工具了。
//   - 正在用的东西不因为开关关着而消失。直播正在进行、录音已经归了活动,
//     对应的控件照样在;由各个视图自己用 `shows(inUse:)` 判断。

import Combine
import Foundation

@MainActor
final class HostMode: ObservableObject {
    static let shared = HostMode()

    static let defaultsKey = "capture.host_mode.enabled"

    /// What the person chose; nil until they touch the switch.
    @Published private(set) var choice: Bool?
    /// A city identity is signed in on this Mac: the answer until a choice is made.
    @Published private(set) var signedIn: Bool

    private let defaults: UserDefaults
    private var observer: AnyCancellable?

    /// Whether the tools for hosting an event are offered.
    var isOn: Bool { choice ?? signedIn }

    /// `signedIn` is the live answer to "is a city identity signed in"; the
    /// shared instance follows `CityStore`, tests pass their own.
    init(
        defaults: UserDefaults = .standard,
        initiallySignedIn: Bool? = nil,
        signedIn: AnyPublisher<Bool, Never>? = nil
    ) {
        self.defaults = defaults
        choice = defaults.object(forKey: Self.defaultsKey) as? Bool
        let city = signedIn == nil ? CityStore.shared : nil
        self.signedIn = initiallySignedIn ?? (city?.account != nil)
        let source = signedIn
            ?? city?.$account.map { $0 != nil }.eraseToAnyPublisher()
        observer = source?
            .removeDuplicates()
            .sink { [weak self] value in
                guard let self, self.signedIn != value else { return }
                self.signedIn = value
            }
    }

    func set(_ on: Bool) {
        choice = on
        defaults.set(on, forKey: Self.defaultsKey)
    }

    /// A control that belongs to hosting shows when hosting is on, or when
    /// the thing it controls is already running — turning the switch off
    /// must never hide the only way to stop a live share or change where a
    /// recording is filed.
    func shows(inUse: Bool) -> Bool {
        isOn || inUse
    }
}
