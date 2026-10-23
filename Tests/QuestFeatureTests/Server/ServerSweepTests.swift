import AinkradAppKit
import AppKit
import SwiftUI
import XCTest

@testable import QuestFeature

/// Quest's server tabs under Neon and Liquid Glass, read from a LIVE Citadel server, written as
/// `<dir>/<name>-neon.png` / `-glass.png` for review against `Designs/quest-server/_renders`. A tool, not a check:
/// it runs only with AINKRAD_SWEEP_DIR, AINKRAD_THEMES_DIR (the catalog's `themes/`), QUEST_SWEEP_SERVER and
/// QUEST_SWEEP_KEY set. Live window captures at desktop level — off-screen `cacheDisplay` cannot draw Liquid Glass.
@MainActor
final class ServerSweepTests: XCTestCase {
    func testShootServerTabs() throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["AINKRAD_SWEEP_DIR"], let themes = env["AINKRAD_THEMES_DIR"],
            let server = env["QUEST_SWEEP_SERVER"], let key = env["QUEST_SWEEP_KEY"]
        else { throw XCTSkip("set AINKRAD_SWEEP_DIR, AINKRAD_THEMES_DIR, QUEST_SWEEP_SERVER and QUEST_SWEEP_KEY") }
        let glass = try Self.glassSkin(themes: URL(fileURLWithPath: themes))
        Self.registerHostFonts()
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

