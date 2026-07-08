//
//  AppDelegate.swift
//  DefaultBrowser
//
//  Created by Cameron Little on 10/23/15.
//  Copyright © 2015 Cameron Little. All rights reserved.
//

import Cocoa
import CoreServices
import Intents
import ServiceManagement
import UniformTypeIdentifiers

// Menu item tags used to fetch them without a direct reference
enum MenuItemTag: Int {
    case BrowserListTop = 1
    case BrowserListBottom
    case usePrimary
    case EditorListTop
    case EditorListBottom
    case useEditorPrimary
}

// Height of each menu item's icon
let MENU_ITEM_HEIGHT: CGFloat = 16

// Adds a bundle id field to menu items and the browser's icon
// used in menu bar and preferences primary browser picker
class BrowserMenuItem: NSMenuItem {
    var height: CGFloat?
    var bundleIdentifier: String? {
        didSet {
            let workspace = NSWorkspace.shared
            if let bid = bundleIdentifier,
               let url = workspace.urlForApplication(withBundleIdentifier: bid) {
                image = workspace.icon(forFile: url.relativePath)
                if let height {
                    image?.size = NSSize(width: height, height: height)
                }
            }
        }
    }
}

class MenuBarIconMenuItem: NSMenuItem {
    var template: Bool?
    var style: MenuBarIconStyle?
}

@NSApplicationMain
class AppDelegate: NSObject {
    @IBOutlet weak var preferencesWindow: NSWindow!
    @IBOutlet weak var descriptiveAppNamesCheckbox: NSButton!
    @IBOutlet weak var disclosureTriangle: NSButton!
    @IBOutlet weak var menuBarIconPopUp: NSPopUpButton!
    @IBOutlet weak var browsersPopUp: NSPopUpButton!
    @IBOutlet weak var showWindowCheckbox: NSButton!
    @IBOutlet weak var launchAtLoginCheckbox: NSButton!
    @IBOutlet weak var blocklistTable: NSTableView!
    @IBOutlet weak var blocklistView: NSScrollView!
    @IBOutlet weak var blocklistStackView: NSStackView!
    @IBOutlet weak var userAccessDisclosureTriangle: NSButton!
    @IBOutlet weak var userAccessTable: EnterKeyTableView!
    @IBOutlet weak var userAccessView: NSView!
    @IBOutlet weak var userAccessStackView: NSStackView!
    @IBOutlet weak var bookmarksTable: DeleteKeyTableView!
    @IBOutlet weak var bookmarksView: NSScrollView!
    @IBOutlet weak var notDefaultText: NSTextField!

    @IBOutlet weak var aboutWindow: NSWindow!
    @IBOutlet weak var logo: NSImageView!
    @IBOutlet weak var versionString: NSTextField!
    @IBOutlet weak var builtByString: NSTextField!
    @IBOutlet weak var githubString: NSTextField!

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let workspace = NSWorkspace.shared

    // a list of all valid browsers installed
    var validBrowsers: [String] = []
    var userScopedBrowsers: [URL] = []

    // a list of all valid markdown editors installed (always includes Obsidian, which is
    // vault-gated separately rather than discovered — see ObsidianVault.swift)
    var validEditors: [String] = []
    var userScopedEditors: [URL] = []

    let blocklistDelegate = CheckboxBlocklistDataSource(pool: BrowserBlocklistPool())
    let userAccessDelegate = UserAccessBrowserDelegate()
    let bookmarksDelegate = BookmarksDelegate()
    let editorBlocklistDataSource = CheckboxBlocklistDataSource(pool: EditorBlocklistPool())

    // keep an ordered list of running browsers
    var runningBrowsers: [NSRunningApplication] = []

    var runningBrowsersNotBlocked: [NSRunningApplication] {
        runningBrowsers.filter({ runningBrowser in
            !defaults.browserBlocklist.contains(where: { blockedBrowser in
                runningBrowser.bundleIdentifier == blockedBrowser
            })
        })
    }

    // keep an ordered list of running markdown editors (used only to show "not running" as a
    // faded icon in the menu — see updateMenuItems — not for MRU selection; see editorLastActivated)
    var runningEditors: [NSRunningApplication] = []

    // last-activation timestamp per editor bundle id, independent of whether it's still running.
    // Unlike browsers — which are typically kept running semi-permanently, so "most recently
    // activated among currently-running browsers" is a reasonable proxy for "most recently used" —
    // markdown editors are routinely launched, used, and quit. Gating MRU selection on "is it still
    // running" meant any editor merely left open in the background (e.g. for unrelated work) would
    // win over the editor actually last used for markdown, and over the primary editor setting.
    // Tracking real timestamps here lets the true most-recently-used editor be relaunched from disk
    // even if it's no longer running.
    var editorLastActivated: [String: Date] = [:]

    // an explicitly chosen default browser
    var explicitBrowser: String? = nil

    // an explicitly chosen default markdown editor
    var explicitEditor: String? = nil

    // the user's "system" default browser
    var usePrimaryBrowser: Bool? = false

    // force always using the primary markdown editor, ignoring MRU — mirrors usePrimaryBrowser
    var usePrimaryEditor: Bool? = false

    // user settings
    let defaults = ThisDefaults()

    // get around a bug in the browser list when this app wasn't set as the default OS browser
    var firstTime = false

    var primaryBrowserObserver: NSKeyValueObservation?
    var blockedBrowserObserver: NSKeyValueObservation?
    var primaryEditorObserver: NSKeyValueObservation?
    var blockedEditorObserver: NSKeyValueObservation?

    // Built programmatically rather than as XIB-connected IBOutlets — see buildEditorPreferencesSection()
    var editorsPopUp: NSPopUpButton?
    var editorBlocklistTable: NSTableView?
    var editorBlocklistScrollView: NSScrollView?
    var editorExplanationLabel: NSTextField?
    var editorDeleteExplanationLabel: NSTextField?

    // MARK: Signal/Notification Responses

