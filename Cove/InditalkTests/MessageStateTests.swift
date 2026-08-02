//
//  MessageStateTests.swift
//  InditalkTests
//
//  Exhaustive coverage of the outgoing-message delivery state machine.
//

import XCTest
@testable import Inditalk

final class MessageStateTests: XCTestCase {

    func testForwardTransitionsAreLegal() {
        XCTAssertTrue(MessageStateMachine.canTransition(from: .sending, to: .sent))
        XCTAssertTrue(MessageStateMachine.canTransition(from: .sent, to: .delivered))
        XCTAssertTrue(MessageStateMachine.canTransition(from: .delivered, to: .read))
    }

    func testFailureAndRetry() {
        XCTAssertTrue(MessageStateMachine.canTransition(from: .sending, to: .failed))
        XCTAssertTrue(MessageStateMachine.canTransition(from: .sent, to: .failed))
        XCTAssertTrue(MessageStateMachine.canTransition(from: .failed, to: .sending))
    }

    func testIllegalBackwardTransitionsRejected() {
        XCTAssertFalse(MessageStateMachine.canTransition(from: .read, to: .delivered))
        XCTAssertFalse(MessageStateMachine.canTransition(from: .delivered, to: .sent))
        XCTAssertFalse(MessageStateMachine.canTransition(from: .read, to: .sending))
    }

    func testApplyIgnoresIllegalTransition() {
        XCTAssertEqual(MessageStateMachine.apply(.sent, to: .read), .read)   // stays read
        XCTAssertEqual(MessageStateMachine.apply(.delivered, to: .sent), .delivered)
    }

    func testMergeNeverRegresses() {
        XCTAssertEqual(MessageStateMachine.merge(current: .read, incoming: .delivered), .read)
        XCTAssertEqual(MessageStateMachine.merge(current: .sent, incoming: .delivered), .delivered)
        XCTAssertEqual(MessageStateMachine.merge(current: .delivered, incoming: .delivered), .delivered)
    }

    func testFailedDoesNotOverrideRead() {
        XCTAssertEqual(MessageStateMachine.merge(current: .read, incoming: .failed), .read)
        XCTAssertEqual(MessageStateMachine.merge(current: .sent, incoming: .failed), .failed)
    }

    func testOutOfOrderReceiptsConverge() {
        // Simulate receipts arriving out of order: read before delivered.
        var state: MessageState = .sent
        state = MessageStateMachine.merge(current: state, incoming: .read)
        state = MessageStateMachine.merge(current: state, incoming: .delivered)   // late, ignored
        XCTAssertEqual(state, .read)
    }
}
