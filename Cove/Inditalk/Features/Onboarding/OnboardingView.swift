//
//  OnboardingView.swift
//  Inditalk
//
//  Phone-number auth with a 6-digit OTP flow, always backed by real Firebase phone
//  auth. There is no mock or offline sign-in: an unconfigured build shows
//  FirebaseSetupView and never reaches this screen.
//

import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var store: DataStore
    @StateObject private var vm: OnboardingViewModel

    init() {
        _vm = StateObject(wrappedValue: OnboardingViewModel(auth: FirebaseAuthService.shared))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                switch vm.step {
                case .welcome:  welcome
                case .phone:    PhoneEntryView(vm: vm)
                case .code:     OTPView(vm: vm) {
                    // Persist the number the user actually verified so Profile/Settings
                    // show it instead of the seeded placeholder.
                    store.updatePhoneNumber(vm.verifiedPhoneE164)
                    session.completeSignIn()
                }
                }
            }
            .background(Palette.background)
        }
        .tint(Palette.ink)
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle().fill(Palette.ink).frame(width: 120, height: 120)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 52)).foregroundStyle(Palette.textOnAccent)
            }
            Text("Welcome to Inditalk").font(.system(size: 30, weight: .bold, design: .serif))
                .foregroundStyle(Palette.textPrimary)
            Text("Private messaging, built to keep your conversations yours. Simple and warm.")
                .font(.system(size: 16)).foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Spacer()
            Button { vm.step = .phone } label: {
                Text("Get started").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.textOnAccent)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(Palette.ink, in: Capsule())
            }
            Text("By tapping Get started, you agree to the [Terms](https://inditalk.web.app/terms) & [Privacy Policy](https://inditalk.web.app/privacy).")
                .font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                .tint(Palette.ink)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }
}

struct PhoneEntryView: View {
    @ObservedObject var vm: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Enter your phone number")
                .font(.system(size: 24, weight: .bold)).foregroundStyle(Palette.textPrimary)
            Text("Inditalk will send an SMS to verify your number. Carrier rates may apply.")
                .font(.system(size: 15)).foregroundStyle(Palette.textSecondary)

            HStack(spacing: 10) {
                Menu {
                    ForEach(OnboardingViewModel.countryCodes) { entry in
                        Button {
                            vm.countryCode = entry.code
                            Haptics.selection()
                        } label: {
                            if vm.countryCode == entry.code {
                                Label("\(entry.name) (\(entry.code))", systemImage: "checkmark")
                            } else {
                                Text("\(entry.name) (\(entry.code))")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(vm.countryCode).font(.system(size: 18, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, 14).frame(height: 52)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                }
                TextField("Phone number", text: $vm.phone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .font(.system(size: 18))
                    .padding(.horizontal, 14).frame(height: 52)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            }

            if let error = vm.error {
                Text(error).font(.system(size: 13)).foregroundStyle(Palette.danger)
            }

            Spacer()

            Button { vm.requestCode() } label: {
                HStack {
                    if vm.isSending { ProgressView().tint(.white) }
                    Text(vm.isSending ? "Sending…" : "Send code")
                        .font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(Palette.textOnAccent)
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(vm.canSendCode ? Palette.ink : Palette.ink.opacity(0.4), in: Capsule())
            }
            .disabled(!vm.canSendCode || vm.isSending)
        }
        .padding(24)
        .navigationTitle("Verify").navigationBarTitleDisplayMode(.inline)
    }
}

struct OTPView: View {
    @ObservedObject var vm: OnboardingViewModel
    let onVerified: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Enter the 6-digit code")
                .font(.system(size: 24, weight: .bold)).foregroundStyle(Palette.textPrimary)
            Text("Sent to \(vm.enteredNumberDisplay).")
                .font(.system(size: 15)).foregroundStyle(Palette.textSecondary)

            TextField("• • • • • •", text: $vm.code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .padding().frame(maxWidth: .infinity)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
                .disabled(vm.isVerifying)
                .onChange(of: vm.code) { _, _ in vm.verifyIfComplete(onVerified) }

            if vm.isVerifying {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Verifying…").font(.system(size: 14)).foregroundStyle(Palette.textSecondary)
                }
            }

            if let error = vm.error {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).font(.system(size: 13)).foregroundStyle(Palette.danger)
                    Button { vm.retryCodeEntry() } label: {
                        Text("Try again").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                    }
                }
            }

            HStack(spacing: 20) {
                Button { vm.resend() } label: {
                    Text(vm.canResend ? "Resend code" : "Resend code in \(vm.resendCountdownLabel)")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(vm.canResend ? Palette.ink : Palette.textSecondary)
                        .monospacedDigit()
                }
                .disabled(!vm.canResend)

                Button { vm.editNumber() } label: {
                    Text("Wrong number?").font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Palette.ink)
                }
            }

            Spacer()
        }
        .padding(24)
        .navigationTitle("Verify").navigationBarTitleDisplayMode(.inline)
    }
}
