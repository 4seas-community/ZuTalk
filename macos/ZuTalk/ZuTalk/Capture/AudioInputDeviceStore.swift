import AudioToolbox
import Combine
import CoreAudio
import Foundation

struct AudioInputDevice: Equatable, Identifiable {
    let deviceID: AudioDeviceID
    let uid: String
    let name: String

    var id: String { uid }
}

struct AudioInputDeviceSnapshot: Equatable {
    let devices: [AudioInputDevice]
    let defaultInputDeviceID: AudioDeviceID?

    var defaultInputDevice: AudioInputDevice? {
        guard let defaultInputDeviceID else { return nil }
        return devices.first { $0.deviceID == defaultInputDeviceID }
    }
}

protocol AudioInputDeviceCataloging {
    func snapshot() throws -> AudioInputDeviceSnapshot
}

enum AudioInputDeviceError: Error, Equatable, LocalizedError {
    case queryFailed(operation: String, status: OSStatus)
    case noInputDevice
    case selectedDeviceUnavailable(name: String)
    case audioUnitUnavailable(name: String)
    case bindingFailed(name: String, status: OSStatus)
    case switchUnavailable

    var errorDescription: String? {
        switch self {
        case .queryFailed(let operation, let status):
            return String(
                format: String(localized: "settings.audio_input.error.query_format"),
                operation,
                String(status)
            )
        case .noInputDevice:
            return String(localized: "settings.audio_input.error.no_device")
        case .selectedDeviceUnavailable(let name):
            return String(
                format: String(localized: "settings.audio_input.error.unavailable_format"),
                name
            )
        case .audioUnitUnavailable(let name):
            return String(
                format: String(localized: "settings.audio_input.error.audio_unit_format"),
                name
            )
        case .bindingFailed(let name, let status):
            return String(
                format: String(localized: "settings.audio_input.error.binding_format"),
                name,
                String(status)
            )
        case .switchUnavailable:
            return String(localized: "settings.audio_input.error.switch_unavailable")
        }
    }
}

struct CoreAudioInputDeviceCatalog: AudioInputDeviceCataloging {
    func snapshot() throws -> AudioInputDeviceSnapshot {
        let deviceIDs = try readDeviceIDs()
        let devices = deviceIDs.compactMap { deviceID -> AudioInputDevice? in
            guard ((try? inputChannelCount(deviceID)) ?? 0) > 0,
                  (try? isAlive(deviceID)) != false,
                  let uid = try? readString(
                      objectID: deviceID,
                      selector: kAudioDevicePropertyDeviceUID,
                      operation: "device UID"
                  )
            else { return nil }

            let name = (try? readString(
                objectID: deviceID,
                selector: kAudioObjectPropertyName,
                operation: "device name"
            )) ?? uid
            return AudioInputDevice(deviceID: deviceID, uid: uid, name: name)
        }
        .sorted { left, right in
            let order = left.name.localizedStandardCompare(right.name)
            return order == .orderedSame ? left.uid < right.uid : order == .orderedAscending
        }

        return AudioInputDeviceSnapshot(
            devices: devices,
            defaultInputDeviceID: try readDefaultInputDeviceID()
        )
    }

    private func readDeviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &byteCount
        )
        guard status == noErr else {
            throw AudioInputDeviceError.queryFailed(operation: "device list", status: status)
        }

        let count = Int(byteCount) / MemoryLayout<AudioDeviceID>.stride
        guard count > 0 else { return [] }
        var deviceIDs = [AudioDeviceID](repeating: kAudioObjectUnknown, count: count)
        status = deviceIDs.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &byteCount,
                bytes.baseAddress!
            )
        }
        guard status == noErr else {
            throw AudioInputDeviceError.queryFailed(operation: "device list", status: status)
        }
        return deviceIDs
    }

    private func readDefaultInputDeviceID() throws -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var byteCount = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &byteCount,
            &deviceID
        )
        guard status == noErr else {
            throw AudioInputDeviceError.queryFailed(operation: "default input", status: status)
        }
        return deviceID == kAudioObjectUnknown ? nil : deviceID
    }

    private func inputChannelCount(_ deviceID: AudioDeviceID) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return 0 }
        var byteCount: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &byteCount)
        guard status == noErr else {
            throw AudioInputDeviceError.queryFailed(operation: "input channels", status: status)
        }
        guard byteCount >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(byteCount),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        var mutableByteCount = byteCount
        let readStatus = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &mutableByteCount,
            storage
        )
        guard readStatus == noErr else {
            throw AudioInputDeviceError.queryFailed(
                operation: "input channels",
                status: readStatus
            )
        }

        let buffers = UnsafeMutableAudioBufferListPointer(
            storage.assumingMemoryBound(to: AudioBufferList.self)
        )
        return buffers.reduce(0) { $0 + $1.mNumberChannels }
    }

    private func isAlive(_ deviceID: AudioDeviceID) throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return true }
        var value: UInt32 = 0
        var byteCount = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &byteCount,
            &value
        )
        guard status == noErr else {
            throw AudioInputDeviceError.queryFailed(operation: "device availability", status: status)
        }
        return value != 0
    }

    private func readString(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        operation: String
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var byteCount = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &byteCount,
            &value
        )
        guard status == noErr, let value else {
            throw AudioInputDeviceError.queryFailed(operation: operation, status: status)
        }
        return value.takeRetainedValue() as String
    }
}

