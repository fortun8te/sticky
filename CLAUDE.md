# Sticky

Read **[AGENTS.md](AGENTS.md)** first — it is the contract, and it wins over
everything else in this repo.

- **[PLAN.md](PLAN.md)** — the reasoning, the research, the phase gates.
- **[AUDIT.md](AUDIT.md)** — what the previous build was and why it's being replaced.
- **[docs/TASKS.md](docs/TASKS.md)** — the work queue. One card, one agent, one gate.
- **[docs/PROTOCOL.md](docs/PROTOCOL.md)** — the wire format. Both platforms implement it.
- **[docs/ICONS.md](docs/ICONS.md)** — every icon, verified.

```bash
scripts/lint.sh                 # before every commit — CI runs it on push
scripts/symcheck.swift          # after adding any SF Symbol
swift build && swift test       # mac
dotnet build && dotnet test     # windows
scripts/roundtrip.sh            # phase 3 gate — real two-machine transfer
```

Three things that are non-negotiable and easy to break by accident:

1. **No keyboard capture, no Accessibility, ever.** The previous build did all
   three. `scripts/lint.sh` fails the build if any of it returns.
2. **Notch geometry is measured, never hardcoded.** The notch is 185.0 × 32.0 pt
   and sits 0.5 pt *left* of screen centre — deriving x from `frame.midX` costs a
   visible pixel. AGENTS.md §3.
3. **The notch shows the current transfer and nothing else.** The previous build
   died of becoming a dashboard. AGENTS.md §2.
