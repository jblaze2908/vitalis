# 00 · Design system (Vital line) — moved

The design system now lives in **[spec/30-design-system.md](../../spec/30-design-system.md)**: tokens (LOCKED hexes), fonts and licences, type roles, spacing, components (PrimaryButton, SecondaryButton, MonoLabel, ReadingRow, TabBar, PulseLine, MuscleMap, StatusRow, ScreenHeader, ProgressTrack, RangeBar, WeekBars, Toast), the five brand rules, platform rules and the acceptance checklist.

It is a consolidated copy of the former contents of this file with the open items resolved:

- PulseLine time → x and which events dip: server-driven (`pulse` in `GET /v2/today` / `GET /v2/digest`).
- MuscleMap heat: server values 0–4 for all 17 muscles (`training.heat`, session `heat`); the only client-side lighting is catalog lighting on the Watch handoff and the offline Watch summary.
- Toast auto-dismiss: 5 s.

The muscle-map path data stays here: [assets/muscle-map-paths.json](assets/muscle-map-paths.json) (MIT, attribution in spec/30 → MuscleMap). Brand board and locked reference: `spec/design/00-brand-board.png`, `spec/design/01-locked-identity-reference.png`.
