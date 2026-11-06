import AppKit
import CryptoKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Space Lens

final class SpaceNode: Identifiable, @unchecked Sendable {
    let url: URL
    let name: String
    var size: Int64
    let isDirectory: Bool
    let isAggregate: Bool
    var children: [SpaceNode]
    weak var parent: SpaceNode?
    var id: URL { url }

    init(url: URL, name: String, size: Int64, isDirectory: Bool, isAggregate: Bool = false, children: [SpaceNode] = []) {
        self.url = url
        self.name = name
        self.size = size
        self.isDirectory = isDirectory
        self.isAggregate = isAggregate
        self.children = children
        for c in children { c.parent = self }
    }
}

final class ScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _files = 0
    private var _cancelled = false
    var files: Int { lock.lock(); defer { lock.unlock() }; return _files }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func add(_ n: Int) { lock.lock(); _files += n; lock.unlock() }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
}

enum SpaceScanner {
    static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
    static let skipRoots: Set<String> = ["/System/Volumes", "/Volumes", "/dev", "/private/var/vm", "/cores", "/net", "/home"]
    /// Files smaller than this are folded into a "Smaller items" entry to keep the tree light.
    static let keepThreshold: Int64 = 2_000_000

    static func scan(_ root: URL, counter: ScanCounter) -> SpaceNode {
        let kids = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [])) ?? []
        var nodes = [SpaceNode?](repeating: nil, count: kids.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: kids.count) { i in
            let n = node(for: kids[i], counter: counter)
            lock.lock(); nodes[i] = n; lock.unlock()
        }
        return makeDir(root, children: nodes.compactMap { $0 })
    }

    private static func node(for url: URL, counter: ScanCounter) -> SpaceNode? {
        guard !counter.cancelled, !skipRoots.contains(url.path),
              let v = try? url.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { return nil }
        if v.isDirectory == true {
            if v.isPackage == true {
                return SpaceNode(url: url, name: url.lastPathComponent, size: FileOps.allocatedSize(of: url), isDirectory: false)
            }
            let kids = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])) ?? []
            counter.add(kids.count)
            return makeDir(url, children: kids.compactMap { node(for: $0, counter: counter) })
        }
        let size = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        return SpaceNode(url: url, name: url.lastPathComponent, size: size, isDirectory: false)
    }

    private static func makeDir(_ url: URL, children: [SpaceNode]) -> SpaceNode {
        var kept: [SpaceNode] = []
        var small: Int64 = 0
        for c in children {
            if c.isDirectory || c.size >= keepThreshold { kept.append(c) } else { small += c.size }
        }
        if small > 0 {
            kept.append(SpaceNode(url: url.appendingPathComponent(".zclean-small"), name: "Smaller items", size: small, isDirectory: false, isAggregate: true))
        }
        kept.sort { $0.size > $1.size }
        let total = kept.reduce(Int64(0)) { $0 + $1.size }
        return SpaceNode(url: url, name: url.lastPathComponent.isEmpty ? "Macintosh HD" : url.lastPathComponent,
                         size: total, isDirectory: true, children: kept)
    }
}

/// Squarified treemap layout (Bruls, Huizing & van Wijk).
enum Treemap {
    static func layout(_ sizes: [Double], in rect: CGRect) -> [CGRect] {
        let total = sizes.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return sizes.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        let areas = sizes.map { $0 * scale }
        var result: [CGRect] = []
        var remaining = rect
        var row: [Double] = []
        var i = 0
        while i < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            let candidate = row + [areas[i]]
            if row.isEmpty || worst(candidate, side) <= worst(row, side) {
                row = candidate
                i += 1
            } else {
                let (placed, rest) = place(row, in: remaining)
                result += placed
                remaining = rest
                row = []
            }
        }
        if !row.isEmpty { result += place(row, in: remaining).0 }
        return result
    }

    private static func worst(_ row: [Double], _ w: Double) -> Double {
        let s = row.reduce(0, +)
        guard let mx = row.max(), let mn = row.min(), s > 0, mn > 0 else { return .infinity }
        return max(w * w * mx / (s * s), s * s / (w * w * mn))
    }

    private static func place(_ row: [Double], in rect: CGRect) -> ([CGRect], CGRect) {
        let s = row.reduce(0, +)
        var rects: [CGRect] = []
        if rect.width >= rect.height {
            let w = CGFloat(s) / rect.height
            var y = rect.minY
            for a in row {
                let h = CGFloat(a) / w
                rects.append(CGRect(x: rect.minX, y: y, width: w, height: h))
                y += h
            }
            return (rects, CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w, height: rect.height))
        } else {
            let h = CGFloat(s) / rect.width
            var x = rect.minX
            for a in row {
                let w = CGFloat(a) / h
                rects.append(CGRect(x: x, y: rect.minY, width: w, height: h))
                x += w
            }
            return (rects, CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h))
        }
    }
}

