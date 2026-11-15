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
}
