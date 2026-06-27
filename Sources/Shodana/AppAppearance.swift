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
    private static let appearanceModeDefaultsKey = "Shodana.appearanceMode"
    private static let legacyAppearanceModeDefaultsKeys = ["Mihako.appearanceMode"]

    static var mode: AppAppearanceMode {
        guard let rawValue = AppDefaults.migratedString(
            forKey: appearanceModeDefaultsKey,
            legacyKeys: legacyAppearanceModeDefaultsKeys
        ),
              let mode = AppAppearanceMode(rawValue: rawValue) else {
            return .system
        }

        return mode
    }

    static func setMode(_ mode: AppAppearanceMode) {
        if mode == .system {
            AppDefaults.removeCurrentAndLegacyKeys(
                appearanceModeDefaultsKey,
                legacyKeys: legacyAppearanceModeDefaultsKeys
            )
        } else {
            AppDefaults.setCurrentAndRemoveLegacy(
                mode.rawValue,
                forKey: appearanceModeDefaultsKey,
                legacyKeys: legacyAppearanceModeDefaultsKeys
            )
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
