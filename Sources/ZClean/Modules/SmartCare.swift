import SwiftUI

@MainActor
final class SmartCareModel: ObservableObject {
    unowned let app: AppState
    @Published var phase: Phase = .idle
    @Published var step = ""
    @Published var trashSize: Int64 = 0
    @Published var doJunk = true
    @Published var doTrash = true
    @Published var doThreats = false
    @Published var doMaintenance = false
    @Published var summary: [String] = []

    init(app: AppState) { self.app = app }

    var junkSize: Int64 { app.junk.selectedSize }
    var threatCount: Int { app.malware.threats.filter { $0.severity > .low }.count }
    var updateCount: Int { app.updater.updates.count }
    var maintenanceDue: Bool { Date().timeIntervalSince1970 - app.maintenance.lastRun > 7 * 86400 }

    func scan() async {
        phase = .scanning
        step = "Looking for junk"
        await app.junk.scan()
        step = "Measuring the Trash"
        trashSize = await Task.detached { TrashModel.measure() }.value
        step = "Checking for threats"
        await app.malware.scan()
        step = "Checking for app updates"
        await app.updater.scan()
        doJunk = junkSize > 0
        doTrash = trashSize > 0
        doThreats = app.malware.threats.contains { $0.severity == .high }
        doMaintenance = maintenanceDue
        phase = .results
    }

    func run() async {
        phase = .working
        var lines: [String] = []
        if doJunk && junkSize > 0 {
            step = "Cleaning junk"
            await app.junk.clean()
            lines.append("Cleaned \(formatBytes(app.junk.freed)) of junk")
        }
        if doTrash && trashSize > 0 {
            step = "Emptying the Trash"
            app.trash.canSeeTrash = Permissions.hasFullDiskAccess
            app.trash.size = trashSize
            await app.trash.empty()
            lines.append("Emptied \(formatBytes(trashSize)) from the Trash")
        }
        if doThreats && threatCount > 0 {
            step = "Removing threats"
            await app.malware.removeSelected()
            lines.append("Removed \(app.malware.removed) threat\(app.malware.removed == 1 ? "" : "s")")
        }
        if doMaintenance {
            step = "Running maintenance"
            await app.maintenance.run()
            lines.append("Ran \(app.maintenance.tasks.filter(\.selected).count) maintenance tasks")
        }
        summary = lines.isEmpty ? ["Nothing needed doing. Your Mac is in great shape."] : lines
        phase = .done
    }
}

struct SmartCareView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: SmartCareModel

    var body: some View {
        switch model.phase {
        case .idle:
            ModuleHero(module: .smartCare, subtitle: greeting) { Task { await model.scan() } } extra: {
                FullDiskAccessBanner().frame(maxWidth: 520)
            }
        case .scanning:
            ScanningView(module: .smartCare, status: "\(model.step)…", detail: app.junk.currentPath)
        case .working:
            ScanningView(module: .smartCare, status: "\(model.step)…")
        case .done:
            VStack(spacing: 18) {
                Spacer()
                GlowIcon(icon: "checkmark", colors: Module.smartCare.colors, size: 130)
                Text("All done").font(.system(size: 30, weight: .bold, design: .rounded))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.summary, id: \.self) { Label($0, systemImage: "checkmark.circle.fill") }
                }
                .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Button("Done") { model.phase = .idle }.buttonStyle(GlassButtonStyle()).padding(.bottom, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .results:
            VStack(spacing: 20) {
                HStack {
                    Button { model.phase = .idle } label: { Label("Start Over", systemImage: "chevron.left") }
                        .buttonStyle(GlassButtonStyle(compact: true))
                    Spacer()
                }
                Text("Here's what we found").font(.system(size: 28, weight: .bold, design: .rounded))
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                    Tile(module: .systemJunk, value: formatBytes(model.junkSize), caption: "of junk to clean",
                         isOn: $model.doJunk, enabled: model.junkSize > 0) { app.module = .systemJunk }
                    Tile(module: .trash, value: formatBytes(model.trashSize), caption: model.trashSize > 0 ? "in the Trash" : "Trash is empty or hidden",
                         isOn: $model.doTrash, enabled: model.trashSize > 0) { app.module = .trash }
                    Tile(module: .malware, value: model.threatCount == 0 ? "No threats" : "\(model.threatCount) found",
                         caption: model.threatCount == 0 ? "Startup items look clean" : "suspicious items",
                         isOn: $model.doThreats, enabled: model.threatCount > 0) { app.module = .malware }
                    Tile(module: .maintenance, value: model.maintenanceDue ? "Tune-up due" : "Recently tuned",
                         caption: "Free RAM, flush DNS and more", isOn: $model.doMaintenance, enabled: true) { app.module = .maintenance }
                    Tile(module: .updater, value: model.updateCount == 0 ? "Up to date" : "\(model.updateCount) update\(model.updateCount == 1 ? "" : "s")",
                         caption: "Review in Updater", isOn: nil, enabled: model.updateCount > 0) { app.module = .updater }
                    Tile(module: .spaceLens, value: formatBytes(FileOps.diskSpace.free), caption: "free on your disk",
                         isOn: nil, enabled: true) { app.module = .spaceLens }
                }
                .frame(maxWidth: 760)
                Spacer()
                BigButton(title: "Run", colors: Module.smartCare.colors,
                          disabled: !(model.doJunk || model.doTrash || model.doThreats || model.doMaintenance)) {
                    Task { await model.run() }
                }
                .padding(.bottom, 24)
            }
            .padding(24)
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let part = h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
        return "\(part)! Scan your Mac for junk, threats, slowdowns and outdated apps in one go."
    }
}

private struct Tile: View {
    let module: Module
    let value: String
    let caption: String
    var isOn: Binding<Bool>?
    let enabled: Bool
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 14) {
            GlowIcon(icon: module.icon, colors: module.colors, size: 44).frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(module.title).font(.caption).foregroundStyle(.white.opacity(0.6))
                Text(value).font(.system(size: 20, weight: .bold, design: .rounded))
                Text(caption).font(.caption).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            if let isOn {
                Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden().disabled(!enabled)
            }
        }
        .padding(16)
        .background(.white.opacity(hover ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: open)
        .help("Open \(module.title)")
    }
}
