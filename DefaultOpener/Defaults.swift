//
//  Defaults.swift
//  DefaultBrowser
//
//  Created by Cameron Little on 11/2/15.
//  Copyright © 2015 Cameron Little. All rights reserved.
//

import Foundation

enum MenuBarIconStyle: Int, RawRepresentable, CaseIterable {
    case browserIcon = 1
    case framed = 2

    var description: String {
        switch self {
        case .browserIcon:
            return "Browser Icon"
        case .framed:
            return "Framed"
        }
    }
}

private enum DefaultKey: String {
    case OpenWindowOnLaunch
    case DetailedAppNames
    case PrimaryBrowser
    case BrowserBlocklist
    case PrimaryEditor
    case EditorBlocklist
    case AdditionalEditors
    case MenuBarIconStyle
    case TemplateMenuBarIcon
    case Bookmarks
    case AskedAboutLaunchAtLogin
    case DebugLoggingEnabled
    case DebugLogFilePath
    case DetectObsidianVaults

    /// @deprecated replaced with BrowserBlocklist
    case BrowserBlacklist
}

// default values for this application's user defaults
// (it's confusing, because the user specific settings are called defaults)
let defaultSettings: [String: AnyObject] = [
    DefaultKey.OpenWindowOnLaunch.rawValue: true as AnyObject,
    DefaultKey.DetailedAppNames.rawValue: false as AnyObject,
    DefaultKey.PrimaryBrowser.rawValue: "" as AnyObject,
    DefaultKey.BrowserBlocklist.rawValue: [] as AnyObject,
    DefaultKey.PrimaryEditor.rawValue: "" as AnyObject,
    DefaultKey.EditorBlocklist.rawValue: [] as AnyObject,
    DefaultKey.AdditionalEditors.rawValue: [] as AnyObject,
    DefaultKey.MenuBarIconStyle.rawValue: MenuBarIconStyle.framed.rawValue as AnyObject,
    DefaultKey.TemplateMenuBarIcon.rawValue: true as AnyObject,
    DefaultKey.Bookmarks.rawValue: [:] as AnyObject,
    DefaultKey.AskedAboutLaunchAtLogin.rawValue: false as AnyObject,
    DefaultKey.DebugLoggingEnabled.rawValue: false as AnyObject,
    DefaultKey.DebugLogFilePath.rawValue: "" as AnyObject,
    DefaultKey.DetectObsidianVaults.rawValue: true as AnyObject,
]

extension ThisDefaults {
    @objc dynamic var PrimaryBrowser: String? {
        string(forKey: DefaultKey.PrimaryBrowser.rawValue)
    }

    @objc dynamic var BrowserBlocklist: String? {
        string(forKey: DefaultKey.BrowserBlocklist.rawValue)
    }

    @objc dynamic var PrimaryEditor: String? {
        string(forKey: DefaultKey.PrimaryEditor.rawValue)
    }

    @objc dynamic var EditorBlocklist: String? {
        string(forKey: DefaultKey.EditorBlocklist.rawValue)
    }
}

class ThisDefaults: UserDefaults {
    // Open the preferences window on application launch
    var openWindowOnLaunch: Bool {
        get {
            bool(forKey: DefaultKey.OpenWindowOnLaunch.rawValue)
        }
        set (value) {
            set(value, forKey: DefaultKey.OpenWindowOnLaunch.rawValue)
        }
    }

    // Show application version in list
    var detailedAppNames: Bool {
        get {
            bool(forKey: DefaultKey.DetailedAppNames.rawValue)
        }
        set (value) {
            set(value, forKey: DefaultKey.DetailedAppNames.rawValue)
        }
    }
    
    // The user's primary browser (their old default browser)
    var primaryBrowser: String? {
        get {
            let value = string(forKey: DefaultKey.PrimaryBrowser.rawValue)
            if value == "" {
                return nil
            }
            return value
        }
        set (value) {
            // don't set to self
            if value != nil && value?.lowercased() == Bundle.main.bundleIdentifier?.lowercased() {
                return
            }
            set(value as? NSString, forKey: DefaultKey.PrimaryBrowser.rawValue)
        }
    }
    
    // a list of browsers to never set as default
    var browserBlocklist: [String] {
        get {
            stringArray(forKey: DefaultKey.BrowserBlocklist.rawValue) ?? stringArray(forKey: DefaultKey.BrowserBlacklist.rawValue)!
        }
        set (value) {
            setValue(value, forKey: DefaultKey.BrowserBlocklist.rawValue)
        }
    }

