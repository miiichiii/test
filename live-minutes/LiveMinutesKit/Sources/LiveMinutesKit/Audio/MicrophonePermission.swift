import AVFoundation

/// マイクの使用許可。テストでは偽物に差し替える。
public protocol MicrophonePermission: Sendable {
    /// 許可済みなら true。未決定なら許可を求め、その結果を返す。拒否・制限されていれば false。
    func requestAccessIfNeeded() async -> Bool
}

/// macOS のマイク許可（AVCaptureDevice）。macOS には AVAudioSession がないので、こちらで求める。
public struct SystemMicrophonePermission: MicrophonePermission {
    public init() {}

    public func requestAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }
}
