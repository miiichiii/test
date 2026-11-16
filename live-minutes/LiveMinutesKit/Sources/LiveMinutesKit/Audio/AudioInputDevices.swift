import CoreAudio
import Foundation

/// 入力を持つ音声デバイス（DESIGN.md §4.1「マイクの選択」）。
public struct AudioInputDevice: Equatable, Hashable, Sendable, Identifiable {
    /// `kAudioDevicePropertyDeviceUID`。抜き差ししても変わらないので、保存にはこれを使う
    public let uid: String
    public let name: String

    public var id: String { uid }

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

/// Core Audio の入力デバイスの一覧と、その変化の通知。
public enum AudioInputDevices {
    /// 入力を持つデバイスの一覧（Core Audio が返す順）。仮想デバイスや集約デバイスも外さない
    public static func list() -> [AudioInputDevice] {
        allDeviceIDs().compactMap(inputDevice(for:))
    }

    /// Mac の設定で選ばれている入力デバイス
    public static func defaultInput() -> AudioInputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return inputDevice(for: deviceID)
    }

    /// UID に当たる、入力を持つデバイスの ID。つながっていなければ nil
    static func deviceID(forUID uid: String) -> AudioObjectID? {
        allDeviceIDs().first { self.uid(of: $0) == uid && inputChannelCount(of: $0) > 0 }
    }

    /// デバイスの一覧か、Mac の設定の入力デバイスが変わったら流す（最新の1件だけ溜める）。
    ///
    /// 呼ぶたびに新しいリスナーとストリームを作る。ストリームが終わったらリスナーを外す。
    public static func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let registration = ListenerRegistration(
            selectors: [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]
        ) { _, _ in
            // ここでは yield だけを行う（引数のポインタは持ち出さない）。
            continuation.yield()
        }
        continuation.onTermination = { _ in registration.remove() }
        return stream
    }

    // MARK: - Core Audio

    private static func allDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func inputDevice(for id: AudioObjectID) -> AudioInputDevice? {
        guard inputChannelCount(of: id) > 0, let uid = uid(of: id), !uid.isEmpty else { return nil }
        return AudioInputDevice(uid: uid, name: name(of: id) ?? uid)
    }

    /// 入力スコープのチャンネル数の合計（ストリームはあるが 0ch のデバイスを外すため）
    static func inputChannelCount(of id: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func uid(of id: AudioObjectID) -> String? {
        stringProperty(id, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func name(of id: AudioObjectID) -> String? {
        stringProperty(id, selector: kAudioObjectPropertyName)
    }

    /// CFString のプロパティを読む（呼び出し側が解放する、とヘッダにあるので retained として受け取る）。
    private static func stringProperty(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// Core Audio のリスナーの登録。追加と削除に同じブロックの値とキューを渡す（クロージャを2回書くと別のブロックになり、外れない）。
final class ListenerRegistration: @unchecked Sendable {
    // @unchecked の理由: フィールドはすべて let。可変の状態は isRemoved だけで、remove はキューの上で直列に行う。
    // ブロック（AudioObjectPropertyListenerBlock）は Sendable ではないが、作った後は変えず、Core Audio に渡すだけ。
    private let block: AudioObjectPropertyListenerBlock
    private let queue = DispatchQueue(label: "LiveMinutes.AudioInputDevices.listener")
    private let addresses: [AudioObjectPropertyAddress]
    private var isRemoved = false

    init(selectors: [AudioObjectPropertySelector], block: @escaping AudioObjectPropertyListenerBlock) {
        self.block = block
        addresses = selectors.map {
            AudioObjectPropertyAddress(mSelector: $0, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        }
        for var address in addresses {
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }
    }

    func remove() {
        queue.async { [self] in
            guard !isRemoved else { return }
            isRemoved = true
            for var address in addresses {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
            }
        }
    }
}

/// マイクの選択の決め方（純粋な関数。テストできるように分ける）。
public enum InputDeviceSelection {
    /// 選択欄の1項目。`tag` が空なら「Mac の設定に従う」
    public struct Option: Equatable, Hashable, Sendable, Identifiable {
        public let tag: String
        public let label: String
        public var id: String { tag }
    }

    /// 今使うべきマイクの UID。選ばれていない・つながっていない・上限で止めた場合は nil（Mac の設定のマイク）
    public static func target(preferredUID: String?, availableUIDs: [String], suppressed: Bool = false) -> String? {
        guard !suppressed, let preferredUID, !preferredUID.isEmpty, availableUIDs.contains(preferredUID) else { return nil }
        return preferredUID
    }

    /// エンジンを作り直すか（今のエンジンが使っているマイクと、今使うべきマイクが違うときだけ）
    public static func needsRebuild(currentUID: String?, targetUID: String?) -> Bool {
        currentUID != targetUID
    }

    /// 選択欄の項目（既定・一覧・未接続の行）
    /// - Parameter isListLoaded: 一覧を読み終えたか。読む前は、保存済みのマイクを「未接続」と書かない
    public static func options(
        savedUID: String,
        savedName: String,
        devices: [AudioInputDevice],
        defaultDeviceName: String?,
        isListLoaded: Bool = true
    ) -> [Option] {
        let defaultLabel = defaultDeviceName.map { "Mac の設定に従う（\($0)）" } ?? "Mac の設定に従う"
        var options = [Option(tag: "", label: defaultLabel)]
        options += devices.map { Option(tag: $0.uid, label: $0.name) }
        if !savedUID.isEmpty, !devices.contains(where: { $0.uid == savedUID }) {
            // 選ばれたままにする（項目がないと Picker が不正な選択になる）。
            let name = savedName.isEmpty ? savedUID : savedName
            options.append(Option(tag: savedUID, label: isListLoaded ? "（未接続）\(name)" : name))
        }
        return options
    }
}

/// 作り直しの回数を数え、短い間に続きすぎたら知らせる（ループを防ぐ）。
struct RebuildLimiter {
    let window: Duration
    let maxCount: Int
    private var times: [ContinuousClock.Instant] = []

    init(window: Duration = .seconds(10), maxCount: Int = 5) {
        self.window = window
        self.maxCount = maxCount
    }

    /// 作り直しを1回数える。窓の中の回数が上限を超えたら true
    mutating func record(at now: ContinuousClock.Instant) -> Bool {
        times.removeAll { now - $0 > window }
        times.append(now)
        return times.count > maxCount
    }

    mutating func reset() {
        times.removeAll()
    }
}
