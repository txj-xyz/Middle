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

// Renders the iconset the bundle icon is built from; see Resources/make-icon.sh.
if let flag = CommandLine.arguments.firstIndex(of: "--export-icon") {
    let path = CommandLine.arguments.count > flag + 1
        ? CommandLine.arguments[flag + 1]
        : FileManager.default.currentDirectoryPath + "/Middle.iconset"
    do {
        try MiddleIcon.exportIconset(to: URL(fileURLWithPath: path))
        print("Wrote \(path)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Could not write \(path): \(error)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu bar only: no Dock icon, no app menu.
app.setActivationPolicy(.accessory)
app.run()