@MainActor
final class SpaceLensModel: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var root: SpaceNode?
    @Published var current: SpaceNode?
    @Published var scanned = 0
    @Published var target: URL = FileOps.home
    @Published var selected: Set<URL> = []
    @Published var hovered: URL?
    @Published var message: String?
    private var counter: ScanCounter?

    func scan() async {
        phase = .scanning
        scanned = 0
        selected = []
        let counter = ScanCounter()
        self.counter = counter
        let ticker = Task { while !Task.isCancelled { scanned = counter.files; try? await Task.sleep(for: .milliseconds(200)) } }
        let target = self.target
        let tree = await Task.detached(priority: .userInitiated) { SpaceScanner.scan(target, counter: counter) }.value
        ticker.cancel()
        if counter.cancelled { phase = .idle; return }
        root = tree
        current = tree
        phase = .results
    }

    func stop() { counter?.cancel() }

    func open(_ node: SpaceNode) {
        guard node.isDirectory, !node.children.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.25)) { current = node }
    }

    func up() {
        if let p = current?.parent { withAnimation(.easeInOut(duration: 0.25)) { current = p } }
    }

    var breadcrumb: [SpaceNode] {
        var list: [SpaceNode] = []
        var n = current
        while let node = n { list.insert(node, at: 0); n = node.parent }
        return list
    }

    var selectedSize: Int64 {
        current?.children.filter { selected.contains($0.url) }.reduce(0) { $0 + $1.size } ?? 0
    }

    func removeSelected() async {
        guard let current else { return }
        let nodes = current.children.filter { selected.contains($0.url) && !$0.isAggregate }
        let moved = await withCheckedContinuation { c in FileOps.recycle(nodes.map(\.url)) { c.resume(returning: $0) } }
        var freed: Int64 = 0
        for n in nodes where moved.contains(n.url) {
            freed += n.size
            current.children.removeAll { $0.url == n.url }
        }
        // Propagate the new sizes up the tree.
        var p: SpaceNode? = current
        while let node = p { node.size -= freed; p = node.parent }
        selected = []
        message = "Moved \(moved.count) item\(moved.count == 1 ? "" : "s") (\(formatBytes(freed))) to the Trash"
        objectWillChange.send()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = target
        if panel.runModal() == .OK, let url = panel.url { target = url }
    }
}

struct SpaceLensView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: SpaceLensModel

    var body: some View {
        switch model.phase {
        case .idle, .done, .working:
            ModuleHero(module: .spaceLens, subtitle: "See what's taking up space in \(FileOps.displayPath(model.target)).") {
                Task { await model.scan() }
            } extra: {
                HStack {
                    Button("Home Folder") { model.target = FileOps.home }.buttonStyle(GlassButtonStyle(compact: true))
                    Button("Whole Disk") { model.target = URL(fileURLWithPath: "/") }.buttonStyle(GlassButtonStyle(compact: true))
                    Button("Choose…") { model.chooseFolder() }.buttonStyle(GlassButtonStyle(compact: true))
                }
            }
        case .scanning:
            ScanningView(module: .spaceLens, status: "Mapping your storage…", detail: "\(model.scanned.formatted()) items", onStop: { model.stop() })
        case .results:
            if let current = model.current { SpaceLensResults(model: model, current: current) }
        }
    }
}

