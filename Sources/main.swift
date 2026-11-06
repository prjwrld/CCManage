// Accounts for Claude - a menu bar front end for `claude-multi`.
//
// Status (which profiles exist, which are running, which account each one is
// signed in to, how much of each plan's limits is used) is read straight from
// disk and from the process table, so the popover opens instantly. Anything
// that changes state (open, restart, sync, doctor) is delegated to the
// `claude-multi` script, which stays the single source of truth for how
// profiles are launched and synced.

import AppKit
import SwiftUI
import ServiceManagement

// MARK: - Paths and constants (mirror the ones at the top of claude-multi)

let home = FileManager.default.homeDirectoryForCurrentUser.path
let profilesRoot = home + "/.claude-profiles"
let accountsMap = profilesRoot + "/accounts.tsv"
let mainDataDir = home + "/Library/Application Support/Claude"
let syncLogPath = home + "/.claude/logs/claude-sessions-sync.log"
let claudeBundleID = "com.anthropic.claudefordesktop"
let claudeAppPath = "/Applications/Claude.app"
let appRepoURL = URL(string: "https://github.com/prjwrld/accounts-for-claude")!
/// The command-line tool this app drives (by Emin Budak, MIT).
let cliRepoURL = URL(string: "https://github.com/EminBudak/claude-multi-account#quick-start")!

/// claude-multi lives in ~/.local/bin, which a Finder-launched app does not
/// have on its PATH, so look in the usual places explicitly.
let cliPath: String? = [
    home + "/.local/bin/claude-multi",
    "/opt/homebrew/bin/claude-multi",
    "/usr/local/bin/claude-multi",
].first { FileManager.default.isExecutableFile(atPath: $0) }

// MARK: - Model

/// How much of the plan's limits the account has used: live from claude.ai
/// (LiveUsage.swift) when that works, otherwise the sample Claude Desktop last
/// saved in plan-usage-history.json, which can be hours old.
struct Usage {
    let fiveHour: Int   // % of the 5-hour session limit
    let week: Int       // % of the weekly limit
    let updated: Date
    var fiveHourResets: Date? = nil   // only known live
    var weekResets: Date? = nil
    var isLive = false

    /// Live numbers are refreshed every 30 s while the popover is open, so 3
    /// minutes means refreshing stopped working. Saved ones lag by design.
    var isStale: Bool { Date().timeIntervalSince(updated) > (isLive ? 3 * 60 : 10 * 60) }
}

struct Profile {
    let name: String          // folder name under ~/.claude-profiles, or "main"
    let dataDir: String
    let account: String?      // e-mail (or short uuid) it is signed in to; nil = never signed in
    var usage: Usage?
    var liveError: String?    // why live usage failed last time, if it did
    var app: NSRunningApplication?
    /// True when this row's account is open in the plain Claude app rather than
    /// in the profile's own window (see foldMainApp).
    var viaMainApp = false

    var isMain: Bool { name == "main" }
    var isRunning: Bool { app != nil }
    var isSignedIn: Bool { account != nil }

    /// What the row shows as its title: the profile's e-mail, or for the plain
    /// Claude app, the account it is signed in to.
    var title: String { isMain ? (account ?? "Claude") : name }

    /// A profile named after an e-mail address that is signed in to some other
    /// account - exactly the "my old chats are gone" situation.
    var accountMismatch: Bool {
        guard !isMain, let account, name.contains("@") else { return false }
        return account.lowercased() != name.lowercased()
    }
}

// MARK: - Reading state from disk and the process table

/// The full argument vector of another process of the same user, via the
/// KERN_PROCARGS2 sysctl (the data `ps -o command=` prints).
/// Layout: argc (Int32) | exec path \0 | padding \0... | argv[0] \0 | argv[1] \0 ...
func arguments(of pid: pid_t) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
    let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
    var i = 4
    while i < size && buf[i] != 0 { i += 1 }   // skip the exec path
    while i < size && buf[i] == 0 { i += 1 }   // skip the padding
    var args: [String] = []
    while args.count < argc && i < size {
        let start = i
        while i < size && buf[i] != 0 { i += 1 }
        args.append(String(decoding: buf[start..<i], as: UTF8.self))
        i += 1
    }
    return args
}

