import Foundation

enum AppDefaults {
    static func migratedString(forKey key: String, legacyKeys: [String]) -> String? {
        let defaults = UserDefaults.standard

        if let value = defaults.string(forKey: key) {
            return value
        }

        for legacyKey in legacyKeys {
            if let value = defaults.string(forKey: legacyKey) {
                defaults.set(value, forKey: key)
                return value
            }
        }

        return nil
    }

    static func migratedBool(forKey key: String, legacyKeys: [String]) -> Bool? {
        let defaults = UserDefaults.standard

        if let value = defaults.object(forKey: key) as? Bool {
            return value
        }

        for legacyKey in legacyKeys {
            if let value = defaults.object(forKey: legacyKey) as? Bool {
                defaults.set(value, forKey: key)
                return value
            }
        }

        return nil
    }

    static func migratedStringArray(forKey key: String, legacyKeys: [String]) -> [String]? {
        let defaults = UserDefaults.standard

        if let value = defaults.stringArray(forKey: key) {
            return value
        }

        for legacyKey in legacyKeys {
            if let value = defaults.stringArray(forKey: legacyKey) {
                defaults.set(value, forKey: key)
                return value
            }
        }

        return nil
    }

    static func migratedData(forKey key: String, legacyKeys: [String]) -> Data? {
        let defaults = UserDefaults.standard

        if let value = defaults.data(forKey: key) {
            return value
        }

        for legacyKey in legacyKeys {
            if let value = defaults.data(forKey: legacyKey) {
                defaults.set(value, forKey: key)
                return value
            }
        }

        return nil
    }

    static func removeCurrentAndLegacyKeys(_ key: String, legacyKeys: [String]) {
        let defaults = UserDefaults.standard
        ([key] + legacyKeys).forEach { defaults.removeObject(forKey: $0) }
    }

    static func setCurrentAndRemoveLegacy<T>(_ value: T, forKey key: String, legacyKeys: [String]) {
        let defaults = UserDefaults.standard
        defaults.set(value, forKey: key)
        legacyKeys.forEach { defaults.removeObject(forKey: $0) }
    }
}
