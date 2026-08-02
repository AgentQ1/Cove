//
//  CallSessionMachine.swift
//  Inditalk
//
//  Pure state machine for a call's lifecycle, shared by the CallKit path and the
//  WebRTC/signaling path so both agree on legal transitions. Side-effect free and
//  exhaustively testable.
//
//  Caller:  idle -> dialing -> connecting -> active -> ended
//  Callee:  idle -> ringing -> connecting -> active -> ended
//  Any leg may drop to `failed` (ICE/media failure) or `ended` (hang up / decline).
//

import Foundation

enum CallSessionMachine {

    static func canTransition(from: CallState, to: CallState) -> Bool {
        switch (from, to) {
        case (.idle, .dialing), (.idle, .ringing):
            return true
        case (.dialing, .connecting), (.dialing, .ended), (.dialing, .failed):
            return true
        case (.ringing, .connecting), (.ringing, .ended), (.ringing, .failed):
            return true
        case (.connecting, .active), (.connecting, .failed), (.connecting, .ended):
            return true
        case (.active, .held), (.active, .ended), (.active, .failed):
            return true
        case (.held, .active), (.held, .ended):
            return true
        case let (a, b) where a == b:
            return true                       // idempotent
        default:
            return false
        }
    }

    static func apply(_ event: CallState, to current: CallState) -> CallState {
        guard !isTerminal(current) else { return current }   // ended/failed are final
        return canTransition(from: current, to: event) ? event : current
    }

    static func isTerminal(_ state: CallState) -> Bool {
        state == .ended || state == .failed
    }

    /// Which signal drives which state on the receiving side.
    static func state(after signal: CallSignalKind, current: CallState) -> CallState {
        switch signal {
        case .ringing:   return apply(.ringing, to: current)
        case .offer:     return apply(current == .idle ? .ringing : current, to: current)
        case .answer:    return apply(.connecting, to: current)
        case .candidate: return current                       // no state change
        case .hangup, .decline, .busy: return apply(.ended, to: current)
        }
    }
}