/// Running Claude Desktop instances keyed by user-data dir ("" = main profile).
func runningInstances() -> [String: NSRunningApplication] {
    var result: [String: NSRunningApplication] = [:]
    for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == claudeBundleID {
        let flag = "--user-data-dir="
        let dir = arguments(of: app.processIdentifier)
            .first { $0.hasPrefix(flag) }
            .map { String($0.dropFirst(flag.count)) } ?? ""
        result[standardized(dir)] = app
    }
    return result
}

func standardized(_ path: String) -> String {
    path.isEmpty ? "" : (path as NSString).standardizingPath
}

func readJSON(_ path: String) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// lastKnownAccountUuid from a profile's config.json, nil if never signed in.
func accountUUID(in dataDir: String) -> String? {
    guard let uuid = readJSON(dataDir + "/config.json")?["lastKnownAccountUuid"] as? String,
          !uuid.isEmpty else { return nil }
    return uuid
}

/// The newest sample in plan-usage-history.json:
///   {"version":2,"samples":[{"t":<ms>,"org":"<uuid>","u":{"fh":<%>,"sd":<%>}}, ...]}
func savedUsage(in dataDir: String) -> Usage? {
    guard let samples = readJSON(dataDir + "/plan-usage-history.json")?["samples"] as? [[String: Any]]
    else { return nil }
    func time(_ s: [String: Any]) -> Double { (s["t"] as? NSNumber)?.doubleValue ?? 0 }
    guard let newest = samples.max(by: { time($0) < time($1) }),
          let u = newest["u"] as? [String: Any] else { return nil }
    let fiveHour = (u["fh"] as? NSNumber)?.intValue
    let week = (u["sd"] as? NSNumber)?.intValue
    guard fiveHour != nil || week != nil else { return nil }
    return Usage(fiveHour: fiveHour ?? 0, week: week ?? 0,
                 updated: Date(timeIntervalSince1970: time(newest) / 1000))
}

/// Whichever is newer: the last live answer or the last saved sample.
func latestUsage(in dataDir: String) -> Usage? {
    let saved = savedUsage(in: dataDir)
    if let live = liveUsage[dataDir], live.updated > (saved?.updated ?? .distantPast) { return live }
    return saved
}

/// uuid -> e-mail, learned by claude-multi from the profile names.
func loadAccountMap() -> [String: String] {
    guard let text = try? String(contentsOfFile: accountsMap, encoding: .utf8) else { return [:] }
    var map: [String: String] = [:]
    for line in text.split(separator: "\n") {
        let cols = line.split(separator: "\t", maxSplits: 1)
        if cols.count == 2 { map[String(cols[0])] = String(cols[1]) }
    }
    return map
}

func loadProfiles() -> [Profile] {
    let running = runningInstances()
    let map = loadAccountMap()
    func profile(_ name: String, _ dir: String, _ app: NSRunningApplication?) -> Profile {
        Profile(name: name, dataDir: dir,
                account: accountUUID(in: dir).map { map[$0] ?? String($0.prefix(8)) },
                usage: latestUsage(in: dir), liveError: liveErrors[dir], app: app)
    }

    var profiles: [Profile] = []
    let names = (try? FileManager.default.contentsOfDirectory(atPath: profilesRoot)) ?? []
    for name in names.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
        let dir = profilesRoot + "/" + name
        var isDir: ObjCBool = false
        guard !name.hasPrefix("."), FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue
        else { continue }
        profiles.append(profile(name, dir, running[standardized(dir)]))
    }
    profiles.append(profile("main", mainDataDir, running[""]))
    return foldMainApp(profiles)
}

/// The plain Claude app is often signed in to the same account as one of the
/// profiles. Listing both made one account look "Stopped" and "Running" at
/// once, so merge them into the profile's row: it counts as running when either
/// window is open, and shows whichever usage sample is newer. Only when both
/// windows are open do they stay separate rows, since there really are two.
func foldMainApp(_ profiles: [Profile]) -> [Profile] {
    guard let mainIndex = profiles.firstIndex(where: \.isMain),
          let account = profiles[mainIndex].account?.lowercased(),
          let index = profiles.firstIndex(where: { !$0.isMain && $0.name.lowercased() == account })
    else { return profiles }
    let main = profiles[mainIndex]
    var merged = profiles
    var row = merged[index]
    if row.isRunning && main.isRunning { return profiles }
    if !row.isRunning, let app = main.app {
        row.app = app
        row.viaMainApp = true
    }
    if let u = main.usage, u.updated > (row.usage?.updated ?? .distantPast) { row.usage = u }
    merged[index] = row
    merged.remove(at: mainIndex)
    return merged
}

