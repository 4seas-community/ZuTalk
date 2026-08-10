// Recording-domain models shared across Capture / MenuBar / Pages. Lives in
// `Capture/` because these types describe what a recording session looks like
// (its elapsed time, paused state, transcript lines, etc.);
// they were temporarily housed under `MenuBar/` during the Dynamic-Island rip
// and now sit beside the Notebook-owned capture runtime.

import Foundation
import SwiftUI

/// Snapshot of the active recording, mutated through
/// `MenuBarRuntimeStore.updateRecording` on each timer tick and on
/// pause and capture-state changes.
struct RecordingInfo: Equatable {
    var sessionId: String? = nil
    var remoteRealtimeEnabled: Bool = false
    var elapsed: TimeInterval = 0
    var isPaused: Bool = false
    var languagePair: String = "EN · 中"
    var engine: String = "SONIOX RT5"
    var captureState: NotebookCaptureState = .recording
    var remoteHealth: NotebookRemoteHealth = .off
    var projectionState: NotebookProjectionState = .pending
    var latencyMs: Int = 187
    var encryptionLabel: String = "AES-256"

    var elapsedString: String {
        let h = Int(elapsed) / 3600
        let m = (Int(elapsed) % 3600) / 60
        let s = Int(elapsed) % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

/// One line of live transcript shown in the recording popover's transcript
/// preview block. Live capture supplies the stable utterance id so replacing a
/// speculative tail updates one row instead of deleting and inserting it.
struct TranscriptLine: Equatable, Identifiable {
    let id: String
    var timestamp: String
    var languageLabel: String
    var text: String

    init(
        id: String = UUID().uuidString,
        timestamp: String,
        languageLabel: String,
        text: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.languageLabel = languageLabel
        self.text = text
    }

    static func == (lhs: TranscriptLine, rhs: TranscriptLine) -> Bool {
        lhs.id == rhs.id
            && lhs.timestamp == rhs.timestamp
            && lhs.languageLabel == rhs.languageLabel
            && lhs.text == rhs.text
    }
}

/// Snapshot of an explicit asynchronous transcription shown
/// in the popover when `MenuBarRuntimeStore.state == .backgroundProcessing`.
struct ProcessingInfo: Equatable {
    enum Stage {
        case transcribing
        case completed
    }

    var stage: Stage
    var progress: Double
    var sessionId: String

    var label: String {
        switch stage {
        case .transcribing: return "Transcribing…"
        case .completed: return "Ready in Home"
        }
    }

    var color: Color {
        switch stage {
        case .transcribing: return .signalBlue
        case .completed: return .signalGreen
        }
    }
}