    // Respond to the user opening a link
    @objc func handleGetURLEvent(event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        // not sure if the format always matches what I expect
        if let urlDescriptor = event.atIndex(1),
           let urlStr = urlDescriptor.stringValue,
           let url = URL(string: urlStr) {
            // The app also registers CFBundleURLTypes for the "file" scheme (inherited from
            // DefaultBrowser, so file:// links can be opened in the MRU browser too). On current
            // macOS, that means Finder/LaunchServices deliver essentially all file opens — not
            // just http(s) links — as GetURL Apple Events here, rather than as an 'odoc' event to
            // application(_:openFile:)/openFiles:. Without this check, every .md open was being
            // silently treated as a browser open.
            if url.isFileURL && isMarkdownFile(url) {
                // Two experiments to fix Finder's open-animation timing (deferring the Apple Event
                // reply, then a transient invisible window) both made things worse — reverted back
                // to a plain, direct call. The animation-timing quirk is being left as a known
                // cosmetic issue of this being an invisible (LSUIElement) intermediary app.
                _ = openMarkdownFiles(urls: [url])
            } else {
                _ = openUrls(urls: [url], additionalEventParamDescriptor: replyEvent)
            }
        } else {
            let errorAlert = NSAlert()
            let appName = FileManager.default.displayName(atPath: Bundle.main.bundlePath)
            errorAlert.messageText = "Error"
            errorAlert.informativeText = "\(appName) couldn't understand an URL. Please report this error."
            errorAlert.alertStyle = .critical
            errorAlert.addButton(withTitle: "Okay")
            errorAlert.addButton(withTitle: "Report")
            switch errorAlert.runModal() {
            case NSApplication.ModalResponse.alertSecondButtonReturn:
                let titleText = "Failed to open URL"
                let bodyText = "\(appName) couldn't handle to some url.\n\nInformation:\n```\n\(event.data.base64EncodedString())\n```".addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)!

                var components = URLComponents()
                components.scheme = "https"
                components.host = "github.com"
                components.path = "apexskier/DefaultBrowser/issues/new"
                components.queryItems = [
                    URLQueryItem(name: "title", value: titleText),
                    URLQueryItem(name: "body", value: bodyText)
                ]

                workspace.open(components.url!)
            default:
                break
            }
        }
    }

    // Respond to the user opening or quitting applications
    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey : Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard let change = change else {
            return
        }

        var apps: [NSRunningApplication]? = nil

        if let rv = change[NSKeyValueChangeKey.kindKey] as? UInt, let kind = NSKeyValueChange(rawValue: rv) {
            switch kind {
            case .insertion:
                // Get the inserted apps (usually only one, but you never know)
                apps = change[NSKeyValueChangeKey.newKey] as? [NSRunningApplication]
            case .removal:
                // Get the removed apps (usually only one, but you never know)
                apps = change[NSKeyValueChangeKey.oldKey] as? [NSRunningApplication]
            default:
                return // nothing to refresh; should never happen, but...
            }
        }

        updateBrowsers(apps: apps)
        updateEditors(apps: apps)
    }

    // Respond to the user changing applications
    @objc func applicationChange(notification: NSNotification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            runningBrowsers.sort { a, _ in
                a.bundleIdentifier == app.bundleIdentifier
            }
            runningEditors.sort { a, _ in
                a.bundleIdentifier == app.bundleIdentifier
            }
            if let bid = app.bundleIdentifier, validEditors.contains(bid) {
                editorLastActivated[bid] = Date()
            }
            updateMenuItems()
        }
    }

    // Respond to the user changing appearance
    @objc func appearanceChange(notification: NSNotification) {
        updateMenuItems()
        updateMenuBarIconPopUp()
    }

    func openUrls(urls: [URL], additionalEventParamDescriptor descriptor: NSAppleEventDescriptor?) -> Bool {
        guard let theBrowser = getOpeningBrowserId() else {
            let noBrowserAlert = NSAlert()
            noBrowserAlert.messageText = "No Browsers Found"
            noBrowserAlert.informativeText = "\(selfName) couldn't find any other installed browsers to use. Install something!"
            noBrowserAlert.alertStyle = .warning
            noBrowserAlert.runModal()
            return false
        }

        guard let browserUrl = workspace.urlForApplication(withBundleIdentifier: theBrowser) else {
            let alert = NSAlert()
            alert.messageText = "Browser Not Found"
            alert.informativeText = "\(selfName) couldn't find \(theBrowser)."
            alert.alertStyle = .warning
            alert.runModal()
            return false
        }

        print("opening: \(urls) in \(theBrowser)")
        let openConfiguration = NSWorkspace.OpenConfiguration()
        workspace.open(urls, withApplicationAt: browserUrl, configuration: openConfiguration)
        return true
    }

    // Open markdown files with the MRU-selected editor, routing through Obsidian's obsidian://
    // URL scheme (rather than a plain launch) when the file lives inside one of its vaults.
    // `completion` fires once the hand-off to the target editor has actually finished (not just
    // been kicked off) — not currently used by any caller, but kept since the completion-handler
    // variants of NSWorkspace.open are also how we detect/log a failed hand-off.
    func openMarkdownFiles(urls: [URL], completion: (() -> Void)? = nil) -> Bool {
        guard let firstFile = urls.first else {
            completion?()
            return false
        }

        guard let theEditor = getOpeningEditorId(forFile: firstFile) else {
            let noEditorAlert = NSAlert()
            noEditorAlert.messageText = "No Markdown Editors Found"
            noEditorAlert.informativeText = "\(selfName) couldn't find any installed markdown editors to use. Install something!"
            noEditorAlert.alertStyle = .warning
            noEditorAlert.runModal()
            completion?()
            return false
        }

        if theEditor == obsidianBundleId {
            guard let obsidianUrl = ObsidianVault.openURL(for: firstFile) else {
                completion?()
                return false
            }
            print("opening: \(firstFile) in Obsidian via \(obsidianUrl)")
            workspace.open(obsidianUrl)
            completion?()
            return true
        }

        guard let editorUrl = workspace.urlForApplication(withBundleIdentifier: theEditor) else {
            let alert = NSAlert()
            alert.messageText = "Editor Not Found"
            alert.informativeText = "\(selfName) couldn't find \(theEditor)."
            alert.alertStyle = .warning
            alert.runModal()
            completion?()
            return false
        }

        let alreadyRunning = workspace.runningApplications.contains {
            $0.bundleIdentifier?.lowercased() == theEditor.lowercased()
        }

        if alreadyRunning {
            print("opening: \(urls) in \(theEditor) (already running)")
            workspace.open(urls, withApplicationAt: editorUrl, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error {
                    print("failed to open \(urls) in \(theEditor): \(error)")
                }
                completion?()
            }
        } else {
            // Launching a not-yet-running app and handing it files in one combined call appears to
            // race with something in LaunchServices' cold-launch resolution — observed in practice
            // as the open silently falling through to the default browser instead of the intended
            // editor. Explicitly launching first and only handing off the files once the launch
            // completes sidesteps that: by the time we call open(withApplicationAt:), it's the same
            // already-running case that works reliably.
            print("launching \(theEditor) before opening: \(urls)")
            workspace.openApplication(at: editorUrl, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                guard let self else {
                    completion?()
                    return
                }
                if let error {
                    print("failed to launch \(theEditor): \(error)")
                    completion?()
                    return
                }
                DispatchQueue.main.async {
                    self.workspace.open(urls, withApplicationAt: editorUrl, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                        if let error {
                            print("failed to open \(urls) in \(theEditor) after launch: \(error)")
                        }
                        completion?()
                    }
                }
            }
        }
        return true
    }

    // MARK: Management Methods

    private func updatePreferencesBrowsersPopup() {
        browsersPopUp.removeAllItems()
        var selectedPrimaryBrowser: NSMenuItem? = nil
        for bid in validBrowsers {
            let menuItem = BrowserMenuItem(title: appName(for: bid), action: nil, keyEquivalent: "")
            menuItem.height = MENU_ITEM_HEIGHT
            menuItem.bundleIdentifier = bid
            if defaults.primaryBrowser?.lowercased() == bid.lowercased() {
                selectedPrimaryBrowser = menuItem
            }
            browsersPopUp.menu?.addItem(menuItem)
        }
        browsersPopUp.select(selectedPrimaryBrowser)
    }

    // Editor preferences UI is built programmatically (see setupEditorPreferencesSection), so
    // these outlets may not exist yet on first call — no-op until they're constructed.
    private func updatePreferencesEditorsPopup() {
        guard let editorsPopUp else { return }
        editorsPopUp.removeAllItems()
        var selectedPrimaryEditor: NSMenuItem? = nil
        for bid in validEditors {
            let menuItem = BrowserMenuItem(title: appName(for: bid), action: nil, keyEquivalent: "")
            menuItem.height = MENU_ITEM_HEIGHT
            menuItem.bundleIdentifier = bid
            if defaults.primaryEditor?.lowercased() == bid.lowercased() {
                selectedPrimaryEditor = menuItem
            }
            editorsPopUp.menu?.addItem(menuItem)
        }
        editorsPopUp.select(selectedPrimaryEditor)
    }

    private var menuBarCases = MenuBarIconStyle.allCases.flatMap({ [(true, $0), (false, $0)] })

    private func updateMenuBarIconPopUp() {
        menuBarIconPopUp.removeAllItems()
        var selected: MenuBarIconMenuItem? = nil

        guard let base = NSImage(named: "StatusBarButtonImage") else {
            return
        }

        for style in MenuBarIconStyle.allCases {
            for template in [true, false] {
                let menuItem = MenuBarIconMenuItem(title: "\(template ? "Adaptive" : "Full Color") \(style.description)", action: nil, keyEquivalent: "")
                menuItem.style = style
                menuItem.template = template
                if defaults.templateMenuBarIcon == template && defaults.menuBarIconStyle == style {
                    selected = menuItem
                }
                menuItem.image = generateIcon(
                    key: IconCacheKey(
                        appearance: NSApplication.shared.effectiveAppearance,
                        style: style,
                        template: template,
                        size: MENU_ITEM_HEIGHT * 2,
                        bundleId: defaults.primaryBrowser ?? "com.apple.Safari"
                    ),
                    base: base,
                    in: workspace
                )
                menuBarIconPopUp.menu?.addItem(menuItem)
            }
        }

        menuBarIconPopUp.select(selected)
    }

    // update list of currently running browsers
    func updateBrowsers(apps: [NSRunningApplication]?) {
        if let apps = apps {
            /// Use one of the Dictionary extensions to merge the changes into procdict.
            for app in apps.filter({ $0.bundleIdentifier != nil }) {
                let remove = app.isTerminated // insert or remove?

                if (validBrowsers.contains(app.bundleIdentifier!)) {
                    if remove {
                        if let index = runningBrowsers.firstIndex(of: app) {
                            runningBrowsers.remove(at: index)
                        }
                    } else {
                        runningBrowsers.append(app)
                    }
                }
            }
            updateMenuItems()
        }
    }

    // update list of currently running markdown editors
    func updateEditors(apps: [NSRunningApplication]?) {
        if let apps = apps {
            for app in apps.filter({ $0.bundleIdentifier != nil }) {
                let remove = app.isTerminated // insert or remove?

                if (validEditors.contains(app.bundleIdentifier!)) {
                    if remove {
                        if let index = runningEditors.firstIndex(of: app) {
                            runningEditors.remove(at: index)
                        }
                    } else {
                        runningEditors.append(app)
                    }
                }
            }
            updateMenuItems()
        }
    }

    // decide which browser should be used to open a link
    func getOpeningBrowserId() -> String? {
        // if usePrimaryBrowser is true, use that
        if let primaryBrowser = defaults.primaryBrowser, usePrimaryBrowser == true {
            return primaryBrowser
        }
        // if an explicit browser is chosen, use that
        if let explicitBrowser {
            return explicitBrowser
        }
        // use the last used browser that's running
        let blocklist = defaults.browserBlocklist
        if let firstRunningBrowser = runningBrowsers
            .filter({ runningBrowser in
                !blocklist.contains(where: { blockedBrowser in
                    runningBrowser.bundleIdentifier == blockedBrowser
                })
            })
                .first?.bundleIdentifier {
            return firstRunningBrowser
        }
        // if no browsers are running, use the primary one
        if let primaryBrowser = defaults.primaryBrowser {
            return primaryBrowser
        }
        // if no primary browser is chosen, pick the first non-blocked one
        if let firstAvailableBrowser = validBrowsers.filter({ blocklist.contains($0) }).first {
            return firstAvailableBrowser
        }
        return nil
    }

    // decide which markdown editor should be used to open a file. Obsidian is excluded unless
    // the file actually lives inside one of its registered vaults — it can't sensibly open
    // anything else, so it isn't a valid candidate at all in that case.
    func getOpeningEditorId(forFile file: URL) -> String? {
        let fileIsInVault = ObsidianVault.contains(file)
        let blocklist = defaults.editorBlocklist
        func isEligible(_ bundleId: String) -> Bool {
            if bundleId == obsidianBundleId && !fileIsInVault {
                return false
            }
            return !blocklist.contains(bundleId)
        }

        // if usePrimaryEditor is forced on, use that unconditionally — mirrors usePrimaryBrowser
        if let primaryEditor = defaults.primaryEditor, usePrimaryEditor == true, isEligible(primaryEditor) {
            return primaryEditor
        }
        // if an explicit editor is chosen, use that
        if let explicitEditor, isEligible(explicitEditor) {
            return explicitEditor
        }
        // use the most recently activated eligible editor, by real timestamp — regardless of
        // whether it's still running (openMarkdownFiles will relaunch it from disk if needed)
        if let mostRecentlyUsed = validEditors
            .filter(isEligible)
            .compactMap({ bid in editorLastActivated[bid].map { (bid, $0) } })
            .max(by: { $0.1 < $1.1 })?.0 {
            return mostRecentlyUsed
        }
        // if no eligible editor has ever been activated, use the primary one
        if let primaryEditor = defaults.primaryEditor, isEligible(primaryEditor) {
            return primaryEditor
        }
        // if no primary editor is chosen, pick the first eligible one
        if let firstAvailableEditor = validEditors.filter({ isEligible($0) }).first {
            return firstAvailableEditor
        }
        return nil
    }

    // check if DefaultBrowser is the OS level link handler
    func isCurrentlyDefaultHttpHandler() -> Bool? {
        guard let selfBundleID = Bundle.main.bundleIdentifier,
              let testUrl = URL(string: "http:"),
              let defaultApplicationUrl = workspace.urlForApplication(toOpen: testUrl),
              let currentDefaultBrowser = bundle(url: defaultApplicationUrl, defaults: defaults)?.bundleIdentifier else {
            return nil
        }
        return currentDefaultBrowser.lowercased() == selfBundleID.lowercased()
    }

    // check if DefaultBrowser is the OS level html file handler
    func isCurrentlyDefaultHTMLHandler() -> Bool? {
        guard let selfBundleID = Bundle.main.bundleIdentifier else {
            return nil
        }

        if #available(macOS 12.0, *) {
            guard let defaultApplicationUrl = workspace.urlForApplication(toOpen: UTType.html),
                  let currentDefault = bundle(url: defaultApplicationUrl, defaults: defaults)?.bundleIdentifier else {
                return nil
            }
            return currentDefault.lowercased() == selfBundleID.lowercased()
        } else {
            guard let testUrl = Bundle.main.url(forResource: "test", withExtension: "html") else {
                return nil
            }
            var err: Unmanaged<CFError>?
            let applicationUrl = LSCopyDefaultApplicationURLForURL(testUrl as CFURL, .viewer, &err)
            if let err {
                print(err)
                return nil
            }
            guard let applicationUrl,
                  let handlerBundleId = bundle(url: applicationUrl.takeUnretainedValue() as URL, defaults: defaults)?.bundleIdentifier else {
                return nil
            }
            return handlerBundleId.lowercased() == selfBundleID.lowercased()
        }
    }

    // set DefaultBrowser as the OS level link handler
    func setAsDefaultHttpHandler() {
        if #available(macOS 12.0, *) {
            if let testUrl = URL(string: "http:"),
               let defaultApplicationUrl = workspace.urlForApplication(toOpen: testUrl),
               let currentDefaultBrowser = bundle(url: defaultApplicationUrl, defaults: defaults)?.bundleIdentifier {
                defaults.primaryBrowser = currentDefaultBrowser
            }
            Task {
                do {
                    try await workspace.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http")
                } catch {
                    print("failed to set default http scheme handler: \(error)")
                    let errorAlert = await NSAlert(error: error)
                    await errorAlert.runModal()
                }
                await MainActor.run {
                    updateMenuItems()
                }
            }
        } else {
            let selfBundleID = Bundle.main.bundleIdentifier! as CFString
            for scheme in browserQualifyingSchemes {
                let error = LSSetDefaultHandlerForURLScheme(scheme as CFString, selfBundleID)
                if error != noErr {
                    print("failed to set handler for scheme \(scheme)")
                }
            }
            updateMenuItems()
        }
    }

    func setAsDefaultHTMLHandler() {
        if #available(macOS 12.0, *) {
            Task {
                do {
                    try await workspace.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: .html)
                } catch {
                    print("failed to set default html file handler: \(error)")
                    // this appears to be intentional by Apple, unfortunately
                    // https://github.com/Hammerspoon/hammerspoon/issues/2205#issuecomment-541972453
                }
            }
        } else {
            let selfBundleID = Bundle.main.bundleIdentifier! as CFString
            let error = LSSetDefaultRoleHandlerForContentType("public.html" as CFString, .viewer, selfBundleID)
            if error != noErr {
                print("failed to set html file handler")
            }
        }
    }

    // Check if app is currently registered as a login item
    func isRegisteredAsLoginItem() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        } else {
            if
                let loginItemsRef = LSSharedFileListCreate(nil, kLSSharedFileListSessionLoginItems.takeRetainedValue(), nil)?.takeRetainedValue() as LSSharedFileList?,
                let loginItems = LSSharedFileListCopySnapshot(loginItemsRef, nil)?.takeRetainedValue() as? NSArray
            {
                let appURL = Bundle.main.bundleURL
                for currentItem in loginItems {
                    let currentItemRef: LSSharedFileListItem = currentItem as! LSSharedFileListItem
                    if let itemURL = LSSharedFileListItemCopyResolvedURL(currentItemRef, 0, nil) {
                        if (itemURL.takeRetainedValue() as NSURL).isEqual(appURL) {
                            return true
                        }
                    }
                }
            }
            return false
        }
    }

    // Register for launch at login
    func registerLoginItem() {
        if #available(macOS 13.0, *) {
            if SMAppService.mainApp.status != .enabled {
                try? SMAppService.mainApp.register()
            }
        } else {
            if
                let loginItemsRef = LSSharedFileListCreate(nil, kLSSharedFileListSessionLoginItems.takeRetainedValue(), nil)?.takeRetainedValue() as LSSharedFileList?,
                let loginItems = LSSharedFileListCopySnapshot(loginItemsRef, nil)?.takeRetainedValue() as? NSArray
            {
                let appURL = Bundle.main.bundleURL
                let lastItemRef = loginItems.lastObject as! LSSharedFileListItem
                for currentItem in loginItems {
                    let currentItemRef: LSSharedFileListItem = currentItem as! LSSharedFileListItem
                    if let itemURL = LSSharedFileListItemCopyResolvedURL(currentItemRef, 0, nil) {
                        if (itemURL.takeRetainedValue() as NSURL).isEqual(appURL) {
                            print("Already registered in startup list.")
                            return
                        }
                    }
                }
                print("Registering in startup list.")
                LSSharedFileListInsertItemURL(loginItemsRef, lastItemRef, nil, nil, appURL as CFURL, nil, nil)
            }
        }
    }

    // Unregister from launch at login
    func unregisterLoginItem() {
        if #available(macOS 13.0, *) {
            if SMAppService.mainApp.status == .enabled {
                try? SMAppService.mainApp.unregister()
            }
        } else {
            if
                let loginItemsRef = LSSharedFileListCreate(nil, kLSSharedFileListSessionLoginItems.takeRetainedValue(), nil)?.takeRetainedValue() as LSSharedFileList?,
                let loginItems = LSSharedFileListCopySnapshot(loginItemsRef, nil)?.takeRetainedValue() as? NSArray
            {
                let appURL = Bundle.main.bundleURL
                for currentItem in loginItems {
                    let currentItemRef: LSSharedFileListItem = currentItem as! LSSharedFileListItem
                    if let itemURL = LSSharedFileListItemCopyResolvedURL(currentItemRef, 0, nil) {
                        if (itemURL.takeRetainedValue() as NSURL).isEqual(appURL) {
                            print("Removing from startup list.")
                            LSSharedFileListItemRemove(loginItemsRef, currentItemRef)
                            return
                        }
                    }
                }
            }
        }
    }

    // set to open automatically at login (with user consent dialog)
    func setOpenOnLogin() {
        // Check if already registered - if so, no need to ask
        if isRegisteredAsLoginItem() {
            return
        }

        // Check if we've already asked the user
        if defaults.askedAboutLaunchAtLogin {
            return
        }

        // Haven't asked yet, show consent dialog
        let alert = NSAlert()
        alert.messageText = "Launch at Login"
        alert.informativeText = "Would you like Default Browser to launch automatically when you log in?"
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        alert.alertStyle = .informational

        let response = alert.runModal()
        defaults.askedAboutLaunchAtLogin = true

        if response == .alertFirstButtonReturn {
            registerLoginItem()
        }
    }

    // reset lists of browsers
    func resetBrowsers() {
        validBrowsers = getAllBrowsers(defaults: defaults)
        userScopedBrowsers = getUserScopedBrowsers(defaults: defaults)
        runningBrowsers = []
        updateBrowsers(apps: workspace.runningApplications.sorted { a, _ in
            (a.bundleIdentifier ?? "") == defaults.primaryBrowser
        })
        // Defer updates to avoid layout recursion
        DispatchQueue.main.async {
            self.updateBlocklistTable()
            self.updateBookmarksTable()
            self.updatePreferencesBrowsersPopup()
            self.updateUserAccessTable()
        }
    }

    // reset lists of markdown editors
    func resetEditors() {
        validEditors = getAllEditors(defaults: defaults)
        userScopedEditors = getUserScopedEditors(defaults: defaults)
        runningEditors = []
        updateEditors(apps: workspace.runningApplications.sorted { a, _ in
            (a.bundleIdentifier ?? "") == defaults.primaryEditor
        })
        // Defer updates to avoid layout recursion
        DispatchQueue.main.async {
            self.updateEditorBlocklistTable()
            self.updatePreferencesEditorsPopup()
        }
    }

    private var iconCache = NSCache<IconCacheKey, NSImage>()

    func getMenuBarIcon(for bundleId: String) -> NSImage? {
        guard let h = NSApplication.shared.mainMenu?.menuBarHeight else {
            return nil
        }

        let key = IconCacheKey(
            appearance: NSApplication.shared.effectiveAppearance,
            style: defaults.menuBarIconStyle,
            template: defaults.templateMenuBarIcon,
            size: h,
            bundleId: bundleId
        )
        if let image = iconCache.object(forKey: key) {
            return image
        }
        guard let base = NSImage(named: "StatusBarButtonImage") else {
            return nil
        }

        if let image = generateIcon(key: key, base: base,in: workspace) {
            // cache so we don't have to go through all this again
            iconCache.setObject(image, forKey: key)
            return image
        }

        return nil
    }

    func appName(for bundleId: String) -> String {
        defaults.detailedAppNames
            ? getDetailedAppName(bundleId: bundleId, defaults: defaults)
            : getAppName(bundleId: bundleId, defaults: defaults)
    }

    func appName(for app: NSRunningApplication) -> String {
        defaults.detailedAppNames
            ? getDetailedAppName(bundleId: app.bundleIdentifier ?? "", defaults: defaults)
            : (app.localizedName ?? getAppName(bundleId: app.bundleIdentifier ?? "", defaults: defaults))
    }

    // refresh menu bar ui
    func updateMenuItems() {
        guard let menu = statusItem.menu else {
            return
        }

        let top = menu.indexOfItem(withTag: MenuItemTag.BrowserListTop.rawValue)
        let bottom = menu.indexOfItem(withTag: MenuItemTag.BrowserListBottom.rawValue)
        for i in ((top+1)..<bottom).reversed() {
            statusItem.menu?.removeItem(at: i)
        }

        var idx = top + 1

        let menuBrowsers = validBrowsers
        // don't show blocked browsers
            .filter({ browser in
                !defaults.browserBlocklist.contains(where: { blockedBrowser in
                    browser == blockedBrowser
                })
            })
        // sort alphabetically, to be more stable
            .sorted { appName(for: $0) < appName(for: $1) }

        for app in menuBrowsers {
            let item = BrowserMenuItem(
                title: appName(for: app),
                action: #selector(selectBrowser),
                keyEquivalent: "\(idx - top)"
            )
            item.height = MENU_ITEM_HEIGHT
            item.bundleIdentifier = app
            if !runningBrowsers.contains(where: { $0.bundleIdentifier == app }) {
                // I want the item's image to be semi-transparent in this case
                item.image = item.image?.withAlpha(0.5)
            }
            if item.bundleIdentifier == explicitBrowser {
                item.state = .on
            }
            menu.insertItem(item, at: idx)
            idx += 1
        }
        if let explicitBrowser, !menuBrowsers.contains(where: { $0 == explicitBrowser }) {
            let item = BrowserMenuItem(
                title: appName(for: explicitBrowser),
                action: #selector(selectBrowser),
                keyEquivalent: "\(idx - top)"
            )
            item.height = MENU_ITEM_HEIGHT
            item.bundleIdentifier = explicitBrowser
            item.state = .on
            menu.insertItem(item, at: idx)
        }
        if let button = statusItem.button {
            if isCurrentlyDefaultHttpHandler() != true {
                button.image = NSImage(named: "StatusBarButtonImageError")
            } else {
                if firstTime {
                    firstTime = true
                    resetBrowsers()
                    return
                }

                if let openingBrowser = getOpeningBrowserId() {
                    button.image = getMenuBarIcon(for: openingBrowser) ?? NSImage(named: "StatusBarButtonImage")
                } else {
                    button.image = NSImage(named: "StatusBarButtonImageError")
                }
            }
        }

        let item = menu.item(withTag: MenuItemTag.usePrimary.rawValue)!
        switch usePrimaryBrowser {
        case .none:
            item.state = .mixed
        case .some(let wrapped):
            item.state = wrapped ? .on : .off
        }

        // populate the markdown editor section, mirroring the browser section above
        let editorTop = menu.indexOfItem(withTag: MenuItemTag.EditorListTop.rawValue)
        let editorBottom = menu.indexOfItem(withTag: MenuItemTag.EditorListBottom.rawValue)
        for i in ((editorTop+1)..<editorBottom).reversed() {
            statusItem.menu?.removeItem(at: i)
        }

        var editorIdx = editorTop + 1

        let menuEditors = validEditors
            .filter({ editor in
                !defaults.editorBlocklist.contains(where: { blockedEditor in
                    editor == blockedEditor
                })
            })
            .sorted { appName(for: $0) < appName(for: $1) }

        for editor in menuEditors {
            let editorItem = BrowserMenuItem(
                title: appName(for: editor),
                action: #selector(selectEditor),
                keyEquivalent: ""
            )
            editorItem.height = MENU_ITEM_HEIGHT
            editorItem.bundleIdentifier = editor
            if !runningEditors.contains(where: { $0.bundleIdentifier == editor }) {
                editorItem.image = editorItem.image?.withAlpha(0.5)
            }
            if editorItem.bundleIdentifier == explicitEditor {
                editorItem.state = .on
            }
            menu.insertItem(editorItem, at: editorIdx)
            editorIdx += 1
        }
        if let explicitEditor, !menuEditors.contains(where: { $0 == explicitEditor }) {
            let editorItem = BrowserMenuItem(
                title: appName(for: explicitEditor),
                action: #selector(selectEditor),
                keyEquivalent: ""
            )
            editorItem.height = MENU_ITEM_HEIGHT
            editorItem.bundleIdentifier = explicitEditor
            editorItem.state = .on
            menu.insertItem(editorItem, at: editorIdx)
        }

        let useEditorPrimaryItem = menu.item(withTag: MenuItemTag.useEditorPrimary.rawValue)!
        switch usePrimaryEditor {
        case .none:
            useEditorPrimaryItem.state = .mixed
        case .some(let wrapped):
            useEditorPrimaryItem.state = wrapped ? .on : .off
        }
    }

    // refresh blocklist bar ui
    private func updateBlocklistTable() {
        // Blocklist membership lives in each row's checkbox now, not in table selection, so this
        // is just a plain reload (refreshes checkbox state + the primary browser's disabled
        // appearance) — no more reselecting rows, which fought the table's own scroll-into-view
        // behavior on every refresh (e.g. a menu update mid-scroll would jump the list).
        // reloadData() clears the table's selection as a side effect, so capture/restore it —
        // this runs (via the browserBlocklist KVO observer) every time a checkbox is toggled,
        // and losing the selection there would clobber a multi-row selection built up
        // specifically to toggle several checkboxes together.
        let selection = blocklistTable.selectedRowIndexes
        blocklistTable.needsDisplay = true
        blocklistTable.reloadData()
        blocklistTable.selectRowIndexes(selection, byExtendingSelection: false)
    }

    private func updateEditorBlocklistTable() {
        guard let editorBlocklistTable else { return }
        // Blocklist membership lives in each row's checkbox now, not in table selection, so this
        // is just a plain reload (refreshes checkbox state + the primary editor's disabled
        // appearance) — no more reselecting rows, which is what was fighting the table's own
        // scroll-into-view behavior on every click.
        // reloadData() clears the table's selection as a side effect, so capture/restore it —
        // this runs (via the editorBlocklist KVO observer) every time a checkbox is toggled, and
        // losing the selection there would clobber a multi-row selection built up specifically to
        // toggle several checkboxes together.
        let selection = editorBlocklistTable.selectedRowIndexes
        editorBlocklistTable.reloadData()
        editorBlocklistTable.selectRowIndexes(selection, byExtendingSelection: false)
    }

    // Finds a stack view by its Interface Builder `identifier` attribute. Used to attach the
    // programmatically-built editor preferences section (see setupEditorPreferencesSection) to
    // the existing "mainWrapper" stack view without editing MainMenu.xib by hand.
    private func findStackView(identifier: String, in view: NSView) -> NSStackView? {
        if let stack = view as? NSStackView, stack.identifier?.rawValue == identifier {
            return stack
        }
        for subview in view.subviews {
            if let found = findStackView(identifier: identifier, in: subview) {
                return found
            }
        }
        return nil
    }

    // Depth-first search for the first NSTableView anywhere within `view` — used to find the
    // table inside a just-selected tab's content so it can be made first responder.
    private func findTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView {
            return table
        }
        for subview in view.subviews {
            if let found = findTableView(in: subview) {
                return found
            }
        }
        return nil
    }

    // Builds the "Markdown Editor" preferences content (primary editor popup + blocklist table)
    // without attaching it anywhere — setupPreferencesTabs places it in the "Markdown" tab.
    private func buildEditorPreferencesSection() -> NSStackView {
        let primaryLabel = NSTextField(labelWithString: "Primary Markdown Editor:")
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.target = self
        popUp.action = #selector(primaryEditorPopUpChange(sender:))
        editorsPopUp = popUp

        // A flexible spacer between the label and popup pushes the popup to the row's trailing
        // edge — matching the Browser tab's "Primary Web Browser" row, which right-justifies its
        // popup the same way (a plain, unconstrained spacer view with low hugging priority so it
        // absorbs whatever extra width the row has).
        let primarySpacer = NSView()
        primarySpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let primaryRow = NSStackView(views: [primaryLabel, primarySpacer, popUp])
        primaryRow.orientation = .horizontal
        primaryRow.alignment = .centerY

        let explanation = NSTextField(wrappingLabelWithString: "Checked editors will never be opened by \(selfName), even if last used. Check or uncheck multiple items by selecting more than one.")
        explanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        // Matches the equivalent label above the Browser blocklist, which uses labelColor (not
        // secondaryLabelColor) in the XIB.
        explanation.textColor = .labelColor
        explanation.translatesAutoresizingMaskIntoConstraints = false
        editorExplanationLabel = explanation

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("editorNameColumn"))
        column.title = "Editor"
        column.width = 292

        // DeleteKeyTableView is the exact same class bookmarksTable already uses for its own
        // Delete-key-to-remove gesture — reused directly rather than introducing another subclass.
        let table = DeleteKeyTableView()
        table.addTableColumn(column)
        table.headerView = nil
        table.allowsMultipleSelection = true
        table.rowSizeStyle = .default
        table.rowHeight = 15
        table.intercellSpacing = NSSize(width: 3, height: 2)
        if #available(macOS 11.0, *) {
            table.style = .plain // avoid the newer inset/rounded-selection list appearance
        }
        // Faint alternating row shading — with the list now wide, it's otherwise hard to visually
        // trace a row across from its checkbox back to its name.
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = editorBlocklistDataSource
        table.delegate = editorBlocklistDataSource
        table.doubleAction = #selector(removeSelectedAdditionalEditors(sender:))
        editorBlocklistDataSource.pool.appDelegate = self
        editorBlocklistTable = table
        NotificationCenter.default.addObserver(editorBlocklistDataSource, selector: #selector(CheckboxBlocklistDataSource.windowResized(_:)), name: NSWindow.didResizeNotification, object: preferencesWindow)

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder // match the browser blocklist's IB-authored scroll view
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        editorBlocklistScrollView = scrollView
        // Width is tied dynamically to the tab's actual width in setupPreferencesTabs, once the
        // tab view exists — a fixed/minimum constant here made the list an oddly-fixed width that
        // never tracked the window's real available space.
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        // The scroll view (and only the scroll view) should absorb any extra space this section
        // is given — without an explicit low priority here, Auto Layout has no clear tie-breaker
        // for where leftover vertical space goes, and can resolve it differently across layout
        // passes (e.g. on window activation or tab switches), which showed up as the whole
        // section appearing to "jump" to the bottom of the tab.
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let clearButton = NSButton(title: "Clear", target: self, action: #selector(editorBlocklistClearPress(sender:)))
        let addEditorButton = NSButton(title: "Add Editor…", target: self, action: #selector(addEditorPress(sender:)))
        let buttonRow = NSStackView(views: [clearButton, addEditorButton])
        buttonRow.orientation = .horizontal
        buttonRow.setContentHuggingPriority(.required, for: .vertical)

        let deleteExplanation = NSTextField(wrappingLabelWithString: "Added editors appear in italics; select and press delete to remove them.")
        deleteExplanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        // Matches the equivalent label above the Browser blocklist, which uses labelColor (not
        // secondaryLabelColor) in the XIB.
        deleteExplanation.textColor = .labelColor
        deleteExplanation.translatesAutoresizingMaskIntoConstraints = false
        deleteExplanation.setContentHuggingPriority(.required, for: .vertical)
        // Tied to markdownTabContent's width in setupPreferencesTabs, same as `explanation` below —
        // NOT tied directly to `explanation`'s width here: creating a constraint directly between
        // two views that are both still detached from any window/view hierarchy reproducibly
        // deadlocked the Auto Layout engine (hung applicationDidFinishLaunching indefinitely, with
        // zero CPU usage, right at that constraint's activation). Tying each label separately to an
        // ancestor once one actually exists avoids it.
        editorDeleteExplanationLabel = deleteExplanation

        primaryRow.setContentHuggingPriority(.required, for: .vertical)
        explanation.setContentHuggingPriority(.required, for: .vertical)

        let section = NSStackView(views: [primaryRow, explanation, scrollView, buttonRow, deleteExplanation])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        return section
    }

    // Splits Preferences into "Browser" and "Markdown" tabs. The browser controls (Primary Web
    // Browser, Blocklist, Additional Browsers) are existing XIB-authored views — rather than
    // editing MainMenu.xib to reparent them (real risk: a wrong outlet/connection in a hand-edited
    // XIB fails silently at runtime, not at compile time), they're located here via outlets we
    // already have (browsersPopUp, disclosureTriangle, userAccessDisclosureTriangle) and their
    // known containing-stack-view structure, then moved into tabs entirely in code.
    private func setupPreferencesTabs() {
        guard let contentView = preferencesWindow.contentView,
              let topWrapper = findStackView(identifier: "topWrapper", in: contentView) else {
            NSLog("[DefaultOpener] setupPreferencesTabs: couldn't find topWrapper stack view; skipping")
            return
        }

        guard let browserRow = browsersPopUp.superview,
              let blocklistSection = disclosureTriangle.superview?.superview,
              let additionalBrowsersSection = userAccessDisclosureTriangle.superview?.superview else {
            NSLog("[DefaultOpener] setupPreferencesTabs: couldn't locate existing browser sections; skipping")
            return
        }

        let markdownSection = buildEditorPreferencesSection()

        let insertionIndex = topWrapper.arrangedSubviews.firstIndex(of: browserRow) ?? topWrapper.arrangedSubviews.count
        for view in [browserRow, blocklistSection, additionalBrowsersSection] {
            topWrapper.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let browserTabContent = NSStackView(views: [browserRow, blocklistSection, additionalBrowsersSection])
        browserTabContent.orientation = .vertical
        browserTabContent.alignment = .leading
        browserTabContent.spacing = 12
        browserTabContent.edgeInsets = NSEdgeInsets(top: 16, left: 4, bottom: 16, right: 4)

        let markdownTabContent = NSStackView(views: [markdownSection])
        markdownTabContent.orientation = .vertical
        markdownTabContent.alignment = .leading
        markdownTabContent.edgeInsets = NSEdgeInsets(top: 16, left: 4, bottom: 16, right: 4)
        // NSStackView.alignment has no "fill" case for the cross axis — a vertical stack's
        // "leading" alignment leaves each arranged subview at its own natural width, so without
        // this explicit constraint markdownSection just sits at its own natural width, leaving
        // blank space on the right whenever the tab is wider than the Markdown content alone needs.
        markdownSection.widthAnchor.constraint(
            equalTo: markdownTabContent.widthAnchor,
            constant: -(markdownTabContent.edgeInsets.left + markdownTabContent.edgeInsets.right)
        ).isActive = true

        // Tie the list and explanatory labels' widths to the tab's actual available width
        // (ultimately anchored by the Browser tab's own, wider content) rather than a fixed
        // constant — otherwise they're stuck at whatever that constant was regardless of how
        // much space the window actually has.
        if let scrollView = editorBlocklistScrollView {
            scrollView.widthAnchor.constraint(equalTo: markdownTabContent.widthAnchor, constant: -8).isActive = true
        }
        if let explanationLabel = editorExplanationLabel {
            explanationLabel.widthAnchor.constraint(equalTo: markdownTabContent.widthAnchor, constant: -8).isActive = true
        }
        if let deleteExplanationLabel = editorDeleteExplanationLabel {
            deleteExplanationLabel.widthAnchor.constraint(equalTo: markdownTabContent.widthAnchor, constant: -8).isActive = true
        }

        // NSTabView has a long-documented quirk (going back to the pre-Auto-Layout NSViewController
        // era) where assigning a real, non-trivial view directly as tabViewItem.view causes it to
        // mismanage that view's frame — confirmed here as: the tab that's attached later via an
        // actual user switch (as opposed to whichever tab starts out selected) gets a wrong initial
        // width, and then drifts diagonally by a few points on every single window
        // activate/deactivate cycle thereafter, compounding indefinitely. Only a real window resize
        // forces NSTabView through a layout path that computes the correct geometry. The documented
        // fix is to never hand NSTabView the real content view: wrap each in a plain, empty host
        // view instead, and pin the real content to the host's edges ourselves via Auto Layout —
        // NSTabView's own (buggy) geometry management only ever touches the trivial host.
        func hostedTabView(for content: NSView) -> NSView {
            let host = NSView()
            // Leave the host in legacy autoresizing mode (the default) rather than opting it into
            // Auto Layout — NSTabView expects to manage its assigned content view's frame the
            // traditional way, and setting translatesAutoresizingMaskIntoConstraints = false on
            // this outer view was already tried directly on browserTabContent/markdownTabContent
            // and made no difference, since it hit NSTabView's same geometry bug either way. A
            // view can host Auto Layout constraints among its own subviews regardless of that
            // flag's setting, so the real content inside can still be constraint-pinned normally.
            host.autoresizingMask = [.width, .height]
            content.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                content.topAnchor.constraint(equalTo: host.topAnchor),
                content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
            return host
        }

        let browserTabItem = NSTabViewItem(identifier: "browser")
        browserTabItem.label = "Browser"
        browserTabItem.view = hostedTabView(for: browserTabContent)

        let markdownTabItem = NSTabViewItem(identifier: "markdown")
        markdownTabItem.label = "Markdown"
        markdownTabItem.view = hostedTabView(for: markdownTabContent)

        let tabView = NSTabView()
        tabView.addTabViewItem(browserTabItem)
        tabView.addTabViewItem(markdownTabItem)
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.delegate = self

        topWrapper.insertArrangedSubview(tabView, at: min(insertionIndex, topWrapper.arrangedSubviews.count))
        // topWrapper's "leading" alignment doesn't stretch arranged subviews to its full width on
        // its own — without this, the tab view (and everything inside it, including the Markdown
        // list) just sits at its own natural width instead of tracking the window's actual width.
        tabView.widthAnchor.constraint(equalTo: topWrapper.widthAnchor).isActive = true

        // Switching tabs doesn't hand keyboard focus to anything in the newly-shown tab on its
        // own, so a table there stays visually "not focused" (gray selection) even after the user
        // clicks a row — until something explicitly makes it first responder. tabView(_:didSelect:)
        // below handles this on every switch; call it once now for whichever tab starts selected.
        self.tabView(tabView, didSelect: tabView.selectedTabViewItem)

        // mainWrapper (topWrapper's container) has a plain NSView spacer between topWrapper and the
        // "not default browser" warning row, with a very low hugging priority so it stretches to
        // fill leftover space — that made sense to push the warning to the bottom of the original,
        // much taller single-column window. With most of topWrapper's content now moved into a
        // single (much shorter) tab view, that spacer would otherwise just greedily expand to
        // consume the freed-up space instead of letting the window shrink. Pin it to a small fixed
        // gap instead.
        if let mainWrapper = findStackView(identifier: "mainWrapper", in: contentView) {
            for view in mainWrapper.arrangedSubviews where !(view is NSStackView) {
                view.translatesAutoresizingMaskIntoConstraints = false
                view.heightAnchor.constraint(equalToConstant: 16).isActive = true
            }
        }

        preferencesWindow.title = "Default Opener"
        DispatchQueue.main.async { [weak self] in
            guard let self, let contentView = self.preferencesWindow.contentView else { return }
            contentView.layoutSubtreeIfNeeded()
            self.preferencesWindow.setContentSize(contentView.fittingSize)
        }
    }

    private func updateBookmarksTable() {
        bookmarksTable.reloadData()
        bookmarksTable.needsDisplay = true
    }

    private func updateUserAccessTable() {
        bookmarksTable.reloadData()
        userAccessTable.needsDisplay = true
    }

    // MARK: UI Actions

    // user clicked a browser from the menu
    @objc func selectBrowser(sender: NSMenuItem) {
        if let menuItem = sender as? BrowserMenuItem {
            if explicitBrowser == menuItem.bundleIdentifier {
                setExplicitBrowser(bundleId: nil)
            } else {
                setExplicitBrowser(bundleId: menuItem.bundleIdentifier)
            }
        }
    }

    // user clicked a browser from the menu
    func setExplicitBrowser(bundleId: String?) {
        if #available(macOS 11.0, *) {
            let intent: INIntent
            if let bid = bundleId {
                let setBrowserIntent = SetCurrentBrowserIntent()
                setBrowserIntent.browser = bid
                if let browserAppUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid),
                   let browserBundle = Bundle(url: browserAppUrl),
                   let appName = browserBundle.appName {
                    setBrowserIntent.suggestedInvocationPhrase = "Set browser to \(appName)"
                }
                intent = setBrowserIntent
            } else {
                intent = ClearCurrentBrowserIntent()
                intent.suggestedInvocationPhrase = "Use last used browser"
            }
            let donatedInteraction = INInteraction(intent: intent, response: nil)
            donatedInteraction.donate()
        }

        explicitBrowser = bundleId
        updateMenuItems()
    }

    // user clicked a markdown editor from the menu
    @objc func selectEditor(sender: NSMenuItem) {
        if let menuItem = sender as? BrowserMenuItem {
            if explicitEditor == menuItem.bundleIdentifier {
                setExplicitEditor(bundleId: nil)
            } else {
                setExplicitEditor(bundleId: menuItem.bundleIdentifier)
            }
        }
    }

    func setExplicitEditor(bundleId: String?) {
        explicitEditor = bundleId
        updateMenuItems()
    }

    // use user's primary browser -- user clicked the menu button
    @objc func usePrimary(sender: NSMenuItem) {
        setUsePrimary(state: sender.state != .on)
    }

    func setUsePrimary(state: Bool) {
        if defaults.primaryBrowser != "" {
            usePrimaryBrowser = state
            statusItem.button?.appearsDisabled = state
            explicitBrowser = nil
            updateMenuItems()
        }
    }

    @objc func useEditorPrimary(sender: NSMenuItem) {
        setUseEditorPrimary(state: sender.state != .on)
    }

    func setUseEditorPrimary(state: Bool) {
        if defaults.primaryEditor != nil {
            usePrimaryEditor = state
            explicitEditor = nil
            updateMenuItems()
        }
    }

    @objc func openPreferencesWindow(sender: AnyObject) {
        // Activate the app BEFORE ordering the window front, and use the forceful
        // ignoringOtherApps variant unconditionally. The newer argument-less NSApp.activate()
        // (macOS 14+) applies its own heuristics and can silently decline to activate — the window
        // then gets ordered front but stays behind whatever app was already frontmost, with no
        // error or signal that it happened. ignoringOtherApps: true is deprecated in favor of
        // activate(), but it's the right tool for a direct, deliberate user click on our own menu
        // item (as opposed to some background app grabbing focus uninvited, which is what the
        // newer API's heuristics guard against), and doesn't exhibit the same silent failure.
        // Accessory-policy (no Dock icon, i.e. LSUIElement) apps like this one are the sharpest
        // edge case for window activation in general — see
        // https://steipete.me/posts/2025/showing-settings-from-macos-menu-bar-items for a deeper
        // workaround (temporarily switching to .regular activation policy) if this ever recurs.
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindow.makeKeyAndOrderFront(sender)
    }

    @objc func openAboutWindow(sender: AnyObject) {
        aboutWindow.center()
        aboutWindow.makeKeyAndOrderFront(sender)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func setupMenus() {
        let about = {
            NSMenuItem(title: "About \(self.selfName)", action: #selector(self.openAboutWindow), keyEquivalent: "")
        }
        let preferences = {
            NSMenuItem(title: "Preferences...", action: #selector(self.openPreferencesWindow), keyEquivalent: ",")
        }
        let quit = {
            NSMenuItem(title: "Quit", action: #selector(self.terminate), keyEquivalent: "q")
        }

        // Set up status bar menu
        let statusMenu = NSMenu()
        statusMenu.addItem(about())
        statusMenu.addItem(preferences())
        let browserListTop = NSMenuItem.separator()
        browserListTop.tag = MenuItemTag.BrowserListTop.rawValue
        statusMenu.addItem(browserListTop)
        let browserListBottom = NSMenuItem.separator()
        browserListBottom.tag = MenuItemTag.BrowserListBottom.rawValue
        statusMenu.addItem(browserListBottom)
        let usePrimaryMenuItem = NSMenuItem(title: "Use Primary Browser", action: #selector(usePrimary), keyEquivalent: "0")
        usePrimaryMenuItem.tag = MenuItemTag.usePrimary.rawValue
        statusMenu.addItem(usePrimaryMenuItem)
        statusMenu.addItem(NSMenuItem.separator())
        statusMenu.addItem(NSMenuItem(title: "Markdown Editor", action: nil, keyEquivalent: ""))
        let editorListTop = NSMenuItem.separator()
        editorListTop.tag = MenuItemTag.EditorListTop.rawValue
        statusMenu.addItem(editorListTop)
        let editorListBottom = NSMenuItem.separator()
        editorListBottom.tag = MenuItemTag.EditorListBottom.rawValue
        statusMenu.addItem(editorListBottom)
        let useEditorPrimaryMenuItem = NSMenuItem(title: "Use Primary Editor", action: #selector(useEditorPrimary), keyEquivalent: "")
        useEditorPrimaryMenuItem.tag = MenuItemTag.useEditorPrimary.rawValue
        statusMenu.addItem(useEditorPrimaryMenuItem)
        statusMenu.addItem(quit())
        statusItem.menu = statusMenu
        
        // Set up application menu bar with standard macOS shortcuts
        let mainMenu = NSMenu()
        
        // Application menu
        let appMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        
        appMenu.addItem(about())
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(preferences())
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(
            title: "Hide \(selfName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        ))
        let hideOthersItem = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        ))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(quit())
        
        mainMenu.addItem(appMenuItem)
        
        // Window menu
        let windowMenu = NSMenu(title: "Window")
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        
        windowMenu.addItem(NSMenuItem(
            title: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        ))
        windowMenu.addItem(NSMenuItem(
            title: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        ))
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(NSMenuItem(
            title: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        ))
        
        mainMenu.addItem(windowMenuItem)
        NSApp.mainMenu = mainMenu
    }

    @objc func terminate() {
        NSApplication.shared.terminate(self)
    }

    func relaunchApp() {
        let alert = NSAlert()
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Cancel")
        alert.messageText = "Restart Required"
        alert.informativeText = "The app needs to restart for access to change. Restart now?"
        alert.alertStyle = .informational

        switch alert.runModal() {
        case NSApplication.ModalResponse.alertFirstButtonReturn:
            let appPath = Bundle.main.bundleURL
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.environment = ["OPENNEXT": "TRUE"]

            NSWorkspace.shared.openApplication(at: appPath, configuration: configuration) { app, error in
                app?.activate(options: .activateAllWindows)
                if let error {
                    print("Failed to relaunch: \(error)")
                } else {
                    // Terminate current instance after new one starts
                    DispatchQueue.main.async {
                        NSApplication.shared.terminate(self)
                    }
                }
            }
        default:
            // User cancelled, just refresh without restart
            resetBrowsers()
        }
    }

    // MARK: IB Actions

    @IBAction func primaryBrowserPopUpChange(sender: NSPopUpButton) {
        guard let item = sender.selectedItem as? BrowserMenuItem,
              let bid = item.bundleIdentifier else {
            return
        }
        defaults.primaryBrowser = bid
        defaults.browserBlocklist = defaults.browserBlocklist.filter { $0 != bid }
        // Defer updates to avoid layout recursion
        DispatchQueue.main.async {
            self.updateBlocklistTable()
            self.updateMenuItems()
        }
    }

    @objc func primaryEditorPopUpChange(sender: NSPopUpButton) {
        guard let item = sender.selectedItem as? BrowserMenuItem,
              let bid = item.bundleIdentifier else {
            return
        }
        defaults.primaryEditor = bid
        defaults.editorBlocklist = defaults.editorBlocklist.filter { $0 != bid }
        DispatchQueue.main.async {
            self.updateEditorBlocklistTable()
            self.updateMenuItems()
        }
    }

    @IBAction func menuBarIconPopupChange(sender: NSPopUpButton) {
        guard let item = sender.selectedItem as? MenuBarIconMenuItem,
        let template = item.template,
        let style = item.style else { return }
        defaults.templateMenuBarIcon = template
        defaults.menuBarIconStyle = style
        updateMenuBarIconPopUp()
        updateMenuItems()
    }

    @IBAction func descriptiveAppNamesChange(sender: NSButton) {
        defaults.detailedAppNames = sender.state == .on
        // Defer updates to avoid layout recursion
        DispatchQueue.main.async {
            self.updateMenuItems()
            self.updateBlocklistTable()
            self.updatePreferencesBrowsersPopup()
        }
    }

    @IBAction func showWindowChange(sender: NSButton) {
        defaults.openWindowOnLaunch = sender.state == .on
    }

    @IBAction func launchAtLoginChange(sender: NSButton) {
        if sender.state == .on {
            registerLoginItem()
        } else {
            unregisterLoginItem()
        }
    }

    @IBAction func setAsDefaultPress(sender: AnyObject) {
        setAsDefaultHttpHandler()
        // Relabeled from "Set Default" to "OK" since this window has no other way to dismiss it —
        // but only the title changed; it never actually closed the window, so clicking it looked
        // like it did nothing (setAsDefaultHttpHandler() is a no-op once already default).
        preferencesWindow.close()
    }

    func doDisclosure(sender: NSButton) {
        let expanded = sender.state == .on
        if sender == disclosureTriangle {
            blocklistStackView.isHidden = !expanded
            // Defer updates to avoid layout recursion
            DispatchQueue.main.async {
                self.updateBlocklistTable()
                self.updatePreferencesBrowsersPopup()
            }
        } else if sender == userAccessDisclosureTriangle {
            userAccessStackView.isHidden = !expanded
        }
    }

    @IBAction func blocklistDisclosurePress(sender: NSButton) {
        doDisclosure(sender: sender)
    }

    @IBAction func infoDisclosurePress(sender: NSButton) {
        doDisclosure(sender: sender)
    }

    @IBAction func blocklistClearPress(sender: NSButton) {
        defaults.browserBlocklist.removeAll()
    }

    @objc func editorBlocklistClearPress(sender: NSButton) {
        defaults.editorBlocklist.removeAll()
    }

    // For editors that don't declare markdown document type handling themselves (same situation
    // as Obsidian, just not common enough to hardcode) — lets the user manually add one.
    @objc func addEditorPress(sender: NSButton) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        if #available(macOS 11.0, *) {
            openPanel.allowedContentTypes = [.applicationBundle]
        } else {
            openPanel.allowedFileTypes = ["app"]
        }
        openPanel.directoryURL = URL(fileURLWithPath: "/Applications")
        openPanel.prompt = "Add Editor"
        openPanel.message = "Select an application to always offer as a markdown editor, even if it doesn't declare markdown support itself."

        openPanel.begin { [weak self] response in
            guard response == .OK, let url = openPanel.urls.first, let self else {
                return
            }
            guard let bundleId = Bundle(url: url)?.bundleIdentifier else {
                let alert = NSAlert()
                alert.messageText = "Couldn't Read App"
                alert.informativeText = "\(url.lastPathComponent) doesn't look like a valid application."
                alert.alertStyle = .warning
                alert.runModal()
                return
            }
            if !self.defaults.additionalEditors.contains(bundleId) {
                self.defaults.additionalEditors.append(bundleId)
            }
            self.resetEditors()
        }
    }

    // Removes manually-added editors from the list entirely on Delete (via EditorBlocklistTableView)
    // — mirrors revokeBookmark's pattern. Only bundle ids actually in additionalEditors are
    // removable this way; discovered/hardcoded editors in the selection are silently left alone,
    // since deleting them wouldn't mean anything (they'd just reappear on the next resetEditors()).
    @objc func removeSelectedAdditionalEditors(sender: NSTableView) {
        let selected = sender.selectedRowIndexes.compactMap { validEditors.indices.contains($0) ? validEditors[$0] : nil }
        let removable = Set(selected).intersection(defaults.additionalEditors)
        guard !removable.isEmpty else {
            return
        }
        defaults.additionalEditors = defaults.additionalEditors.filter { !removable.contains($0) }
        defaults.editorBlocklist = defaults.editorBlocklist.filter { !removable.contains($0) }
        resetEditors()
    }
}

extension AppDelegate: NSTabViewDelegate {
    // Switching tabs doesn't hand keyboard focus to anything in the newly-shown tab on its own —
    // without this, a table there stays visually "not focused" (gray selection) even after being
    // clicked, since it was never actually made first responder.
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        // Force a layout pass as soon as a tab's content is actually part of the visible
        // hierarchy, rather than waiting for whatever later event happens to trigger one.
        DispatchQueue.main.async { [weak self] in
            self?.preferencesWindow.contentView?.layoutSubtreeIfNeeded()
        }

        guard let view = tabViewItem?.view, let tableView = findTableView(in: view) else {
            return
        }
        preferencesWindow.makeFirstResponder(tableView)
    }
}

extension AppDelegate: NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Watch for when the user opens and quits applications
        workspace.addObserver(self, forKeyPath: "runningApplications", options: [.old, .new], context: nil)
        // Watch for when the user switches applications
        workspace.notificationCenter.addObserver(
            self,
            selector: #selector(applicationChange),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        // Watch for dark mode change
        workspace.notificationCenter.addObserver(
            self,
            selector: #selector(appearanceChange),
            name: NSNotification.Name(rawValue: "AppleInterfaceThemeChangedNotification"),
            object: nil
        )
        // Watch for the user opening links
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent),
            forEventClass: UInt32(kInternetEventClass),
            andEventID: UInt32(kAEGetURL)
        )
        // Watch for user defaults changes
        primaryBrowserObserver = defaults.observe(\.PrimaryBrowser) { _, _ in
            DispatchQueue.main.async {
                self.resetBrowsers()
            }
        }
        blockedBrowserObserver = defaults.observe(\.BrowserBlocklist) { _, _ in
            DispatchQueue.main.async {
                self.resetBrowsers()
            }
        }
        primaryEditorObserver = defaults.observe(\.PrimaryEditor) { _, _ in
            DispatchQueue.main.async {
                self.resetEditors()
            }
        }
        blockedEditorObserver = defaults.observe(\.EditorBlocklist) { _, _ in
            DispatchQueue.main.async {
                self.resetEditors()
            }
        }
    }

    private var selfName: String {
        getAppName(bundleId: Bundle.main.bundleIdentifier!, defaults: defaults)
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        defaults.register(defaults: defaultSettings)

        // Discovery and menu/status-item setup happen first, before either blocking modal below —
        // both handleGetURLEvent (file:// opens) and application(_:openFile:)/openFiles: (odoc
        // opens) can fire as soon as this app is launched to service an open request, and on a
        // fresh cold launch that request can arrive while a runModal() alert below is still
        // un-dismissed. Since neither alert is about markdown editors at all, validEditors must be
        // populated before either one, or a .md open racing ahead of the user dismissing them would
        // hit an empty list and report "No Markdown Editors Found".
        if let button = statusItem.button {
            button.image = NSImage(named: "StatusBarButtonImage")
            button.allowsMixedState = true
        }

        setupMenus()
        setupPreferencesTabs()

        resetBrowsers()
        resetEditors()
        updateMenuItems()
        updateMenuBarIconPopUp()

        if isCurrentlyDefaultHttpHandler() == false {
            let notDefaultAlert = NSAlert()
            notDefaultAlert.addButton(withTitle: "Set As Default")
            notDefaultAlert.addButton(withTitle: "Cancel")
            notDefaultAlert.messageText = "Set Default Browser"
            notDefaultAlert.informativeText = "\(selfName) must be set as your default browser. Your current default will be remembered."
            notDefaultAlert.alertStyle = .warning
            switch notDefaultAlert.runModal() {
            case NSApplication.ModalResponse.alertFirstButtonReturn:
                setAsDefaultHttpHandler()
            default:
                break
            }
        } else {
            notDefaultText.isHidden = true
        }

        setOpenOnLogin()

        // open window?
        preferencesWindow.isReleasedWhenClosed = false
        if defaults.openWindowOnLaunch {
            preferencesWindow.makeKeyAndOrderFront(self)
        }

        showWindowCheckbox.state = defaults.openWindowOnLaunch ? .on : .off
        launchAtLoginCheckbox.state = isRegisteredAsLoginItem() ? .on : .off
        descriptiveAppNamesCheckbox.state = defaults.detailedAppNames ? .on : .off
        blocklistStackView.isHidden = true
        userAccessStackView.isHidden = true

        blocklistTable.dataSource = blocklistDelegate
        blocklistTable.delegate = blocklistDelegate
        blocklistDelegate.pool.appDelegate = self
        blocklistTable.usesAlternatingRowBackgroundColors = true
        if #available(macOS 11.0, *) {
            blocklistTable.style = .plain // avoid the newer inset/rounded-selection list appearance
        }
        NotificationCenter.default.addObserver(blocklistDelegate, selector: #selector(CheckboxBlocklistDataSource.windowResized(_:)), name: NSWindow.didResizeNotification, object: preferencesWindow)

        userAccessTable.dataSource = userAccessDelegate
        userAccessTable.delegate = userAccessDelegate
        userAccessTable.doubleAction = #selector(requestFileAccess)
        userAccessDelegate.parent = self

        bookmarksTable.dataSource = bookmarksDelegate
        bookmarksTable.delegate = bookmarksDelegate
        bookmarksTable.doubleAction = #selector(revokeBookmark)
        bookmarksDelegate.parent = self

        // Defer UI updates to avoid layout recursion during initial setup
        DispatchQueue.main.async {
            self.updateBlocklistTable()
            self.updatePreferencesBrowsersPopup()

            // show blocklist contents if it's being used
            if !self.defaults.browserBlocklist.isEmpty {
                self.disclosureTriangle.state = .on
                self.doDisclosure(sender: self.disclosureTriangle)
            }
        }
        userAccessDisclosureTriangle.state = .off

        logo.image = NSImage(named: "AppIcon")

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "<unknown>"
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "<unknown>"
        versionString.attributedStringValue = NSAttributedString(
            string: "Version \(shortVersion) (\(buildNumber))",
            attributes: [
                .paragraphStyle: paragraph,
                .font: font,
            ]
        )

        let cameronLink = NSAttributedString(
            string: "Cameron Little",
            attributes: [
                .link: "https://camlittle.com",
                .paragraphStyle: paragraph,
                .font: font,
            ]
        )
        let builtBy = NSMutableAttributedString(
            string: "Built by ",
            attributes: [
                .paragraphStyle: paragraph,
                .font: font,
            ]
        )
        builtBy.append(cameronLink)
        builtByString.allowsEditingTextAttributes = true
        builtByString.attributedStringValue = builtBy

        let githubLink = NSAttributedString(
            string: "GitHub project",
            attributes: [
                .link: "https://github.com/apexskier/DefaultBrowser",
                .paragraphStyle: paragraph,
                .font: font,
            ]
        )
        githubString.allowsEditingTextAttributes = true
        githubString.attributedStringValue = githubLink
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        false
    }

    func applicationWillTerminate(aNotification: NSNotification) {
        // Insert code here to tear down your application
        workspace.removeObserver(self, forKeyPath: "runningApplications")
        workspace.notificationCenter.removeObserver(self, name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSAppleEventManager.shared().removeEventHandler(forEventClass: UInt32(kInternetEventClass), andEventID: UInt32(kAEGetURL))
        primaryBrowserObserver?.invalidate()
        primaryEditorObserver?.invalidate()
    }

    private func isMarkdownFile(_ url: URL) -> Bool {
        markdownEditorQualifyingExtensions.contains(url.pathExtension.lowercased())
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        if isMarkdownFile(url) {
            return openMarkdownFiles(urls: [url])
        }
        return openUrls(urls: [url], additionalEventParamDescriptor: nil)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        let markdownUrls = urls.filter(isMarkdownFile)
        let otherUrls = urls.filter { !isMarkdownFile($0) }
        if !markdownUrls.isEmpty {
            _ = openMarkdownFiles(urls: markdownUrls)
        }
        if !otherUrls.isEmpty {
            _ = openUrls(urls: otherUrls, additionalEventParamDescriptor: nil)
        }
    }

    @available(macOS 11.0, *)
    func application(_ application: NSApplication, handlerFor intent: INIntent) -> Any? {
        switch intent {
        case is SetCurrentBrowserIntent:
            return SetCurrentBrowserIntentHandler()
        case is ClearCurrentBrowserIntent:
            return ClearCurrentBrowserIntentHandler()
        default:
            return nil
        }
    }

    @objc func requestFileAccess(sender: NSTableView) {
        userAccessDelegate.requestAccess(sender: sender)
    }

    @IBAction func requestFileAccessButton(sender: Any) {
        userAccessDelegate.requestAccess(sender: nil)
    }

    @objc func revokeBookmark(sender: NSTableView) {
        bookmarksDelegate.revokeBookmark(sender: sender)
    }
}

