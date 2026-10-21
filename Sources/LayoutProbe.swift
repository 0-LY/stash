import SwiftUI

private struct LayoutReportKey: EnvironmentKey {
    static let defaultValue: (@MainActor (String, CGRect) -> Void)? = nil
}

extension EnvironmentValues {
    var layoutReport: (@MainActor (String, CGRect) -> Void)? {
        get { self[LayoutReportKey.self] }
        set { self[LayoutReportKey.self] = newValue }
    }
}

private struct Probe: ViewModifier {
    let id: String
    @Environment(\.layoutReport) private var report

    func body(content: Content) -> some View {
        if let report {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named("probe")) } action: { report(id, $0) }
        } else {
            content
        }
    }
}

extension View {
    func probe(_ id: String) -> some View { modifier(Probe(id: id)) }
}
