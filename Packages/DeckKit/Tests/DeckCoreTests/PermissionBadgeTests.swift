//
//  PermissionBadgeTests.swift · Tests/DeckCoreTests
//
//  What the deck says about a session that is not asking permission.
//
//  This is the highest-consequence field the deck carries. Everything else it
//  shows is a fact about work in progress; this one is a fact about whether
//  the human is still in the loop at all, and the rewrite had it as a grey row
//  in a form behind a selection. The rules below are what make it a badge, and
//  they are rules rather than styling because "how loud is this" is a
//  judgement about risk.
//

import Testing
import DeckCore

struct PermissionBadgeTests {

    /// **Silence is what earns the alarm its volume.**
    ///
    /// `default` is the mode nearly every session runs in. A badge on every
    /// card reading "Default" is a badge the eye stops seeing — and it stops
    /// seeing the one that says BYPASSING along with it.
    @Test("the ordinary mode says nothing", arguments: [nil, "default", ""])
    func theDefaultIsSilent(_ raw: String?) {
        #expect(PermissionBadge.forMode(raw) == nil,
                Comment(rawValue: "\(raw ?? "nil") earned a badge; only a deviation should"))
    }

    /// A session that acts without asking is the loudest thing on the deck.
    @Test("bypassing permissions is an alarm")
    func bypassIsAnAlarm() {
        let badge = PermissionBadge.forMode(PermissionBadge.bypass)
        #expect(badge?.severity == .alarm)
        // Not the raw API token. Somebody glancing at a deck needs the fact,
        // not the identifier the fact arrived under.
        #expect(badge?.label != PermissionBadge.bypass)
        #expect(badge?.label.lowercased().contains("bypass") == true)
    }

    /// Auto-accepting edits is worth noticing and is not the same as bypassing
    /// everything: files change without asking, tool calls still stop.
    @Test("auto-accepting edits is a caution, not an alarm")
    func acceptEditsIsACaution() {
        let badge = PermissionBadge.forMode(PermissionBadge.acceptEdits)
        #expect(badge?.severity == .caution)
    }

    /// Plan mode is the SAFE deviation — the session will not act at all — so
    /// it is shown without being alarming. Showing it matters anyway: "why is
    /// nothing happening" is answered by this badge.
    @Test("plan mode is shown without raising an alarm")
    func planIsNormalButPresent() {
        let badge = PermissionBadge.forMode(PermissionBadge.plan)
        #expect(badge != nil, "plan mode says nothing, so a stalled-looking session has no reason")
        #expect(badge?.severity == .normal)
    }

    /// **The unknown-is-not-error rule, and its other half.**
    ///
    /// A mode the deck has never seen may not be called a failure. It also may
    /// not be waved through — staying quiet about an unrecognised permission
    /// mode is the deck vouching for something it cannot read. So: shown,
    /// verbatim, marked worth a look.
    @Test("an unrecognised mode is shown verbatim and marked worth a look")
    func unknownModesAreSurfacedNotSwallowed() {
        let badge = PermissionBadge.forMode("someFutureMode")
        #expect(badge != nil, "an unknown mode vanished — the deck vouched for what it cannot read")
        #expect(badge?.label == "someFutureMode", "the raw mode was not preserved")
        #expect(badge?.severity == .caution, "an unknown mode was called a failure, or called safe")
    }

    /// The ordering is the whole point of using a severity rather than a
    /// boolean: bypassing outranks accepting edits, which outranks plan.
    @Test("the severities are ordered by how much supervision is lost")
    func severitiesAreOrdered() {
        let bypass = PermissionBadge.forMode(PermissionBadge.bypass)!
        let accept = PermissionBadge.forMode(PermissionBadge.acceptEdits)!
        let plan = PermissionBadge.forMode(PermissionBadge.plan)!
        #expect(bypass.severity > accept.severity)
        #expect(accept.severity > plan.severity)
    }

    /// A screen reader hears a noun phrase floating beside a session name
    /// unless the badge says what it means. The label alone does not.
    @Test("what a badge says out loud explains itself")
    func spokenDescriptionExplains() {
        let bypass = PermissionBadge.forMode(PermissionBadge.bypass)!
        #expect(bypass.spokenDescription.contains(bypass.label))
        #expect(bypass.spokenDescription.count > bypass.label.count,
                "the alarm is announced as a bare label with no explanation of the risk")

        // The safe deviation needs no warning attached — a plan-mode session
        // is not a risk, and describing it as one is the same failure as
        // describing every session as one.
        let plan = PermissionBadge.forMode(PermissionBadge.plan)!
        #expect(plan.spokenDescription == plan.label)
    }
}
