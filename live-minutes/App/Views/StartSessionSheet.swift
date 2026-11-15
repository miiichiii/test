import LiveMinutesKit
import SwiftUI

/// 開始時に会議名を入力するシート。空のまま開始すると、日時から名前を付ける。
struct StartSessionSheet: View {
    let onStart: (String) -> Void
    let onCancel: () -> Void
    @State private var title = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新しい会議")
                .font(.headline)
            TextField("会議名", text: $title, prompt: Text(SessionController.defaultTitle(for: Date())))
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit { onStart(title) }
            Text("空のままにすると、開始日時から名前を付けます。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("キャンセル", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("開始") { onStart(title) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { isFocused = true }
    }
}
