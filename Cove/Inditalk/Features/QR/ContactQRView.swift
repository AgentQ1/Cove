//
//  ContactQRView.swift
//  Inditalk
//
//  "My code" / "Scan code", the WhatsApp-style pair. The displayed code encodes the
//  signed-in user's real Firebase uid; scanning resolves the scanned uid against
//  Firestore and offers to open a chat with that genuine account.
//
//  Every failure is explicit — an unknown uid, a non-Inditalk code, and a network problem
//  read differently, because "nothing happened" is the worst possible outcome here.
//

import SwiftUI

struct ContactQRView: View {
    @EnvironmentObject private var store: DataStore
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case myCode = "My code"
        case scan = "Scan"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .myCode
    @State private var resolved: ResolvedContact?
    @State private var errorMessage: String?
    @State private var isResolving = false
    @State private var cameraDenied = false

    /// A scan that resolved to a real account.
    private struct ResolvedContact: Identifiable {
        let user: InditalkUser
        var id: UUID { user.id }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(16)

                switch mode {
                case .myCode: myCode
                case .scan:   scanner
                }
            }
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle("Contact code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }.tint(Palette.ink)
                }
            }
            .alert("Couldn't add contact", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(item: $resolved) { match in
                ScannedContactSheet(user: match.user) { dismiss() }
            }
        }
    }

    // MARK: My code

    @ViewBuilder private var myCode: some View {
        let uid = store.currentUser.remoteUID

        VStack(spacing: 20) {
            Spacer(minLength: 0)

            if let uid, !uid.isEmpty, let image = InditalkQRCode.image(for: InditalkQRCode.payload(for: uid)) {
                VStack(spacing: 16) {
                    AvatarView(name: store.currentUser.displayName,
                               imageName: store.currentUser.avatarAsset,
                               localName: store.currentUser.avatarLocalName,
                               size: 64)
                    Text(store.currentUser.displayName.isEmpty ? "Your code" : store.currentUser.displayName)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)

                    Image(uiImage: image)
                        .interpolation(.none)          // keep QR modules crisp
                        .resizable()
                        .scaledToFit()
                        .frame(width: 240, height: 240)
                        .padding(16)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                    Text("Have someone scan this to start a chat with you.")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
            } else {
                // No uid means the account isn't linked to Firebase yet. Say so plainly
                // instead of rendering a code that resolves to nobody.
                EmptyStateView(
                    symbol: "qrcode",
                    title: "No code yet",
                    message: "Your contact code appears once you're signed in and your profile has synced with Inditalk."
                )
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Scanner

    @ViewBuilder private var scanner: some View {
        ZStack {
            if cameraDenied {
                VStack(spacing: 16) {
                    EmptyStateView(
                        symbol: "camera.fill",
                        title: "Camera access is off",
                        message: "Allow camera access in Settings to scan a contact code."
                    )
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(minWidth: 44, minHeight: 44)
                }
            } else {
                QRScannerView(
                    onScan: { handleScan($0) },
                    onFailure: { errorMessage = $0 }
                )
                .ignoresSafeArea(edges: .bottom)

                // Aiming reticle.
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.9), lineWidth: 3)
                    .frame(width: 230, height: 230)
                    .shadow(radius: 8)
                    .allowsHitTesting(false)

                if isResolving {
                    ProgressView()
                        .tint(.white)
                        .padding(20)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .task(id: mode) {
            guard mode == .scan else { return }
            cameraDenied = await PermissionsManager.shared.requestCamera() == false
        }
    }

    // MARK: Resolution

    private func handleScan(_ value: String) {
        guard !isResolving else { return }

        let uid: String
        do {
            uid = try InditalkQRCode.uid(from: value)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        guard uid != store.currentUser.remoteUID else {
            errorMessage = "That's your own contact code."
            return
        }

        isResolving = true
        Task {
            defer { isResolving = false }
            do {
                guard let remote = try await FirestoreService.shared.fetchUser(uid: uid),
                      let user = FirebaseSyncCoordinator.mapUser(remote) else {
                    errorMessage = "No Inditalk account matches that code. They may have deleted their account."
                    return
                }
                // Persist the scanned account locally so the chat has a real, uid-linked
                // contact behind it.
                store.ingest(remoteUsers: [user])
                resolved = ResolvedContact(user: store.users[user.id] ?? user)
            } catch {
                errorMessage = "Couldn't look that code up. Check your connection and try again."
            }
        }
    }
}

/// Confirmation shown after a successful scan.
private struct ScannedContactSheet: View {
    @EnvironmentObject private var store: DataStore
    @Environment(\.dismiss) private var dismiss
    let user: InditalkUser
    let onOpenChat: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            AvatarView(name: user.displayName, imageName: user.avatarAsset,
                       localName: user.avatarLocalName, size: 84)
                .padding(.top, 32)
            Text(user.displayName.isEmpty ? user.phoneNumber : user.displayName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            if !user.phoneNumber.isEmpty {
                Text(user.phoneNumber)
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.textSecondary)
            }

            Button {
                store.startDirectChat(with: user)
                dismiss()
                onOpenChat()
            } label: {
                Text("Message")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.textOnAccent)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Palette.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.horizontal, 24)

            Button("Not now") { dismiss() }
                .font(.system(size: 16))
                .foregroundStyle(Palette.textSecondary)
                .frame(minWidth: 44, minHeight: 44)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Palette.background.ignoresSafeArea())
        .presentationDetents([.medium])
    }
}
