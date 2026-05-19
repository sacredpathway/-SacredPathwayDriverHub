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
        // Pro tier — auto-renewable
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

        /// New "Driver Hub Pro" product with 7-day free trial. Once this
        /// product is created in App Store Connect it will appear in the
        /// paywall alongside the legacy `proMonthly`. Keeping both IDs in
        /// `all` ensures existing subscribers stay entitled while new
        /// purchases default to this product.
        static let driverHubProMonthly = "com.demarquishinton.sacredpathway.pro.monthly"

        // Carrier tier — auto-renewable
        static let carrierMonthly = "com.sacredpathway.driverhub.carrier_monthly"
        static let carrierAnnual  = "com.sacredpathway.driverhub.carrier_annual"

        /// Every product ID that the paywall is allowed to request from
        /// StoreKit. Must stay in sync with App Store Connect.
        static let all: Set<String> = [
            proMonthly, proAnnual,
            driverHubProMonthly,
            carrierMonthly, carrierAnnual
        ]
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