/// Time and session count from the last line of the sync log.
func lastSync() -> (time: String, sessions: String?)? {
    guard let text = try? String(contentsOfFile: syncLogPath, encoding: .utf8),
          let line = text.split(separator: "\n").last.map(String.init)
    else { return nil }
    let time = line.split(separator: " ").dropFirst().first.map { String($0.prefix(5)) } ?? "?"
    let count = line.range(of: #"\((\d+) session"#, options: .regularExpression)
        .map { String(line[$0].filter(\.isNumber)) }
    return (time, count)
}

// MARK: - Menu bar icon

/// Claude's own menu bar logo, read from the installed Claude.app so this
/// project ships no copy of it. Bundle.image(forResource:) picks up the @2x
/// and @3x files too, so it stays sharp on every display.
func claudeLogo() -> NSImage {
    if let image = Bundle(path: claudeAppPath)?.image(forResource: "TrayIconTemplate") {
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }
    let fallback = NSImage(systemSymbolName: "asterisk", accessibilityDescription: "Accounts for Claude")!
    fallback.isTemplate = true
    return fallback
}

// MARK: - Running claude-multi

struct CommandResult {
    let status: Int32
    let output: String
}

func runCLI(_ args: [String]) -> CommandResult {
    guard let cliPath else {
        return CommandResult(status: 127, output: "claude-multi was not found in ~/.local/bin, /opt/homebrew/bin or /usr/local/bin.")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: cliPath)
    process.arguments = args
    var env = ProcessInfo.processInfo.environment
    // Finder gives apps a minimal PATH; the script needs python3, osascript, etc.
    env["PATH"] = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                   "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
    process.environment = env
    process.standardInput = FileHandle.nullDevice   // no tty: the script uses dialogs instead of prompts
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch {
        return CommandResult(status: 126, output: "Could not run claude-multi: \(error.localizedDescription)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
}

// MARK: - Popover state and actions

final class Store: ObservableObject {
    @Published var profiles: [Profile] = []
    @Published var busy: String?           // non-nil while a claude-multi command runs
    @Published var refreshing = false      // live usage request in flight
    @Published var syncTime: String?
    @Published var syncSessions: String?
    @Published var openAtLogin = false

    func reload() {
        profiles = loadProfiles()
        let sync = lastSync()
        syncTime = sync?.time
        syncSessions = sync?.sessions
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// Everything the popover can ask the app to do.
struct Actions {
    let open: (String) -> Void
    let restart: (String) -> Void
    let fixSignIn: (String) -> Void
    let remove: (String) -> Void
    let addAccount: () -> Void
    let openAll: () -> Void
    let quitAll: () -> Void
    let sync: () -> Void
    let showSyncLog: () -> Void
    let doctor: () -> Void
    let toggleLogin: () -> Void
    let quitApp: () -> Void
}

// MARK: - Popover views

let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)

/// Bar colour for a share of a limit that is used up (0-100).
func usageTint(_ percent: Int) -> Color {
    // TODO(human)
    return .accentColor
}

struct PopoverView: View {
    @ObservedObject var store: Store
    let act: Actions

    private var accounts: [Profile] { store.profiles.filter { !$0.isMain } }
    private var main: Profile? { store.profiles.first(where: \.isMain) }
    private var busy: Bool { store.busy != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if cliPath == nil { setupNotice; Divider() }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(accounts.enumerated()), id: \.element.name) { i, profile in
                    AccountRow(profile: profile, index: i, disabled: busy, act: act)
                }
                if let main {
                    Text("Default Claude app")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 2)
                    AccountRow(profile: main, index: accounts.count, disabled: busy, act: act)
                }
            }
            .padding(6)
            Divider()
            footer
        }
        .frame(width: 330)
        // A popover is see-through by default: over a white web page its dark
        // mode text sat on light grey. A solid window colour keeps the contrast
        // the same whatever is behind it, in light and dark mode.
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: claudeLogo())
                .renderingMode(.template)
                .resizable().frame(width: 16, height: 16)
                .foregroundStyle(claudeOrange)
            Text("Accounts for Claude").font(.system(size: 13, weight: .semibold))
            Spacer()
            if let label = store.busy {
                ProgressView().controlSize(.small)
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                if store.refreshing { ProgressView().controlSize(.mini).help("Updating usage…") }
                Text(store.syncTime.map { "Synced \($0)" } ?? "Not synced yet")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(store.syncSessions.map { "\($0) sessions in every account" } ?? "")
                IconButton(symbol: "arrow.triangle.2.circlepath", help: "Sync sessions and update usage now",
                           action: act.sync)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// Shown until claude-multi is installed: without it the app can show
    /// accounts and usage, but can't open, add or sync them.
    private var setupNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "wrench.and.screwdriver").foregroundStyle(claudeOrange)
            VStack(alignment: .leading, spacing: 2) {
                Text("One more step").font(.system(size: 12, weight: .semibold))
                Text("Install claude-multi to open, add and sync accounts.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("How") { NSWorkspace.shared.open(cliRepoURL) }
                .controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            PillButton(symbol: "plus", title: "Add", help: "Add an account", action: act.addAccount)
                .disabled(busy)
            PillButton(symbol: "macwindow.on.rectangle", title: "Open all", help: "Open every account",
                       action: act.openAll)
                .disabled(busy || !accounts.contains { !$0.isRunning })
            PillButton(symbol: "power", title: "Quit all", help: "Quit every Claude window",
                       action: act.quitAll)
                .disabled(!store.profiles.contains(where: \.isRunning))
            Spacer()
            Menu {
                Button("Run Doctor…", action: act.doctor).disabled(busy)
                Button("Open Sync Log", action: act.showSyncLog)
                Toggle("Open at Login", isOn: Binding(get: { store.openAtLogin }, set: { _ in act.toggleLogin() }))
                Divider()
                Button("About Accounts for Claude") { NSWorkspace.shared.open(appRepoURL) }
                Button("Quit Accounts for Claude", action: act.quitApp)
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 14))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }
}

