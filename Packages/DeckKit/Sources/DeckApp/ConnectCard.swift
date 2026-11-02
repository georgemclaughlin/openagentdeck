//
//  ConnectCard.swift · DeckApp
//
//  Setting the deck up, where somebody already is.
//
//  There is no setup wizard. Connecting is ONE WRITE (every hook the deck
//  manages, into `~/.claude/settings.json`). The empty state reads
//  `Connection`, whose every case knows its own sentence and whether
//  connecting would help.
//
//  Setup finishes when it works, not when the file is written. Claude Code
//  may need a session restart to pick up new hooks, so the `waiting` state
//  says so, and names sessions that were already running (the fleet feed
//  sees sessions that have never fired a hook). It clears itself the
//  instant a hook arrives.
//

import SwiftUI
import DeckCore
import DeckPorts

struct ConnectCard: View {
    let runtime: DeckRuntime

    /// Preselected. The statusline is the only source of the context gauge
    /// and usage windows, so the deck offers to add one if the user has none.
    @State private var addStatusline = true
    /// NOT preselected: launching at login is a machine-level habit some
    /// people manage elsewhere.
    @State private var openAtLogin = false
    @State private var showingChanges = false
    @State private var preview: Reconciliation?
    @State private var failure: String?
    @State private var working = false
    /// Which existing hooks the user agreed to adopt. Empty by default: the
    /// deck never takes over a hook it did not write (see
    /// `SettingsMerge.isDeckHook`).
    @State private var adopting: Set<String> = []

    private var connection: Connection { runtime.connection }
    /// Recompute the preview whenever anything it depends on moves.
    private var previewKey: String { "\(addStatusline)-\(adopting.sorted().joined())" }

