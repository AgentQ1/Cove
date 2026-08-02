//
//  LocationService.swift
//  Inditalk
//
//  One-shot location for the "share location" composer action. Wraps
//  CLLocationManager's delegate callbacks (which arrive off-main) into async
//  main-actor APIs: request when-in-use permission, then fetch a single fix
//  with a timeout.
//

import Foundation
import CoreLocation

@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    enum LocationError: Error, LocalizedError {
        case denied
        case unavailable

        var errorDescription: String? {
            switch self {
            case .denied: return "Location access is off. Enable it in Settings to share your location."
            case .unavailable: return "Your location couldn't be determined. Try again."
            }
        }
    }

    @Published var authorization: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()
    private var permissionContinuations: [CheckedContinuation<Bool, Never>] = []
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorization = manager.authorizationStatus
    }

    /// Ask for when-in-use permission (or resolve immediately if already decided).
    func requestPermission() async -> Bool {
        switch authorization {
        case .authorizedWhenInUse, .authorizedAlways: return true
        case .denied, .restricted: return false
        default: break
        }
        return await withCheckedContinuation { continuation in
            permissionContinuations.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    /// One-shot fix with a 10s timeout. Throws LocationError.denied / .unavailable.
    func currentLocation() async throws -> CLLocation {
        guard await requestPermission() else { throw LocationError.denied }
        guard locationContinuation == nil else { throw LocationError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            locationContinuation = continuation
            manager.requestLocation()
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                self?.finish(with: .failure(LocationError.unavailable))
            }
        }
    }

    private func finish(with result: Result<CLLocation, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let continuation = locationContinuation else { return }
        locationContinuation = nil
        continuation.resume(with: result)
    }

    // MARK: CLLocationManagerDelegate (callbacks arrive off-main — hop to MainActor)

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            guard status != .notDetermined else { return }
            let granted = status == .authorizedWhenInUse || status == .authorizedAlways
            let waiting = self.permissionContinuations
            self.permissionContinuations = []
            for continuation in waiting { continuation.resume(returning: granted) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in self.finish(with: .success(location)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(with: .failure(LocationError.unavailable)) }
    }
}
