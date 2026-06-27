import Foundation

enum AppLanguageMode: String, CaseIterable, Identifiable {
    case system
    case english
    case japanese

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .system:
            return "Use System Language"
        case .english:
            return "English"
        case .japanese:
            return "Japanese"
        }
    }
}

enum L10n {
    private static let languageModeDefaultsKey = "Shodana.languageMode"
    private static let legacyLanguageModeDefaultsKeys = ["Mihako.languageMode"]

    static var languageMode: AppLanguageMode {
        guard let rawValue = AppDefaults.migratedString(
            forKey: languageModeDefaultsKey,
            legacyKeys: legacyLanguageModeDefaultsKeys
        ),
              let mode = AppLanguageMode(rawValue: rawValue) else {
            return .system
        }

        return mode
    }

    static func setLanguageMode(_ mode: AppLanguageMode) {
        if mode == .system {
            AppDefaults.removeCurrentAndLegacyKeys(
                languageModeDefaultsKey,
                legacyKeys: legacyLanguageModeDefaultsKeys
            )
        } else {
            AppDefaults.setCurrentAndRemoveLegacy(
                mode.rawValue,
                forKey: languageModeDefaultsKey,
                legacyKeys: legacyLanguageModeDefaultsKeys
            )
        }
    }

    static func string(_ key: String) -> String {
        localizationBundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: Locale.current, arguments: arguments)
    }

    private static var localizationBundle: Bundle {
        let languageCode: String

        switch languageMode {
        case .system:
            languageCode = Locale.preferredLanguages.first?.hasPrefix("ja") == true ? "ja" : "en"
        case .english:
            languageCode = "en"
        case .japanese:
            languageCode = "ja"
        }

        guard let path = Bundle.module.path(forResource: languageCode, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return Bundle.module
        }

        return bundle
    }
}
