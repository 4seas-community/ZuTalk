import SwiftUI

// MARK: - Audio input picker

/// Where a recording's sound comes from: a microphone, or what the Mac plays
/// (the far side of an online meeting). The Record page and a recording's
/// settings show this same control, so the choice made before Start is the
/// one the recording's settings show, and a switch mid-recording goes through
/// the same path.
struct AudioInputPicker: View {
    let notebookId: String
    var width: CGFloat = 280
    @ObservedObject private var capture = ActiveBilingualTranscriptStore.shared
    @ObservedObject private var inputDevices = AudioInputDeviceStore.shared

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Picker("", selection: selection) {
                Text(systemDefaultInputTitle).tag(String?.none)
                if inputDevices.isSystemAudioSupported {
                    Text(String(localized: "settings.audio_input.system_audio"))
                        .tag(Optional(AudioInputDevice.systemAudioUID))
                    Divider()
                }
                ForEach(inputDevices.devices) { device in
                    Text(device.name).tag(Optional(device.uid))
                }
                if inputDevices.isExplicitSelectionUnavailable,
                   let missingUID = inputDevices.selectedUID {
                    Text(unavailableInputTitle).tag(Optional(missingUID))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: width, alignment: .trailing)
            .disabled(selectionDisabled)
            .accessibilityLabel(Text(String(localized: "settings.audio_input.device")))

            Button {
                inputDevices.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundColor(.textSecondary)
            .disabled(capture.isAudioInputSwitching)
            .help(String(localized: "settings.audio_input.refresh"))
            .accessibilityLabel(Text(String(localized: "settings.audio_input.refresh")))
        }
    }

    private var selection: Binding<String?> {
        Binding(
            get: { inputDevices.selectedUID },
            set: { requestedUID in
                Task { @MainActor in
                    do {
                        try await capture.selectAudioInputDevice(
                            uid: requestedUID,
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
        )
    }

    private var selectionDisabled: Bool {
        capture.isAudioInputSwitching
            || capture.captureState == .draining
            || (capture.isCaptureActive && capture.notebookId != notebookId)
    }

    private var systemDefaultInputTitle: String {
        let resolvedDevice = inputDevices.selectedUID == nil && capture.isCaptureActive
            ? capture.activeAudioInputDevice
            : inputDevices.defaultInputDevice
        guard let name = resolvedDevice?.name else {
            return String(localized: "settings.audio_input.system_default")
        }
        return String(
            format: String(localized: "settings.audio_input.system_default_format"),
            name
        )
    }

    private var unavailableInputTitle: String {
        let name = inputDevices.selectedDeviceLastKnownName
            ?? inputDevices.selectedUID
            ?? String(localized: "settings.audio_input.device")
        return String(
            format: String(localized: "settings.audio_input.unavailable_format"),
            name
        )
    }
}
