import Foundation

/// Best-effort USD cost estimate for OpenAI-compat providers (and friends) so
/// the post-turn token summary on `ask` and `repl` shows dollars, not just
/// tokens. Pricing is hand-maintained and inevitably stale — when a vendor
/// changes their rates we update this table. Unknown providers/models return
/// nil and the caller prints tokens-only.
///
/// Rates are USD per 1M tokens, (input, output). Multiple models per provider
/// match by substring; the first hit wins, so list specific entries above
/// generic ones.
enum CostEstimator {
    static func estimate(provider: String, model: String?, inputTokens: Int, outputTokens: Int) -> Double? {
        guard let rate = rateFor(provider: provider, model: model ?? "") else { return nil }
        let input  = Double(inputTokens)  / 1_000_000 * rate.input
        let output = Double(outputTokens) / 1_000_000 * rate.output
        return input + output
    }

    /// Formats `dollars` for the post-turn line. Tiny numbers print as `<$0.001`
    /// instead of `$0.0003` so users see a recognisable shape.
    static func format(_ dollars: Double) -> String {
        if dollars < 0.001 { return "<$0.001" }
        if dollars < 1     { return String(format: "$%.3f", dollars) }
        return String(format: "$%.2f", dollars)
    }

    private struct Rate { let input: Double; let output: Double }

    /// ISO date the rate table below was last verified against vendor pricing
    /// pages. `lingcode doctor` warns if this is more than 90 days old, so we
    /// have a forcing function to keep it fresh. Bump on each update.
    static let rateTableUpdated = "2026-04-30"

    /// Per-provider, per-model rate table. Updated 2026-04-30. Add a row when a
    /// vendor publishes a new model. Keep entries sorted from specific to broad.
    private static let table: [(provider: String, modelMatch: String, rate: Rate)] = [
        // — openai
        ("openai", "gpt-5",       .init(input: 3.00,  output: 15.00)),
        ("openai", "o1",          .init(input: 15.00, output: 60.00)),
        ("openai", "gpt-4o-mini", .init(input: 0.15,  output: 0.60)),
        ("openai", "gpt-4o",      .init(input: 2.50,  output: 10.00)),
        ("openai", "",            .init(input: 2.50,  output: 10.00)), // generic fallback
        // — gemini (substring match; specific before broad)
        ("gemini", "3.1-flash-lite", .init(input: 0.10,  output: 0.40)),
        ("gemini", "3.1-pro",        .init(input: 2.00,  output: 12.00)),
        ("gemini", "3-flash",        .init(input: 0.50,  output: 3.00)),
        ("gemini", "2.5-pro",        .init(input: 3.50,  output: 10.50)),
        ("gemini", "2.5-flash",      .init(input: 0.30,  output: 2.50)),
        ("gemini", "",               .init(input: 0.30,  output: 2.50)),
        // — kimi (moonshot)
        ("kimi",   "k2",          .init(input: 0.50,  output: 1.50)),
        ("kimi",   "",            .init(input: 0.50,  output: 1.50)),
        // — qwen (dashscope)
        ("qwen",   "max",         .init(input: 1.20,  output: 4.80)),
        ("qwen",   "plus",        .init(input: 0.40,  output: 1.20)),
        ("qwen",   "",            .init(input: 0.20,  output: 0.60)),
        // — mistral
        ("mistral", "large",      .init(input: 2.00,  output: 6.00)),
        ("mistral", "small",      .init(input: 0.20,  output: 0.60)),
        ("mistral", "",           .init(input: 0.40,  output: 1.20)),
        // — xai
        ("xai",    "grok-4",      .init(input: 5.00,  output: 15.00)),
        ("xai",    "",            .init(input: 5.00,  output: 15.00)),
        // — groq (token pricing varies wildly by model; conservative)
        ("groq",   "llama-3",     .init(input: 0.59,  output: 0.79)),
        ("groq",   "",            .init(input: 0.20,  output: 0.40)),
        // — together
        ("together", "",          .init(input: 0.60,  output: 0.60)),
        // — fireworks
        ("fireworks", "",         .init(input: 0.90,  output: 0.90)),
        // — deepseek-compat (mirrors deepseek pricing)
        ("deepseek-compat", "v4-pro",   .init(input: 0.27,  output: 1.10)),
        ("deepseek-compat", "v4-flash", .init(input: 0.07,  output: 1.10)),
        ("deepseek-compat", "",         .init(input: 0.07,  output: 1.10)),
        // — ollama runs locally — zero monetary cost.
        ("ollama", "",            .init(input: 0.0,   output: 0.0)),
        // — openrouter passes through; we can't know without per-model pricing,
        //   so leave it unrated (caller falls back to tokens-only).
    ]

    private static func rateFor(provider: String, model: String) -> Rate? {
        let p = provider.lowercased()
        let m = model.lowercased()
        for entry in table where entry.provider == p {
            if entry.modelMatch.isEmpty || m.contains(entry.modelMatch) {
                return entry.rate
            }
        }
        return nil
    }
}
