import Foundation

enum RecordingLiveError: Error, LocalizedError {
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission denied. Open System Settings → Privacy & Security → Microphone and enable Zulangue."
        }
    }
}
