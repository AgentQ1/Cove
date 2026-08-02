//
//  LocationPickerSheet.swift
//  Inditalk
//
//  "Share location" flow from the attachment picker: requests when-in-use
//  permission through LocationService, resolves a one-shot fix with a spinner,
//  shows the result on a map, and hands the coordinate back for the attachment
//  preview. Denied permission gets an inline recovery path (Open Settings),
//  never a dead end.
//

import SwiftUI
import UIKit
import MapKit
import CoreLocation

struct LocationPickerSheet: View {
    let onPick: (_ latitude: Double, _ longitude: Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading

    private enum Phase {
        case loading
        case denied
        case failed(String)
        case ready(CLLocationCoordinate2D)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    VStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Palette.ink)
                        Text("Finding your location…")
                            .font(.system(size: 15))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .denied:
                    recovery(
                        symbol: "location.slash",
                        title: "Location access is off",
                        message: "Allow location access in Settings so Inditalk can share where you are.",
                        primaryTitle: "Open Settings",
                        primaryAction: {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    )

                case .failed(let message):
                    recovery(
                        symbol: "location.magnifyingglass",
                        title: "Couldn't find your location",
                        message: message,
                        primaryTitle: "Try Again",
                        primaryAction: { Task { await resolve() } }
                    )

                case .ready(let coordinate):
                    VStack(spacing: 0) {
                        Map(initialPosition: .region(MKCoordinateRegion(
                            center: coordinate,
                            span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)))) {
                            Marker("You are here", coordinate: coordinate)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(Metrics.screenPadding)

                        Button {
                            Haptics.selection()
                            onPick(coordinate.latitude, coordinate.longitude)
                        } label: {
                            Label("Send current location", systemImage: "location.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.ink)
                        .padding(.horizontal, Metrics.screenPadding)
                        .padding(.bottom, Metrics.screenPadding)
                    }
                }
            }
            .background(Palette.background)
            .navigationTitle("Share location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Palette.ink)
                }
            }
        }
        .task { await resolve() }
    }

    private func recovery(symbol: String, title: String, message: String,
                          primaryTitle: String, primaryAction: @escaping () -> Void) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Palette.textSecondary.opacity(0.7))
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Button(primaryTitle, action: primaryAction)
                .buttonStyle(.borderedProminent)
                .tint(Palette.ink)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resolve() async {
        phase = .loading
        guard await LocationService.shared.requestPermission() else {
            phase = .denied
            return
        }
        do {
            let location = try await LocationService.shared.currentLocation()
            phase = .ready(location.coordinate)
        } catch {
            phase = .failed("Your location couldn't be determined. Check that you have a clear GPS signal and try again.")
        }
    }
}
