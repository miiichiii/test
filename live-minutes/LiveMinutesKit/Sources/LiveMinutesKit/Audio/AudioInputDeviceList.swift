import Foundation
import Observation

/// 設定画面が読む入力デバイスの一覧（DESIGN.md §4.1「マイクの選択」）。
///
/// 一覧の変化は、設定画面を開いている間（`observe()` を待っている間）だけ聞く。
@MainActor
@Observable
public final class AudioInputDeviceList {
    public private(set) var devices: [AudioInputDevice] = []
    public private(set) var defaultDevice: AudioInputDevice?
    /// 一覧を一度でも読んだか
    public private(set) var isLoaded = false

    @ObservationIgnored private let load: @Sendable () -> ([AudioInputDevice], AudioInputDevice?)
    @ObservationIgnored private let changes: @Sendable () -> AsyncStream<Void>

    /// - Parameters:
    ///   - load: 一覧と、Mac の設定の入力デバイスを読む。テストでは決まった値を返すものに差し替える
    ///   - changes: 一覧の変化の通知
    public init(
        load: @escaping @Sendable () -> ([AudioInputDevice], AudioInputDevice?) = {
            (AudioInputDevices.list(), AudioInputDevices.defaultInput())
        },
        changes: @escaping @Sendable () -> AsyncStream<Void> = { AudioInputDevices.changes() }
    ) {
        self.load = load
        self.changes = changes
    }

    /// 一覧を読み、変化に合わせて読み直す。呼んだ側の Task がキャンセルされたら（画面を閉じたら）終わる。
    public func observe() async {
        let updates = changes()
        refresh()
        for await _ in updates {
            refresh()
        }
    }

    public func refresh() {
        let (list, defaultInput) = load()
        if list != devices { devices = list }
        if defaultInput != defaultDevice { defaultDevice = defaultInput }
        if !isLoaded { isLoaded = true }
    }

    /// 選択欄の項目
    public func options(savedUID: String, savedName: String) -> [InputDeviceSelection.Option] {
        InputDeviceSelection.options(
            savedUID: savedUID,
            savedName: savedName,
            devices: devices,
            defaultDeviceName: defaultDevice?.name,
            isListLoaded: isLoaded
        )
    }
}
