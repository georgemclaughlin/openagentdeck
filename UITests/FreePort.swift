//
//  FreePort.swift · OpenAgentDeckUITests
//
//  A loopback port nothing is listening on, found by asking rather than
//  claiming.
//
//  Do not use `bind()` to 127.0.0.1:0 and read back the ephemeral port. The
//  UI-test runner (`OpenAgentDeckUITests-Runner.app`) is sandboxed with
//  `com.apple.security.network.client` but without
//  `com.apple.security.network.server`, and binding a listening socket is a
//  server operation: the sandbox denies it and `bind()` returns -1.
//
//  Instead, `connect()`. Connecting is a client operation, which the runner
//  may do. A connection to a loopback port with no listener is refused
//  immediately (`ECONNREFUSED`), and that refusal is the evidence the port
//  is free.
//
//  Race: between "nothing answered" and "the deck binds it", something else
//  could take the port. A `bind()`-then-close probe has the same gap.
//  Random selection in the range below makes a collision between concurrent
//  runs unlikely, not impossible.
//

import Darwin
import Foundation

/// `nonisolated` because the callers are: `DeckHookTests` and
/// `DeckBandCycleTests` are `nonisolated` classes calling this from
/// synchronous helpers, and the target's default actor isolation would
/// otherwise require `@MainActor` on a function that touches no UI.
nonisolated enum FreePort {

    /// The private/ephemeral range (RFC 6335). Randomised rather than
    /// walked upward from a fixed base, so two concurrent test processes
    /// do not probe the same sequence.
    private static let range: ClosedRange<UInt16> = 49152...65535

    /// A port on 127.0.0.1 that answered nothing.
    ///
    /// Throws `Unavailable` rather than a borrowed `CocoaError`, so a
    /// failure reads as what it is.
    static func next(attempts: Int = 200) throws -> UInt16 {
        for _ in 0 ..< attempts {
            let candidate = UInt16.random(in: range)
            if nothingIsListening(on: candidate) { return candidate }
        }
        throw Unavailable(attempts: attempts)
    }

    /// `true` only for a REFUSED connection, the one answer that means
    /// "free". A successful connection proves something is listening. Any
    /// other errno (notably `EPERM`, a sandbox denial) is deliberately not
    /// treated as free: that would return a port on no evidence and turn a
    /// permissions regression into a flaky test instead of a loud
    /// `Unavailable`.
    private static func nothingIsListening(on port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = port.bigEndian

        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        if connected { return false }
        return errno == ECONNREFUSED
    }

    struct Unavailable: Error, CustomStringConvertible {
        let attempts: Int
        var description: String {
            "no free loopback port after \(attempts) probes. If every probe was DENIED "
            + "rather than refused, the runner's sandbox is missing network access — see "
            + "FreePort.swift's own file doc for the entitlement this whole file works around."
        }
    }
}
