import AppKit
import LiveMinutesKit
import SwiftUI

/// 設定画面: OpenAI への接続方法（API キー / ChatGPT プラン）、モデルID、接続テスト、認識言語。
struct SettingsView: View {
    @Bindable var settings: AppSettings
    let secretStore: any SecretStore
    let connectionTest: ConnectionTest
    let chatGPTAccount: ChatGPTAccount
    let inputDevices: AudioInputDeviceList
    let whisperModels: WhisperModelManager
    /// マイクを選び直したとき（UID。空なら Mac の設定のマイク）。録音中ならすぐに切り替える
    let onInputDeviceChange: (String) -> Void
    /// 認識言語の候補（BCP 47 の識別子）を読む
    let loadLocales: () async -> [String]
    /// 資格情報が変わったとき（API キーの保存・削除、接続方法の変更。会議中なら、その時点からノートの更新を始める・再開する）
    let onCredentialsChange: () -> Void

    @State private var apiKeyInput = ""
    /// 保存済みか。確かめるまでは nil
    @State private var hasAPIKey: Bool?
    @State private var keyMessage: KeyMessage?
    @State private var localeIdentifiers: [String] = []
    /// 用語の入力欄（1行に1つ）。入力中の改行を消さないよう、文字列のまま持ち、変わるたびに一覧にして保存する
    @State private var glossaryDraft = ""
    /// 保存・削除の処理中（連打で2本同時に走らせない）
    @State private var isUpdatingKey = false

