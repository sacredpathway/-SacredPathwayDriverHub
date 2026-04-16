import Foundation

enum Config {
    // ⚠️ PASTE YOUR ACTUAL VALUES HERE (from Supabase Dashboard → Settings → API)
    static let supabaseURL = URL(string: "https://rmzqxsfhjqrshhdjzhze.supabase.co")!
    static let supabaseAnonKey = "sb_publishable_fmtOiW3h_Gt_vdpY6MiKkQ_-9ZAOQA_"

    // ⚠️ PASTE YOUR ANTHROPIC API KEY HERE (from console.anthropic.com → API Keys)
    // This powers the AI document scanning — Claude reads rate cons, receipts, invoices
    static let anthropicAPIKey = "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"
}
