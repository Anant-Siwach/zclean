import SwiftUI

extension Binding where Value == Set<URL> {
    /// A checkbox binding for membership of `url` in a selection set.
    func contains(_ url: URL) -> Binding<Bool> {
        Binding<Bool>(get: { wrappedValue.contains(url) },
                      set: { if $0 { wrappedValue.insert(url) } else { wrappedValue.remove(url) } })
    }
}

// MARK: - Hero (idle state of every module)

struct ModuleHero<Extra: View>: View {
    let module: Module
    var buttonTitle = "Scan"
    var subtitle: String?
    let action: () -> Void
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            GlowIcon(icon: module.icon, colors: module.colors, size: 150)
            VStack(spacing: 8) {
                Text(module.title).font(.system(size: 30, weight: .bold, design: .rounded))
                Text(subtitle ?? module.tagline)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            extra
            Spacer()
            BigButton(title: buttonTitle, colors: module.colors, action: action)
                .padding(.bottom, 34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension ModuleHero where Extra == EmptyView {
    init(module: Module, buttonTitle: String = "Scan", subtitle: String? = nil, action: @escaping () -> Void) {
        self.init(module: module, buttonTitle: buttonTitle, subtitle: subtitle, action: action) { EmptyView() }
    }
}

struct GlowIcon: View {
    let icon: String
    let colors: [Color]
    var size: CGFloat = 150
    var spinning = false
    @State private var angle = 0.0

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [colors[0].opacity(0.55), .clear], center: .center, startRadius: 0, endRadius: size * 0.75))
                .frame(width: size * 1.6, height: size * 1.6)
                .blur(radius: 10)
            Circle()
                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .shadow(color: colors[0].opacity(0.6), radius: 24)
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1.5))
            if spinning {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: size + 26, height: size + 26)
                    .rotationEffect(.degrees(angle))
                    .onAppear {
                        withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { angle = 360 }
                    }
            }
            Image(systemName: icon)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        }
    }
}

struct BigButton: View {
    let title: String
    let colors: [Color]
    var disabled = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 92, height: 92)
                .background(
                    Circle().fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                )
                .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 2))
                .overlay(Circle().stroke(colors[0].opacity(0.35), lineWidth: hover ? 14 : 8).padding(-8))
                .shadow(color: colors[0].opacity(0.6), radius: hover ? 22 : 14)
                .scaleEffect(hover ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .onHover { h in withAnimation(.spring(response: 0.3)) { hover = h } }
    }
}

/// Scanning state: spinning icon + current path.
struct ScanningView: View {
    let module: Module
    let status: String
    var detail: String = ""
    var progress: Double?
    var onStop: (() -> Void)?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            GlowIcon(icon: module.icon, colors: module.colors, size: 140, spinning: true)
            Text(status).font(.system(size: 22, weight: .semibold, design: .rounded))
            if let progress {
                ProgressView(value: progress).frame(width: 320).tint(.white)
            }
            Text(detail)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 520)
            Spacer()
            if let onStop {
                Button("Stop", action: onStop).buttonStyle(GlassButtonStyle()).padding(.bottom, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Final state after a clean/remove.
struct DoneView: View {
    let module: Module
    let title: String
    let detail: String
    var failures: Int = 0
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                GlowIcon(icon: "checkmark", colors: module.colors, size: 130)
            }
            Text(title).font(.system(size: 28, weight: .bold, design: .rounded))
            Text(detail).foregroundStyle(.white.opacity(0.7))
            if failures > 0 {
                Text("\(failures) item\(failures == 1 ? "" : "s") couldn't be removed (in use or protected).")
                    .font(.caption).foregroundStyle(.orange)
            }
            Spacer()
            Button("Done", action: onDone).buttonStyle(GlassButtonStyle()).padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Results scaffolding

/// Header + content + bottom action bar used by result screens.
struct ResultsScaffold<Content: View>: View {
    let module: Module
    let title: String
    var subtitle: String = ""
    var actionTitle: String
    var actionEnabled = true
    let onBack: () -> Void
    let onAction: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Button(action: onBack) {
                    Label("Start Over", systemImage: "chevron.left").labelStyle(.titleAndIcon)
                }
                .buttonStyle(GlassButtonStyle(compact: true))
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)

            HStack(spacing: 16) {
                GlowIcon(icon: module.icon, colors: module.colors, size: 54)
                    .frame(width: 70, height: 70)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 24, weight: .bold, design: .rounded))
                    if !subtitle.isEmpty {
                        Text(subtitle).foregroundStyle(.white.opacity(0.65))
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 10)

            content
                .padding(.horizontal, 24)
                .frame(maxHeight: .infinity)

            HStack {
                Spacer()
                BigButton(title: actionTitle, colors: module.colors, disabled: !actionEnabled, action: onAction)
                Spacer()
            }
            .padding(.vertical, 18)
        }
    }
}

struct GlassPanel<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}

struct GlassButtonStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 14, weight: .medium))
            .padding(.horizontal, compact ? 12 : 22)
            .padding(.vertical, compact ? 6 : 10)
            .background(.white.opacity(configuration.isPressed ? 0.25 : 0.13), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
            .foregroundStyle(.white)
    }
}

/// A row with a checkbox, icon, title, subtitle and trailing size.
struct CheckRow<Leading: View>: View {
    @Binding var isOn: Bool
    let title: String
    var subtitle: String = ""
    var trailing: String = ""
    var warning: String?
    @ViewBuilder var leading: Leading

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $isOn).toggleStyle(.checkbox).labelsHidden()
            leading
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1).truncationMode(.middle)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.5)).lineLimit(1).truncationMode(.middle)
                }
            }
            if let warning {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).help(warning)
            }
            Spacer()
            Text(trailing).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.75))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct FileIcon: View {
    let url: URL
    var size: CGFloat = 22
    var body: some View {
        Image(nsImage: FileOps.icon(url)).resizable().frame(width: size, height: size)
    }
}

/// Banner asking for Full Disk Access when a module needs it.
struct FullDiskAccessBanner: View {
    @EnvironmentObject var app: AppState
    var reason = "Some locations (Mail, Safari, Trash, app containers) are hidden without Full Disk Access."

    var body: some View {
        if !app.hasFullDiskAccess {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill").foregroundStyle(.yellow)
                Text(reason).font(.caption).foregroundStyle(.white.opacity(0.8))
                Spacer()
                Button("Grant Access") { Permissions.openFullDiskAccessSettings() }
                    .buttonStyle(GlassButtonStyle(compact: true))
            }
            .padding(10)
            .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct SizeBar: View {
    let fraction: Double
    let colors: [Color]
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(3, g.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

/// Category list on the left of results screens.
struct CategoryRow: View {
    let icon: String
    let title: String
    let size: String
    let selected: Bool
    @Binding var checked: Bool
    var mixed = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $checked).toggleStyle(.checkbox).labelsHidden()
            Image(systemName: icon).frame(width: 20).foregroundStyle(.white.opacity(0.85))
            Text(title).lineLimit(1)
            Spacer()
            Text(size).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(selected ? .white.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
}

struct EmptyResult: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.white.opacity(0.6))
            Text(title).font(.title3.bold())
            Text(detail).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