struct AccountRow: View {
    let profile: Profile
    let index: Int
    let disabled: Bool
    let act: Actions
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(text: profile.title, running: profile.isRunning, index: index)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(profile.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if hovering && profile.isRunning && !profile.isMain && !profile.viaMainApp && !disabled {
                        IconButton(symbol: "arrow.clockwise", help: "Restart this account") { act.restart(profile.name) }
                    }
                    StatusPill(running: profile.isRunning,
                               help: profile.viaMainApp ? "Open in the default Claude app"
                                   : profile.isRunning ? "Its Claude window is open" : "Click the card to open it")
                }
                .frame(height: 18)
                details
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if !disabled { act.open(profile.name) } }
        .help(profile.viaMainApp ? "Open in the default Claude app · click to bring it to the front"
              : profile.isRunning ? "Running · click to bring it to the front" : "Click to open")
        .contextMenu {
            Button(profile.isRunning ? "Bring to Front" : "Open") { act.open(profile.name) }
            if !profile.isMain {
                Button("Restart") { act.restart(profile.name) }.disabled(!profile.isRunning || profile.viaMainApp)
                Divider()
                Button("Remove…") { act.remove(profile.name) }.disabled(profile.isRunning && !profile.viaMainApp)
            }
        }
    }

    @ViewBuilder private var details: some View {
        if profile.accountMismatch, let account = profile.account {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Signed in as \(account)").lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Button("Fix") { act.fixSignIn(profile.name) }
                    .controlSize(.mini).buttonStyle(.bordered).disabled(disabled)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        if !profile.isSignedIn {
            Text("Not signed in").font(.system(size: 11)).foregroundStyle(.secondary)
        } else if let usage = profile.usage {
            VStack(alignment: .leading, spacing: 4) {
                UsageBar(label: "5-hour", percent: usage.fiveHour, resets: usage.fiveHourResets)
                UsageBar(label: "Week", percent: usage.week, resets: usage.weekResets)
                if !usage.isLive {
                    // Only shown when live failed: say how old the number is, and why.
                    Text("Saved \(usage.updated.formatted(date: .omitted, time: .shortened))"
                         + (profile.liveError.map { " · \($0)" } ?? ""))
                        .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .opacity(usage.isStale ? 0.5 : 1)
            .help(usage.isLive ? "Live · updated \(usage.updated.formatted(.relative(presentation: .named)))"
                               : "Last saved by Claude; live numbers unavailable")
        } else if let error = profile.liveError {
            Text(error).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
        } else {
            Text("No usage yet").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }
}

struct UsageBar: View {
    let label: String
    let percent: Int
    var resets: Date? = nil

    private var resetsText: String {
        guard let resets else { return "\(label): \(percent)% used" }
        let when = Calendar.current.isDateInToday(resets)
            ? resets.formatted(date: .omitted, time: .shortened)
            : resets.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return "\(label): \(percent)% used · resets \(when)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(usageTint(percent))
                        .frame(width: max(4, geo.size.width * CGFloat(min(max(percent, 0), 100)) / 100))
                }
            }
            .frame(height: 5)
            Text("\(percent)%")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
        .help(resetsText)
    }
}

struct Avatar: View {
    let text: String
    let running: Bool
    let index: Int      // row position: the list is sorted, so each account keeps its colour

    /// Colour by position rather than by a hash of the address: with only a
    /// handful of accounts, hashes collide often; positions never do.
    private var color: Color {
        let palette: [Color] = [.orange, .blue, .purple, .teal, .pink, .indigo, .green, .brown]
        return palette[index % palette.count]
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle().fill(color.opacity(0.85))
                .frame(width: 28, height: 28)
                .overlay(Text(text.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white))
            // Always shown, so a closed account reads as "stopped", not as "unknown".
            Circle().fill(statusColor(running: running))
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                .offset(x: 1, y: 1)
        }
        .help(running ? "Running" : "Stopped")
    }
}

