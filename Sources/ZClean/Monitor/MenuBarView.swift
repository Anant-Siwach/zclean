import SwiftUI

struct MenuBarView: View {
    @ObservedObject var monitor = SystemMonitor.shared
    @Environment(\.openWindow) private var openWindow
    @State private var freeing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(LinearGradient(colors: Module.smartCare.colors, startPoint: .top, endPoint: .bottom))
                Text("ZClean").font(.headline)
                Spacer()
                Text("Up \(uptimeText)").font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Gauge2(title: "CPU", value: monitor.cpu, text: "\(Int(monitor.cpu * 100))%", colors: Module.performance)
                Gauge2(title: "Memory", value: Double(monitor.memoryUsed) / Double(max(monitor.memoryTotal, 1)),
                       text: formatBytes(monitor.memoryUsed), colors: Module.applications)
                Gauge2(title: "Disk", value: 1 - Double(monitor.diskFree) / Double(max(monitor.diskTotal, 1)),
                       text: "\(formatBytes(monitor.diskFree)) free", colors: Module.files)
            }

            Card {
                HStack {
                    Label(rate(monitor.download), systemImage: "arrow.down.circle.fill").foregroundStyle(.cyan)
                    Spacer()
                    Label(rate(monitor.upload), systemImage: "arrow.up.circle.fill").foregroundStyle(.pink)
                }
                .font(.callout.monospacedDigit())
            }

            if let b = monitor.battery {
                Card {
                    HStack {
                        Image(systemName: b.charging ? "battery.100.bolt" : batteryIcon(b.percent))
                            .foregroundStyle(b.percent < 20 && !b.onAC ? .red : .green)
                        Text("\(b.percent)%").font(.callout.bold())
                        if let m = b.minutesLeft, !b.onAC { Text("· \(m / 60)h \(m % 60)m left").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if let h = b.health { Text("Health \(h)%").font(.caption).foregroundStyle(.secondary) }
                        if let c = b.cycles { Text("· \(c) cycles").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Top apps").font(.caption.bold()).foregroundStyle(.secondary)
                        Spacer()
                        Text("Swap \(formatBytes(monitor.swapUsed))").font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(monitor.topProcesses) { p in
                        HStack(spacing: 8) {
                            if let icon = p.app?.icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                            else { Image(systemName: "gearshape").frame(width: 16) }
                            Text(p.app?.localizedName ?? p.name).lineLimit(1)
                            Spacer()
                            Text(String(format: "%.0f%%", p.cpu)).monospacedDigit().foregroundStyle(.secondary)
                            Text(formatBytes(p.memory)).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                        }
                        .font(.caption)
                    }
                }
            }

            HStack {
                Button {
                    freeing = true
                    Task {
                        _ = await Task.detached { Shell.admin("/usr/sbin/purge") }.value
                        freeing = false
                    }
                } label: { Label(freeing ? "Freeing…" : "Free Up RAM", systemImage: "memorychip") }
                    .disabled(freeing)
                Spacer()
                Button("Open ZClean") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.borderedProminent)
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit ZClean")
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { monitor.start() }
    }

    private var uptimeText: String {
        let h = Int(monitor.uptime) / 3600
        return h >= 24 ? "\(h / 24)d \(h % 24)h" : "\(h)h \((Int(monitor.uptime) % 3600) / 60)m"
    }

    private func rate(_ bytesPerSec: Double) -> String { formatBytes(Int64(bytesPerSec)) + "/s" }

    private func batteryIcon(_ p: Int) -> String {
        switch p { case 76...: "battery.100"; case 51...: "battery.75"; case 26...: "battery.50"; case 11...: "battery.25"; default: "battery.0" }
    }
}

private extension Module {
    static let performance = Module.optimization.colors
    static let applications = Module.uninstaller.colors
    static let files = Module.spaceLens.colors
}

private struct Gauge2: View {
    let title: String
    let value: Double
    let text: String
    let colors: [Color]

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 7)
                Circle().trim(from: 0, to: min(max(value, 0), 1))
                    .stroke(AngularGradient(colors: colors + [colors[0]], center: .center), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut, value: value)
                Text("\(Int(value * 100))%").font(.system(size: 13, weight: .bold, design: .rounded))
            }
            .frame(width: 64, height: 64)
            Text(title).font(.caption.bold())
            Text(text).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
