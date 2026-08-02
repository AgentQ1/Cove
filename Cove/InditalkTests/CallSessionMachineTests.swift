//
//  CallSessionMachineTests.swift
//  InditalkTests
//
//  Covers the call lifecycle state machine used by both the CallKit and WebRTC paths.
//

import XCTest
@testable import Inditalk

final class CallSessionMachineTests: XCTestCase {

    func testCallerHappyPath() {
        var s: CallState = .idle
        s = CallSessionMachine.apply(.dialing, to: s);    XCTAssertEqual(s, .dialing)
        s = CallSessionMachine.apply(.connecting, to: s); XCTAssertEqual(s, .connecting)
        s = CallSessionMachine.apply(.active, to: s);     XCTAssertEqual(s, .active)
        s = CallSessionMachine.apply(.ended, to: s);      XCTAssertEqual(s, .ended)
    }

    func testCalleeHappyPath() {
        var s: CallState = .idle
        s = CallSessionMachine.apply(.ringing, to: s);    XCTAssertEqual(s, .ringing)
        s = CallSessionMachine.apply(.connecting, to: s); XCTAssertEqual(s, .connecting)
        s = CallSessionMachine.apply(.active, to: s);     XCTAssertEqual(s, .active)
    }

    func testTerminalStatesAreFinal() {
        XCTAssertEqual(CallSessionMachine.apply(.active, to: .ended), .ended)
        XCTAssertEqual(CallSessionMachine.apply(.dialing, to: .failed), .failed)
        XCTAssertTrue(CallSessionMachine.isTerminal(.ended))
        XCTAssertTrue(CallSessionMachine.isTerminal(.failed))
        XCTAssertFalse(CallSessionMachine.isTerminal(.active))
    }

    func testIllegalTransitionsIgnored() {
        XCTAssertEqual(CallSessionMachine.apply(.active, to: .idle), .idle)   // can't jump idle→active
        XCTAssertEqual(CallSessionMachine.apply(.ringing, to: .active), .active)
    }

    func testHoldToggle() {
        var s: CallState = .active
        s = CallSessionMachine.apply(.held, to: s);   XCTAssertEqual(s, .held)
        s = CallSessionMachine.apply(.active, to: s); XCTAssertEqual(s, .active)
    }

    func testSignalDrivenTransitions() {
        XCTAssertEqual(CallSessionMachine.state(after: .offer, current: .idle), .ringing)
        XCTAssertEqual(CallSessionMachine.state(after: .answer, current: .dialing), .connecting)
        XCTAssertEqual(CallSessionMachine.state(after: .candidate, current: .connecting), .connecting)
        XCTAssertEqual(CallSessionMachine.state(after: .hangup, current: .active), .ended)
        XCTAssertEqual(CallSessionMachine.state(after: .decline, current: .ringing), .ended)
    }
}