/// Green for a Claude window that is open, red for one that is not.
func statusColor(running: Bool) -> Color {
    Color(nsColor: running ? .systemGreen : .systemRed)
}

/// "● Running" / "● Stopped" at the right of a card's title row.
struct StatusPill: View {
    let running: Bool
    var help = ""

    var body: some View {
        let color = statusColor(running: running)
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(running ? "Running" : "Stopped")
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.15)))
        .fixedSize()
        .help(help)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

struct PillButton: View {
    let symbol: String
    let title: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(hovering ? 0.1 : 0.05)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - App

/// Every profile's data dir, including the plain app's even when its row is
/// folded into a profile's, so each one gets its own live request.
func allDataDirs() -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: profilesRoot)) ?? []
    let dirs = names.filter { !$0.hasPrefix(".") }.map { profilesRoot + "/" + $0 }.filter {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
    }
    return dirs + [mainDataDir]
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    /// Live usage refreshes only while someone is looking: on open, then every
    /// 30 s until the popover closes. Nothing polls claude.ai in the background.
    private var liveTimer: Timer?
    /// Watches clicks in other apps while the popover is open (see showPopover).
    private var outsideClickMonitor: Any?
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let store = Store()

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.reload()
        let host = NSHostingController(rootView: PopoverView(store: store, act: makeActions()))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient     // closes on a click outside or Esc
        popover.delegate = self

        if let button = statusItem.button {
            button.image = claudeLogo()
            button.toolTip = "Accounts for Claude"
            button.target = self
            button.action = #selector(togglePopover)
        }

        // Keep the rows current when Claude instances start or stop.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if app?.bundleIdentifier == claudeBundleID { self?.store.reload() }
            }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.reload()   // re-read on every open, so it never shows stale state
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // .transient only closes on outside clicks while this app is the
            // active one, and macOS often keeps another app active when a menu
            // bar item is clicked. A global monitor sees clicks in every other
            // app (it never sees our own, so clicks inside the popover still
            // work) and closes the popover on the first one.
            if outsideClickMonitor == nil {
                outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                    matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
                ) { [weak self] _ in self?.popover.performClose(nil) }
            }
            refreshLive()
            liveTimer?.invalidate()
            liveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.refreshLive()
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        liveTimer?.invalidate()
        liveTimer = nil
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    private func refreshLive() {
        guard !store.refreshing else { return }
        store.refreshing = true
        refreshLiveUsage(dataDirs: allDataDirs()) { [weak self] in
            self?.store.refreshing = false
            self?.store.reload()
        }
    }

    private func setBusy(_ label: String?) {
        store.busy = label
        statusItem.button?.appearsDisabled = label != nil
    }

    /// Every action closes the popover first, so alerts and windows it opens
    /// are not hidden behind it.
    private func makeActions() -> Actions {
        func closing(_ f: @escaping () -> Void) -> () -> Void {
            { [weak self] in self?.popover.performClose(nil); f() }
        }
        func closing(_ f: @escaping (String) -> Void) -> (String) -> Void {
            { [weak self] name in self?.popover.performClose(nil); f(name) }
        }
        return Actions(
            open: closing { [unowned self] in openProfile($0) },
            restart: closing { [unowned self] in runTool(["open", $0, "--restart"], busy: "Restarting…") },
            fixSignIn: closing { [unowned self] in fixSignIn($0) },
            remove: closing { [unowned self] in removeAccount($0) },
            addAccount: closing { [unowned self] in addAccount() },
            openAll: closing { [unowned self] in openAll() },
            quitAll: closing { [unowned self] in quitAll() },
            sync: { [unowned self] in
                retryKeychainAccess()   // a refused Keychain prompt is asked again only on purpose
                refreshLive()
                runTool(["sync", "--apply", "--wait", "20"], busy: "Syncing…")
            },
            showSyncLog: closing { NSWorkspace.shared.open(URL(fileURLWithPath: syncLogPath)) },
            doctor: closing { [unowned self] in
                runInBackground("Running doctor…", showOutput: "claude-multi doctor") { runCLI(["doctor"]) }
            },
            toggleLogin: { [unowned self] in toggleLoginItem() },
            quitApp: { NSApp.terminate(nil) }
        )
    }

    // MARK: Actions

    private func openProfile(_ name: String) {
        guard let profile = loadProfiles().first(where: { $0.name == name }) else { return }
        if let app = profile.app {
            // Already running: just bring it forward. (claude-multi would show a
            // "restart it?" dialog here, which is not what a click means.)
            app.unhide()
            app.activate()
        } else if profile.isMain {
            runInBackground("Opening Claude…") {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                p.arguments = ["-n", "-a", claudeAppPath]
                try? p.run(); p.waitUntilExit()
                return CommandResult(status: p.terminationStatus, output: "Could not open \(claudeAppPath).")
            }
        } else {
            runTool(["open", name], busy: "Opening…")
        }
    }

    private func openAll() {
        let stopped = loadProfiles().filter { !$0.isMain && !$0.isRunning }.map(\.name)
        guard !stopped.isEmpty else { return }
        runInBackground("Opening \(stopped.count)…") {
            for name in stopped {
                let r = runCLI(["open", name])
                if r.status != 0 { return r }
            }
            return CommandResult(status: 0, output: "")
        }
    }

    private func quitAll() {
        guard confirm("Quit every Claude window?",
                      "This also stops any Claude Code session running in them.",
                      button: "Quit All") else { return }
        runInBackground("Quitting…") {
            quitAllInstances()
                ? CommandResult(status: 0, output: "")
                : CommandResult(status: 1, output: "Some Claude windows did not quit within 20 seconds.")
        }
    }

    /// The fix for a profile signed in to the wrong account: it must sign in
    /// while it is the ONLY Claude instance, because macOS hands the claude://
    /// sign-in callback to whichever instance started first.
    private func fixSignIn(_ name: String) {
        guard confirm("Sign \(name) back in?",
                      """
                      This profile is signed in to a different account. To fix it, every Claude window \
                      quits (including running Claude Code sessions), then \(name) opens on its own.

                      In that window: open the account menu (bottom left) → Log out → sign in with \(name). \
                      Then right-click it in this menu and choose Restart.
                      """,
                      button: "Quit All and Open") else { return }
        runInBackground("Preparing sign-in…") {
            guard quitAllInstances() else {
                return CommandResult(status: 1, output: "Some Claude windows did not quit; close them and try again.")
            }
            return runCLI(["open", name])
        }
    }

    // MARK: Add / remove accounts

    private func addAccount() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Add a Claude account"
        alert.informativeText = """
            Enter the e-mail address you sign in to Claude with. A new window opens for it, \
            and you sign in there once. After that it opens without signing in.
            """
        let field = NSTextField(frame: NSRect(x: 0, y: 28, width: 300, height: 24))
        field.placeholderString = "name@example.com"
        let copyMCP = NSButton(checkboxWithTitle: "Copy my MCP server settings (may include API keys)",
                               target: nil, action: nil)
        copyMCP.frame = NSRect(x: 0, y: 0, width: 360, height: 20)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 54))
        box.addSubview(field)
        box.addSubview(copyMCP)
        alert.accessoryView = box
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let email = field.stringValue.trimmingCharacters(in: .whitespaces)
        if let problem = validateNewAccount(email) {
            showText("Can't add that account", problem)
            return
        }
        let mcpFlag = copyMCP.state == .on ? "--with-mcp-config" : "--no-mcp-config"

        // Sign-in only reaches the new window if it is the only Claude running.
        let othersRunning = loadProfiles().contains(where: \.isRunning)
        if othersRunning, !confirm("Quit every Claude window first?",
                                   """
                                   To sign in, \(email) has to be the only Claude window open: macOS sends \
                                   the sign-in back to whichever Claude started first. This also stops any \
                                   Claude Code session running in them.
                                   """,
                                   button: "Quit All and Add") { return }

        runInBackground("Adding \(email)…", onSuccess: { [weak self] in
            self?.showText("Sign in to \(email)",
                           """
                           A new Claude window has opened. Sign in there with \(email).

                           Once signed in, right-click it in this menu and choose Restart \
                           so your synced sessions show up.
                           """)
        }) {
            if othersRunning, !quitAllInstances() {
                return CommandResult(status: 1, output: "Some Claude windows did not quit; close them and try again.")
            }
            return runCLI(["open", email, "--yes", mcpFlag])
        }
    }

    /// Why this address can't be a new profile, or nil if it can.
    /// Mirrors claude-multi's check_name() and is_email_shaped(), so the script
    /// never has to reject it after every Claude window has already quit.
    private func validateNewAccount(_ email: String) -> String? {
        if email.isEmpty { return "Enter the e-mail address you sign in to Claude with." }
        if email.hasPrefix(".") || email.hasPrefix("-") { return "An address can't start with “\(email.first!)”." }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._%+@-")
        if let bad = email.first(where: { !allowed.contains($0) }) {
            return "“\(bad)” isn't allowed. Use letters, digits and . _ % + @ - only."
        }
        // is_email_shaped: something@something.something
        guard let at = email.firstIndex(of: "@"), email[email.index(after: at)...].contains(".") else {
            return "“\(email)” doesn't look like an e-mail address."
        }
        // The default APFS volume ignores case, so Work@x.com and work@x.com are one folder.
        if loadProfiles().contains(where: { !$0.isMain && $0.name.lowercased() == email.lowercased() }) {
            return "\(email) is already in the list."
        }
        return nil
    }

    /// Moves the profile folder and its launcher to the Trash (recoverable),
    /// instead of claude-multi's `rm -rf`, which also needs a terminal to confirm.
    private func removeAccount(_ name: String) {
        guard let profile = loadProfiles().first(where: { $0.name == name }), !profile.isMain else { return }
        guard !profile.isRunning || profile.viaMainApp else {
            showText("\(name) is running", "Quit that Claude window first, then remove it.")
            return
        }
        guard confirm("Remove \(name)?",
                      """
                      Its profile folder and its launcher move to the Trash. Your chats stay with the \
                      account online, and its Claude Code sessions are already synced to your other \
                      accounts. Add it again any time.
                      """,
                      button: "Move to Trash") else { return }

        var errors: [String] = []
        let launchers = ["/Applications", home + "/Applications"].map { "\($0)/Claude - \(name).app" }
        for path in [profile.dataDir] + launchers where FileManager.default.fileExists(atPath: path) {
            do { try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) }
            catch { errors.append("\(path): \(error.localizedDescription)") }
        }
        if !errors.isEmpty { showText("Couldn't remove everything", errors.joined(separator: "\n")) }
        store.reload()
    }

    private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            popover.performClose(nil)
            showText("Could not change the login item", error.localizedDescription)
        }
        store.reload()
    }

    // MARK: Helpers

    private func runTool(_ args: [String], busy label: String) {
        runInBackground(label) { runCLI(args) }
    }

    /// Runs work off the main thread, shows a spinner meanwhile, and reports
    /// failures (or the output, when `showOutput` names a window title).
    private func runInBackground(_ label: String, showOutput: String? = nil,
                                 onSuccess: (() -> Void)? = nil,
                                 _ work: @escaping () -> CommandResult) {
        setBusy(label)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = work()
            DispatchQueue.main.async {
                self.setBusy(nil)
                self.store.reload()
                if let title = showOutput {
                    self.showText(title, result.output)
                } else if result.status != 0 {
                    self.showText("\(label.replacingOccurrences(of: "…", with: "")) failed",
                                  result.output.isEmpty ? "Exit code \(result.status)" : result.output)
                } else {
                    onSuccess?()
                }
            }
        }
    }

    private func confirm(_ title: String, _ message: String, button: String) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// An alert with scrollable, monospaced text (for doctor output and errors).
    private func showText(_ title: String, _ text: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 560, height: 280)
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            view.string = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        alert.accessoryView = scroll
        alert.runModal()
    }
}

