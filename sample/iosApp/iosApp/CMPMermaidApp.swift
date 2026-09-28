import CmpMermaidDebugUi
import SwiftUI
import UIKit

@main
struct CMPMermaidApp: App {
    var body: some Scene {
        WindowGroup {
            ComposeView()
                .ignoresSafeArea(.keyboard)
        }
    }
}

private struct ComposeView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--load-test") {
            return IosDebugUiKt.MermaidLoadTestViewController()
        }
        if let demoId = argumentValue(named: "--audit-demo-id", in: arguments) {
            let layout = argumentValue(named: "--audit-layout", in: arguments) ?? "dagre"
            return IosDebugUiKt.MermaidAuditViewController(
                demoId: demoId,
                layout: layout
            )
        }
        return IosDebugUiKt.MermaidDebugViewController()
    }

    func updateUIViewController(
        _ uiViewController: UIViewController,
        context: Context
    ) {
    }
}

private func argumentValue(named name: String, in arguments: [String]) -> String? {
    let prefix = "\(name)="
    if let argument = arguments.first(where: { $0.hasPrefix(prefix) }) {
        return String(argument.dropFirst(prefix.count))
    }
    guard
        let index = arguments.firstIndex(of: name),
        arguments.indices.contains(index + 1)
    else {
        return nil
    }
    return arguments[index + 1]
}
