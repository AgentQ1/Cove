//
//  Disappearing.swift
//  Inditalk
//
//  Options for the per-chat disappearing-messages timer (Phase 5 implements the
//  scheduled local deletion; the model + UI live here so Phase 1/2 can drive them).
//

import Foundation

enum DisappearingOption: Int, CaseIterable, Identifiable {
    case off = 0
    case twentyFourHours = 86_400
    case sevenDays = 604_800
    case ninetyDays = 7_776_000

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .twentyFourHours: return "24 hours"
        case .sevenDays: return "7 days"
        case .ninetyDays: return "90 days"
        }
    }

    static func label(for seconds: Int) -> String {
        DisappearingOption(rawValue: seconds)?.label ?? "\(seconds / 3600) hours"
    }
}
