//
//  TouchTarget.swift · DeckCore
//
//  How big a thing has to be before a finger can hit it.
//
//  macOS sizes its controls for a pointer. A stock SwiftUI button measures 24
//  points tall, comfortable with a mouse and unusable with a thumb, and this
//  deck's premise is a touchscreen strip (with an iPad over Sidecar as the
//  second surface). Adopting the platform's look must not mean adopting a
//  metric written for different hardware, so the floors are stated here and
//  asserted against the controls as they actually render.
//
//  **The strip sharpens even this floor.** The HIG's 44 was sized for the
//  displays it shipped on: at the strip's ~225 ppi and 1x scale a point is
//  ≈0.113mm, so 44pt is only ≈5mm of glass (≈7mm on the hardware the
//  guideline was written against). A control that should be COMFORTABLY
//  tappable on the strip sizes itself larger than 44 to restore the physical
//  intent; `OverviewLayout.actionPillHeight` (64, ≈7.2mm) does this for the
//  quick-action bar.
//

import Foundation

public enum TouchTarget {

    /// The floor for anything a finger is meant to hit.
    ///
    /// 44 is Apple's number from the Human Interface Guidelines for touch
    /// surfaces. macOS assumes a pointer, but the hardware here is touch.
    public static let minimum: Double = 44

    /// The floor for a decision — Allow, Deny, and anything else that resolves
    /// a hold.
    ///
    /// Larger than the general floor because of what a mis-hit costs. Every
    /// other control is recoverable: pick the wrong session and you pick
    /// again. Hit Deny when you meant Allow and a tool call is refused on
    /// somebody's behalf, the one outcome the deck exists to get right.
    public static let decision: Double = 64
}
