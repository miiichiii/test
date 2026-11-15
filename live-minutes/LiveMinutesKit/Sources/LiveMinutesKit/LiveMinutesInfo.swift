/// パッケージ自体の情報。
///
/// 型名をモジュール名（`LiveMinutesKit`）と同じにすると、`LiveMinutesKit.Foo` という
/// モジュール修飾が型のメンバー参照として解決されてしまうため、別の名前にしている。
public enum LiveMinutesInfo {
    /// LiveMinutesKit のバージョン。
    ///
    /// パッケージがアプリから呼べることを確かめるための値で、アプリのバージョン
    /// （`project.yml` の `MARKETING_VERSION`）とは別に管理している。
    public static let version = "0.1.0"

    /// os.Logger の subsystem。ログには会議の内容（文字起こしやノートの本文）を出さない。
    static let logSubsystem = "com.example.LiveMinutes"
}
