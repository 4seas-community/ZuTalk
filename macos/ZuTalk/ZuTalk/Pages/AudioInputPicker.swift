import SwiftUI

// MARK: - The choices

/// What can be chosen as the sound source, in the order it is offered. The
/// pill in a topic's options and the pill on Home's start card both lay out
/// their menu from this, so the two never offer different things.
nonisolated enum AudioInputMenu {
    nonisolated enum Choice: Equatable, Sendable {
        /// Whatever microphone the system uses; its name when known.
        case systemDefault(name: String?)
        /// What the Mac plays.
        case soundFromMac
        case device(uid: String, name: String)
        /// The saved choice, when it is not plugged in right now.
        case unavailable(uid: String, name: String?)

        /// Tells the choices of one list apart.
        var id: String {
            switch self {
            case .systemDefault: return "default"
            case .soundFromMac: return "sound-from-mac"
            case .device(let uid, _): return "device:" + uid
            case .unavailable(let uid, _): return "unavailable:" + uid
            }
        }

        /// A line is drawn under the Mac's own sound: it is not a microphone.
        var endsGroup: Bool { self == .soundFromMac }
    }

    static func choices(
        devices: [AudioInputDevice],
        defaultName: String?,
        soundFromMacSupported: Bool,
        selectedUID: String?,
        selectionUnavailable: Bool,
        lastKnownName: String?
    ) -> [Choice] {
        var choices: [Choice] = [.systemDefault(name: defaultName)]
        if soundFromMacSupported {
            choices.append(.soundFromMac)
        }
        choices.append(contentsOf: devices.map { .device(uid: $0.uid, name: $0.name) })
        if selectionUnavailable, let selectedUID {
            choices.append(.unavailable(uid: selectedUID, name: lastKnownName))
        }
        return choices
    }
}

extension AudioInputMenu.Choice {
    /// What `AudioInputDeviceStore` stores for this choice.
    @MainActor
    var uid: String? {
        switch self {
        case .systemDefault: return nil
        case .soundFromMac: return AudioInputDevice.systemAudioUID
        case .device(let uid, _), .unavailable(let uid, _): return uid
        }
    }
}

extension AudioInputMenu {
    @MainActor
    static func choices(
        _ inputDevices: AudioInputDeviceStore,
        defaultDevice: AudioInputDevice?
    ) -> [Choice] {
        choices(
            devices: inputDevices.devices,
            defaultName: defaultDevice?.name,
            soundFromMacSupported: inputDevices.isSystemAudioSupported,
            selectedUID: inputDevices.selectedUID,
            selectionUnavailable: inputDevices.isExplicitSelectionUnavailable,
            lastKnownName: inputDevices.selectedDeviceLastKnownName
        )
    }

    @MainActor
    static func title(_ choice: Choice) -> String {
        switch choice {
        case .systemDefault(let name):
            guard let name else {
                return String(localized: "settings.audio_input.system_default")
            }
            return String(
                format: String(localized: "settings.audio_input.system_default_format"),
                name
            )
        case .soundFromMac:
            return String(localized: "audio_input.sound_from_mac")
        case .device(_, let name):
            return name
        case .unavailable(let uid, let name):
            return String(
                format: String(localized: "settings.audio_input.unavailable_format"),
                name ?? uid
            )
        }
    }

    /// Switches the source, and says so when it could not.
    @MainActor
    static func select(uid: String?, notebookId: String) {
        Task { @MainActor in
            do {
                try await ActiveBilingualTranscriptStore.shared.selectAudioInputDevice(
                    uid: uid,
                    notebookId: notebookId
                )
            } catch {
                ToastCenter.shared.error(
                    String(localized: "capture.toast.audio_input_switch_failed"),
                    detail: error.localizedDescription
                )
            }
        }
    }
}

// MARK: - Audio input picker

extension AudioInputMenu {
    /// Where the sound comes from right now, as the pill words it: the
    /// microphone, the Mac's own sound, or a microphone picked by hand.
    @MainActor
    static func source(_ inputDevices: AudioInputDeviceStore) -> RecordingPlan.Source {
        if inputDevices.isSystemAudioSelected { return .soundFromMac }
        // Following the system default is "the microphone"; one picked by
        // hand is named.
        guard inputDevices.selectedUID != nil else { return .thisMac }
        return .microphone(
            inputDevices.selectedDevice?.name ?? inputDevices.selectedDeviceLastKnownName ?? ""
        )
    }
}

