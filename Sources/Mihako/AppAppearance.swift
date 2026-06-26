import AppKit
import Foundation

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .system:
            return "Use System Appearance"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }
}

@MainActor
enum AppAppearance {
    private static let appearanceModeDefaultsKey = "Mihako.appearanceMode"

    static var mode: AppAppearanceMode {
        guard let rawValue = UserDefaults.standard.string(forKey: appearanceModeDefaultsKey),
              let mode = AppAppearanceMode(rawValue: rawValue) else {
            return .system
        }

        return mode
    }

    static func setMode(_ mode: AppAppearanceMode) {
        if mode == .system {
            UserDefaults.standard.removeObject(forKey: appearanceModeDefaultsKey)
        } else {
            UserDefaults.standard.set(mode.rawValue, forKey: appearanceModeDefaultsKey)
        }

        apply(mode)
    }

    static func applySavedMode() {
        apply(mode)
    }

    private static func apply(_ mode: AppAppearanceMode) {
        switch mode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
