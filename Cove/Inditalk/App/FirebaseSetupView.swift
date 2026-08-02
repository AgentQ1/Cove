//
//  FirebaseSetupView.swift
//  Inditalk
//
//  Shown INSTEAD of the app when Firebase isn't configured. Inditalk has no demo or
//  offline mode: rather than seeding fabricated chats so the UI "looks alive", we
//  state plainly what is missing and how to fix it. This screen is a developer
//  setup aid — a correctly configured build never reaches it.
//

import SwiftUI

struct FirebaseSetupView: View {
    let problem: AppConfig.ConfigurationProblem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Palette.ochre)
                    .accessibilityHidden(true)

                Text(problem.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(problem.detail)
                    .font(.callout)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Fix it with the Firebase CLI")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.textPrimary)
                    Text(Self.cliSteps)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(Palette.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.background.ignoresSafeArea())
    }

    private static let cliSteps = """
    firebase apps:list --project cove-7f31f
    firebase apps:sdkconfig IOS <APP_ID> \\
      --project cove-7f31f \\
      --out Inditalk/Resources/GoogleService-Info.plist
    """
}

#Preview("Missing plist") {
    FirebaseSetupView(problem: .missingPlist)
}

#Preview("Malformed plist") {
    FirebaseSetupView(problem: .malformedPlist(missingKeys: ["API_KEY", "PROJECT_ID"]))
}
