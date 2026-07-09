# Markdown Editor MRU Feature: Design, Build, Bugs Overcome, Upstream Contributions, and Upstreaming Considerations

This document covers the markdown-editor MRU (most-recently-used) extension built on top of
apexskier/DefaultBrowser in this fork (`~/Projects/defaultopener`, remote `fork` =
`marcpbailey/DefaultBrowser`, remote `upstream` = `apexskier/DefaultBrowser`), including the three
unrelated bug-fix PRs contributed back upstream along the way, and what would actually be required,
from a macOS security/sandboxing/App Store compliance standpoint, to bring the markdown feature
itself back to a sandboxed, upstreamable build.

## 1. What we designed

DefaultBrowser already solved "open a link with whichever browser I used most recently." The goal
was to extend that same idea to markdown files: double-clicking a `.md` file should open it in
whichever markdown-capable editor (BBEdit, VS Code, Typora, Antigravity IDE, Obsidian) was used
most recently, as a second capability bolted on next to the existing browser MRU, not a
replacement for it.

Key design decisions:

- **Two independent dispatch paths, reused.** DefaultBrowser already had `handleGetURLEvent` (fires
  for `http`/`https`/`file` scheme opens via the `CFBundleURLTypes` registration) driving the
  browser-open path. Markdown files come through the same event handler (since the app registers
  a `file` URL scheme handler); the fix was a single branch inside it: if the incoming file is
  `.md`/`.markdown`, route to a new markdown-opening path instead of the browser path. Everything
  else (HTML/XHTML handling, the browser pool itself) is untouched.
- **MRU tracking is activation-based and content-agnostic.** A single
  `NSWorkspace.didActivateApplicationNotification` observer already re-sorted `runningBrowsers` to
  track "most recently activated." The same observer now also maintains an independently-filtered
  second pool, `runningEditors`, for editors.
- **Discovery via UTType, same API as browsers.** `getAllBrowsers` discovers candidates via
  `NSWorkspace.urlsForApplications(toOpen:)` keyed on the `http`/`https` schemes; `getAllEditors`
  does the same keyed on `UTType(filenameExtension: "md")`. BBEdit, VS Code, Typora, and Antigravity
  IDE are all discovered this way, since they declare real markdown UTI conformance.
- **Obsidian needed hardcoding, not just special open-handling.** Obsidian's own `Info.plist`
  declares only `CFBundleTypeName = "All Files"`, `LSItemContentTypes = [public.data,
  public.content]`, `LSHandlerRank = None` — it doesn't register as a markdown or text viewer at
  all, so discovery never surfaces it. It's force-added to the candidate list in code, gated by
  vault membership, and driven exclusively through its `obsidian://open?path=...` URL scheme
  instead of `NSWorkspace.open(urls:withApplicationAt:...)`.
- **Duplicate rather than abstract.** Adding a second MRU pool meant duplicating candidate
  discovery, a running/MRU list, a blocklist, a "get opening app id" function, and a Preferences UI
  section. Chose to duplicate as parallel code (`validEditors`/`runningEditors`/`editorBlocklist`,
  `getOpeningEditorId(forFile:)`) rather than refactor the existing, working browser
  implementation into a shared abstraction used only twice — zero regression risk to browser
  behavior Marc explicitly wanted preserved untouched.

## 2. What we built

- **`DefaultOpener/SystemUtilities.swift`**: `getAllEditors`/`getUserScopedEditors`, mirroring the
  browser discovery functions, keyed on the markdown UTType; force-appends `md.obsidian`.
- **`DefaultOpener/ObsidianVault.swift`**: reads Obsidian's vault registry
  (`~/Library/Application Support/obsidian/obsidian.json`), exposes `contains(_ file: URL) -> Bool`
  (path-component-boundary matching, so a vault at `/Users/marc/Projects/linkcast` doesn't
  false-positive-match `linkcast2`), and `openURL(for:)` to build the `obsidian://open?path=...`
  URL. Obsidian resolves the containing vault itself from an absolute path, so no vault-name or
  vault-relative-path computation is needed.
- **`DefaultOpener/Defaults.swift`**: new persisted keys `PrimaryEditor`, `EditorBlocklist`,
  `AdditionalEditors` (editors manually added because they don't declare markdown UTI support,
  same situation as Obsidian but not common enough to hardcode), plus two added later in this
  effort: `DebugLoggingEnabled`/`DebugLogFilePath` (gated diagnostic logging, off by default) and
  `DetectObsidianVaults` (on by default; see section 3).
