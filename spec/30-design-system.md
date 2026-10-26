# 30 · Design system (v1)

Source of truth: Draft design system **Vitalis** v1 (canvas `kqPE9w5k-9`, style guide "vitalis-rules"), approved by the owner on 26 Oct 2026. It formalises the 2e look: black ground, #161616 cards, condensed caps headlines, wide numbers. Code: `apple/VitalisKit/Sources/VitalisUI/DesignSystem.swift` and `Components/`. `VitalisTests/DesignSystemLintTests` fails when a screen uses a literal colour or an old type helper.

This replaces the earlier "Vital line" poster spec.

## Layout
- Screen gutter 16 (`VSpace.edge`) for headlines, section labels, cards and lists.
- Spacing steps 4 / 8 / 12 / 16 / 24 / 32 / 48 (`VSpace.s1…s7`). Cards 12 apart, sections 24, a section label 8 above its card.
- Radii: controls 8, buttons and inner panels 12, cards and sheets 16.

## Colour
| Role | Hex | Use |
|---|---|---|
| ground | #000000 | Screen |
| surface | #161616 | Cards, lists, segments |
| surface-2 | #1E1E1E | Inside a card: fields, panels, secondary buttons |
| line | #262626 | Dividers |
| track | #2A2A2A | Empty part of a bar |
| grid | #1C1C1C | Chart grid |
| range | #333333 | Usual or aim range behind a bar or chart |
| text / text-2 / text-3 | #F2EEE6 / #A8A8A8 / #6E6E6E | Primary, secondary, axes and hints |
| accent | #FF4538 | One primary action, now, heart rate, muscle load |
| good / watch | #6FCF97 / #E9B949 | Status dots only |
| sleep (deep, REM) | #6F8FC2 (#5D63A8, #8DBFCB) | Sleep tab |
| body | #A78BFA | Body tab |
| eat | #FF8A3D | Eat tab |
| heat 0/2/3/4 | #363636 / #8F352E / #C63E34 / #FF4538 | Muscle load |

## Type (Archivo at 62 / 100 / 125 width; Azeret Mono for labels and axes)
| Style | Spec | Use |
|---|---|---|
| display | 62%, 800, 32/34, caps | Tab headline |
| numXL / numL / numM / numS | 125%, 300/400/400/500, 56/40/28/20 | Numbers, tabular |
| title | 600, 17 | Pushed-screen titles |
| headline | 600, 15 | Card and row titles |
| body | 400, 15 | Sentences |
| secondary | 400, 13, text-2 | Second lines, captions |
| unit | 500, 13, text-2 | Unit beside a number, sentence case |
| label | Mono 600, 11, caps .12em | Section labels only |
| axis | Mono 500, 10, text-3 | Chart axes only |

## Components
VHeader (settings inside, freshness line), FreshnessLine, VCard + CardHeader + StatusWord, Figure, Meter (8 high, target tick drawn over it), ReadoutRow, ListCard + ListRow, ComparisonBar (4 high, 84 name lane, 24 count lane), SectionLabel, PillPicker, PeriodStepper, chart frame (3 grid lines, right y lane, x labels 8 below, usual range as a band, one callout), PrimaryButton (52, radius 12, tab colour), SecondaryButton, PillButton, saved-meal chip, TabBar.

## Behaviour
- Every tab: pull to refresh, reload on returning to the foreground and after a sync, freshness line in the header ("Updated 2 min ago", "Updating…", amber after 6 h).
- Live workout: Live Activity in the Dynamic Island (compact, minimal, expanded) and on the lock screen.