/// Where a recording's sound comes from: a microphone, or what the Mac plays
/// (the far side of an online meeting). The control in a topic's options —
/// the same pill and the same choices as Home's start card, so the choice
/// made before Start is the one shown here, and a switch mid-recording goes
/// through the same path.
///
/// It differs from `AudioInputPill` only in what a recording in progress
/// asks of it: while this topic records on the system default, "default" is
/// the device the recording actually opened; and it cannot be switched from
/// here while another topic records.
struct AudioInputPicker: View {
    let notebookId: String
    @ObservedObject private var capture = ActiveBilingualTranscriptStore.shared
    @ObservedObject private var inputDevices = AudioInputDeviceStore.shared

    var body: some View {
        let sound = StartCardSound.resolve(AudioInputMenu.source(inputDevices))
        MenuPill(
            sound.title,
            titleIsName: sound.labelKey == nil,
            systemImage: sound.systemImage,
            tone: inputDevices.isExplicitSelectionUnavailable ? .warning : .normal,
            help: explanation,
            accessibilityLabel: String(localized: "settings.audio_input.title")
        ) {
            // The list may be a moment old; ask again for the next opening.
            inputDevices.refreshInBackground()
            var items: [PillMenuItem] = []
            for choice in choices {
                items.append(PillMenuItem(
                    AudioInputMenu.title(choice),
                    isOn: choice.uid == inputDevices.selectedUID
                ) {
                    AudioInputMenu.select(uid: choice.uid, notebookId: notebookId)
                })
                if choice.endsGroup {
                    items.append(.separator)
                }
            }
            items.append(.separator)
            items.append(PillMenuItem(String(localized: "settings.audio_input.refresh")) {
                inputDevices.refreshInBackground()
            })
            return items
        }
        .disabled(selectionDisabled)
    }

    private var choices: [AudioInputMenu.Choice] {
        // While this notebook records on the system default, the default is
        // whatever device the recording actually opened.
        AudioInputMenu.choices(
            inputDevices,
            defaultDevice: inputDevices.selectedUID == nil && capture.isCaptureActive
                ? capture.activeAudioInputDevice
                : inputDevices.defaultInputDevice
        )
    }

    private var selectionDisabled: Bool {
        capture.isAudioInputSwitching
            || capture.captureState == .draining
            || (capture.isCaptureActive && capture.notebookId != notebookId)
    }

    /// The sentences that used to be printed around the picker: what can be
    /// chosen, that the choice is this Mac's, which channel is recorded, and
    /// — during a recording — what switching costs.
    private var explanation: String {
        var lines = [
            String(localized: "settings.audio_input.subtitle"),
            String(localized: "settings.audio_input.local_scope"),
        ]
        if inputDevices.isSystemAudioSelected == false {
            lines.append(String(localized: "settings.audio_input.channel_one_hint"))
        }
        if capture.isCaptureActive, capture.notebookId == notebookId {
            lines.append(String(localized: "settings.audio_input.active_switch_hint"))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Audio input pill

/// The same choice as `AudioInputPicker`, as one pill on Home's start card:
/// an icon and a word for where the sound comes from, and the picker's own
/// choices in its menu.
struct AudioInputPill: View {
    let notebookId: String
    /// What the card worked out the source to be; the pill says it in a word.
    let source: RecordingPlan.Source
    @ObservedObject private var inputDevices = AudioInputDeviceStore.shared

    var body: some View {
        let sound = StartCardSound.resolve(source)
        MenuPill(
            sound.title,
            titleIsName: sound.labelKey == nil,
            systemImage: sound.systemImage,
            help: explanation,
            accessibilityLabel: String(localized: "record.page.input")
        ) {
            // The list may be a moment old; ask again for the next opening.
            inputDevices.refreshInBackground()
            var items: [PillMenuItem] = []
            for choice in AudioInputMenu.choices(
                inputDevices,
                defaultDevice: inputDevices.defaultInputDevice
            ) {
                items.append(PillMenuItem(
                    AudioInputMenu.title(choice),
                    isOn: choice.uid == inputDevices.selectedUID
                ) {
                    AudioInputMenu.select(uid: choice.uid, notebookId: notebookId)
                })
                if choice.endsGroup {
                    items.append(.separator)
                }
            }
            return items
        }
        .disabled(ActiveBilingualTranscriptStore.shared.isAudioInputSwitching)
    }

    /// The sentence that used to sit beside the picker: what each source is
    /// for, and which to choose for an online meeting.
    private var explanation: String {
        if inputDevices.isSystemAudioSelected {
            return String(localized: "record.page.input_detail_system_audio")
        }
        return String(localized: inputDevices.isSystemAudioSupported
            ? "home.options.source_detail_microphone_or_mac"
            : "record.page.input_detail_microphone")
    }
}
