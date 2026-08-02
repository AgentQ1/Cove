//
//  ContactsMatchingTests.swift
//  InditalkTests
//
//  Covers the phone-number canonicalization used to match device contacts and
//  saved contacts against Inditalk users: `ContactsService.normalized(phone:)` and
//  `ContactsService.phonesMatch(_:_:)`.
//

import XCTest
@testable import Inditalk

final class ContactsMatchingTests: XCTestCase {

    // MARK: normalized(phone:)

    func testNormalizedStripsFormatting() {
        XCTAssertEqual(ContactsService.normalized(phone: "+1 (415) 555-0102"), "14155550102")
        XCTAssertEqual(ContactsService.normalized(phone: "415.555.0102"), "4155550102")
        XCTAssertEqual(ContactsService.normalized(phone: "+91 98450 11223"), "919845011223")
        XCTAssertEqual(ContactsService.normalized(phone: "  1-415-555-0102 x9 "), "141555501029",
                       "every digit survives, everything else is dropped")
    }

    func testNormalizedNonNumericBecomesEmpty() {
        XCTAssertEqual(ContactsService.normalized(phone: ""), "")
        XCTAssertEqual(ContactsService.normalized(phone: "no digits here"), "")
        XCTAssertEqual(ContactsService.normalized(phone: "+()- ."), "")
    }

    // MARK: phonesMatch(_:_:)

    func testPhonesMatchExactEquality() {
        XCTAssertTrue(ContactsService.phonesMatch("14155550102", "14155550102"))
        // Short numbers (under 10 digits) match only when exactly equal.
        XCTAssertTrue(ContactsService.phonesMatch("5550102", "5550102"))
    }

    func testPhonesMatchIgnoresCountryCodeViaLastTenDigits() {
        XCTAssertTrue(ContactsService.phonesMatch("14155550102", "4155550102"))
        XCTAssertTrue(ContactsService.phonesMatch("919845011223", "9845011223"))
        XCTAssertTrue(ContactsService.phonesMatch("0014155550102", "14155550102"))
    }

    func testPhonesMatchRejectsShortMismatch() {
        // Both under 10 digits and unequal: no suffix rule applies.
        XCTAssertFalse(ContactsService.phonesMatch("5550102", "15550102"))
        // One side under 10 digits blocks the suffix comparison too.
        XCTAssertFalse(ContactsService.phonesMatch("555010", "14155550102"))
    }

    func testPhonesMatchRejectsEmpty() {
        XCTAssertFalse(ContactsService.phonesMatch("", "14155550102"))
        XCTAssertFalse(ContactsService.phonesMatch("14155550102", ""))
        XCTAssertFalse(ContactsService.phonesMatch("", ""))
    }

    func testPhonesMatchRejectsDifferentNumbers() {
        XCTAssertFalse(ContactsService.phonesMatch("14155550102", "14155550103"))
        XCTAssertFalse(ContactsService.phonesMatch("919845011223", "14155550102"))
    }
}