// Abstracts over the two checkbox-blocklist tables (browsers, markdown editors) so
// CheckboxBlocklistDataSource below can drive either one without knowing which. appDelegate is
// settable (rather than injected at init) because the pool is built as a stored property before
// self is fully initialized — the same deferred-assignment pattern the old parent-per-delegate
// design used.
protocol BlocklistPool: AnyObject {
    var appDelegate: AppDelegate? { get set }
    var candidates: [String] { get }
    var primary: String? { get }
    var blocklist: [String] { get set }
    var manuallyAdded: [String] { get } // bundle ids visually marked as manually added (italics)
    var table: NSTableView? { get }
}

extension BlocklistPool {
    var manuallyAdded: [String] { [] }
}

final class BrowserBlocklistPool: BlocklistPool {
    weak var appDelegate: AppDelegate?
    var candidates: [String] { appDelegate?.validBrowsers ?? [] }
    var primary: String? { appDelegate?.defaults.primaryBrowser }
    var blocklist: [String] {
        get { appDelegate?.defaults.browserBlocklist ?? [] }
        set { appDelegate?.defaults.browserBlocklist = newValue }
    }
    var table: NSTableView? { appDelegate?.blocklistTable }
}

final class EditorBlocklistPool: BlocklistPool {
    weak var appDelegate: AppDelegate?
    var candidates: [String] { appDelegate?.validEditors ?? [] }
    var primary: String? { appDelegate?.defaults.primaryEditor }
    var blocklist: [String] {
        get { appDelegate?.defaults.editorBlocklist ?? [] }
        set { appDelegate?.defaults.editorBlocklist = newValue }
    }
    var manuallyAdded: [String] { appDelegate?.defaults.additionalEditors ?? [] }
    var table: NSTableView? { appDelegate?.editorBlocklistTable }
}

