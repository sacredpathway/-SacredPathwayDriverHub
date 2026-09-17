import Foundation

/// Centralised configuration. The iPhone no longer holds any AI provider
/// secrets — all OpenAI calls happen on the Supabase Edge Functions
/// (`extract-document`, `generate-insights`).
///
/// Supabase URL + anon key still live here so the SDK can talk to Postgres,
/// Storage, and Functions; both are public values.
enum Config {
    // MARK: - Supabase
    static let supabaseURL = URL(string: "https://rmzqxsfhjqrshhdjzhze.supabase.co")!
    static let supabaseAnonKey = "sb_publishable_fmtOiW3h_Gt_vdpY6MiKkQ_-9ZAOQA_"

    // MARK: - Storage
    /// Bucket created in `supabase/migrations/20260417120000_openai_documents.sql`.
    static let documentsBucket = "documents"

    // MARK: - Edge Functions
    static let extractDocumentFunction = "extract-document"
    static let generateInsightsFunction = "generate-insights"

    /// Deploy the SQL + Edge Function from `supabase/functions/delete-account`
    /// and name it exactly `delete-account`. The function hard-deletes the
    /// user's row in auth.users via the service role key; this is the only
    /// App-Store-compliant way to provide in-app account deletion because the
    /// client doesn't (and must not) hold the service role key.
    static let deleteAccountFunction = "delete-account"

    // MARK: - In-App Purchase product IDs
    //
    // Replace these strings with the EXACT Product ID you configure in App
    // Store Connect → My Apps → Sacred Pathway → Features → Subscriptions.
    // They are the single source of truth — every purchase and entitlement
    // check resolves through these constants.
    enum IAP {
        // Owner Operator legacy products — auto-renewable
        // Product IDs MUST match App Store Connect exactly. These mirror
        // the "Sacred Pathway Subscriptions" group (Apple ID: 22038490).
        // NOTE: these IDs are intentionally inconsistent — each one was
        // re-created in App Store Connect with a unique mix of "." and
        // "_" because the original all-period IDs were already taken
        // and Apple does not allow duplicates. Do NOT "fix" them. They
        // must match App Store Connect verbatim or `Product.products(for:)`
        // returns empty and the paywall says "products are unavailable".
        static let proMonthly   = "com.sacredpathway.pro_monthly"
        static let proAnnual    = "com.sacredpathway.driverhub_pro.annual"

        /// Driver monthly product. The ID still contains "pro" because Apple
        /// product IDs are immutable once created; entitlement mapping treats
        /// it as the Driver tier.
        static let driverHubProMonthly = "com.demarquishinton.sacredpathway.pro.monthly"

        // Carrier tier — auto-renewable
        static let carrierMonthly = "com.sacredpathway.driverhub.carrier_monthly"
        static let carrierAnnual  = "com.sacredpathway.driverhub.carrier_annual"

        // ── Driver Annual (STAGED — not yet created in App Store Connect) ──
        // Phase 2 · S10 revenue finding: Driver is the ONLY tier with no
        // annual option. The constant below is the ID to use WHEN creating
        // the product in ASC (Subscriptions → "Sacred Pathway Subscriptions"
        // group → + → Auto-Renewable; copy this string verbatim — IDs are
        // immutable once created, so create it EXACTLY as written).
        //
        // Suggested ASC setup: $149.99/yr (≈2 months free vs $14.99/mo),
        // same 7-day intro offer as Driver Monthly, same subscription group
        // (so Apple handles upgrade/crossgrade automatically).
        //
        // SAFETY: `driverAnnualEnabled` stays false until the product is
        // live in ASC. While false, the ID is excluded from `all`, so
        // StoreKit is never asked for an uncreated product and the paywall
        // renders exactly as today. Flip to true ONLY after ASC shows the
        // product "Ready to Submit"/"Approved". Entitlement mapping for this
        // ID must be added to SubscriptionService.tier(for:) in the same
        // change that flips this flag (one reviewable commit).
        static let driverAnnual = "com.sacredpathway.driverhub.driver_annual"
        static let driverAnnualEnabled = false

        /// Every product ID that the paywall is allowed to request from
        /// StoreKit. Must stay in sync with App Store Connect.
        static var all: Set<String> {
            var ids: Set<String> = [
                proMonthly, proAnnual,
                driverHubProMonthly,
                carrierMonthly, carrierAnnual
            ]
            if driverAnnualEnabled {
                ids.insert(driverAnnual)
            }
            return ids
        }
    }

    // MARK: - Force Update / Remote Config
    //
    // Remote JSON file that decides whether the app should block launch
    // and require an update. See `Models/RemoteAppConfig.swift` for the
    // schema. Hosted in the public Supabase Storage bucket `config`
    // (project `rmzqxsfhjqrshhdjzhze`). Edit by re-uploading via the
    // Supabase dashboard — the public URL is stable across edits.
    //
    // Operational rule: KEEP THIS URL STABLE. Once a build ships pointing
    // at this URL, every future build must keep reading from the same URL
    // or older clients won't see the kill-switch.
    enum ForceUpdate {
        static let configURL = URL(string: "https://rmzqxsfhjqrshhdjzhze.supabase.co/storage/v1/object/public/config/force-update.json")!

        /// Apple App Store product URL fallback if the JSON omits it.
        /// Live Driver Hub Apple ID (Sacred Pathway LLC, bundle
        /// `com.demarquishinton.sacredpathway`). The remote JSON's
        /// `appStoreURL` overrides this when present.
        static let fallbackAppStoreURL = URL(string: "https://apps.apple.com/us/app/sacred-pathway-driver-hub/id6762578372")!