        let store = QuestServerStore(documents: MemoryDocumentStore(), secrets: SweepSecrets())
        store.serverDraft = server
        store.keyDraft = key
        store.connect()
        let deadline = Date().addingTimeInterval(20)
        while (store.phase != .connected || store.snapshots.count < 3) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(store.phase, .connected)
        let size = CGSize(width: 1280, height: 800)
        let shots: [(String, Int64, QuestSurface)] = [
            ("01-backlog", 1, .backlog), ("02-sprint-planning", 1, .sprint), ("03-sprint-board", 1, .board),
            ("04-kanban", 2, .board), ("05-reports", 1, .reports), ("06-list", 1, .list), ("07-today", 1, .today),
            ("08-overview", 1, .overview), ("09-timeline", 1, .timeline),
        ]
        let only = env["AINKRAD_SWEEP_ONLY"].flatMap { $0.isEmpty ? nil : $0.split(separator: ",").map(String.init) }
        for (theme, skin) in [("neon", AinkradSkin.standard), ("glass", glass)] {
            let hostTheme = HostTheme(HostThemeTokens(skin: skin))
            hostTheme.updateStatusColors(
                HostStatusColors(
                    success: skin.color(skin.palette.success), warning: skin.color(skin.palette.warning),
                    danger: skin.color(skin.palette.danger)))
            func shoot(_ name: String, _ view: some View) throws {
                guard only?.contains(where: name.hasPrefix) ?? true else { return }
                try LiveCapture.shoot(
                    view.frame(width: size.width, height: size.height)
                        .background(skin.color(skin.palette.background))
                        .ainkradHostTheme(hostTheme)
                        .ainkradSkin(skin)
                        .environment(
                            \.ainkradTypography, AinkradTypography(fontFamilyName: theme == "neon" ? "Exo 2" : nil)
                        )
                        .environment(\.colorScheme, .dark),
                    size: size, to: URL(fileURLWithPath: out).appendingPathComponent("\(name)-\(theme).png"))
            }
            for (name, project, surface) in shots {
                store.select(project: project)
                store.notice = nil
                try shoot(name, ServerShell(store: store, openCitadel: {}, surface: surface).ainkradToastHost())
            }
            // 04: a drop into the full In progress column springs back with the WIP toast.
            if let mac = store.companyProjects.first(where: { $0.mode == .kanban }),
                let card = store.snapshots[mac.id]?.issues.first(where: { $0.state == "todo" })
            {
                store.select(project: mac.id)
                let column = BoardLogic.columns(mode: .kanban, limits: store.snapshots[mac.id]?.limits ?? [:])[1]
                let done = expectation(description: "drop")
                Task {
                    await store.drop(card, on: column, project: mac)
                    done.fulfill()
                }
                wait(for: [done], timeout: 5)
                try shoot("04-kanban-wip-refused", ServerShell(store: store, openCitadel: {}, surface: .board))
            }
            // API minor 9: the project settings' sections, New project, and an item's labels and flow times.
            if let citadel = store.companyProjects.first(where: { $0.mode == .scrum }) {
                store.select(project: citadel.id)
                store.notice = nil
                for (index, section) in SettingsSection.allCases.enumerated() {
                    store.settingsSheet = section
                    try shoot(
                        "1\(index)-settings-\(section.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))",
                        ServerShell(store: store, openCitadel: {}, surface: .board))
                }
                store.settingsSheet = nil
                try shoot("14-new-project", Self.sheet(ServerNewProjectForm(store: store) {}))
                if let labeled = store.snapshots[citadel.id]?.issues.last(where: {
                    $0.state == "done" && !$0.labels.isEmpty
                }) {
                    try shoot("15-item-detail", Self.sheet(ServerItemDetail(store: store, issue: labeled) {}))
                }
            }
            try shoot(
                "00-connect",
                ServerConnectCard(store: QuestServerStore(documents: MemoryDocumentStore(), secrets: SweepSecrets())) {}
            )
        }
        store.stop()
    }

    /// Edits round-trip against the live server: a re-rank, an estimate, a board move and a sprint-commit
    /// rejection, each read back from the server. Same env gate as the shots; it changes the seeded database.
    func testLiveRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["QUEST_SWEEP_SERVER"], let key = env["QUEST_SWEEP_KEY"], env["QUEST_SWEEP_WRITE"] != nil
        else { throw XCTSkip("set QUEST_SWEEP_SERVER, QUEST_SWEEP_KEY and QUEST_SWEEP_WRITE") }
        let store = QuestServerStore(documents: MemoryDocumentStore(), secrets: SweepSecrets())
        store.serverDraft = server
        store.keyDraft = key
        store.connect()
        for _ in 0..<200 where store.phase != .connected || store.snapshots.count < 3 {
            try await Task.sleep(for: .milliseconds(100))
        }
        let project = try XCTUnwrap(store.companyProjects.first { $0.mode == .scrum })
        let backlog = BacklogLogic.backlog(store.snapshots[project.id]?.issues ?? [])
        let last = try XCTUnwrap(backlog.last)
        await store.rerank(RankMove(issue: last.id, place: .top, epic: nil), project: project.id)
        XCTAssertEqual(BacklogLogic.backlog(store.snapshots[project.id]?.issues ?? []).first?.id, last.id)
        XCTAssertNil(store.notice)

        await store.estimate(last, points: 8, project: project.id)
        XCTAssertEqual(store.snapshots[project.id]?.issues.first { $0.id == last.id }?.points, 8)

        let todo = try XCTUnwrap(store.snapshots[project.id]?.issues.first { $0.state == "todo" && $0.sprintID != nil })
        let columns = BoardLogic.columns(mode: .scrum, limits: [:])
        await store.drop(todo, on: columns[1], project: project)
        XCTAssertEqual(store.snapshots[project.id]?.issues.first { $0.id == todo.id }?.state, "in_progress")

        // API minor 9 (seed9: S5 is a draft): a label on and off, a member's capacity, and the owner's commit,
        // which the server refuses while S4 runs — with an error id behind "Copy error".
        let label = try XCTUnwrap(store.snapshots[project.id]?.labels.first)
        await store.toggle(label, on: last, project: project.id)
        XCTAssertTrue(store.snapshots[project.id]?.issues.first { $0.id == last.id }?.labels.contains(label) == true)
        let labeled = try XCTUnwrap(store.snapshots[project.id]?.issues.first { $0.id == last.id })
        await store.toggle(label, on: labeled, project: project.id)
        XCTAssertFalse(store.snapshots[project.id]?.issues.first { $0.id == last.id }?.labels.contains(label) == true)
        let member = try XCTUnwrap(store.snapshots[project.id]?.capacity.members.last)
        await store.setCapacity(9, agent: member.agentID, project: project.id)
        XCTAssertEqual(store.snapshots[project.id]?.capacity.capacity(of: .agent(member.agentID)), 9)
        guard
            case .draft(let planned) = SprintGate.state(
                sprints: store.snapshots[project.id]?.sprints ?? [], approvals: store.approvals)
        else { return XCTFail("the seeded S5 is a draft") }
        await store.commit(planned, overrideReason: "fits", project: project.id)
        XCTAssertEqual(store.notice?.actionTitle, "Copy error", store.notice?.message ?? "no notice")
        store.stop()
    }

    /// A modal's content as the kit modal frames it: padded on a panel, centred.
    static func sheet(_ content: some View) -> some View {
        content.padding(AinkradSpacing.lg).ainkradPanel().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func registerHostFonts() {
        let resources = URL(fileURLWithPath: "/Applications/Ainkrad.app/Contents/Resources")
        let fonts = (try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)) ?? []
        for font in fonts where font.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
        }
    }

    /// `glass-dark.theme` on the standard skin, coloured by `glass-dark.scheme`, as the host composes it.
    static func glassSkin(themes: URL) throws -> AinkradSkin {
        let dir = themes.appendingPathComponent("glass")
        let base = try JSONEncoder().encode(AinkradSkin.standard)
        let theme = try Data(contentsOf: dir.appendingPathComponent("glass-dark.theme"))
        let variant = try XCTUnwrap(ainkradLoadThemes([base, theme]).themes["glass.dark"])
        var scheme = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("glass-dark.scheme")))
                as? [String: Any])
        scheme.removeValue(forKey: "appearance")
        scheme.removeValue(forKey: "host")
        scheme["base"] = "glass.dark"
        return try AinkradThemeFile(
            decoding: JSONSerialization.data(withJSONObject: scheme), bases: ["glass.dark": variant]
        ).skin
    }
}

private final class SweepSecrets: PluginSecretStore, @unchecked Sendable {
    var storage: [String: String] = [:]
    func secret(forKey key: String) -> String? { storage[key] }
    func setSecret(_ value: String?, forKey key: String) { storage[key] = value }
}

/// Captures a desktop-level window by id (`screencapture -l`): never the user's screen, never focus. Copied
/// from AinkradCitadelPlugin's sweep.
@MainActor
enum LiveCapture {
    private final class KeyAppearancePanel: NSPanel {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
        override var canBecomeKey: Bool { false }
        @objc var hasKeyAppearance: Bool { true }
        @objc var hasMainAppearance: Bool { true }
        @objc var _hasActiveAppearance: Bool { true }
        @objc var _hasActiveAppearanceIgnoringKeyFocus: Bool { true }
    }

    static func shoot(_ view: some View, size: CGSize, to url: URL) throws {
        let panel = KeyAppearancePanel(
            contentRect: NSRect(origin: CGPoint(x: 200, y: 200), size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.contentView = NSHostingView(
            rootView: view.environment(\.ainkradMotionBudget, .frozen).environment(\.controlActiveState, .key))
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(panel.windowNumber), url.path]
        try capture.run()
        capture.waitUntilExit()
        XCTAssertEqual(capture.terminationStatus, 0, "no capture for \(url.lastPathComponent)")
    }
}
