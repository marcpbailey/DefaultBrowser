//
//  ObsidianVault.swift
//  DefaultOpener
//
//  Obsidian only opens files that live inside one of its registered vaults, so unlike the other
//  markdown editors it can't just be launched with an arbitrary file path — it needs vault-aware
//  routing via its `obsidian://` URL scheme.
//

import Foundation

enum ObsidianVault {
    private static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
    }

    private struct VaultEntry: Decodable {
        let path: String
    }

    private struct VaultsFile: Decodable {
        let vaults: [String: VaultEntry]
    }

    // Cached for the process lifetime; obsidian.json only changes when vaults are added/removed,
    // which is rare enough that picking up changes on next launch is fine.
    private static let vaultPaths: [String] = {
        guard let data = try? Data(contentsOf: configURL),
              let decoded = try? JSONDecoder().decode(VaultsFile.self, from: data) else {
            return []
        }
        return decoded.vaults.values.map { $0.path }
    }()

    // True if `file` lives inside one of Obsidian's registered vaults. Matches on path-component
    // boundaries so e.g. a vault at /Users/marc/Projects/linkcast doesn't false-positive-match
    // /Users/marc/Projects/linkcast2.
    static func contains(_ file: URL) -> Bool {
        let filePath = file.standardizedFileURL.path
        return vaultPaths.contains { vaultPath in
            let standardizedVaultPath = URL(fileURLWithPath: vaultPath).standardizedFileURL.path
            return filePath == standardizedVaultPath || filePath.hasPrefix(standardizedVaultPath + "/")
        }
    }

    // Build an obsidian:// URI that opens `file` directly. Obsidian resolves the containing vault
    // itself from the absolute path, so there's no need to compute a vault name or a
    // vault-relative path here.
    static func openURL(for file: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: file.standardizedFileURL.path)]
        return components.url
    }
}
