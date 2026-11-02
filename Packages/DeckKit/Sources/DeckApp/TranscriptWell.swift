//
//  TranscriptWell.swift · DeckApp
//
//  The card shows the last thing a person said through ANY door: typed in
//  the session's terminal, tapped on the deck, or a Claude Code recap.
//  `LaneView.transcript` (DeckCore) holds the merged chronological ledger;
//  this view renders it. It also replaces the act zone's idle placeholder
//  and the old queue column, so one fact is never shown in two places.
//
//  `QueueSection.waitingLabel(runtime:)` is the single source of the stall
//  sentences shown in this well's header line.
//
//  This is the one place in the band where a `ScrollView` is correct: the
//  content (a session's whole prompt-and-send history) is unbounded, and
//  growing the band past its measured budget would cause a self-resize
//  loop (see `DetailBand.body`). The scroll view lives inside a FIXED
//  height budget, and `.defaultScrollAnchor(.bottom)` keeps the newest row
//  visible, like a terminal.
//
//  Monospaced (like `SubjectWell.detailText`) because the well shows
//  verbatim bytes (a command or a prompt), not prose the deck wrote.
//

import SwiftUI
import DeckCore

struct TranscriptWell: View {
    let lane: LaneView
    let runtime: DeckRuntime
    /// The ScrollView's height ceiling. `DetailBand` computes it by pure
    /// arithmetic over `usableHeight` (never a `GeometryReader`), so a
    /// `fittingSize`-based render test can derive the same expectation.
    /// Only the `ScrollView` reads it; the stall sentence stays uncapped.
    let maxHeight: Double

    /// Why the queue is not moving, when it is not. Only the two STALL
    /// sentences surface; the neutral "Queued" label is omitted because the
    /// rows already carry their own "Waiting" status.
    private var stallSentence: String? {
        guard runtime.frame.queueAwaitsUsage || runtime.frame.queueStalled else { return nil }
        return QueueSection.waitingLabel(runtime: runtime)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let stallSentence {
                Text(stallSentence)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if lane.transcript.isEmpty {
                // Same wording as the old act-zone placeholder: an empty
                // lane still explains itself.
                Text("Nothing needs you here right now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // Snapshot coherence: `lane` is an immutable value, so
                // `lane.transcript` is one snapshot. Each row captures its
                // `entry` VALUE, never an index into `runtime.frame`.
                // `id: \.source.raw` is the entry's `EventID`: stable, and
                // synthesized deterministically for projected queued rows
                // (see `Projection.swift`). Never use an offset.
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(lane.transcript, id: \.source.raw) { entry in
                            TranscriptRow(entry: entry, runtime: runtime)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .frame(maxHeight: maxHeight, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One row — a terminal prompt or a deck send, in the order they actually
/// happened (or, for the still-queued tail, will).
private struct TranscriptRow: View {
    let entry: TranscriptEntry
    let runtime: DeckRuntime

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Provenance glyph: terminal, deck, or an answered question.
            // The answered-question glyph is distinct because that row is
            // "a question was answered", not "somebody said something".
            Image(systemName: glyphName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .accessibilityHidden(true)

            // A recap is the one row that is NOT monospaced: it is prose
            // (Claude Code's own 172-310 byte sentences about the session,
            // see `TranscriptTail`), and proportional type fits more of it.
            //
            // A recap is never truncated. Other rows are prompts or sends
            // the person already knows, so two lines identify them. A recap
            // is the one thing they have NOT read, and a summary cut off
            // mid-sentence is no summary.
            //
            // This does not grow the band: the well's `ScrollView` is
            // capped by `maxHeight`, so a long recap scrolls.
            //
            // `fixedSize(horizontal: false, vertical: true)` makes the wrap
            // actually happen: inside an `HStack` a `Text` would otherwise
            // accept a compressed single-line height, and `lineLimit(nil)`
            // alone does not stop that. Horizontal stays free so the text
            // fills only the width the row offers.
            content
                .lineLimit(entry.origin == .recap ? nil : 2)
                .fixedSize(horizontal: false, vertical: entry.origin == .recap)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .copyable(entry.text.value)

            // How old the summary is, in the trailing slot a deck row uses
            // for its status. A recap can be hours old when it is read, and
            // an undated summary would read as describing the session NOW.
            // Recomputed from `runtime.frame.at` so the label keeps aging.
            if entry.origin == .recap {
                Text(RelativeAge.label(of: entry.at, now: runtime.frame.at))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .layoutPriority(1)
            }

            // A terminal row carries no status. A deck row carries the send
            // ledger's three-state status, right-aligned, using the shared
            // `QuickAction.Status` glyph, name and tint.
            if entry.origin == .deck, let status = entry.deckStatus {
                HStack(spacing: 4) {
                    Text(status.spokenName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Image(systemName: status.symbolName)
                        .font(.caption2)
                        .foregroundStyle(status.tint)
                        .symbolRenderingMode(.hierarchical)
                }
                if status == .queued {
                    cancelButton
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The recap's `recap:` label. Claude Code's terminal renders it as
    /// `※ recap: <summary>` (bold label, italic summary); the deck matches
    /// that format so strip and terminal show the same thing.
    ///
    /// ONE concatenated `Text`, not an `HStack` of two: side-by-side views
    /// would wrap the summary in a narrow column beside the label. `Text`
    /// `+` `Text` makes one paragraph, so the summary wraps back under the
    /// label. Fonts are set on the runs because an outer `.font()` only
    /// supplies a default for runs that name none.
    ///
    /// The label is NOT part of `copyable(entry.text.value)`: copying a
    /// recap yields Claude Code's sentence, not the deck's chrome.
    @ViewBuilder
    private var content: some View {
        if entry.origin == .recap {
            Text("recap: ").font(.callout.weight(.semibold))
                + Text(entry.text.value).font(.callout.italic())
        } else {
            Text(entry.text.value).font(.callout.monospaced())
        }
    }

    /// One glyph per `TranscriptEntry.Origin`. An exhaustive `switch` so a
    /// new origin fails to compile here instead of inheriting a default.
    private var glyphName: String {
        switch entry.origin {
        case .terminal:        "keyboard"
        case .deck:             "hand.tap.fill"
        case .answeredQuestion: "checkmark.bubble.fill"
        // Not a speech glyph: a recap is the session summarizing itself,
        // with nobody speaking (see `TranscriptEntry.Origin.recap`).
        case .recap:            "sparkles"
        }
    }

    /// A queued row's inline cancel. Reads `runtime.frame.actions` at TAP
    /// time, by id, never by render index: `entry.actionID` is a captured
    /// value, and a stale action list can only find nothing (a no-op).
    @ViewBuilder
    private var cancelButton: some View {
        if let actionID = entry.actionID {
            Button {
                if let action = runtime.frame.actions.first(where: { $0.id == actionID }) {
                    runtime.cancel(action)
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .touchTarget(minHeight: TouchTarget.minimum, minWidth: TouchTarget.minimum)
            // Bare "Cancel" is sufficient: the row's `HStack` uses
            // `.accessibilityElement(children: .combine)`, so VoiceOver
            // speaks the entry's text, its status, then "Cancel" as ONE
            // utterance. `QueueSection`'s rows do not combine children,
            // which is why their button labels carry the payload. A11y
            // labels are spoken UI, never logged.
            .accessibilityLabel("Cancel")
        }
    }
}
