import Foundation
import WebKit

/// Solves a Cloudflare challenge for the extension host (`net.challengeRequired`), as Mihon's
/// Cloudflare interceptor does: the page loads in a WKWebView with the extension's user agent, and
/// once Cloudflare sets `cf_clearance` for the site, its cookies go back to the host. Challenges
/// that need a person (a checkbox) time out; the source then reports Cloudflare's error, and the
/// series can be opened in the browser to pass it.
@MainActor
final class CloudflareSolver: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?

    func solve(_ challenge: ExtensionRPC.ChallengeRequired, timeout: Duration = .seconds(30)) async -> ExtensionRPC.ChallengeResolved {
        guard let url = URL(string: challenge.url) else {
            return .init(challengeId: challenge.challengeId, solved: false, reason: "Bad URL")
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        webView.customUserAgent = challenge.userAgent ?? ExtensionHost.userAgent
        self.webView = webView
        defer {
            webView.stopLoading()
            self.webView = nil
        }
        // Cookies the host's jar should have already: start from what WebKit knows.
        let store = configuration.websiteDataStore.httpCookieStore
        let before = await store.allCookies().first { $0.name == "cf_clearance" && Self.matches($0, host: challenge.host) }?.value
        webView.load(URLRequest(url: url))
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(500))
            let cookies = await store.allCookies().filter { Self.matches($0, host: challenge.host) }
            if let clearance = cookies.first(where: { $0.name == "cf_clearance" }), clearance.value != before {
                return .init(challengeId: challenge.challengeId, solved: true, cookies: cookies.map(Self.cookie))
            }
        }
        return .init(challengeId: challenge.challengeId, solved: false, reason: "timeout")
    }

    private static func matches(_ cookie: HTTPCookie, host: String) -> Bool {
        let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        return host == domain || host.hasSuffix("." + domain)
    }

    private static func cookie(_ cookie: HTTPCookie) -> ExtensionRPC.Cookie {
        ExtensionRPC.Cookie(
            name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path,
            expiresAt: cookie.expiresDate.map { Int64($0.timeIntervalSince1970 * 1000) }, secure: cookie.isSecure,
            httpOnly: cookie.isHTTPOnly, hostOnly: !cookie.domain.hasPrefix(".")
        )
    }
}
