// HotKeyManager.swift
// 全局快捷键注册（Carbon RegisterEventHotKey）

import AppKit
import Carbon.HIToolbox

// MARK: - HotKey Definition

struct HotKeyBinding {
    let id: UInt32              // 应用内唯一 id
    let signature: OSType       // 4-char OSType, e.g. 'VTHK'
    let keyCode: UInt32         // Carbon key code (e.g. kVK_ANSI_V)
    let modifiers: UInt32       // controlKey | optionKey | ...
    let action: () -> Void
}

// MARK: - HotKeyManager

/// 全局快捷键管理器
///
/// 用 Carbon RegisterEventHotKey API（macOS 上唯一可靠的全局热键 API）。
/// 默认绑定：⌃⌥R → 打开录音 Notebook。
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var bindings: [UInt32: HotKeyBinding] = [:]
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var isInstalled = false

    private init() {}

    // MARK: - Install

    /// 注册默认全局快捷键。
    func installDefaults(toggleRecording: @escaping () -> Void) {
        installEventHandler()

        let signature = OSType(0x56544B4B) // 'VTKK'
        let modifiers = UInt32(controlKey | optionKey)

        register(
            HotKeyBinding(
                id: 2,
                signature: signature,
                keyCode: UInt32(kVK_ANSI_R),
                modifiers: modifiers,
                action: toggleRecording
            )
        )
    }

    // MARK: - Register / Unregister

    func register(_ binding: HotKeyBinding) {
        let hotKeyID = EventHotKeyID(signature: binding.signature, id: binding.id)
        var hotKeyRef: EventHotKeyRef?

        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr, let ref = hotKeyRef {
            bindings[binding.id] = binding
            hotKeyRefs[binding.id] = ref
        } else {
            print("[HotKeyManager] Failed to register hot key id=\(binding.id), status=\(status)")
        }
        _ = hotKeyID // silence warning
    }

    func unregisterAll() {
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        bindings.removeAll()
    }

    // MARK: - Carbon event handler

    private func installEventHandler() {
        guard !isInstalled else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let context = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, userData) -> OSStatus in
                guard let userData = userData, let eventRef = eventRef else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()

                var hotKeyID = EventHotKeyID()
                let result = GetEventParameter(
                    eventRef,
                    OSType(kEventParamDirectObject),
                    OSType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                if result == noErr {
                    if let binding = manager.bindings[hotKeyID.id] {
                        DispatchQueue.main.async {
                            binding.action()
                        }
                    }
                }
                return noErr
            },
            1,
            &eventType,
            context,
            &eventHandler
        )

        if status == noErr {
            isInstalled = true
        } else {
            print("[HotKeyManager] InstallEventHandler failed: \(status)")
        }
    }
}