    var body: some View {
        // Scrolls: the strip is 480 points tall and this card can exceed it,
        // which would clip the button.
        ScrollView {
            content.padding(28).frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task(id: previewKey) {
            preview = await runtime.connectionPreview(addStatusline: addStatusline,
                                                      adopting: adopting)
        }
    }

    private var content: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(connection.needsAttention ? AnyShapeStyle(.orange)
                                                           : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)

            Text(connection.title).font(.title3.weight(.semibold))

            Text(connection.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)

            if connection.isConnectable, connection != .connected {
                candidates
                options
                connectButton
                if preview?.steps.isEmpty == false { changes }
            }

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }
        }
    }

    private var symbol: String {
        switch connection {
        case .unreadable: "exclamationmark.triangle.fill"
        case .notConnected: "cable.connector"
        case .wrongPort: "arrow.triangle.branch"
        case .waiting: "clock.badge.questionmark"
        case .connected: "checkmark.circle"
        case .unlisted: "antenna.radiowaves.left.and.right"
        case .superseded: "rectangle.on.rectangle"
        }
    }

    // ------------------------------------------------------------- options

    @ViewBuilder
    private var options: some View {
        // Only offered when it would do something; a tick beside "add a
        // statusline" for someone who has one would misstate the button.
        if case .notConnected = connection, runtime.hasNoStatusline {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $addStatusline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Also add a statusline")
                        Text("You don't have one. It's what feeds the context gauge and "
                             + "the usage windows.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Toggle("Open Open Agent Deck at login", isOn: $openAtLogin)
            }
            .toggleStyle(.checkbox)
            .frame(maxWidth: 420, alignment: .leading)
        }
    }

    /// Hooks already in the file that might be this deck's.
    ///
    /// Ownership cannot be inferred from the command text (`curl` takes a
    /// destination with no scheme, so a deck-shaped URL may be the target
    /// or may be data). Don't guess: guessing deleted users' hooks. The
    /// user is shown the command and asked.
    @ViewBuilder
    private var candidates: some View {
        if let found = preview?.candidates, !found.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(found.count == 1 ? "There is already a hook here that may be this deck's"
                                      : "There are already hooks here that may be this deck's")
                    .font(.callout.weight(.medium))
                Text("If it is, adopting it keeps it up to date and removes it when you "
                     + "disconnect. If it is not, leave it alone — the deck will add its own "
                     + "beside it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(found, id: \.self) { command in
                    Toggle(isOn: Binding(get: { adopting.contains(command) },
                                         set: { on in
                                             if on { adopting.insert(command) }
                                             else { adopting.remove(command) }
                                         })) {
                        Text(command)
                            .font(.caption2.monospaced())
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
        }
    }

    private var connectButton: some View {
        Button {
            Task { await run() }
        } label: {
            Text(working ? "Connecting…" : buttonTitle)
                .frame(minWidth: 180)
        }
        .buttonStyle(.glassProminent)
        .touchTarget(minHeight: TouchTarget.decision, minWidth: 200)
        .disabled(working)
        .keyboardShortcut(.defaultAction)
    }

    /// The reconciliation converges from any state, so "Connect" and
    /// "Repair" are the same press; the title says what it will do.
    private var buttonTitle: String {
        switch connection {
        case .wrongPort(_, let listening): "Point Claude Code at \(listening)"
        case .waiting: "Check again"
        case .unlisted: "Reconnect"
        default: "Connect Claude Code"
        }
    }

    // ------------------------------------------------------------- disclosure

    /// The diff as DISCLOSURE, not a gate: users see exactly what changes
    /// without approving it screen by screen.
    private var changes: some View {
        DisclosureGroup(isExpanded: $showingChanges) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array((preview?.steps ?? []).enumerated()), id: \.offset) { _, step in
                    Label(step, systemImage: "circle.fill")
                        .font(.caption)
                        .labelStyle(BulletLabel())
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("~/.claude/settings.json")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        } label: {
            Text("Show what this changes").font(.callout)
        }
        .frame(maxWidth: 460)
    }

    // ------------------------------------------------------------- doing it

    private func run() async {
        working = true
        defer { working = false }
        failure = nil
        // "Check again" only re-reads; nothing to write while waiting.
        if case .waiting = connection {
            await runtime.refreshConnection()
            return
        }
        switch await runtime.connect(addStatusline: addStatusline, adopting: adopting) {
        case .success:
            if openAtLogin { LoginItem.enable(&failure) }
        case .failure(let error):
            failure = error.sentence
        }
    }
}

// ------------------------------------------------------------- the banner

/// The connection, said above the fleet, whether or not the fleet is empty.
///
/// The setup card lives in the empty-deck overlay, but the fleet feed finds
/// sessions through `claude agents --json`, which needs no hooks. A deck
/// with dead or removed hooks would show cards that never update, with the
/// explaining surface hidden behind them. So this banner is pinned to the
/// top edge, always visible.
struct ConnectionBanner: View {
    let runtime: DeckRuntime
    @Binding var showingSetup: Bool

    var body: some View {
        if runtime.connection.needsAttention {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(runtime.connection.title).font(.callout.weight(.medium))
                    Text(runtime.connection.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button("Fix This") { showingSetup = true }
                    .buttonStyle(.glass)
                    .touchTarget(minWidth: 100)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            // A plain fill over untinted glass: a tint riding the material
            // goes gray with the inactive window (same as SessionCard's wash).
            .background(Color.orange.opacity(0.18), in: .rect(cornerRadius: 0))
            .glassEffect(.regular, in: .rect(cornerRadius: 0))
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(runtime.connection.title). \(runtime.connection.detail)")
        }
    }
}

/// A bullet that keeps its text's wrapping, which a stock icon label does
/// not at this size.
private struct BulletLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.font(.system(size: 4)).foregroundStyle(.tertiary)
            configuration.title.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension PortFailure {
    /// What a person reads when a boundary refuses. The associated value is
    /// already a sentence in every case; this only unwraps it.
    var sentence: String {
        switch self {
        case .unavailable(let s), .refused(let s), .malformed(let s): s
        }
    }
}