private struct SpaceLensResults: View {
    @ObservedObject var model: SpaceLensModel
    let current: SpaceNode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                Button { model.phase = .idle } label: { Image(systemName: "chevron.left") }.buttonStyle(GlassButtonStyle(compact: true))
                ForEach(model.breadcrumb, id: \.url) { node in
                    Text(node.name).font(.callout.bold())
                        .foregroundStyle(node === current ? .white : .white.opacity(0.55))
                        .onTapGesture { model.current = node }
                    if node !== current { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.4)) }
                }
                Spacer()
                Text(formatBytes(current.size)).font(.title3.bold())
            }
            if let msg = model.message {
                Text(msg).font(.caption).foregroundStyle(.green)
            }
            HStack(alignment: .top, spacing: 14) {
                GlassPanel(padding: 6) {
                    VStack {
                        List(current.children) { node in
                            HStack(spacing: 8) {
                                Toggle("", isOn: $model.selected.contains(node.url))
                                    .toggleStyle(.checkbox).labelsHidden().disabled(node.isAggregate)
                                if node.isAggregate { Image(systemName: "square.grid.3x3.fill").frame(width: 20).foregroundStyle(.white.opacity(0.5)) }
                                else { FileIcon(url: node.url, size: 20) }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(node.name).lineLimit(1)
                                    SizeBar(fraction: Double(node.size) / Double(max(current.size, 1)), colors: Module.spaceLens.colors)
                                }
                                Text(formatBytes(node.size)).font(.caption.monospacedDigit()).frame(width: 70, alignment: .trailing)
                            }
                            .padding(.vertical, 2)
                            .background(model.hovered == node.url ? .white.opacity(0.1) : .clear)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { model.open(node) }
                            .contextMenu { if !node.isAggregate { Button("Show in Finder") { FileOps.reveal(node.url) } } }
                        }
                        .scrollContentBackground(.hidden).listStyle(.plain)
                        HStack {
                            Text("\(formatBytes(model.selectedSize)) selected").font(.caption)
                            Spacer()
                            Button("Move to Trash") { Task { await model.removeSelected() } }
                                .buttonStyle(GlassButtonStyle(compact: true)).disabled(model.selected.isEmpty)
                        }
                        .padding(6)
                    }
                }
                .frame(width: 330)

                TreemapView(model: model, node: current)
            }
        }
        .padding(24)
    }
}

private struct TreemapView: View {
    @ObservedObject var model: SpaceLensModel
    let node: SpaceNode

    private let palette: [[Color]] = [
        [.orange, .yellow], [.pink, .orange], [.purple, .pink], [.blue, .purple], [.teal, .blue],
        [.green, .teal], [.indigo, .blue], [.red, .orange],
    ]

    var body: some View {
        GeometryReader { geo in
            let items = Array(node.children.filter { $0.size > 0 }.prefix(60))
            let rects = Treemap.layout(items.map { Double($0.size) }, in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(items.enumerated()), id: \.element.url) { i, child in
                    let r = rects[i].insetBy(dx: 2, dy: 2)
                    let colors = child.isAggregate ? [Color.gray.opacity(0.5), .gray.opacity(0.3)] : palette[i % palette.count]
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LinearGradient(colors: colors.map { $0.opacity(model.hovered == child.url ? 0.95 : 0.7) },
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(model.selected.contains(child.url) ? 0.95 : 0.1),
                                                                                lineWidth: model.selected.contains(child.url) ? 3 : 1))
                        .overlay(alignment: .topLeading) {
                            if r.width > 70 && r.height > 36 {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(child.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                    Text(formatBytes(child.size)).font(.system(size: 11)).opacity(0.85)
                                }
                                .padding(8)
                                .shadow(radius: 2)
                            }
                        }
                        .frame(width: max(r.width, 0), height: max(r.height, 0))
                        .offset(x: r.minX, y: r.minY)
                        .onHover { h in model.hovered = h ? child.url : (model.hovered == child.url ? nil : model.hovered) }
                        .onTapGesture { model.open(child) }
                        .help("\(child.name) · \(formatBytes(child.size))\(child.isDirectory ? " · click to open" : "")")
                }
            }
        }
        .padding(4)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Large & Old Files

struct BigFile: Identifiable, Hashable {
    enum Kind: String, CaseIterable { case all = "All", video = "Video", audio = "Audio", image = "Images", archive = "Archives", disk = "Disk Images", document = "Documents", other = "Other" }
    let url: URL
    let size: Int64
    let modified: Date?
    let accessed: Date?
    let kind: Kind
    var id: URL { url }