    // an explicitly chosen default markdown editor
    var primaryEditor: String? {
        get {
            let value = string(forKey: DefaultKey.PrimaryEditor.rawValue)
            if value == "" {
                return nil
            }
            return value
        }
        set (value) {
            // don't set to self
            if value != nil && value?.lowercased() == Bundle.main.bundleIdentifier?.lowercased() {
                return
            }
            set(value as? NSString, forKey: DefaultKey.PrimaryEditor.rawValue)
        }
    }

    // a list of markdown editors to never set as default
    var editorBlocklist: [String] {
        get {
            stringArray(forKey: DefaultKey.EditorBlocklist.rawValue) ?? []
        }
        set (value) {
            setValue(value, forKey: DefaultKey.EditorBlocklist.rawValue)
        }
    }

    // editors manually added by the user because they don't declare markdown document type
    // handling themselves (same situation as Obsidian, just not common enough to hardcode)
    var additionalEditors: [String] {
        get {
            stringArray(forKey: DefaultKey.AdditionalEditors.rawValue) ?? []
        }
        set (value) {
            setValue(value, forKey: DefaultKey.AdditionalEditors.rawValue)
        }
    }

    var menuBarIconStyle: MenuBarIconStyle {
        get {
            .init(rawValue: integer(forKey: DefaultKey.MenuBarIconStyle.rawValue)) ?? .framed
        }
        set (value) {
            setValue(value.rawValue, forKey: DefaultKey.MenuBarIconStyle.rawValue)
        }
    }

    var templateMenuBarIcon: Bool {
        get {
            bool(forKey: DefaultKey.TemplateMenuBarIcon.rawValue)
        }
        set (value) {
            set(value, forKey: DefaultKey.TemplateMenuBarIcon.rawValue)
        }
    }

    var bookmarks: [URL: Data] {
        get {
            let rawDict = dictionary(forKey: DefaultKey.Bookmarks.rawValue) as? [String: Data] ?? [:]
            return rawDict.reduce(into: [URL: Data]()) { result, pair in
                let (key, value) = pair
                if let url = URL(string: key) {
                    result[url] = value
                }
            }
        }
    }

    func setBookmark(key: URL, value: Data) {
        var raw = dictionary(forKey: DefaultKey.Bookmarks.rawValue) as? [String: Data] ?? [:]
        raw[key.absoluteString] = value
        set(raw, forKey: DefaultKey.Bookmarks.rawValue)
    }

    func removeBookmark(key: URL) {
        var raw = dictionary(forKey: DefaultKey.Bookmarks.rawValue) as? [String: Data] ?? [:]
        raw.removeValue(forKey: key.absoluteString)
        set(raw, forKey: DefaultKey.Bookmarks.rawValue)
    }

    // Track whether user has been asked about launch at login
    var askedAboutLaunchAtLogin: Bool {
        get {
            bool(forKey: DefaultKey.AskedAboutLaunchAtLogin.rawValue)
        }
        set (value) {
            set(value, forKey: DefaultKey.AskedAboutLaunchAtLogin.rawValue)
        }
    }

    // Enables verbose diagnostic logging of the markdown-editor open path. Off by default; toggle with
    // `defaults write com.marcbailey.defaultopener DebugLoggingEnabled -bool true`.
    var debugLoggingEnabled: Bool {
        get {
            bool(forKey: DefaultKey.DebugLoggingEnabled.rawValue)
        }
        set (value) {
            set(value, forKey: DefaultKey.DebugLoggingEnabled.rawValue)
        }
    }

    // Optional file path to also append diagnostic log lines to (in addition to os_log), e.g.
    // `defaults write com.marcbailey.defaultopener DebugLogFilePath -string /tmp/defaultopener.log`.
    var debugLogFilePath: String? {
        get {
            let value = string(forKey: DefaultKey.DebugLogFilePath.rawValue)
            return (value?.isEmpty ?? true) ? nil : value
        }
        set (value) {
            set(value as? NSString, forKey: DefaultKey.DebugLogFilePath.rawValue)
        }
    }

    // When on (default), Obsidian is only considered as a candidate editor for files that live
    // inside one of its registered vaults (see ObsidianVault.swift). When off, Obsidian is treated
    // like any other editor and gets sent every markdown file unconditionally via its URL scheme,
    // regardless of vault membership.
    var detectObsidianVaults: Bool {
        get {
            bool(forKey: DefaultKey.DetectObsidianVaults.rawValue)
        }
        set (value) {
            set(value, forKey: DefaultKey.DetectObsidianVaults.rawValue)
        }
    }
}

