import SwiftUI

enum ModuleGroup: String, CaseIterable {
    case care = "", cleanup = "Cleanup", protection = "Protection", performance = "Performance", applications = "Applications", files = "Files"

    var modules: [Module] { Module.allCases.filter { $0.group == self } }
}

enum Module: String, CaseIterable, Identifiable {
    case smartCare, systemJunk, trash
    case malware, privacy
    case optimization, maintenance
    case uninstaller, updater
    case spaceLens, largeFiles, duplicates, shredder

    var id: String { rawValue }

    var group: ModuleGroup {
        switch self {
        case .smartCare: .care
        case .systemJunk, .trash: .cleanup
        case .malware, .privacy: .protection
        case .optimization, .maintenance: .performance
        case .uninstaller, .updater: .applications
        case .spaceLens, .largeFiles, .duplicates, .shredder: .files
        }
    }

    var title: String {
        switch self {
        case .smartCare: "Smart Care"
        case .systemJunk: "System Junk"
        case .trash: "Trash Bins"
        case .malware: "Security Check"
        case .privacy: "Privacy"
        case .optimization: "Optimization"
        case .maintenance: "Maintenance"
        case .uninstaller: "Uninstaller"
        case .updater: "Updater"
        case .spaceLens: "Space Lens"
        case .largeFiles: "Large & Old Files"
        case .duplicates: "Duplicates"
        case .shredder: "Shredder"
        }
    }

    var icon: String {
        switch self {
        case .smartCare: "sparkles"
        case .systemJunk: "externaldrive.badge.xmark"
        case .trash: "trash.fill"
        case .malware: "shield.lefthalf.filled"
        case .privacy: "hand.raised.fill"
        case .optimization: "slider.horizontal.3"
        case .maintenance: "wrench.and.screwdriver.fill"
        case .uninstaller: "xmark.app.fill"
        case .updater: "arrow.triangle.2.circlepath"
        case .spaceLens: "circle.hexagongrid.fill"
        case .largeFiles: "doc.badge.ellipsis"
        case .duplicates: "square.on.square"
        case .shredder: "scissors"
        }
    }

    var tagline: String {
        switch self {
        case .smartCare: "Scan your whole Mac in one go: junk, threats, speed and apps."
        case .systemJunk: "Clear caches, logs, developer leftovers and other files your Mac doesn't need."
        case .trash: "Empty the Trash and free the space it's holding."
        case .malware: "Check startup items for adware and unsigned software, and review your Mac's protection."
        case .privacy: "Remove browsing history, cookies and recent-items lists."
        case .optimization: "Control what launches at startup and find apps hogging your CPU and memory."
        case .maintenance: "Run tune-up tasks: flush DNS, free RAM, reindex Spotlight and more."
        case .uninstaller: "Remove apps completely, including the files they leave behind."
        case .updater: "Find updates for your apps from the App Store and developers."
        case .spaceLens: "See what's taking up space, folder by folder."
        case .largeFiles: "Find big and forgotten files in your home folder."
        case .duplicates: "Find identical copies of files and keep just one."
        case .shredder: "Erase files so they're hard to recover."
        }
    }

    /// Accent gradient for the module's hero and background.
    var colors: [Color] {
        switch group {
        case .care: [Color(red: 0.75, green: 0.3, blue: 1.0), Color(red: 1.0, green: 0.35, blue: 0.65)]
        case .cleanup: [Color(red: 0.15, green: 0.85, blue: 0.6), Color(red: 0.1, green: 0.6, blue: 0.95)]
        case .protection: [Color(red: 1.0, green: 0.35, blue: 0.35), Color(red: 1.0, green: 0.65, blue: 0.2)]
        case .performance: [Color(red: 0.25, green: 0.55, blue: 1.0), Color(red: 0.2, green: 0.9, blue: 0.95)]
        case .applications: [Color(red: 0.45, green: 0.4, blue: 1.0), Color(red: 0.8, green: 0.4, blue: 1.0)]
        case .files: [Color(red: 1.0, green: 0.6, blue: 0.15), Color(red: 1.0, green: 0.85, blue: 0.25)]
        }
    }

    var background: [Color] {
        switch group {
        case .care: [Color(red: 0.22, green: 0.08, blue: 0.32), Color(red: 0.12, green: 0.05, blue: 0.2)]
        case .cleanup: [Color(red: 0.03, green: 0.22, blue: 0.22), Color(red: 0.03, green: 0.11, blue: 0.16)]
        case .protection: [Color(red: 0.3, green: 0.07, blue: 0.08), Color(red: 0.16, green: 0.05, blue: 0.08)]
        case .performance: [Color(red: 0.05, green: 0.14, blue: 0.32), Color(red: 0.03, green: 0.08, blue: 0.18)]
        case .applications: [Color(red: 0.14, green: 0.1, blue: 0.34), Color(red: 0.08, green: 0.06, blue: 0.2)]
        case .files: [Color(red: 0.3, green: 0.17, blue: 0.04), Color(red: 0.16, green: 0.09, blue: 0.04)]
        }
    }
}

/// Shared app-wide state: the selected module and one model per module, kept alive across navigation.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var module: Module = .smartCare
    @Published var hasFullDiskAccess = Permissions.hasFullDiskAccess

    let junk = JunkModel()
    let trash = TrashModel()
    let malware = MalwareModel()
    let privacy = PrivacyModel()
    let optimization = OptimizationModel()
    let maintenance = MaintenanceModel()
    let apps = AppsModel()
    let updater = UpdaterModel()
    let spaceLens = SpaceLensModel()
    let largeFiles = LargeFilesModel()
    let duplicates = DuplicatesModel()
    let shredder = ShredderModel()
    lazy var smartCare = SmartCareModel(app: self)

    func refreshPermissions() {
        hasFullDiskAccess = Permissions.hasFullDiskAccess
    }
}
