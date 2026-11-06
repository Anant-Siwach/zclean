import AppKit

enum Shell {
    struct Output { var status: Int32; var text: String; var ok: Bool { status == 0 } }

    /// Runs a command synchronously. Call from a background task.
    @discardableResult
    static func run(_ launchPath: String, _ args: [String] = []) -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return Output(status: -1, text: error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Output(status: p.terminationStatus, text: String(decoding: data, as: UTF8.self))
    }

    static func sh(_ command: String) -> Output { run("/bin/zsh", ["-c", command]) }

    /// Runs a shell command as root. macOS shows its own password dialog; ZClean never sees the password.
    static func admin(_ command: String) -> Output {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var result = Output(status: -1, text: "")
        let work = {
            var err: NSDictionary?
            let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")
            let out = script?.executeAndReturnError(&err)
            if let err {
                result = Output(status: Int32((err[NSAppleScript.errorNumber] as? Int) ?? 1),
                                text: err[NSAppleScript.errorMessage] as? String ?? "Cancelled")
            } else {
                result = Output(status: 0, text: out?.stringValue ?? "")
            }
        }
        // NSAppleScript must run on the main thread.
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
        return result
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

enum Permissions {
    /// Full Disk Access lets ZClean see Mail, Safari, Trash and app containers.
    static var hasFullDiskAccess: Bool {
        let probes = [
            "Library/Application Support/com.apple.TCC/TCC.db",
            "Library/Safari/Bookmarks.plist",
            "Library/Containers/com.apple.stocks",
        ]
        for p in probes {
            let url = FileOps.homePath(p)
            guard FileOps.exists(url) else { continue }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                if (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil { return true }
            } else if let h = try? FileHandle(forReadingFrom: url) {
                try? h.close()
                return true
            }
            return false
        }
        return false
    }

    static func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}