    static func kind(for url: URL) -> Kind {
        let ext = url.pathExtension.lowercased()
        if ["dmg", "iso", "img", "sparseimage", "sparsebundle", "vmdk", "qcow2"].contains(ext) { return .disk }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .archive) || ["zip", "rar", "7z", "tar", "gz", "xz", "tgz"].contains(ext) { return .archive }
        if type.conforms(to: .pdf) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet) || type.conforms(to: .text) { return .document }
        return .other
    }
}

@MainActor
final class LargeFilesModel: ObservableObject {
    enum Age: String, CaseIterable { case any = "Any age", month = "1+ month", halfYear = "6+ months", year = "1+ year"
        var days: Double { [0, 30, 182, 365][Self.allCases.firstIndex(of: self)!] }
    }
    @Published var phase: Phase = .idle
    @Published var files: [BigFile] = []
    @Published var selected: Set<URL> = []
    @Published var kind: BigFile.Kind = .all
    @Published var age: Age = .any
    @Published var currentPath = ""
    @Published var message: String?
    @AppStorage("largeFileThresholdMB") var thresholdMB = 50.0

    var visible: [BigFile] {
        files.filter { f in
            (kind == .all || f.kind == kind)
                && (age == .any || (f.accessed ?? f.modified ?? .distantPast) < Date().addingTimeInterval(-age.days * 86400))
        }
    }
    var selectedSize: Int64 { files.filter { selected.contains($0.url) }.reduce(0) { $0 + $1.size } }

    func scan() async {
        phase = .scanning
        let threshold = Int64(thresholdMB * 1_000_000)
        let throttle = Throttle()
        files = await Task.detached(priority: .userInitiated) { () -> [BigFile] in
            let home = FileOps.home
            let skip: Set<String> = ["Library", ".Trash"]
            let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .contentAccessDateKey, .isPackageKey]
            var found: [BigFile] = []
            for top in FileOps.children(of: home, includeHidden: false) where !skip.contains(top.lastPathComponent) {
                let e = FileManager.default.enumerator(at: top, includingPropertiesForKeys: keys,
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true })
                if let v = try? top.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, Int64(v.totalFileAllocatedSize ?? 0) >= threshold {
                    found.append(BigFile(url: top, size: Int64(v.totalFileAllocatedSize ?? 0), modified: v.contentModificationDate,
                                         accessed: v.contentAccessDate, kind: BigFile.kind(for: top)))
                }
                while let url = e?.nextObject() as? URL {
                    guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                    let size: Int64
                    if v.isPackage == true { size = FileOps.allocatedSize(of: url) }
                    else if v.isRegularFile == true { size = Int64(v.totalFileAllocatedSize ?? 0) }
                    else { continue }
                    throttle.run { let p = FileOps.displayPath(url); Task { @MainActor in self.currentPath = p } }
                    guard size >= threshold, !FileOps.isExcluded(url), url.pathExtension != "app" else { continue }
                    found.append(BigFile(url: url, size: size, modified: v.contentModificationDate, accessed: v.contentAccessDate,
                                         kind: BigFile.kind(for: url)))
                }
            }
            return found.sorted { $0.size > $1.size }
        }.value
        selected = []
        phase = .results
    }

    func remove() async {
        let urls = files.filter { selected.contains($0.url) }.map(\.url)
        let moved = await withCheckedContinuation { c in FileOps.recycle(urls) { c.resume(returning: $0) } }
        let freed = files.filter { moved.contains($0.url) }.reduce(0) { $0 + $1.size }
        files.removeAll { moved.contains($0.url) }
        selected.subtract(moved)
        message = "Moved \(moved.count) file\(moved.count == 1 ? "" : "s") (\(formatBytes(freed))) to the Trash"
    }
}

struct LargeFilesView: View {
    @ObservedObject var model: LargeFilesModel

