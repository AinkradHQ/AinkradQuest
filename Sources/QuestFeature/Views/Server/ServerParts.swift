import AinkradAppKit
import SwiftUI

extension View {
    /// Text in the skin's font at a size key, mono when asked.
    func questFont(_ size: String, weight: String? = nil, mono: Bool = false) -> some View {
        modifier(QuestFont(size: size, weight: weight, mono: mono))
    }
}

private struct QuestFont: ViewModifier {
    let size: String
    let weight: String?
    let mono: Bool
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTypography) private var typo

    func body(content: Content) -> some View {
        content.font(
            skin.font(AinkradFontToken(sizeKey: size, weight: weight, mono: mono ? "family" : nil), typography: typo))
    }
}

/// Who is on an item: an agent as its animated figure (decision #63 — never a letter), the person as the person
/// glyph, nobody as a faint dashed ring.
struct ActorFigure: View {
    let actor: ServerActor
    let store: QuestServerStore
    var size: CGFloat?
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        let side = size ?? skin.size.s20
        switch actor {
        case .agent(let id):
            if let agent = store.agent(id) {
                AinkradAgentFigure(
                    name: agent.name, state: AinkradFigureState(rawValue: agent.figure) ?? .idle,
                    palette: agent.status == "paused" ? .muted : AinkradFigurePalette.named(agent.palette) ?? .neonTide,
                    harness: Self.harness(agent.harness), size: side, showsPlate: false
                )
                .help(agent.name)
            } else {
                unknown(side)
            }
        case .human:
            AinkradIconGlyph(systemName: "person.crop.circle", size: side).help(store.userName)
        case .timer, .none:
            unknown(side)
        }
    }

    private func unknown(_ side: CGFloat) -> some View {
        AinkradIconGlyph(systemName: "circle.dashed", size: side)
            .foregroundStyle(skin.color(skin.text.faint))
            .help("Unassigned")
    }

    static func harness(_ word: String) -> AinkradFigureHarness? {
        switch word {
        case "claude": .claude
        case "codex": .codex
        case "opencode": .openCode
        case "agy": .agy
        default: nil
        }
    }
}

/// The issue's type glyph: story ▣, task ◇, bug ●, subtask ·.
struct KindGlyph: View {
    let kind: String
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradStatusColors) private var status

    var body: some View {
        let (symbol, color): (String, Color) =
            switch kind {
            case "story": ("square.fill", status.success)
            case "bug": ("circle.fill", status.danger)
            case "subtask": ("smallcircle.filled.circle", skin.color(skin.text.muted))
            default: ("diamond", skin.color(skin.palette.accentSecondary))
            }
        AinkradIconGlyph(systemName: symbol, size: skin.size.s10)
            .foregroundStyle(color)
            .help(kind.capitalized)
    }
}

/// `CIT-62` in the accent, mono.
struct IssueKey: View {
    let key: String
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        Text(verbatim: key).questFont("t11", mono: true)
            .foregroundStyle(skin.color(skin.palette.accentSecondary))
            .lineLimit(1)
            .fixedSize()
    }
}

/// The requirement an item serves (decision #49): `R-12` in the primary accent; hover names it.
struct RequirementTag: View {
    let requirement: ServerRequirement?
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        if let requirement {
            AinkradBadge(text: requirement.key, tint: skin.color(skin.palette.accentPrimary))
                .help("\(requirement.key) · \(requirement.title)")
        }
    }
}

/// A small caps label.
struct CapsLabel: View {
    let text: String
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        Text(skin.labelCased(text)).questFont("t10", weight: "semibold")
            .tracking(skin.usesNativeGlass ? 0 : skin.size.s1)
            .foregroundStyle(skin.color(skin.text.muted))
    }
}

/// Muted secondary text.
struct Faint: View {
    let text: String
    var size = "t11"
    @Environment(\.ainkradSkin) private var skin

    init(_ text: String, size: String = "t11") {
        self.text = text
        self.size = size
    }

    var body: some View {
        Text(verbatim: text).questFont(size).foregroundStyle(skin.color(skin.text.faint)).lineLimit(1)
    }
}

/// What an agent is doing on an item right now ("Kestrel working · 4m"), pulsing while it works.
struct WorkingLine: View {
    let issue: ServerIssue
    let store: QuestServerStore
    /// The card says it itself ("merge waits on you").
    var hidesWaiting = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradStatusColors) private var status
    @Environment(\.ainkradReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        if let line {
            HStack(spacing: AinkradSpacing.xs) {
                Circle().fill(line.color).frame(width: skin.size.s6, height: skin.size.s6)
                    .opacity(pulse ? skin.opacity.o40 : 1)
                Text(verbatim: line.text).questFont("t11").foregroundStyle(line.color).lineLimit(1)
            }
            .onAppear {
                guard !reduceMotion, line.pulses else { return }
                withAnimation(skin.animation(skin.motion.present).repeatForever(autoreverses: true)) { pulse = true }
            }
        }
    }

    private var line: (text: String, color: Color, pulses: Bool)? {
        if issue.state == "blocked" { return ("blocked — waiting on another issue", status.danger, false) }
        if let run = store.run(on: issue) {
            let who = store.agent(run.agentID)?.name ?? "An agent"
            let verb = issue.state == "in_review" ? "verifying" : "working"
            let since = run.startedAt.map { " · \(Self.age($0))" } ?? ""
            return ("\(who) \(verb)\(since)", skin.color(skin.palette.accentSecondary), true)
        }
        if !hidesWaiting, issue.isOpen, case .human = issue.next, issue.state == "in_review" {
            return ("waits on you", status.warning, false)
        }
        return nil
    }

    /// `40s`, `4m`, `2h`, `3d`.
    static func age(_ since: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }
}

/// The standing notice over a server surface: a refusal, or a conflict with Undo.
struct ServerNoticeBar: View {
    let store: QuestServerStore

    var body: some View {
        if let notice = store.notice {
            Group {
                if let title = notice.actionTitle, let action = notice.action {
                    AinkradBanner(
                        message: notice.message, status: notice.status, actionTitle: title, action: action,
                        onDismiss: { store.notice = nil })
                } else {
                    AinkradBanner(message: notice.message, status: notice.status, onDismiss: { store.notice = nil })
                }
            }
            .padding(.horizontal, AinkradSpacing.md)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
