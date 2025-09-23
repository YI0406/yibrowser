import Foundation

struct SharedIncomingFile {
    let relativePath: String
    let absolutePath: String
    let displayName: String
    let typeHint: String

    init?(dictionary: [String: Any], containerURL: URL) {
        guard let relative = dictionary["relativePath"] as? String else {
            return nil
        }
        let normalizedRelative = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedRelative.isEmpty {
            return nil
        }
        self.relativePath = normalizedRelative
        let absolute = containerURL.appendingPathComponent(normalizedRelative)
        self.absolutePath = absolute.path
        let providedName = (dictionary["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let providedName, !providedName.isEmpty {
            self.displayName = providedName
        } else {
            self.displayName = absolute.lastPathComponent
        }
        if let type = dictionary["type"] as? String, !type.isEmpty {
            self.typeHint = type
        } else {
            self.typeHint = "file"
        }
    }

    func toDictionary() -> [String: Any] {
        [
            "path": absolutePath,
            "relativePath": relativePath,
            "displayName": displayName,
            "type": typeHint,
        ]
    }
}

final class SharedDownloadsManager {
    static let shared = SharedDownloadsManager()

    private struct Constants {
        static let queueKey = "yibrowser_shared_downloads_queue"
    }

    private let fileManager = FileManager.default
    private var cachedGroupId: String?

    private init() {}

    private func appGroupId() -> String? {
        if let cachedGroupId {
            return cachedGroupId
        }
        guard let groupId = Bundle.main.object(forInfoDictionaryKey: "AppGroupId") as? String,
              !groupId.isEmpty else {
            NSLog("[ShareBridge] Missing AppGroupId in host Info.plist")
            return nil
        }
        cachedGroupId = groupId
        return groupId
    }

    private func sharedDefaults() -> UserDefaults? {
        guard let groupId = appGroupId() else { return nil }
        return UserDefaults(suiteName: groupId)
    }

    private func containerURL() -> URL? {
        guard let groupId = appGroupId() else { return nil }
        return fileManager.containerURL(forSecurityApplicationGroupIdentifier: groupId)
    }

    var hasPendingItems: Bool {
        guard let defaults = sharedDefaults() else { return false }
        guard let entries = defaults.array(forKey: Constants.queueKey) as? [[String: Any]] else {
            return false
        }
        return !entries.isEmpty
    }

    func consumePendingItems() -> [SharedIncomingFile] {
        guard let defaults = sharedDefaults(),
              let container = containerURL() else {
            return []
        }
        guard let entries = defaults.array(forKey: Constants.queueKey) as? [[String: Any]],
              !entries.isEmpty else {
            return []
        }
        defaults.removeObject(forKey: Constants.queueKey)
        defaults.synchronize()
        let items: [SharedIncomingFile] = entries.compactMap {
            guard let item = SharedIncomingFile(dictionary: $0, containerURL: container) else {
                return nil
            }
            if !fileManager.fileExists(atPath: item.absolutePath) {
                NSLog("[ShareBridge] File missing at path %@", item.absolutePath)
                return nil
            }
            return item
        }
        NSLog("[ShareBridge] Consumed %d pending item(s)", items.count)
        return items
    }

    func cleanup(relativePaths: [String]) {
        guard let container = containerURL(), !relativePaths.isEmpty else {
            return
        }
        for relative in relativePaths {
            let trimmed = relative.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let url = container.appendingPathComponent(trimmed)
            do {
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
            } catch {
                NSLog("[ShareBridge] Failed to remove %@: %@", url.path, error.localizedDescription)
            }
        }
    }

    func expectedURLScheme() -> String? {
        guard let bundleId = Bundle.main.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String,
              !bundleId.isEmpty else {
            return nil
        }
        return "ShareMedia-\(bundleId)"
    }

    func canHandle(url: URL) -> Bool {
        guard let expectedScheme = expectedURLScheme(),
              let scheme = url.scheme else {
            return false
        }
        return scheme == expectedScheme
    }
}
//  SharedDownloadsManager.swift
//  Runner
//
//  Created by 詹子逸 on 2025/9/23.
//