        /// How long the launch check waits before failing open. Keep this
        /// short — a slow CDN must NEVER lock the user out of the app.
        static let requestTimeout: TimeInterval = 4.0
    }

    // MARK: - Web Portal
    //
    // The browser portal under `/web/` in this repo (deployed to a static
    // host) lets users sign in with the same Supabase account they use on
    // iOS and view the same loads, documents, broker contacts, and weekly
    // totals from any computer. Update this URL once the portal is live
    // on the production domain — the iOS Settings row reads it directly.
    enum Web {
        static let dashboardURL = URL(string: "https://app.sacredpathway.org/")!

        /// Gate for the Settings → Web Access row. Flipped to `true`
        /// 2026-05-18 after the Cloudflare Pages deploy at
        /// `https://app.sacredpathway.org` verified live + HTTPS + auth
        /// (email/password sign-in working). Cloud Sync users can now
        /// open the web dashboard from inside the iOS app.
        static let portalLive = true
    }

    // MARK: - Sacred Road Supply (sibling brand storefront)
    //
    // Sacred Road Supply is Sacred Pathway LLC's trucker-gear e-commerce
    // store at `https://shop.sacredpathway.org`. Built on Shopify with the
    // same canonical brand palette (spGold + spDarkGreen) so the visual
    // family is preserved across Driver Hub iOS + Sacred Road Supply.
    //
    // The Settings → Sacred Road Supply Store row opens the storefront in
    // Safari (external browser, NOT in-app WebView — keeps clean separation
    // and avoids Apple Guideline 3.1.1 IAP scrutiny on physical goods sold
    // through Shopify's own checkout).
    enum Store {
        static let storeURL = URL(string: "https://shop.sacredpathway.org/")!

        /// Gate for the Settings → Sacred Road Supply row. Set to `false`
        /// until the Shopify storefront is published with products live.
        /// Flip to `true` after Shopify launch + at least one collection
        /// shows products + checkout completes a real test order.
        static let storeLive = false
    }

    // MARK: - Customer Support / Feedback
    //
    // Branded Sacred Pathway support inbox. Must be a monitored mailbox on the
    // sacredpathway.org domain (same domain as the Legal pages Apple review
    // clicks). The Settings → Support section builds `mailto:` links to these
    // addresses with the app version + device pre-filled in the body so users
    // and reviewers can reach a real person.
    enum Support {
        static let supportEmail  = "support@sacredpathway.org"
        static let feedbackEmail = "feedback@sacredpathway.org"

        /// Builds a `mailto:` URL with an encoded subject + body. Returns the
        /// bare `mailto:address` if encoding ever fails so the row still works.
        static func mailto(to address: String, subject: String, body: String) -> URL {
            var components = URLComponents()
            components.scheme = "mailto"
            components.path = address
            components.queryItems = [
                URLQueryItem(name: "subject", value: subject),
                URLQueryItem(name: "body", value: body)
            ]
            return components.url ?? URL(string: "mailto:\(address)")!
        }
    }

    // MARK: - Weather (OpenWeatherMap)
    //
    // The Weather Map + dashboard "Weather Near Me" card use OpenWeatherMap for
    // raster radar tile overlays and current conditions. The API key is NEVER
    // hard-coded here. It is read at runtime from the Info.plist key
    // `OpenWeatherMapAPIKey`, which is populated by a build setting so the
    // literal key is not committed to source control.
    //
    // SETUP (one time):
    //   1. Get a free key at https://openweathermap.org/api (One Call 3.0 is
    //      optional — without it, conditions + tiles still work; provider
    //      alerts are simply omitted).
    //   2. Xcode → target "SacredPathway" → Build Settings → "+" → Add User-
    //      Defined Setting → OPENWEATHERMAP_API_KEY = <your key> (prefer an
    //      .xcconfig that is git-ignored).
    //   3. Info.plist already maps OpenWeatherMapAPIKey = $(OPENWEATHERMAP_API_KEY).
    //
    // For a quick local test set OWM_API_KEY in the Run scheme's environment;
    // that path is checked first.
    enum Weather {
        /// Resolved at runtime. Order: env var → Info.plist build setting → empty.
        static var openWeatherMapAPIKey: String {
            if let env = ProcessInfo.processInfo.environment["OWM_API_KEY"],
               !env.isEmpty {
                return env
            }
            if let key = Bundle.main.object(forInfoDictionaryKey: "OpenWeatherMapAPIKey") as? String,
               !key.isEmpty,
               key != "$(OPENWEATHERMAP_API_KEY)" {
                return key
            }
            return ""
        }

        static var isConfigured: Bool { !openWeatherMapAPIKey.isEmpty }
    }

    // MARK: - Legal URLs
    //
    // These must point to LIVE, REACHABLE pages before submission. Apple
    // review will click both links; a 404 or placeholder triggers a 5.1.1
    // privacy rejection. Host them on a static site (GitHub Pages, Notion,
    // a simple Cloudflare Pages deploy) — any public URL is fine.
    enum Legal {
        static let privacyPolicyURL = URL(string: "https://www.sacredpathway.org/sacredpathway-driver-hub-privacy")!
        static let termsOfServiceURL = URL(string: "https://www.sacredpathway.org/sacredpathway-driver-hub-terms")!

        /// Apple's universal subscription-management deep link. Always valid.
        static let manageSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!
    }
}