- **`DefaultOpener/AppDelegate.swift`**:
  - `getOpeningEditorId(forFile:)`: explicit override, then `usePrimaryEditor`-forced primary, then
    most-recently-activated eligible editor, then primary, then first available — same shape as
    `getOpeningBrowserId()`, with Obsidian excluded from eligibility unless the file is in a
    registered vault (or vault detection is turned off, see section 3).
  - `openMarkdownFiles(urls:completion:)`: resolves the editor, branches to the Obsidian URL-scheme
    path or the normal `NSWorkspace.open(urls:withApplicationAt:configuration:)` path.
  - `openViaAppleEvent(urls:bundleIdentifier:)`: a raw `'aevt'/'odoc'` Apple Event fallback for
    editors that reject `NSWorkspace.open` (see section 3, ChatGPT Atlas).
  - Editor Preferences UI, built entirely programmatically rather than via XIB edits (primary
    editor popup, blocklist table with an "Add Editor…" flow, and a "Detect Obsidian vault
    documents" checkbox with an explanatory tooltip), placed in its own "Markdown" preferences tab
    alongside the existing "Browser" tab.
  - Menu bar: a second list section mirroring the browser section, showing the current
    markdown-editor pick.
- **`DefaultOpener/Info.plist`**: additive `CFBundleDocumentTypes` entry for
  `net.daringfireball.markdown`/`public.plain-text`, extensions `md`/`markdown`.
- **`DefaultOpener.entitlements`**: `com.apple.security.automation.apple-events` added (for the
  Apple Event fallback); `com.apple.security.app-sandbox` ultimately set to `false` (see section 3).

## 3. What we overcame

### NSTabView's frame-drift bug (the single biggest time sink in this effort)

Splitting the programmatically-built Preferences window into "Browser" and "Markdown" tabs
(`setupPreferencesTabs()`) hit a long-documented `NSTabView` quirk, dating back to the
pre-Auto-Layout `NSViewController` era, that cost more debugging time than every other issue in
this document combined.

Symptom: assigning a real, non-trivial content view directly to `NSTabViewItem.view` works fine
for whichever tab starts out selected, but the tab attached later, only reachable by an actual
user tab-switch, gets the wrong initial width the first time it's shown, and then **drifts
diagonally by a few points on every single window activate/deactivate cycle thereafter**,
compounding indefinitely the longer the window stays open. Nothing about the drift is triggered by
user interaction with the content itself; it's `NSTabView`'s own geometry management
mismanaging the assigned view's frame. Only a real window resize forces `NSTabView` through a
layout path that computes the correct geometry, briefly correcting it until the next
activate/deactivate cycle resumes the drift.

Root cause: `NSTabView` was never fully updated for Auto Layout, and still expects to manage its
assigned content view's frame the traditional (pre-Auto-Layout) way. Setting
`translatesAutoresizingMaskIntoConstraints = false` directly on the real content view
(`browserTabContent`/`markdownTabContent`) was tried and made no difference, since it hits the
same buggy geometry path regardless.

Fix (the documented workaround for this specific `NSTabView` quirk): never hand `NSTabView` the
real content view at all. Wrap each tab's real content in a plain, empty host `NSView` left in
legacy autoresizing mode (`autoresizingMask = [.width, .height]`, the default), assign the *host*
to `NSTabViewItem.view`, and pin the real content to the host's edges with an ordinary Auto Layout
constraint set (`content.translatesAutoresizingMaskIntoConstraints = false`, then
leading/trailing/top/bottom anchors to the host). `NSTabView`'s buggy geometry management only
ever touches the trivial host view now; the real content, constraint-pinned inside it, is
unaffected by the drift. See `hostedTabView(for:)` in `setupPreferencesTabs()`.

Two smaller, related traps hit while building the same tabbed UI, worth documenting alongside the
main bug since they'd otherwise resurface for anyone touching this code again:

- **Auto Layout deadlock from constraining two detached views to each other.** Tying a label's
  width directly to another label's width (both still detached from any window/view hierarchy at
  construction time, before being added to the tab content) reproducibly deadlocked the Auto
  Layout engine: `applicationDidFinishLaunching` hung indefinitely, with zero CPU usage, right at
  that constraint's activation. Fix: tie each label's width separately to an actual ancestor view
  once one exists (done in `setupPreferencesTabs`, after the tab content views are attached),
  never directly between two sibling views that aren't attached to anything yet.
