import Foundation
import Security

/// A launchd job (LaunchAgent / LaunchDaemon) that starts software automatically.
struct LaunchItem: Identifiable, Hashable {
    enum Domain: String { case user = "User Agent", systemAgent = "System Agent", systemDaemon = "System Daemon" }

    let plist: URL
    let label: String
    let program: String?
    let domain: Domain
    let runAtLoad: Bool
    let keepAlive: Bool
    var disabled: Bool
    let signature: CodeSignature
    let programExists: Bool

    var id: URL { plist }
    var displayName: String {
        if let program, let app = program.range(of: ".app/") {
            return URL(fileURLWithPath: String(program[..<app.lowerBound])).lastPathComponent
        }
        return label
    }
}

struct CodeSignature: Hashable {
    var signed = false
    var adhoc = false
    var apple = false
    var team: String?
    var signer: String?

    var summary: String {
        if !signed { return "Unsigned" }
        if adhoc { return "Ad-hoc signed" }
        if apple { return "Apple" }
        return signer ?? team ?? "Signed"
    }

    var trustworthy: Bool { signed && !adhoc }
}

enum LaunchItems {
    static var uid: String { String(getuid()) }

    static func scan() -> [LaunchItem] {
        let disabledUser = disabledLabels("gui/\(uid)")
        let disabledSystem = disabledLabels("system")
        let dirs: [(URL, LaunchItem.Domain)] = [
            (FileOps.homePath("Library/LaunchAgents"), .user),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .systemAgent),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .systemDaemon),
        ]
        var items: [LaunchItem] = []
        for (dir, domain) in dirs {
            for url in FileOps.children(of: dir) where url.pathExtension == "plist" {
                guard let dict = NSDictionary(contentsOf: url) as? [String: Any] else { continue }
                let label = dict["Label"] as? String ?? url.deletingPathExtension().lastPathComponent
                var program = dict["Program"] as? String ?? (dict["ProgramArguments"] as? [String])?.first
                if let p = program, p.hasPrefix("~") { program = (p as NSString).expandingTildeInPath }
                let exists = program.map { FileManager.default.fileExists(atPath: $0) } ?? false
                let disabledFlag = (dict["Disabled"] as? Bool) ?? false
                let overrides = domain == .systemDaemon ? disabledSystem : disabledUser
                items.append(LaunchItem(
                    plist: url, label: label, program: program, domain: domain,
                    runAtLoad: dict["RunAtLoad"] as? Bool ?? false,
                    keepAlive: (dict["KeepAlive"] as? Bool) ?? (dict["KeepAlive"] is [String: Any]),
                    disabled: overrides[label] ?? disabledFlag,
                    signature: exists ? signature(of: program!) : CodeSignature(),
                    programExists: exists))
            }
        }
        return items.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Parses `launchctl print-disabled` output: "label" => disabled/enabled (or true/false).
    private static func disabledLabels(_ domain: String) -> [String: Bool] {
        let out = Shell.run("/bin/launchctl", ["print-disabled", domain]).text
        var map: [String: Bool] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            map[label] = value.hasPrefix("disabled") || value.hasPrefix("true")
        }
        return map
    }

    static func signature(of path: String) -> CodeSignature {
        var sig = CodeSignature()
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return sig }
        guard SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { return sig }
        sig.signed = true
        var info: CFDictionary?
        if SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
           let dict = info as? [String: Any] {
            sig.team = dict[kSecCodeInfoTeamIdentifier as String] as? String
            if let flags = dict[kSecCodeInfoFlags as String] as? UInt32 { sig.adhoc = flags & 0x2 != 0 }
            if let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first {
                var cn: CFString?
                SecCertificateCopyCommonName(leaf, &cn)
                sig.signer = (cn as String?)?.replacingOccurrences(of: "Developer ID Application: ", with: "")
            }
        }
        var req: SecRequirement?
        if SecRequirementCreateWithString("anchor apple" as CFString, [], &req) == errSecSuccess, let req {
            sig.apple = SecStaticCodeCheckValidity(code, [], req) == errSecSuccess
        }
        return sig
    }

    // MARK: Actions

    @discardableResult
    static func setEnabled(_ item: LaunchItem, _ enabled: Bool) -> Bool {
        let plist = Shell.quote(item.plist.path)
        switch item.domain {
        case .user, .systemAgent:
            let target = "gui/\(uid)"
            let cmd = enabled
                ? "launchctl enable \(target)/\(Shell.quote(item.label)); launchctl bootstrap \(target) \(plist) 2>/dev/null; true"
                : "launchctl bootout \(target) \(plist) 2>/dev/null; launchctl disable \(target)/\(Shell.quote(item.label))"
            return Shell.sh(cmd).ok
        case .systemDaemon:
            let cmd = enabled
                ? "launchctl enable system/\(Shell.quote(item.label)); launchctl bootstrap system \(plist) 2>/dev/null; true"
                : "launchctl bootout system \(plist) 2>/dev/null; launchctl disable system/\(Shell.quote(item.label))"
            return Shell.admin(cmd).ok
        }
    }

    /// Unloads the job and moves its plist to the Trash.
    @discardableResult
    static func remove(_ item: LaunchItem) -> Bool {
        let plist = Shell.quote(item.plist.path)
        switch item.domain {
        case .user:
            _ = Shell.sh("launchctl bootout gui/\(uid) \(plist) 2>/dev/null")
            return FileOps.trash([(item.plist, 0)], roots: [FileOps.homePath("Library/LaunchAgents")]).failed.isEmpty
        case .systemAgent, .systemDaemon:
            let domain = item.domain == .systemDaemon ? "system" : "gui/\(uid)"
            let trash = Shell.quote(FileOps.homePath(".Trash").path + "/" + item.plist.lastPathComponent)
            return Shell.admin("launchctl bootout \(domain) \(plist) 2>/dev/null; mv \(plist) \(trash)").ok
        }
    }
}
