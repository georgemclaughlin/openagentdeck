//
//  LoginItem.swift · DeckApp
//
//  Opening at login, through the API that does not need a helper bundle.
//
//  `SMAppService.mainApp` is the modern form: no separate login-item target,
//  no `SMLoginItemSetEnabled`, no privileged helper. Registering it puts the
//  app in System Settings ▸ General ▸ Login Items where the user can turn it
//  off, which is the point — a deck that installs itself somewhere the user
//  cannot find is a deck they will end up removing with a hammer.
//
//  Offered at setup and NOT preselected. The deck is ambient furniture and
//  being switched off defeats it, but launching at login is a machine-level
//  habit some people manage deliberately elsewhere, and setup is already
//  asking for one write to their configuration.
//

import Foundation
import ServiceManagement

enum LoginItem {

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Register, reporting rather than throwing: this rides alongside the
    /// connect button, and failing to arrange a login item must never make a
    /// successful connection look like a failed one.
    static func enable(_ failure: inout String?) {
        do { try SMAppService.mainApp.register() } catch {
            failure = "Connected, but the deck could not add itself to your login items — "
                    + "you can add it in System Settings ▸ General ▸ Login Items. "
                    + "(\(error.localizedDescription))"
        }
    }

    static func disable() { try? SMAppService.mainApp.unregister() }

    /// Both directions from one control, so a Settings toggle can bind to it.
    static func set(_ on: Bool) {
        if on { var ignored: String?; enable(&ignored) } else { disable() }
    }
}
