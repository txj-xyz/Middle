import AppKit

if CommandLine.arguments.contains("--diagnose") {
    Diagnose.run()
}

if CommandLine.arguments.contains("--diagnose-conflict") {
    // Launched through `open --args`, so take the log path from wherever it
    // lands in the argument list rather than assuming a working directory.
    let path = CommandLine.arguments.first { $0.hasSuffix(".txt") }
        ?? FileManager.default.currentDirectoryPath + "/conflict-log.txt"
    ConflictDiagnostic.run(seconds: 45, path: path)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu bar only: no Dock icon, no app menu.
app.setActivationPolicy(.accessory)
app.run()
