import Foundation

/// Turns a recipe's stored `sourceURL` string into a `URL` only when it's
/// actually a plain web link — never a `Link(destination:)`/`openURL` target
/// built straight from `URL(string:)` with no further check.
///
/// Direct, confirmed finding: any signed-in user (a total stranger, once a
/// recipe is published to the public Library) can set a recipe's
/// `sourceURL` to anything at all — the backend now rejects a non-http(s)
/// value on write (see `sourceUrlField` in routes/recipeLibrary.js), but a
/// recipe saved before that validation existed, or reached through some
/// other path, could still carry something else: a phishing page, or an
/// arbitrary custom URL scheme another app on the device registered.
/// `URL(string:)` alone doesn't care what scheme a string parses to, and
/// `Link`/`UIApplication.open` will happily open whatever it's handed —
/// this is the one, shared place that actually closes that off on the
/// client, so every "View Original Recipe" call site uses it instead of
/// each re-deriving its own unchecked `URL(string:)`.
enum SafeWebLink {
    static func url(from sourceURL: String?) -> URL? {
        guard let sourceURL, let url = URL(string: sourceURL) else { return nil }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }
}