// Shared by the browser and markdown-editor blocklist tables — both are a list of candidate apps
// with a primary (always disabled/unblockable) and a checkbox per row for blocklist membership,
// independent of table selection. An earlier version drove membership from table selection
// itself (selecting a row blocklisted it), which fought the list's own scroll-into-view behavior
// on every selection change and made discontiguous ⌘-click selection unpredictable. A checkbox
// avoids both problems.
class CheckboxBlocklistDataSource: NSObject {
    let pool: BlocklistPool

    init(pool: BlocklistPool) {
        self.pool = pool
    }
}

extension CheckboxBlocklistDataSource: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        pool.candidates.count
    }
}

extension CheckboxBlocklistDataSource: NSTableViewDelegate {
    // The primary app's checkbox is always unchecked and disabled (it can never be blocklisted),
    // so its row shouldn't be selectable either — otherwise it can end up part of a multi-row
    // selection whose checkbox-toggle silently skips it, which looks broken.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard pool.candidates.indices.contains(row) else {
            return true
        }
        return pool.candidates[row] != pool.primary
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let appDelegate = pool.appDelegate, let col = tableColumn, pool.candidates.indices.contains(row) else {
            return nil
        }
        let id = pool.candidates[row]
        let isPrimary = id == pool.primary

        let cell: NSTableCellView
        let checkbox: NSButton
        if let reused = tableView.makeView(withIdentifier: col.identifier, owner: self) as? NSTableCellView,
           let reusedCheckbox = reused.subviews.first(where: { $0 is NSButton }) as? NSButton {
            cell = reused
            checkbox = reusedCheckbox
        } else {
            cell = NSTableCellView()
            cell.identifier = col.identifier
            // A view built from scratch (rather than an IB-authored cell template) has no
            // autoresizing mask by default, so it never tracks the row's width as the column
            // resizes — it just keeps whatever frame it had when first created. widthSizable
            // makes it stretch with the row the same way an IB-authored cell would.
            cell.autoresizingMask = [.width, .height]

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail
            let checkboxButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            checkboxButton.translatesAutoresizingMaskIntoConstraints = false

            cell.addSubview(imageView)
            cell.addSubview(textField)
            cell.addSubview(checkboxButton)
            cell.imageView = imageView
            cell.textField = textField

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: MENU_ITEM_HEIGHT),
                imageView.heightAnchor.constraint(equalToConstant: MENU_ITEM_HEIGHT),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                // Indented by the overlay scrollbar's width in addition to the usual 5pt inset, so
                // the scroller doesn't cover the checkboxes when it appears.
                checkboxButton.trailingAnchor.constraint(
                    equalTo: cell.trailingAnchor,
                    constant: -(5 + NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay))
                ),
                checkboxButton.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                textField.trailingAnchor.constraint(lessThanOrEqualTo: checkboxButton.leadingAnchor, constant: -8),
            ])
            checkbox = checkboxButton
        }

        if let url = appDelegate.workspace.urlForApplication(withBundleIdentifier: id) {
            let image = appDelegate.workspace.icon(forFile: url.relativePath)
            image.size = NSSize(width: MENU_ITEM_HEIGHT, height: MENU_ITEM_HEIGHT)
            cell.imageView?.image = image
        }
        // Manually-added apps (via "Add Editor…" — browsers have no such mechanism, so this is
        // always empty there) are visually distinguished with a slant. Neither
        // NSFontManager.convert(_:toHaveTrait:) nor NSFontDescriptor symbolic traits reliably
        // produce a distinct italic face for the system font (both can silently no-op) —
        // .obliqueness applies a shear transform to the glyphs directly, which works regardless of
        // whether the font has a true italic design.
        let isManuallyAdded = pool.manuallyAdded.contains(id)
        let baseFont = cell.textField?.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let textColor: NSColor = isPrimary ? .disabledControlTextColor : .controlTextColor
        let name = appDelegate.appName(for: id)
        if isManuallyAdded {
            cell.textField?.attributedStringValue = NSAttributedString(
                string: name,
                attributes: [.font: baseFont, .obliqueness: 0.2, .foregroundColor: textColor]
            )
        } else {
            cell.textField?.font = baseFont
            cell.textField?.textColor = textColor
            cell.textField?.stringValue = name
        }

        checkbox.tag = row
        checkbox.target = self
        checkbox.action = #selector(checkboxToggled(sender:))
        checkbox.state = (pool.blocklist.contains(id) && !isPrimary) ? .on : .off
        checkbox.isEnabled = !isPrimary
        return cell
    }

    // Some of these tables' columns never actually resize as the table's own width changes (the
    // browser table's XIB-declared resizeWithTable="YES"/columnAutoresizingStyle="lastColumnOnly"
    // never took effect on resize; the editor table's column is never given a
    // columnAutoresizingStyle at all) — the table/scrollview itself tracks the window correctly,
    // it's specifically the column inside it that stays pinned at its initial width, leaving a
    // growing dead zone of table background to the right of the real content. sizeToFit() forces
    // the column to fill the table's current width.
    @objc func windowResized(_ note: Notification) {
        pool.table?.sizeToFit()
    }

    @objc func checkboxToggled(sender: NSButton) {
        guard pool.candidates.indices.contains(sender.tag), let table = pool.table else {
            return
        }
        // If the toggled row is part of a multi-row selection, apply the same resulting state to
        // every selected row instead of just the one that was clicked — matches the explanatory
        // label ("check or uncheck multiple items by selecting more than one"), since a plain
        // NSButton in a view-based table row has no built-in multi-row checkbox propagation the
        // way a cell-based checkbox column does.
        var rows: IndexSet = [sender.tag]
        if table.selectedRowIndexes.contains(sender.tag) {
            rows = table.selectedRowIndexes
        }

        let newState = sender.state == .on
        var blocklist = pool.blocklist
        for row in rows {
            guard pool.candidates.indices.contains(row) else { continue }
            let id = pool.candidates[row]
            guard id != pool.primary else { continue }
            if newState {
                if !blocklist.contains(id) {
                    blocklist.append(id)
                }
            } else {
                blocklist.removeAll { $0 == id }
            }
        }
        pool.blocklist = blocklist
        // Setting blocklist triggers the browserBlocklist/editorBlocklist KVO observer
        // (resetBrowsers/resetEditors -> updateBlocklistTable/updateEditorBlocklistTable), which
        // reloads the table and preserves selection — no need to reload here too, and reloading
        // twice was clearing the selection before that observer's preserve/restore logic ever got
        // a chance to run.
    }
}

