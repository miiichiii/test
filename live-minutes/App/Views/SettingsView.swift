import LiveMinutesKit
import SwiftUI

/// 設定画面: OpenAI の API キー、モデルID、接続テスト、認識言語。
struct SettingsView: View {
    @Bindable var settings: AppSettings
    let secretStore: any SecretStore
    let connectionTest: ConnectionTest
    /// 認識言語の候補（BCP 47 の識別子）を読む
    let loadLocales: () async -> [String]
    /// API キーを保存・削除したとき（会議中なら、その時点からノートの更新を始める・再開する）
    let onAPIKeyChange: () -> Void

    @State private var apiKeyInput = ""
    /// 保存済みか。確かめるまでは nil
    @State private var hasAPIKey: Bool?
    @State private var keyMessage: KeyMessage?
    @State private var localeIdentifiers: [String] = []
    /// 保存・削除の処理中（連打で2本同時に走らせない）
    @State private var isUpdatingKey = false

    var body: some View {
        Form {
            Section("OpenAI") {
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
                Text("ライブ更新用のモデルに短いリクエストを1回送り、キーとモデルIDを確かめます（料金がわずかにかかります）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("文字起こし") {
                Picker("認識言語", selection: $settings.recognitionLocaleIdentifier) {
                    ForEach(localeOptions, id: \.self) { identifier in
                        Text(displayName(identifier)).tag(identifier)
                    }
                }
                Text("次に開始する会議から反映します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: settings.liveModelID) { connectionTest.reset() }
        // 保存しなかったキーを入力欄（メモリ）に残さない。
        .onDisappear { apiKeyInput = "" }
        .task {
            hasAPIKey = await secretStore.hasAPIKey()
            localeIdentifiers = await loadLocales()
        }
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
            onAPIKeyChange()
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
            onAPIKeyChange()
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
