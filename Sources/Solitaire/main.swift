import AppKit

MainActor.assumeIsolated {
    // `--render-icon <dir.iconset>` writes app icon PNGs and exits; used by the Makefile.
    if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--render-icon" {
        IconRenderer.render(to: CommandLine.arguments[2])
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    // `--screenshot <file.png>` renders the table a moment after launch and quits.
    if let i = CommandLine.arguments.firstIndex(of: "--screenshot"), i + 1 < CommandLine.arguments.count {
        delegate.screenshotPath = CommandLine.arguments[i + 1]
    }
    // `--uitest <report.txt> <screenshot-dir>` runs the scripted interaction test and quits.
    if let i = CommandLine.arguments.firstIndex(of: "--uitest"), i + 2 < CommandLine.arguments.count {
        delegate.uiTest = UITest(reportPath: CommandLine.arguments[i + 1], screenshotDir: CommandLine.arguments[i + 2])
    }
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
    withExtendedLifetime(delegate) {}
}
