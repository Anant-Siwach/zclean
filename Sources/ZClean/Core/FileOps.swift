import AppKit
import UniformTypeIdentifiers

/// File-system helpers. Every destructive operation goes through here so the safety rules live in one place.
enum FileOps {
    static let fm = FileManager.default
    static let home = fm.homeDirectoryForCurrentUser
    static func homePath(_ relative: String) -> URL { home.appendingPathComponent(relative) }

    static let sizeKeys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]

    // MARK: Sizes

    static func allocatedSize(of url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: sizeKeys) else { return 0 }
        if values.isSymbolicLink == true { return 0 }
        if values.isDirectory != true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        let e = fm.enumerator(at: url, includingPropertiesForKeys: Array(sizeKeys), options: [], errorHandler: { _, _ in true })
        while let item = e?.nextObject() as? URL {
            guard let v = try? item.resourceValues(forKeys: sizeKeys), v.isDirectory != true, v.isSymbolicLink != true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }

    static func children(of url: URL, includeHidden: Bool = true) -> [URL] {
        let opts: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        return (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(sizeKeys) + [.contentModificationDateKey], options: opts)) ?? []
    }

    static func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    static func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    // MARK: Exclusions

    /// Paths the user never wants touched (Settings › Exclusions).
    static var exclusions: [String] {
        UserDefaults.standard.stringArray(forKey: "exclusions") ?? []
    }

    static func isExcluded(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        return exclusions.contains { p == $0 || p.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    // MARK: Removal

    struct Result {
        var freed: Int64 = 0
        var removed: [URL] = []
        var failed: [URL] = []
    }

    /// True when `url` is strictly inside one of `roots` (never a root itself, never home or /).
    static func isInside(_ url: URL, roots: [URL]) -> Bool {
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard p != "/", p != home.path, !p.isEmpty else { return false }
        return roots.contains { root in
            let r = root.standardizedFileURL.resolvingSymlinksInPath().path
            return p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
        }
    }

    /// Moves items to the Trash (recoverable). Items outside `roots` (when given) are refused.
    static func trash(_ items: [(url: URL, size: Int64)], roots: [URL]? = nil) -> Result {
        var result = Result()
        for item in items {
            if let roots, !isInside(item.url, roots: roots) { result.failed.append(item.url); continue }
            if isExcluded(item.url) { result.failed.append(item.url); continue }
            do {
                try fm.trashItem(at: item.url, resultingItemURL: nil)
                result.freed += item.size
                result.removed.append(item.url)
            } catch {
                result.failed.append(item.url)
            }
        }
        return result
    }

    /// Permanently deletes regenerable junk. Refuses anything not strictly inside `roots`.
    static func delete(_ items: [(url: URL, size: Int64)], roots: [URL]) -> Result {
        if UserDefaults.standard.bool(forKey: "junkToTrash") { return trash(items, roots: roots) }
        var result = Result()
        for item in items {
            guard isInside(item.url, roots: roots), !isExcluded(item.url) else { result.failed.append(item.url); continue }
            do {
                try fm.removeItem(at: item.url)
                result.freed += item.size
                result.removed.append(item.url)
            } catch {
                result.failed.append(item.url)
            }
        }
        return result
    }

    /// Recycles with Finder-style authentication (handles root-owned apps). Calls back on the main queue.
    static func recycle(_ urls: [URL], completion: @escaping (Set<URL>) -> Void) {
        let allowed = urls.filter { !isExcluded($0) }
        guard !allowed.isEmpty else { completion([]); return }
        NSWorkspace.shared.recycle(allowed) { moved, _ in
            DispatchQueue.main.async { completion(Set(moved.keys)) }
        }
    }

    // MARK: Display

    static func icon(_ url: URL) -> NSImage { NSWorkspace.shared.icon(forFile: url.path) }

    static func displayPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: home.path, with: "~")
    }

    static func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    static var diskSpace: (total: Int64, free: Int64) {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return (Int64(v?.volumeTotalCapacity ?? 0), v?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func relativeDate(_ date: Date?) -> String {
    guard let date else { return "Never" }
    return date.formatted(.relative(presentation: .named))
}
