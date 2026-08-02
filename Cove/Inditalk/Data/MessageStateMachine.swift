//
//  MessageStateMachine.swift
//  Inditalk
//
//  Pure state machine governing an outgoing message's delivery lifecycle. Kept free
//  of side effects so it is exhaustively unit-tested and reused by both the local
//  simulation (Phase 1) and the real receipt handling (Phase 3).
//
//  Legal transitions:
//    sending   -> sent | failed
//    sent      -> delivered | failed
//    delivered -> read
//    failed    -> sending            (retry)
//    read      -> (terminal)
//  Receipts never move a message *backwards* (a late "delivered" after "read" is ignored).
//

import Foundation

enum MessageStateMachine {

    /// Whether `to` is a legal successor of `from`.
    static func canTransition(from: MessageState, to: MessageState) -> Bool {
        switch (from, to) {
        case (.sending, .sent), (.sending, .failed),
             (.sent, .delivered), (.sent, .failed),
             (.delivered, .read),
             (.failed, .sending):
            return true
        // Allow idempotent no-ops (server may re-send the same receipt).
        case let (a, b) where a == b:
            return true
        default:
            return false
        }
    }

    /// Apply a transition if legal; return the resulting state (unchanged if illegal
    /// or a backwards move, which we silently ignore to tolerate out-of-order receipts).
    static func apply(_ event: MessageState, to current: MessageState) -> MessageState {
        canTransition(from: current, to: event) ? event : current
    }

    /// Numeric rank used to reject out-of-order (backwards) receipts.
    static func rank(_ state: MessageState) -> Int {
        switch state {
        case .failed:    return -1
        case .sending:   return 0
        case .sent:      return 1
        case .delivered: return 2
        case .read:      return 3
        }
    }

    /// Merge an incoming receipt state, never regressing progress.
    static func merge(current: MessageState, incoming: MessageState) -> MessageState {
        if incoming == .failed { return current == .read ? .read : .failed }
        return rank(incoming) > rank(current) ? incoming : current
    }
}