@MainActor
final class AudioInputDeviceStore: ObservableObject {
    static let shared = AudioInputDeviceStore()

    private enum DefaultsKey {
        static let selectedUID = "audio.input.deviceUID"
        static let selectedName = "audio.input.deviceName"
    }

    @Published private(set) var devices: [AudioInputDevice] = []
    @Published private(set) var defaultInputDeviceID: AudioDeviceID?
    @Published private(set) var selectedUID: String?
    @Published private(set) var selectedDeviceLastKnownName: String?
    @Published private(set) var refreshError: String?
    @Published private(set) var hasLoadedSnapshot = false

    private let catalog: any AudioInputDeviceCataloging
    private let defaults: UserDefaults

    init(
        catalog: (any AudioInputDeviceCataloging)? = nil,
        defaults: UserDefaults? = nil
    ) {
        self.catalog = catalog ?? CoreAudioInputDeviceCatalog()
        let resolvedDefaults = defaults ?? .standard
        self.defaults = resolvedDefaults
        let storedUID = resolvedDefaults.string(forKey: DefaultsKey.selectedUID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        selectedUID = storedUID.flatMap { $0.isEmpty ? nil : $0 }
        selectedDeviceLastKnownName = resolvedDefaults.string(forKey: DefaultsKey.selectedName)
    }

    var defaultInputDevice: AudioInputDevice? {
        guard let defaultInputDeviceID else { return nil }
        return devices.first { $0.deviceID == defaultInputDeviceID }
    }

    var selectedDevice: AudioInputDevice? {
        guard let selectedUID else { return defaultInputDevice }
        return devices.first { $0.uid == selectedUID }
    }

    var isExplicitSelectionUnavailable: Bool {
        guard hasLoadedSnapshot, let selectedUID else { return false }
        return devices.contains { $0.uid == selectedUID } == false
    }

    func select(uid: String?) {
        let normalized = uid?.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedUID = normalized.flatMap { $0.isEmpty ? nil : $0 }
        refreshError = nil

        if let selectedUID {
            defaults.set(selectedUID, forKey: DefaultsKey.selectedUID)
            if let name = devices.first(where: { $0.uid == selectedUID })?.name {
                selectedDeviceLastKnownName = name
                defaults.set(name, forKey: DefaultsKey.selectedName)
            }
        } else {
            selectedDeviceLastKnownName = nil
            defaults.removeObject(forKey: DefaultsKey.selectedUID)
            defaults.removeObject(forKey: DefaultsKey.selectedName)
        }
    }

    func refresh() {
        do {
            apply(try catalog.snapshot())
            refreshError = nil
        } catch {
            hasLoadedSnapshot = true
            refreshError = error.localizedDescription
        }
    }

    /// Resolves a stable UID to the current process-local AudioDeviceID. The
    /// result is called once before a capture starts and then frozen by the
    /// live audio source for pause/resume.
    func resolveDeviceForCapture() throws -> AudioInputDevice {
        try resolveDevice(uid: selectedUID)
    }

    /// Resolves a requested preference without committing it. This lets an
    /// active capture validate a new device before it tears down the old tap.
    func resolveDevice(uid: String?) throws -> AudioInputDevice {
        let snapshot = try catalog.snapshot()
        apply(snapshot)
        refreshError = nil

        let trimmedUID = uid?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUID = trimmedUID?.isEmpty == false ? trimmedUID : nil
        if let normalizedUID {
            guard let selected = snapshot.devices.first(where: { $0.uid == normalizedUID }) else {
                throw AudioInputDeviceError.selectedDeviceUnavailable(
                    name: normalizedUID == selectedUID
                        ? (selectedDeviceLastKnownName ?? normalizedUID)
                        : normalizedUID
                )
            }
            return selected
        }

        guard let selected = snapshot.defaultInputDevice else {
            throw AudioInputDeviceError.noInputDevice
        }
        return selected
    }

    private func apply(_ snapshot: AudioInputDeviceSnapshot) {
        devices = snapshot.devices
        defaultInputDeviceID = snapshot.defaultInputDeviceID
        hasLoadedSnapshot = true
        if let selectedUID,
           let name = snapshot.devices.first(where: { $0.uid == selectedUID })?.name {
            rememberName(name)
        }
    }

    private func rememberName(_ name: String) {
        selectedDeviceLastKnownName = name
        defaults.set(name, forKey: DefaultsKey.selectedName)
    }
}