private func commonAncestor(of urls: [URL]) -> URL? {
    guard !urls.isEmpty else { return nil }

    // For a single URL, return its parent directory
    if urls.count == 1 {
        return urls[0]
    }

    // Get standardized path components for all URLs
    let pathComponentArrays = urls.map { $0.standardized.pathComponents }
    let minLength = pathComponentArrays.map { $0.count }.min() ?? 0

    // Find common prefix of path components
    var commonComponents: [String] = []
    for i in 0..<minLength {
        let component = pathComponentArrays[0][i]
        if pathComponentArrays.allSatisfy({ $0[i] == component }) {
            commonComponents.append(component)
        } else {
            break
        }
    }

    guard !commonComponents.isEmpty else { return nil }
    return URL(fileURLWithPath: commonComponents.joined(separator: "/"))
}

class UserAccessBrowserDelegate: NSObject {
    weak var parent: AppDelegate?

    @objc func requestAccess(sender: NSTableView?) {
        guard let parent else {
            return
        }

        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = true
        openPanel.allowsMultipleSelection = true
        openPanel.prompt = "Grant Access"
        openPanel.message = "Select a browser or directory containing additional browsers to grant access."

        if let selectedIndexes = sender?.selectedRowIndexes, !selectedIndexes.isEmpty {
            let selectedURLs = selectedIndexes.compactMap { index in
                if parent.userScopedBrowsers.indices.contains(index) {
                    return parent.userScopedBrowsers[index]
                }
                return nil
            }
            openPanel.directoryURL = commonAncestor(of: selectedURLs)
        }

        openPanel.begin { response in
            guard response == .OK else {
                return
            }

            for selectedURL in openPanel.urls {
                do {
                    let bookmarkData = try selectedURL.bookmarkData(
                        options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    parent.defaults.setBookmark(key: selectedURL, value: bookmarkData)
                } catch {
                    print("Failed to create bookmark for \(selectedURL.path)): \(error)")
                }
            }

            // Bundle loading is cached, so we can't refresh our list of browsers without a full relaunch
            parent.relaunchApp()
        }
    }
}

extension UserAccessBrowserDelegate: NSTableViewDataSource { }

extension UserAccessBrowserDelegate: NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        parent?.userScopedBrowsers.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let parent, let col = tableColumn else {
            return nil
        }

