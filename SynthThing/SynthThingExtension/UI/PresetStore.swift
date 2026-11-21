//
//  PresetStore.swift — Paradise Audio shared on-disk named-preset store.
//
//  Presets are raw state blobs (whatever the AU's `stateData` returns) written
//  to ~/Library/Application Support/ParadiseAudio/<Plugin>/<Name>.preset.
//  Reusable by every plug-in — just pass a unique `plugin` folder name.
//

import Foundation

enum PresetStore {
    static func directory(_ plugin: String) -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ParadiseAudio", isDirectory: true)
            .appendingPathComponent(plugin, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Saved preset names (sorted), without the file extension.
    static func list(_ plugin: String) -> [String] {
        let d = directory(plugin)
        let files = (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "preset" }
                    .map { $0.deletingPathExtension().lastPathComponent }
                    .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func save(_ plugin: String, name: String, data: Data) {
        let safe = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty else { return }
        try? data.write(to: directory(plugin).appendingPathComponent(safe).appendingPathExtension("preset"))
    }

    static func load(_ plugin: String, name: String) -> Data? {
        try? Data(contentsOf: directory(plugin).appendingPathComponent(name).appendingPathExtension("preset"))
    }

    static func delete(_ plugin: String, name: String) {
        try? FileManager.default.removeItem(at: directory(plugin).appendingPathComponent(name).appendingPathExtension("preset"))
    }
}