    var body: some View {
        switch model.phase {
        case .idle, .done, .working:
            ModuleHero(module: .largeFiles, subtitle: "Find files over \(Int(model.thresholdMB)) MB in your home folder.") {
                Task { await model.scan() }
            } extra: {
                HStack {
                    Text("Minimum size").font(.caption)
                    Slider(value: $model.thresholdMB, in: 10...1000, step: 10).frame(width: 200)
                    Text("\(Int(model.thresholdMB)) MB").font(.caption.monospacedDigit())
                }
            }
        case .scanning:
            ScanningView(module: .largeFiles, status: "Looking for large files…", detail: model.currentPath)
        case .results:
            ResultsScaffold(module: .largeFiles, title: "\(model.files.count) large files · \(formatBytes(model.files.reduce(0) { $0 + $1.size }))",
                            subtitle: model.message ?? "\(formatBytes(model.selectedSize)) selected",
                            actionTitle: "Remove", actionEnabled: !model.selected.isEmpty,
                            onBack: { model.phase = .idle }, onAction: { Task { await model.remove() } }) {
                VStack(spacing: 10) {
                    HStack {
                        Picker("", selection: $model.kind) { ForEach(BigFile.Kind.allCases, id: \.self) { Text($0.rawValue) } }
                            .pickerStyle(.segmented).labelsHidden()
                        Picker("", selection: $model.age) { ForEach(LargeFilesModel.Age.allCases, id: \.self) { Text($0.rawValue) } }
                            .labelsHidden().frame(width: 130)
                    }
                    GlassPanel(padding: 6) {
                        List(model.visible) { f in
                            HStack(spacing: 10) {
                                Toggle("", isOn: $model.selected.contains(f.url))
                                    .toggleStyle(.checkbox).labelsHidden()
                                FileIcon(url: f.url, size: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(f.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                    Text(FileOps.displayPath(f.url.deletingLastPathComponent())).font(.caption).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                                }
                                Spacer()
                                Text("Opened \(relativeDate(f.accessed ?? f.modified))").font(.caption).foregroundStyle(.white.opacity(0.55))
                                    .frame(width: 140, alignment: .trailing)
                                Text(formatBytes(f.size)).font(.callout.monospacedDigit().bold()).frame(width: 80, alignment: .trailing)
                            }
                            .padding(.vertical, 2)
                            .contextMenu {
                                Button("Show in Finder") { FileOps.reveal(f.url) }
                                Button("Open") { NSWorkspace.shared.open(f.url) }
                            }
                        }
                        .scrollContentBackground(.hidden).listStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - Duplicates

struct DupFile: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let created: Date?
    var selected = false
    var id: URL { url }
}

struct DupGroup: Identifiable {
    let id = UUID()
    var files: [DupFile]
    var size: Int64 { files.first?.size ?? 0 }
    var wasted: Int64 { files.filter(\.selected).reduce(0) { $0 + $1.size } }
}

enum DuplicateFinder {
    static func find(in folders: [URL], minSize: Int64 = 50_000, progress: @escaping (String) -> Void) -> [DupGroup] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .creationDateKey]
        var bySize: [Int64: [DupFile]] = [:]
        var seen = Set<String>()
        for folder in folders {
            let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                   options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true })
            while let url = e?.nextObject() as? URL {
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                      let size = v.fileSize.map(Int64.init), size >= minSize, !FileOps.isExcluded(url),
                      seen.insert(url.standardizedFileURL.path).inserted else { continue }
                progress(FileOps.displayPath(url))
                bySize[size, default: []].append(DupFile(url: url, size: size, created: v.creationDate))
            }
        }
        var groups: [DupGroup] = []
        for (_, files) in bySize where files.count > 1 {
            // Cheap pass on the first 64 KB, then a full hash for the survivors.
            for sameHead in Dictionary(grouping: files, by: { hash($0.url, limit: 65_536) ?? UUID().uuidString }).values where sameHead.count > 1 {
                for same in Dictionary(grouping: sameHead, by: { f -> String in progress(FileOps.displayPath(f.url)); return hash(f.url) ?? UUID().uuidString }).values where same.count > 1 {
                    groups.append(DupGroup(files: autoSelect(same)))
                }
            }
        }
        return groups.sorted { $0.size * Int64($0.files.count - 1) > $1.size * Int64($1.files.count - 1) }
    }

    /// Keeps one copy: prefer files outside Downloads, then the oldest.
    static func autoSelect(_ files: [DupFile]) -> [DupFile] {
        let downloads = FileOps.homePath("Downloads").path
        let keep = files.min { a, b in
            let ad = a.url.path.hasPrefix(downloads), bd = b.url.path.hasPrefix(downloads)
            if ad != bd { return !ad }
            return (a.created ?? .distantFuture) < (b.created ?? .distantFuture)
        }
        return files.map { var f = $0; f.selected = f.url != keep?.url; return f }
    }

    static func hash(_ url: URL, limit: Int? = nil) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        var read = 0
        while true {
            let chunk = autoreleasepool { h.readData(ofLength: 1 << 20) }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            read += chunk.count
            if let limit, read >= limit { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class DuplicatesModel: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var folders: [URL] = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"].map(FileOps.homePath)
    @Published var groups: [DupGroup] = []
    @Published var currentPath = ""
    @Published var message: String?

    var wasted: Int64 { groups.reduce(0) { $0 + $1.wasted } }

    func scan() async {
        phase = .scanning
        let folders = self.folders
        let throttle = Throttle()
        groups = await Task.detached(priority: .userInitiated) {
            DuplicateFinder.find(in: folders) { p in throttle.run { Task { @MainActor in self.currentPath = p } } }
        }.value
        phase = .results
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { folders += panel.urls.filter { !folders.contains($0) } }
    }

    func autoSelectAll() { for i in groups.indices { groups[i].files = DuplicateFinder.autoSelect(groups[i].files) } }
    func deselectAll() { for i in groups.indices { for j in groups[i].files.indices { groups[i].files[j].selected = false } } }

    func remove() async {
        // Never remove every copy in a group.
        var urls: [URL] = []
        for g in groups {
            var picked = g.files.filter(\.selected)
            if picked.count == g.files.count { picked.removeFirst() }
            urls += picked.map(\.url)
        }
        let moved = await withCheckedContinuation { c in FileOps.recycle(urls) { c.resume(returning: $0) } }
        var freed: Int64 = 0
        for i in groups.indices {
            freed += groups[i].files.filter { moved.contains($0.url) }.reduce(0) { $0 + $1.size }
            groups[i].files.removeAll { moved.contains($0.url) }
        }
        groups.removeAll { $0.files.count < 2 }
        message = "Moved \(moved.count) duplicate\(moved.count == 1 ? "" : "s") (\(formatBytes(freed))) to the Trash"
    }
}

struct DuplicatesView: View {
    @ObservedObject var model: DuplicatesModel

    var body: some View {
        switch model.phase {
        case .idle, .done, .working:
            ModuleHero(module: .duplicates) { Task { await model.scan() } } extra: {
                GlassPanel(padding: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.folders, id: \.self) { f in
                            HStack {
                                Image(systemName: "folder.fill").foregroundStyle(.white.opacity(0.6))
                                Text(FileOps.displayPath(f)).font(.callout)
                                Spacer()
                                Button { model.folders.removeAll { $0 == f } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                            }
                        }
                        Button("Add Folder…") { model.addFolder() }.buttonStyle(.borderless).font(.callout)
                    }
                }
                .frame(width: 360)
            }
        case .scanning:
            ScanningView(module: .duplicates, status: "Comparing files…", detail: model.currentPath)
        case .results:
            ResultsScaffold(module: .duplicates, title: "\(model.groups.count) sets of duplicates",
                            subtitle: model.message ?? "\(formatBytes(model.wasted)) can be freed",
                            actionTitle: "Remove", actionEnabled: model.wasted > 0,
                            onBack: { model.phase = .idle }, onAction: { Task { await model.remove() } }) {
                VStack(spacing: 8) {
                    HStack {
                        Text("One copy in each set stays unchecked. Removed files go to the Trash.").font(.caption).foregroundStyle(.white.opacity(0.6))
                        Spacer()
                        Button("Auto Select") { model.autoSelectAll() }.buttonStyle(GlassButtonStyle(compact: true))
                        Button("Deselect All") { model.deselectAll() }.buttonStyle(GlassButtonStyle(compact: true))
                    }
                    GlassPanel(padding: 6) {
                        if model.groups.isEmpty {
                            EmptyResult(icon: "checkmark.seal.fill", title: "No duplicates", detail: "Every file in these folders is unique.")
                        } else {
                            List {
                                ForEach($model.groups) { $group in
                                    Section {
                                        ForEach($group.files) { $f in
                                            CheckRow(isOn: $f.selected, title: f.url.lastPathComponent,
                                                     subtitle: FileOps.displayPath(f.url.deletingLastPathComponent()),
                                                     trailing: relativeDate(f.created)) { Thumbnail(url: f.url) }
                                                .contextMenu { Button("Show in Finder") { FileOps.reveal(f.url) } }
                                        }
                                    } header: {
                                        Text("\(group.files.count) copies · \(formatBytes(group.size)) each").font(.caption.bold())
                                    }
                                }
                            }
                            .scrollContentBackground(.hidden).listStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

struct Thumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
            else { Image(nsImage: FileOps.icon(url)).resizable() }
        }
        .frame(width: 30, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .task {
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 60, height: 60), scale: 2, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { image = rep.nsImage }
        }
    }
}

// MARK: - Shredder

@MainActor
final class ShredderModel: ObservableObject {
    @Published var items: [URL] = []
    @Published var working = false
    @Published var confirm = false
    @Published var message: String?
    @Published var dropTargeted = false

    var totalSize: Int64 { items.reduce(0) { $0 + FileOps.allocatedSize(of: $1) } }

    func add(_ urls: [URL]) {
        // Only things inside your home folder, and never the home folder itself.
        items += urls.filter { FileOps.isInside($0, roots: [FileOps.home]) && !items.contains($0) }
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func shred() async {
        working = true
        let targets = items
        let failed = await Task.detached { () -> [URL] in
            var failed: [URL] = []
            for url in targets where !FileOps.isExcluded(url) {
                if !Self.shred(url) { failed.append(url) }
            }
            return failed
        }.value
        items = failed
        message = failed.isEmpty ? "Shredded \(targets.count) item\(targets.count == 1 ? "" : "s")." : "\(failed.count) item(s) couldn't be shredded."
        working = false
    }

    /// Overwrites file contents with random data, then deletes. Folders are handled file by file.
    nonisolated static func shred(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        if isDir.boolValue {
            let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
            while let f = e?.nextObject() as? URL {
                if (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { overwrite(f) }
            }
        } else {
            overwrite(url)
        }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    nonisolated private static func overwrite(_ url: URL) {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0,
              let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        var remaining = size
        let chunk = 1 << 20
        while remaining > 0 {
            let n = min(chunk, remaining)
            var bytes = [UInt8](repeating: 0, count: n)
            _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
            h.write(Data(bytes))
            remaining -= n
        }
        try? h.synchronize()
    }
}

struct ShredderView: View {
    @ObservedObject var model: ShredderModel

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                GlowIcon(icon: Module.shredder.icon, colors: Module.shredder.colors, size: 46).frame(width: 60, height: 60)
                VStack(alignment: .leading) {
                    Text("Shredder").font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("Overwrites files with random data before deleting them. This can't be undone.").foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
            }
            GlassPanel {
                if model.items.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.badge.plus").font(.system(size: 44)).foregroundStyle(.white.opacity(0.6))
                        Text("Drop files or folders here").font(.title3.bold())
                        Button("Choose…") { model.choose() }.buttonStyle(GlassButtonStyle())
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack {
                        List {
                            ForEach(model.items, id: \.self) { url in
                                HStack {
                                    FileIcon(url: url, size: 24)
                                    Text(FileOps.displayPath(url)).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Button { model.items.removeAll { $0 == url } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                                }
                            }
                        }
                        .scrollContentBackground(.hidden).listStyle(.plain)
                        HStack {
                            Button("Add More…") { model.choose() }.buttonStyle(GlassButtonStyle(compact: true))
                            Spacer()
                            Text(formatBytes(model.totalSize)).font(.callout.bold())
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(.white.opacity(model.dropTargeted ? 0.8 : 0.15)))
            .onDrop(of: [.fileURL], isTargeted: $model.dropTargeted) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url { DispatchQueue.main.async { model.add([url]) } }
                    }
                }
                return true
            }
            if let msg = model.message { Text(msg).font(.callout).foregroundStyle(.white.opacity(0.8)) }
            Text("On SSDs, macOS may keep copies of old data elsewhere on the drive. FileVault encryption is the best protection.")
                .font(.caption).foregroundStyle(.white.opacity(0.45))
            BigButton(title: model.working ? "…" : "Shred", colors: Module.shredder.colors, disabled: model.items.isEmpty || model.working) {
                model.confirm = true
            }
        }
        .padding(24)
        .confirmationDialog("Shred \(model.items.count) item\(model.items.count == 1 ? "" : "s")?", isPresented: $model.confirm) {
            Button("Shred Permanently", role: .destructive) { Task { await model.shred() } }
        } message: {
            Text("These files will be overwritten and deleted. They won't go to the Trash.")
        }
    }
}
