# R5 — AI model selection and spend controls

| | |
|---|---|
| Phase | 3 — Post-1.0 |
| Severity | Cost |
| Depends on | S1, S4 (input caps and daily limits already in place) |
| Size | S |
| Touches | `backend/index.js` / `routes/proxy/ai.js` |

## Problem

All three Anthropic calls (`/restaurants/search-natural`, `/recipes/extract`,
and `/recipes/recommend`) use `model: "claude-opus-5"`, the largest model
tier, with `max_tokens` up to 16,000. Interpreting a restaurant search query
is a tiny structured-extraction task. A smaller model would likely match
quality at a fraction of the cost and latency.

## Acceptance criteria

- [ ] **Before choosing models, the agent loads the `claude-api` skill** (or
      checks Anthropic's current model documentation) for current model IDs
      and pricing. Don't pick model IDs from memory.
- [ ] Model IDs come from environment variables, with sensible defaults:
      `AI_MODEL_SEARCH` (smallest current model), `AI_MODEL_EXTRACT`
      (mid-tier, vision-capable), and `AI_MODEL_RECOMMEND` (mid-tier). Added
      to `.env.example`.
- [ ] `max_tokens` is right-sized: search ≤ 300, extract ≤ 4,000,
      recommend ≤ 6,000. Check against real output sizes by logging
      `usage.output_tokens` for a few days first, or estimate from the Zod
      schema.
- [ ] Log `usage.input_tokens` and `usage.output_tokens` per call with
      route and user id (no content), so spend can be attributed.
- [ ] Prompt caching isn't worth it here (the prompts are short). Note that
      in a comment so nobody adds it reflexively.
- [ ] Compare quality on 10 real inputs per route with the old and new
      models, and put the comparison table in the PR description.