/// Ask every Claude instance to quit, then wait up to 20 s. True when none is left.
func quitAllInstances() -> Bool {
    func claudes() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == claudeBundleID }
    }
    claudes().forEach { $0.terminate() }
    for _ in 0..<40 {
        if claudes().isEmpty { return true }
        Thread.sleep(forTimeInterval: 0.5)
    }
    return claudes().isEmpty
}

// MARK: - Entry point

// --live: fetch live usage first (both headless modes below), as the popover does on open.
if CommandLine.arguments.contains("--live") {
    var finished = false
    refreshLiveUsage(dataDirs: allDataDirs()) { finished = true }
    while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
}

if CommandLine.arguments.contains("--print-status") {
    // Headless check: print what the popover would show. Prints percentages
    // only - never a cookie or key.
    for p in loadProfiles() {
        let state = p.viaMainApp ? "RUNNING*" : p.isRunning ? "RUNNING" : "stopped"
        let usage = p.usage.map { u in
            let source = u.isLive ? "LIVE, resets \(u.fiveHourResets?.formatted(date: .omitted, time: .shortened) ?? "?")"
                                  : "saved \(u.updated.formatted(date: .omitted, time: .shortened))"
            return "5h \(u.fiveHour)%  week \(u.week)%  (\(source))"
        } ?? "no usage"
        let error = p.liveError.map { "  [live failed: \($0)]" } ?? ""
        let warn = p.accountMismatch ? "  <- signed in to another account" : ""
        print("\(p.title.padding(toLength: 28, withPad: " ", startingAt: 0)) \(state.padding(toLength: 8, withPad: " ", startingAt: 0)) \(usage)\(error)\(warn)")
    }
    print("(* = open in the plain Claude app)")
    print("logo: \(Bundle(path: claudeAppPath)?.image(forResource: "TrayIconTemplate") != nil ? "Claude.app TrayIconTemplate" : "fallback symbol")")
    print("last sync: \(lastSync().map { "\($0.time) · \($0.sessions ?? "?") sessions" } ?? "never")")
    print("claude-multi: \(cliPath ?? "NOT FOUND")")
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    // Headless check: render the popover, in dark mode, to a PNG.
    _ = NSApplication.shared
    let store = Store()
    store.reload()
    if CommandLine.arguments.contains("--demo") {
        // Example accounts for screenshots, so nobody's real addresses get published.
        func demo(_ email: String, _ fiveHour: Int, _ week: Int, running: Bool) -> Profile {
            Profile(name: email, dataDir: "", account: email,
                    usage: Usage(fiveHour: fiveHour, week: week, updated: Date(), isLive: true),
                    app: running ? NSRunningApplication.current : nil)
        }
        store.profiles = [demo("personal@example.com", 34, 61, running: true),
                          demo("work@example.com", 8, 22, running: true),
                          demo("side-project@example.com", 0, 87, running: false)]
        store.syncTime = "18:06"
    }
    let none: () -> Void = {}
    let noneName: (String) -> Void = { _ in }
    let act = Actions(open: noneName, restart: noneName, fixSignIn: noneName, remove: noneName,
                      addAccount: none, openAll: none, quitAll: none, sync: none, showSyncLog: none,
                      doctor: none, toggleLogin: none, quitApp: none)
    let view = NSHostingView(rootView: PopoverView(store: store, act: act)
        .background(Color(nsColor: .windowBackgroundColor)))
    view.appearance = NSAppearance(named: .darkAqua)
    view.frame.size = view.fittingSize
    let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
