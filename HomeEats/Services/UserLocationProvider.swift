import CoreLocation

/// `CLLocationCoordinate2D` doesn't conform to `Equatable` on its own (it's
/// a plain C struct bridged from CoreLocation) — needed here so
/// `RestaurantListView` can `.onChange(of: locationProvider.coordinate)` to
/// notice a fresh fix and forward it into `RestaurantSearchModel`. Just
/// compares the two doubles directly; exact equality is fine since this is
/// never used for "did the user move" comparisons, only "did a new location
/// value just get published."
extension CLLocationCoordinate2D: @retroactive Equatable {
    public static func == (lhs: CLLocationCoordinate2D, rhs: CLLocationCoordinate2D) -> Bool {
        lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
    }
}

/// A lightweight, one-shot "where is the user right now" helper — just
/// enough to bias a restaurant search toward nearby results, not a full
/// location-tracking subsystem. Requests "when in use" permission on first
/// use; if denied (or not yet answered), search just falls back to its
/// previous unbiased behavior rather than blocking on a prompt.
@MainActor
final class UserLocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var coordinate: CLLocationCoordinate2D?

    private let manager = CLLocationManager()
    private var hasRequestedThisLaunch = false

    override init() {
        super.init()
        manager.delegate = self
    }

    /// Kicks off a permission request (if needed) and a location fetch.
    /// Safe to call repeatedly — only the first call in a given app launch
    /// actually triggers anything, since one fix is plenty for biasing
    /// search results (the user isn't expected to be traveling between
    /// keystrokes).
    func requestIfNeeded() {
        guard !hasRequestedThisLaunch else { return }
        hasRequestedThisLaunch = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        Task { @MainActor in
            self.coordinate = latest.coordinate
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Search just keeps working unbiased — not worth surfacing an error
        // for a "nice to have" ranking signal.
    }
}