        let url = parent.userScopedBrowsers[row]
        let cell = tableView.makeView(withIdentifier: col.identifier, owner: self) as! NSTableCellView
        cell.textField?.stringValue = url.relativePath
        return cell
    }
}

class BookmarksDelegate: NSObject {
    weak var parent: AppDelegate?


    var bookmarkUrls: [URL] {
        get {
            guard let parent else { return [] }
            return Array(parent.defaults.bookmarks.keys).sorted { $0.path.localizedCompare($1.path) == .orderedAscending }
        }
    }

    @objc func revokeBookmark(sender: NSTableView?) {
        guard let parent else {
            return
        }

        if let selectedIndexes = sender?.selectedRowIndexes, !selectedIndexes.isEmpty {
            let bookmarkUrlsCopy = bookmarkUrls
            for selectedRow in selectedIndexes {
                let urlToRevoke = bookmarkUrlsCopy[selectedRow]
                parent.defaults.removeBookmark(key: urlToRevoke)
                // Bundle loading is cached, so we can't refresh our list of browsers without a full relaunch
                parent.relaunchApp()
            }
        }
    }
}

extension BookmarksDelegate: NSTableViewDataSource { }

extension BookmarksDelegate: NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        parent?.defaults.bookmarks.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn else {
            return nil
        }

        guard row < bookmarkUrls.count else {
            return nil
        }

        let url = bookmarkUrls[row]
        let cell = tableView.makeView(withIdentifier: col.identifier, owner: self) as! NSTableCellView
        cell.textField?.stringValue = url.relativePath
        return cell
    }
}
