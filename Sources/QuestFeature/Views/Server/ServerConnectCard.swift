import AinkradAppKit
import SwiftUI

/// "Connect to Citadel" — the Citadel plugin's screen-01 pattern: server address + device key, then the state.
/// Quest keeps its own key (plugin secrets are per plugin), so a second Mac app means a second device key.
///
/// Connecting moves Quest to server mode (decision #27). Projects made on this Mac are never touched: Disconnect
/// brings them back exactly as they were.
struct ServerConnectCard: View {
    @Bindable var store: QuestServerStore
    let onDone: () -> Void
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradStatusColors) private var status

    var body: some View {
        AinkradCard {
            VStack(alignment: .leading, spacing: AinkradSpacing.md) {
                Text("Connect Quest to Citadel").questFont("t18", weight: "bold")
                    .foregroundStyle(skin.color(skin.text.primary))
                Text(
                    "Quest reads your Citadel company's projects — backlog, sprints and boards — and stays live. "
                        + "Projects on this Mac stay here, untouched; disconnect to see them again."
                )
                .questFont("t13").foregroundStyle(skin.color(skin.text.muted))
                .fixedSize(horizontal: false, vertical: true)
                AinkradFormRow(title: "Server") {
                    AinkradTextField(text: $store.serverDraft, placeholder: "https://citadel.example.com")
                        .monospaced()
                }
                AinkradFormRow(title: "Device key") {
                    AinkradSecureField(text: $store.keyDraft, placeholder: "ck_…")
                }
                Faint("Create one on the server: citadel-server device add <db> \"Quest on this Mac\"")
                    .textSelection(.enabled)
                statusLine
                HStack {
                    Spacer()
                    if store.isServerMode || store.phase != .setup {
                        AinkradButton(title: "Cancel", style: .ghost) {
                            store.stop()
                            if !store.isServerMode { store.phase = .setup }
                            onDone()
                        }
                    }
                    AinkradButton(title: "Connect ↵", style: .primary) { store.connect() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(AinkradSpacing.sm)
        }
        .frame(width: skin.size.s460)
        .padding(AinkradSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: store.phase) { _, phase in if phase == .connected { onDone() } }
    }

    @ViewBuilder private var statusLine: some View {
        if let problem = store.formProblem {
            Text(problem).questFont("t11").foregroundStyle(status.danger)
        } else {
            switch store.phase {
            case .setup, .connected: EmptyView()
            case .connecting(let step):
                HStack(spacing: AinkradSpacing.xs) {
                    AinkradSpinner(size: skin.size.s12)
                    Faint(step)
                }
            case .rejected:
                Text("The server refused that key — it was revoked or never existed. Nothing was stored.")
                    .questFont("t11").foregroundStyle(status.danger)
            case .offline(let reason):
                Text("Can't reach the server: \(reason)").questFont("t11").foregroundStyle(status.warning)
            }
        }
    }
}
