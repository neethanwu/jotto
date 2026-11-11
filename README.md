# Jotto

Turn your Apple Watch into an always-ready recorder. Clean transcripts on your phone; you decide what happens next. Everything runs on the iPhone; there is no server.

| Path | What |
|------|------|
| `apple/` | iOS + watchOS app (XcodeGen: `cd apple && xcodegen generate`) |
| `docs/` | Scope, decisions, spike notes |
| `brand/` | Logo, app icons, favicons, colour tokens, illustrations ([`brand/README.md`](brand/README.md)) |

Start with [`docs/06-open-source-plan.md`](docs/06-open-source-plan.md). The beta's server (Bun + Hono on Railway) was retired on 2026-11-11; its code is in git history before that date.
