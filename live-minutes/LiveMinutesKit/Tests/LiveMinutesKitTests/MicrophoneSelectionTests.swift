import Foundation
import Testing
@testable import LiveMinutesKit

/// マイクの選択のテスト（Phase 4C）。実際のマイクで録音はしない。
@Suite("マイクの選択")
struct MicrophoneSelectionTests {
    static let builtIn = AudioInputDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro のマイク")
    static let usb = AudioInputDevice(uid: "AppleUSBAudioEngine:Vendor:Mic:1234:1", name: "USB マイク")

    @Test("使うべきマイク: 選ばれていて、つながっていればその UID。そうでなければ Mac の設定のマイク（nil）")
    func target() {
        let available = [Self.builtIn.uid, Self.usb.uid]
        #expect(InputDeviceSelection.target(preferredUID: Self.usb.uid, availableUIDs: available) == Self.usb.uid)
        #expect(InputDeviceSelection.target(preferredUID: Self.usb.uid, availableUIDs: [Self.builtIn.uid]) == nil)
        #expect(InputDeviceSelection.target(preferredUID: nil, availableUIDs: available) == nil)
        #expect(InputDeviceSelection.target(preferredUID: "", availableUIDs: available) == nil)
        // 作り直しが続いて止めている間は、つながっていても使わない。
        #expect(InputDeviceSelection.target(preferredUID: Self.usb.uid, availableUIDs: available, suppressed: true) == nil)
    }

    @Test("作り直すのは、今使っているマイクと使うべきマイクが違うときだけ（同じなら何もしない）")
    func needsRebuild() {
        #expect(InputDeviceSelection.needsRebuild(currentUID: nil, targetUID: nil) == false)
        #expect(InputDeviceSelection.needsRebuild(currentUID: Self.usb.uid, targetUID: Self.usb.uid) == false)
        // 選んだマイクがつながった → 戻す。抜けた → Mac の設定のマイクへ。
        #expect(InputDeviceSelection.needsRebuild(currentUID: nil, targetUID: Self.usb.uid))
        #expect(InputDeviceSelection.needsRebuild(currentUID: Self.usb.uid, targetUID: nil))
        #expect(InputDeviceSelection.needsRebuild(currentUID: Self.builtIn.uid, targetUID: Self.usb.uid))
    }

    @Test("選択欄: 既定（今の名前つき）、一覧、つながっていない保存済みのマイク")
    func options() {
        let connected = InputDeviceSelection.options(
            savedUID: Self.usb.uid, savedName: "USB マイク", devices: [Self.builtIn, Self.usb], defaultDeviceName: Self.builtIn.name
        )
        #expect(connected.map(\.tag) == ["", Self.builtIn.uid, Self.usb.uid])
        #expect(connected.first?.label == "Mac の設定に従う（MacBook Pro のマイク）")

        let disconnected = InputDeviceSelection.options(
            savedUID: Self.usb.uid, savedName: "USB マイク", devices: [Self.builtIn], defaultDeviceName: nil
        )
        #expect(disconnected.map(\.tag) == ["", Self.builtIn.uid, Self.usb.uid])
        #expect(disconnected.first?.label == "Mac の設定に従う")
        #expect(disconnected.last?.label == "（未接続）USB マイク")

        // 名前を保存していなければ UID を出す。
        let noName = InputDeviceSelection.options(savedUID: "uid-x", savedName: "", devices: [], defaultDeviceName: nil)
        #expect(noName.last?.label == "（未接続）uid-x")
        // 一覧を読む前は、保存済みのマイクを「未接続」と書かない（読み終えるまでの一瞬の誤表示を防ぐ）。
        let beforeLoad = InputDeviceSelection.options(
            savedUID: Self.usb.uid, savedName: "USB マイク", devices: [], defaultDeviceName: nil, isListLoaded: false
        )
        #expect(beforeLoad.last?.label == "USB マイク")
        // 既定を選んでいるときは、未接続の行を足さない。
        #expect(InputDeviceSelection.options(savedUID: "", savedName: "", devices: [], defaultDeviceName: nil).count == 1)
    }

    @Test("作り直しは10秒の間に5回までは普通。6回目で上限を超えたと知らせ、窓を過ぎれば数え直す")
    func rebuildLimiter() {
        var limiter = RebuildLimiter()
        let start = ContinuousClock.now
        for index in 0..<5 {
            let exceeded = limiter.record(at: start + .seconds(index))
            #expect(exceeded == false)
        }
        let sixth = limiter.record(at: start + .seconds(5))
        #expect(sixth)
        var spaced = RebuildLimiter()
        for index in 0..<10 {
            let exceeded = spaced.record(at: start + .seconds(index * 3))
            #expect(exceeded == false)
        }
        spaced.reset()
        let afterReset = spaced.record(at: start)
        #expect(afterReset == false)
    }

    @Test("一覧の取得は落ちない（中身は機材によるので、形だけを確かめる。装置が0個でも通る）")
    func listShape() {
        let devices = AudioInputDevices.list()
        #expect(Set(devices.map(\.uid)).count == devices.count)
        for device in devices {
            #expect(!device.uid.isEmpty)
            #expect(!device.name.isEmpty)
            #expect(AudioInputDevices.deviceID(forUID: device.uid) != nil)
        }
        if let defaultInput = AudioInputDevices.defaultInput() {
            #expect(devices.contains(defaultInput))
        }
        #expect(AudioInputDevices.deviceID(forUID: "LiveMinutes.no-such-device") == nil)
    }

    @Test("一覧の変化の通知は、作ってすぐ捨てても、読み始めてからキャンセルしても落ちない")
    func changesLifecycle() async {
        _ = AudioInputDevices.changes()
        let reading = Task {
            for await _ in AudioInputDevices.changes() {}
        }
        try? await Task.sleep(for: .milliseconds(50))
        reading.cancel()
        await reading.value
    }

    @Test("録音していないときに選び直しても、何も始めない（落ちない）")
    func setPreferredWhileStopped() async {
        let microphone = MicrophoneSource(preferredDeviceUID: "LiveMinutes.no-such-device")
        await microphone.setPreferredDevice(uid: nil)
        await microphone.setPreferredDevice(uid: "")
        await microphone.stop()
    }
}

@MainActor
@Suite("マイクの一覧（設定画面）")
struct AudioInputDeviceListTests {
    final class Source: @unchecked Sendable {
        // @unchecked の理由: テストの中で、MainActor からだけ書き換える。load は MainActor の refresh から呼ばれる。
        var devices: [AudioInputDevice] = []
        var defaultDevice: AudioInputDevice?
    }

    @Test("一覧の変化の通知が来たら読み直す。画面を閉じたら（キャンセル）聞くのをやめる")
    func refreshesOnChange() async {
        let source = Source()
        source.devices = [MicrophoneSelectionTests.builtIn]
        source.defaultDevice = MicrophoneSelectionTests.builtIn
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        let list = AudioInputDeviceList(load: { (source.devices, source.defaultDevice) }, changes: { stream })

        let observing = Task { await list.observe() }
        await waitUntil { list.devices == [MicrophoneSelectionTests.builtIn] }
        #expect(list.options(savedUID: "", savedName: "").first?.label == "Mac の設定に従う（MacBook Pro のマイク）")

        source.devices = [MicrophoneSelectionTests.builtIn, MicrophoneSelectionTests.usb]
        continuation.yield()
        await waitUntil { list.devices.count == 2 }

        observing.cancel()
        continuation.finish()
        await observing.value
    }
}