- **Tab switches don't hand keyboard focus to the new tab's content.** Switching tabs doesn't
  automatically make anything in the newly-shown tab first responder, so a table view there stays
  visually "not focused" (gray selection highlight) even after being clicked, until something
  explicitly calls `makeFirstResponder`. Fixed via an `NSTabViewDelegate.tabView(_:didSelect:)`
  implementation that finds the first `NSTableView` in the newly-selected tab's view hierarchy and
  makes it first responder, called both on every real tab switch and once manually at setup time
  for whichever tab starts selected (since `didSelect` doesn't fire for the initial state).

### Obsidian never being selected as an editor, regardless of settings

Symptom: Obsidian configured as primary editor with "Use Primary Editor" on, but never opened
anything, in or out of any vault.

Root cause: `ObsidianVault.swift` reads `~/Library/Application Support/obsidian/obsidian.json`
directly via `Data(contentsOf:)`. While the app was sandboxed with only the
`com.apple.security.files.user-selected.read-only` entitlement (which grants access solely to
files the user explicitly picked via an `NSOpenPanel`, not arbitrary paths), this read silently
failed under `try?`. `vaultPaths` was therefore always `[]`, `ObsidianVault.contains` always
returned `false`, and `isEligible(md.obsidian)` in `getOpeningEditorId` was always `false` — no
file, vault or not, could ever resolve to Obsidian.

### ChatGPT Atlas failing to open `.md` files ("cannot open the specified document")

Symptom: Atlas added as a custom/additional editor (it displays `.md` fine once opened, but
doesn't declare markdown UTI support), Finder/DefaultOpener reporting it "cannot open the
specified document or URL."

Root cause, confirmed via unified log analysis (`log stream`/`log show`, switching diagnostic
logging from `NSLog`/`print` to `os_log("%{public}@", ...)` since the unified logging system
redacts dynamic content as `<private>` for sandboxed apps by default): `NSWorkspace.open`'s
underlying LaunchServices call failed with `kLSAppDoesNotClaimTypeErr` (OSStatus -10820) — "One or
more documents are of types not supported by the target application **(sandboxed callers
only)**." This restriction is enforced specifically when the *calling* app (DefaultOpener) is
sandboxed, regardless of what the target app can actually do.

Attempted fix: send a raw `'aevt'/'odoc'` Apple Event directly (`openViaAppleEvent`), bypassing
`NSWorkspace`'s LaunchServices UTI validation entirely — a documented workaround for exactly this
restriction ([Apple Developer Forums thread](https://developer.apple.com/forums/thread/723842)).
This required an entitlement (`com.apple.security.automation.apple-events`, missing entirely from
`DefaultOpener.entitlements` until added here) and an Info.plist usage-description key
(`NSAppleEventsUsageDescription`, macOS 10.14+ TCC requirement). **This fallback was never tested
in isolation while still sandboxed** — see section 5, this is a real open question for any future
upstreaming attempt.

### The actual fix: disabling App Sandbox entirely

Since this fork is for personal use only and never going through the Mac App Store, sandboxing
was fighting the app's actual purpose (reading arbitrary file paths, sending Apple Events to
arbitrary apps) rather than protecting anything meaningful. Setting
`com.apple.security.app-sandbox` to `false` fixed both problems at the root, confirmed via log
analysis: `.md` files in the `linkcast` Obsidian vault correctly resolved `theEditor=md.obsidian`
and opened via the `obsidian://` URL; ChatGPT Atlas's direct `NSWorkspace.open(withApplicationAt:)`
call started succeeding outright (`completion: error=nil`), with the Apple Event fallback not
even needed in practice once sandbox was off.

### Side effects of disabling sandbox, also overcome

- **"Lost" preferences.** Sandboxed apps store `UserDefaults` in
  `~/Library/Containers/<bundle-id>/Data/Library/Preferences/<bundle-id>.plist`, not the classic
  `~/Library/Preferences/`. The moment sandbox came off, the app started reading/writing the
  classic path instead, which was empty — nothing was actually lost, but it looked that way.
  Recovered via `defaults import com.marcbailey.defaultopener <old container plist>`.
- **`defaults write <bundle-id> ...` CLI gotcha.** Even after disabling sandbox, `defaults write
  com.marcbailey.defaultopener ...` (by bundle ID) kept redirecting to the *stale* container path,
  because the `defaults` CLI's container-redirection logic keys off the **presence of the
  `~/Library/Containers/<bundle-id>` folder on disk**, not the app's live entitlements. The folder
  still existed (leftover from when the app was sandboxed), so the redirection persisted even
  though the running (now non-sandboxed) app itself reads/writes the classic path directly.
  Workaround: use the explicit-path form, `defaults write
  ~/Library/Preferences/com.marcbailey.defaultopener <key> <value>`, which bypasses the bundle-ID
  lookup entirely. (The stale container folder could be deleted to make bundle-ID-based `defaults
  write` behave normally again; not done, since it was out of scope and outside the project
  directory.)

### Diagnostic logging redaction

`NSLog`'s dynamic/interpolated content is redacted as `<private>` by the unified logging system
for sandboxed apps by default. Fixed by switching to the function-based `os_log(_:log:type:...)`
API with an explicit `%{public}@` format specifier (not the newer `Logger` struct, which requires
macOS 11+; this project's deployment target is macOS 10.15).

### Chrome/Safari/Atlas UTI declaration differences (explains an earlier open question)

Investigated why Chrome and Safari could be set as markdown "editors" with no issues even before
sandbox was disabled, while Atlas failed. Google Chrome's `Info.plist` declares
`LSItemContentTypes: public.text` — a modern, UTI-based claim. Since `.md` resolves to
`net.daringfireball.markdown` on a system with BBEdit/Typora/MacDown/VS Code installed, and that
UTI conforms to `public.plain-text` → `public.text`, Chrome's declaration genuinely and correctly
covers `.md` through real UTI inheritance. Safari and ChatGPT Atlas, in contrast, both declare
**only** a legacy-style plain-text entry (`CFBundleTypeExtensions: [txt]` + MIME `text/plain` + OS
type `TEXT`, no `LSItemContentTypes` at all) — which binds narrowly to the literal `.txt`
extension and does not extend to `.md` the way an explicit UTI conformance declaration would.
Safari was never actually tested under the strict sandboxed-caller check (see section 5's open
question), so it's not confirmed whether Safari would have passed or failed that check the same
way Atlas did.

### Git history correction for the three upstream PRs (see section 4)

The three PRs described below were initially merged into `fork/DefaultOpener` using `git merge -s
ours`, which records ancestry but applies zero file content — confirmed via
`git diff <merge-commit>^ <merge-commit> --stat` returning empty. This was caught and corrected:
a disposable branch (`remerge-attempt`) was built from a pre-correction commit, a bridge merge
(`git merge --allow-unrelated-histories -s ours`, safe here because the two histories' trees were
already byte-identical, confirmed via `git diff <import-commit> upstream/main --stat` returning
empty) established shared ancestry, and then each PR branch was merged for real with genuine
3-way conflict resolution. Modify/delete conflicts arose from git's rename detection failing to
link `DefaultBrowser/AppDelegate.swift` (old path) to `DefaultOpener/AppDelegate.swift` (new path,
renamed earlier in this fork's history) across the large diff; resolved each time by confirming
the incoming content was already present at the new path, then removing the stray duplicate.
Final state verified via `git diff <pre-correction-commit> HEAD --stat` returning empty (no
regression) combined with the individual merge commits containing real, resolved diffs.

## 4. What we proposed upstream

Three independent bug-fix PRs were opened against `apexskier/DefaultBrowser` (fork remote:
`marcpbailey/DefaultBrowser`) and, separately, genuinely merged (not just referenced) into
`fork/DefaultOpener`:

| Branch | PR | Merge commit in `fork/DefaultOpener` |
|---|---|---|
| `fix/imagetransforms-typecheck` | apexskier/DefaultBrowser#46 | `ed38dcd` |
| `fix/window-activation` | apexskier/DefaultBrowser#47 | `e1388af` |
| `feat/checkboxed-list` | apexskier/DefaultBrowser#48 | `39f6e0b` |

None of these three PRs touch `.entitlements` or `Info.plist` (confirmed via `git diff` across
each merge commit's parents, scoped to those files, returning empty in every case) — they're
fully orthogonal to everything in sections 2, 3, and 5. These are genuinely upstreamable as-is,
independent of what happens with the markdown feature or the sandbox question.

## 5. Security and compliance: what upstreaming the Markdown feature would actually require

`apexskier/DefaultBrowser` is a Mac App Store app. Evidence: the original (pre-fork)
entitlements already had `com.apple.security.app-sandbox: true` and
`com.apple.security.files.user-selected.read-only: true`; `Info.plist` carries
`LSApplicationCategoryType` and `ITSAppUsesNonExemptEncryption`, both App Store Connect metadata
fields; and the README documents a sandbox limitation directly: *"With App Sandboxing, we only
have automatic access to system installed browsers. To enable browsers outside of `/Applications`,
open 'Preferences', expand 'Additional Browsers', select the browsers you want to enable, and
double click to grant access."*

**The Mac App Store requires the App Sandbox entitlement, without exception.** A non-sandboxed
app cannot be distributed that way. The sandbox removal made in this fork (section 3) is correct
for a personal, ad-hoc-signed, non-Store install, but is a non-starter for anything upstreamed to
`apexskier/DefaultBrowser`.

What each piece of the sandbox-dependent work in this feature would actually need, to go back into
a sandboxed build:

- **Obsidian vault detection.** Fixable without disabling sandbox. `DefaultBrowser` already has
  the sanctioned pattern for exactly this class of problem: the security-scoped bookmark mechanism
  built for "Additional Browsers"/"Additional Editors" (`bookmark(url:defaults:)`,
  `startAccessingSecurityScopedResource`/`stopAccessingSecurityScopedResource` in
  `SystemUtilities.swift`). Instead of a raw `Data(contentsOf:)` read of `obsidian.json`, prompt
  the user once via an `NSOpenPanel` to pick the Obsidian config file (or its containing folder),
  store a security-scoped bookmark, and resolve it on each subsequent read. This is a small,
  well-precedented change, not a new pattern. The `DetectObsidianVaults` preference added in this
  fork (section 2, off by default not required, on by default) becomes a genuinely useful
  complementary option in a sandboxed build: it lets a user skip vault detection entirely and
  avoid the one-time file-access grant altogether, if they don't want to bother with it.
- **ChatGPT Atlas / `kLSAppDoesNotClaimTypeErr`.** No known sandboxed workaround exists for the
  underlying `NSWorkspace.open` restriction itself — it's enforced unconditionally for sandboxed
  callers regardless of entitlements. **However, this fork never actually tested the Apple Event
  fallback (`openViaAppleEvent`, with the `com.apple.security.automation.apple-events`
  entitlement) while still sandboxed** — the Obsidian bug was found and sandbox was disabled
  before that specific test could happen in isolation. `kLSAppDoesNotClaimTypeErr` is raised by
  `NSWorkspace`'s LaunchServices-level document-type validation specifically; a raw Apple Event
  does not go through that validation path at all. It is plausible, but **not confirmed**, that
  the Apple Event fallback alone (sandboxed, with the automation entitlement) would successfully
  open Atlas without needing to disable sandbox at all. This is the single most important open
  question for anyone attempting to upstream this feature: **re-enable sandbox, keep the
  `com.apple.security.automation.apple-events` entitlement and `NSAppleEventsUsageDescription`,
  and retest Atlas via the Apple Event path alone** before concluding the feature can't be
  App-Store-compliant for editors like Atlas. Both the entitlement and the one-time TCC consent
  prompt it triggers are standard, App-Store-safe mechanisms already used by other automation
  utilities on the Store.
- **Everything else (BBEdit, VS Code, Typora, MacDown discovery and opening) needs no sandbox
  changes at all.** These editors declare real markdown UTI conformance, so `NSWorkspace.open`
  succeeds for them even under the strict sandboxed-caller check — this was true throughout
  testing, both before and after sandbox was disabled.
- **Safari was never conclusively tested under the strict sandboxed check either** (see section
  3) — low priority, since Safari isn't a markdown editor Marc actually uses, but worth noting for
  completeness if this document is used as a checklist later.

**Summary for upstreaming:** the markdown MRU feature's core design (discovery, MRU pools,
Preferences UI, menu bar integration) is already sandbox-compatible as built and needs no changes.
Obsidian's vault detection needs a straightforward bookmark-based rework (well-precedented,
low-risk). ChatGPT Atlas support is the only genuinely uncertain piece, and resolving that
uncertainty (Apple Event fallback under sandbox, untested) is the concrete next step before
attempting to upstream editor support for apps like Atlas that don't declare markdown UTI
conformance.