    var body: some View {
        Form {
            Section("OpenAI") {
                Picker("接続方法", selection: $settings.authMethod) {
                    Text("API キー").tag(AuthMethod.apiKey)
                    Text("ChatGPT プラン").tag(AuthMethod.chatGPTPlan)
                }
                .pickerStyle(.segmented)

                switch settings.authMethod {
                case .apiKey:
                    apiKeyControls
                case .chatGPTPlan:
                    ChatGPTSignInControls(account: chatGPTAccount)
                }
            }

            Section("モデル") {
                TextField("ライブ更新（Luna）", text: $settings.liveModelID)
                TextField("議事録の仕上げ（Sol）", text: $settings.finalModelID)
                HStack(alignment: .firstTextBaseline) {
                    Button("接続テスト") {
                        Task {
                            await connectionTest.run(model: settings.effectiveLiveModelID, reasoningEffort: settings.liveReasoningEffort)
                        }
                    }
                    .disabled(connectionTest.status == .running)
                    ConnectionStatusView(status: connectionTest.status)
                }
                if let note = connectionTest.modelListNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("ライブ更新用のモデルに短いリクエストを1回送り、接続とモデルIDを確かめます（API キーでは料金がわずかにかかり、ChatGPT プランでは利用枠をわずかに使います）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("文字起こし") {
                Picker("マイク", selection: Binding(
                    get: { settings.inputDeviceUID },
                    set: { selectInputDevice($0) }
                )) {
                    ForEach(inputDevices.options(savedUID: settings.inputDeviceUID, savedName: settings.inputDeviceName)) { option in
                        Text(option.label).tag(option.tag)
                    }
                }
                Text("録音中に変えると、すぐに切り替えます。選んだマイクがつながっていないときは、Mac の設定のマイクを使います。AirPods をマイクにすると、再生の音質が下がることがあります（macOS の仕様）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Mac 内の音声も取り込む（オンライン会議の相手の声など）", isOn: $settings.captureSystemAudio)
                Text("マイクの音と、Mac から出る音を混ぜて文字起こしします（話者は分けません）。イヤホンで使ってください（スピーカーだと相手の声がマイクにも入り、二重になります）。初めて使うときに「システムオーディオ録音」の許可を求められます。拒否した場合は、マイクだけで文字起こしします。次に開始する会議から反映します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("無音が続いたら一時停止する", isOn: $settings.autoPauseOnSilence)
                Picker("一時停止するまで", selection: $settings.autoPauseMinutes) {
                    ForEach(AppSettings.autoPauseMinuteOptions, id: \.self) { minutes in
                        Text("\(minutes) 分").tag(minutes)
                    }
                }
                .disabled(!settings.autoPauseOnSilence)
                Text("新しい文字がこの時間出なければ、録音を一時停止して通知で知らせます（会議の消し忘れを防ぐため）。「再開」で同じ会議を続けられます。録音中に変えると、すぐに反映します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("書き起こしの方式", selection: $settings.transcriptionEngine) {
                    Text("Apple（端末内）").tag(TranscriptionEngineKind.apple)
                    Text("Whisper（ローカル）").tag(TranscriptionEngineKind.whisperLocal)
                }
                if settings.transcriptionEngine == .whisperLocal {
                    WhisperModelControls(settings: settings, models: whisperModels)
                }

                Picker("認識言語", selection: $settings.recognitionLocaleIdentifier) {
                    ForEach(localeOptions, id: \.self) { identifier in
                        Text(displayName(identifier)).tag(identifier)
                    }
                }
                Text("次に開始する会議から反映します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("用語") {
                TextEditor(text: $glossaryDraft)
                    .font(.body)
                    .frame(minHeight: 80, maxHeight: 140)
                    .onChange(of: glossaryDraft) { settings.glossary = AppSettings.glossaryTerms(from: glossaryDraft) }
                Text("固有名詞や専門用語の正しい表記を、1行に1つ書きます（人名、製品名、社内の用語など）。ノートの整理と議事録で、この表記を使います。Apple の音声認識にも手がかりとして渡します（Whisper には渡しません）。次に開始する会議から反映します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: settings.liveModelID) { connectionTest.reset() }
        // 設定画面を開いている間だけ、マイクの一覧の変化を聞く。
        .task { await inputDevices.observe() }
        .task { await whisperModels.refresh() }
        // 選んでいるマイクの名前が変わったら、保存している名前も合わせる（つながっていないときの表示用）。
        .onChange(of: inputDevices.devices) {
            if let device = inputDevices.devices.first(where: { $0.uid == settings.inputDeviceUID }),
               device.name != settings.inputDeviceName {
                settings.inputDeviceName = device.name
            }
        }
        .onChange(of: settings.authMethod) {
            connectionTest.reset()
            onCredentialsChange()
        }
        // ログイン・ログアウトしたら、前の接続テストの結果を消す。
        .onChange(of: chatGPTAccount.state) { connectionTest.reset() }
        // プランの利用が初めて許可されたときの案内（UI/UX guidelines の「You're using your ChatGPT plan」）。
        .alert(
            "ChatGPT プランを使います",
            isPresented: Binding(
                get: { chatGPTAccount.showsPlanUsageWelcome },
                set: { if !$0 { chatGPTAccount.acknowledgePlanUsageWelcome() } }
            )
        ) {
            Button("OK") { chatGPTAccount.acknowledgePlanUsageWelcome() }
        } message: {
            Text("このアプリでの AI へのリクエストには、あなたの ChatGPT のプランの利用枠を使います（API キーの料金とは別です）。使用量は ChatGPT の設定（使用量）で確かめたり、上限を決めたりできます。")
        }
        // 保存しなかったキーを入力欄（メモリ）に残さない。
        .onDisappear { apiKeyInput = "" }
        .task {
            glossaryDraft = settings.glossary.joined(separator: "\n")
            hasAPIKey = await secretStore.hasAPIKey()
            localeIdentifiers = await loadLocales()
        }
    }

    /// マイクを選ぶ。UID と名前を同時に保存し、マイクに伝える
    private func selectInputDevice(_ uid: String) {
        guard uid != settings.inputDeviceUID else { return }
        settings.inputDeviceUID = uid
        settings.inputDeviceName = inputDevices.devices.first(where: { $0.uid == uid })?.name ?? ""
        onInputDeviceChange(uid)
    }

    /// API キーの入力・保存・削除
    @ViewBuilder
    private var apiKeyControls: some View {
        LabeledContent("API キー") {
            switch hasAPIKey {
            case true?: Label("保存済み", systemImage: "checkmark.seal").foregroundStyle(.green)
            case false?: Text("未設定").foregroundStyle(.secondary)
            case nil: ProgressView().controlSize(.small)
            }
        }
        SecureField("新しい API キー", text: $apiKeyInput, prompt: Text("sk-…"))
        HStack {
            Button("保存") { Task { await saveKey() } }
                .disabled(isUpdatingKey || apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("削除", role: .destructive) { Task { await deleteKey() } }
                .disabled(isUpdatingKey || hasAPIKey != true)
            if let keyMessage {
                Text(keyMessage.text)
                    .font(.callout)
                    .foregroundStyle(keyMessage.isError ? .red : .secondary)
            }
        }
        Text("キーはこの Mac のキーチェーンにだけ保存します。画面には表示しません。")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// 候補の一覧。保存されている値が一覧になくても選べるように足す（空欄にしないため）。
    private var localeOptions: [String] {
        let current = settings.recognitionLocaleIdentifier
        return localeIdentifiers.contains(current) ? localeIdentifiers : [current] + localeIdentifiers
    }

    private func displayName(_ identifier: String) -> String {
        guard let name = Locale.current.localizedString(forIdentifier: identifier) else { return identifier }
        return "\(name)（\(identifier)）"
    }

    private func saveKey() async {
        guard !isUpdatingKey else { return }
        isUpdatingKey = true
        defer { isUpdatingKey = false }
        do {
            try await secretStore.saveAPIKey(apiKeyInput)
            // 入力欄にキーを残さない。
            apiKeyInput = ""
            hasAPIKey = true
            keyMessage = KeyMessage(text: "保存しました", isError: false)
            connectionTest.reset()
            onCredentialsChange()
        } catch {
            keyMessage = KeyMessage(text: error.localizedDescription, isError: true)
        }
    }

    private func deleteKey() async {
        guard !isUpdatingKey else { return }
        isUpdatingKey = true
        defer { isUpdatingKey = false }
        do {
            try await secretStore.deleteAPIKey()
            hasAPIKey = false
            keyMessage = KeyMessage(text: "削除しました", isError: false)
            connectionTest.reset()
            onCredentialsChange()
        } catch {
            keyMessage = KeyMessage(text: error.localizedDescription, isError: true)
        }
    }
}

private struct KeyMessage: Equatable {
    let text: String
    let isError: Bool
}

private struct ConnectionStatusView: View {
    let status: ConnectionTest.Status

    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("確認中…").foregroundStyle(.secondary)
            }
        case .succeeded:
            Label("接続できました", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// ChatGPT でのログイン（DESIGN.md §5・§4.11）。
private struct ChatGPTSignInControls: View {
    let account: ChatGPTAccount

    var body: some View {
        switch account.state {
        case .unknown:
            ProgressView().controlSize(.small)
        case .signedOut, .needsSignIn, .unavailable:
            if case .needsSignIn = account.state {
                Label("ログインし直してください（ログインの有効期限が切れたか、取り消されました）。", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if case .unavailable = account.state {
                Label("キーチェーンからログインの情報を読めませんでした。アクセスを許可するか、ログインし直してください。", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            signInButton("ChatGPT で続ける", mode: .sameAccount)
            // 保存済みの登録と別のアカウントを使うときは、新しく登録し直す。
            signInButton("別のアカウントでログイン", mode: .newAccount)
                .buttonStyle(.link)
        case .signingIn:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("ブラウザでログインしてください…").foregroundStyle(.secondary)
                Button("キャンセル") { account.cancelSignIn() }
            }
        case .signedIn(let email, let planUsageGranted):
            LabeledContent("アカウント") {
                Text(email ?? "（メールアドレスなし）").textSelection(.enabled)
            }
            if planUsageGranted {
                Label("ChatGPT プランを使用中", systemImage: "checkmark.seal")
                    .foregroundStyle(.green)
            } else {
                Label("プランの利用が許可されていません。もう一度ログインして許可してください。", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                signInButton("もう一度ログインして許可する", mode: .grantPlanUsage)
            }
            HStack {
                if let usage = ChatGPTLinks.usage {
                    Link("使用量を管理", destination: usage)
                }
                Spacer()
                Button("ログアウト", role: .destructive) {
                    Task { await account.signOut() }
                }
                .disabled(account.isSigningOut)
            }
        }
        if let message = account.message {
            Text(message.text)
                .font(.callout)
                .foregroundStyle(message.isError ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text("AI へのリクエストに、ChatGPT のプランの利用枠を使います（API キーの料金はかかりません）。ログインの情報はこの Mac のキーチェーンにだけ保存します。")
            .font(.caption)
            .foregroundStyle(.secondary)
            // ChatGPT プランを表示したときだけ、キーチェーンから読む。
            .task { await account.load() }
    }

    private func signInButton(_ title: String, mode: ChatGPTAuth.SignInMode) -> some View {
        Button(title) {
            Task {
                // ログインが終わったら、ブラウザからアプリに戻す。
                if await account.signIn(mode: mode) {
                    NSApplication.shared.activate()
                }
            }
        }
        .help("既定のブラウザで ChatGPT にログインし、このアプリがプランの利用枠を使うことを許可します")
    }
}

/// Whisper（ローカル）のモデルの選択・ダウンロード・削除（DESIGN.md §4.2）。
private struct WhisperModelControls: View {
    @Bindable var settings: AppSettings
    let models: WhisperModelManager

    var body: some View {
        Picker("Whisper のモデル", selection: $settings.whisperModel) {
            ForEach(WhisperModelStore.variants) { variant in
                Text(label(for: variant)).tag(variant.id)
            }
        }
        HStack(spacing: 8) {
            switch models.state(of: settings.whisperModel) {
            case .unknown:
                ProgressView().controlSize(.small)
            case .notDownloaded:
                Text("未ダウンロード").foregroundStyle(.secondary)
                Spacer()
                Button("モデルをダウンロード") { models.download(settings.whisperModel) }
            case .downloading(let value):
                ProgressView(value: value).frame(maxWidth: 200)
                Text("\(Int(value * 100))%").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("キャンセル") { models.cancel(settings.whisperModel) }
            case .downloaded:
                Label("ダウンロード済み", systemImage: "checkmark.circle").foregroundStyle(.green)
                Spacer()
                Button("削除", role: .destructive) {
                    Task { await models.delete(settings.whisperModel) }
                }
            case .failed(let message):
                Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("もう一度") { models.download(settings.whisperModel) }
            }
        }
        Text("モデルは初回だけダウンロードし、この Mac に保存します（数百MB〜1.5GBほど）。書き起こしは Mac の中で行い、音声は外に出しません。初めて使うときは、モデルの読み込みに数分かかることがあります。")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func label(for variant: WhisperModelStore.Variant) -> String {
        models.state(of: variant.id) == .downloaded ? variant.label : "\(variant.label)（未ダウンロード）"
    }
}
