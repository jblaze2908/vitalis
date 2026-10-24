# 00 · Design system (Vital line)

Implements: brand board `fDbT_3oo7i` (rules, logo, icon) with the LOCKED values from the decision log, and the shared patterns repeated across every `V · …` frame. Read this before every other brief.

## Where it lives

Add a second library target **`VitalisUI`** to `apple/VitalisKit/Package.swift` (platforms are already iOS 18 / watchOS 11). Both apps depend on it. It holds tokens, fonts, type roles and every component below. Screens live in the app targets.

```swift
// Package.swift (sketch)
products: [.library(name: "VitalisKit", targets: ["VitalisKit"]),
           .library(name: "VitalisUI", targets: ["VitalisUI"])],
targets: [.target(name: "VitalisKit"),
          .target(name: "VitalisUI", resources: [.process("Fonts"), .process("MuscleMap")])]
```

Add `- package: VitalisKit, product: VitalisUI` to both `Vitalis` and `VitalisWatch` dependencies in `project.yml`.

## Colour tokens

LOCKED (decision log, 24 Oct). These beat the brand board's older hexes (#0B0D10, #FF4D3D, #F2EFEA, #868B94, #23272D).

| Token | Hex | Use |
|---|---|---|
| `ground` | `#000000` | Every background |
| `pulse` | `#FF5233` | The line, the one primary action, "now". Nothing else. |
| `bone` | `#F4F1EC` | Numbers, primary text, fresh muscle |
| `steel` | `#8C8C8C` | Labels, secondary text |
| `rule` | `#1E1E1E` | Hairlines, inactive outlines |
| `good` | `#5FD4B0` | Better than usual |
| `watch` | `#F2B33D` | Worse than usual, warnings |

Derived greys, measured from the approved frames (not in the LOCKED list; use only for these roles):

| Token | Hex | Use |
|---|---|---|
| `future` | `#333333` | Dotted future line, secondary button ring, grabber |
| `track` | `#262626` | Progress and range tracks |
| `sheet` | `#0E0E0E` | Bottom-sheet and widget background |
| `toast` | `#121212` | Undo toast, lock-screen widget |
| `barIdle` | `#3A3A3A` | Week bars not today |
| `disabled` | `#555555` | Upcoming set rows, usual-range band, disabled chevron |
| `rawDot` | `#4A4A4A` | Raw weight readings behind the trend |
| `camera` | `#141414` | Scanner backdrop |
| `muscleBase` | `#151515` | Non-muscle body parts in MuscleMap |
| `tickMajor` | `#666666` | Major ticks on the weight ruler |

```swift
public enum VColor {
    public static let ground = Color(hex: 0x000000)
    public static let pulse  = Color(hex: 0xFF5233)
    public static let bone   = Color(hex: 0xF4F1EC)
    public static let steel  = Color(hex: 0x8C8C8C)
    public static let rule   = Color(hex: 0x1E1E1E)
    public static let good   = Color(hex: 0x5FD4B0)
    public static let watch  = Color(hex: 0xF2B33D)
    // derived: future, track, sheet, toast, barIdle, disabled, rawDot, camera, muscleBase
}
```

Text on a `pulse` fill is `ground` (black), never white.

## Fonts

| Family | File (google/fonts) | Axes | Licence |
|---|---|---|---|
| Archivo | `ofl/archivo/Archivo[wdth,wght].ttf` | wdth 62–125, wght 100–900 | SIL OFL 1.1, "Copyright 2020 The Archivo Project Authors (https://github.com/Omnibus-Type/Archivo)" |
| Azeret Mono | `ofl/azeretmono/AzeretMono[wght].ttf` | wght (400, 500 used) | SIL OFL 1.1, "Copyright 2021 The Azeret Project Authors (https://github.com/displaay/azeret)" |

Licence lines verified on 24 Oct 2026 from each family's `OFL.txt` in github.com/google/fonts. Italic files are not needed.

- Put both `.ttf` files and both `OFL.txt` files (renamed `OFL-Archivo.txt`, `OFL-AzeretMono.txt`) in `VitalisUI/Fonts/`. OFL allows bundling in an app; the licence text must ship with the font. Do not rename the font files' internal names.
- Register at launch in both apps (SPM resources are not in the main bundle, so `UIAppFonts` will not find them): `CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)` with URLs from `Bundle.module`. Call once from `VFont.register()` in each `App.init`.
- Verify the family names after registering (`UIFont.fontNames(forFamilyName:)`). The snippet below assumes the family is `"Archivo"` and `"Azeret Mono"`; if not, fix the constants.
- Add an Acknowledgements line in Settings: Archivo and Azeret Mono, SIL Open Font License 1.1.

### Setting variation axes

`Font.custom` cannot set `wdth`. Build a `UIFont` from a descriptor with the variation attribute, scale it with `UIFontMetrics`, then wrap it.

```swift
public enum VFont {
    static let wdth = 0x77647468 // 'wdth'
    static let wght = 0x77676874 // 'wght'

    /// Archivo at an exact width/weight, scaled for Dynamic Type relative to `style`.
    public static func archivo(_ size: CGFloat, width: CGFloat, weight: CGFloat,
                               relativeTo style: UIFont.TextStyle) -> Font {
        let attrs: [UIFontDescriptor.AttributeName: Any] = [
            .family: "Archivo",
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wdth: width, wght: weight]
        ]
        let base = UIFont(descriptor: UIFontDescriptor(fontAttributes: attrs), size: size)
        return Font(UIFontMetrics(forTextStyle: style).scaledFont(for: base) as CTFont)
    }
}
```

`Font(CTFont)` does not re-scale when the user changes text size, so the type-role modifiers below must read `@Environment(\.dynamicTypeSize)` and rebuild the font when it changes. The same code runs on watchOS (UIFont, UIFontDescriptor and UIFontMetrics are available there).

## Type roles

Sizes are pt. Tracking is `size × em`. One `ViewModifier` per role (`.vHeadline(46)`, `.vNumber(92)`, `.vLabel()`, `.vReading()`, `.vBody()`).

| Role | Font | Sizes used in frames | Tracking | Case | Colour |
|---|---|---|---|---|---|
| **Headline** (condensed caps) | Archivo wdth 62, wght 800 | 46 tab title · 44 setup/digest/settings · 56 sheet hero · 36 alert · 30 section · 26–28 block title · 22 sheet title/meal · 20–21 row title | 0 | UPPERCASE | bone |
| **Action** (button label) | Archivo wdth 62, wght 800 | 20 primary · 16–17 small · 19 toast | 0 | UPPERCASE | ground on pulse, bone on secondary |
| **Number** (expanded light) | Archivo wdth 125, wght 200 | 96 · 92 · 88 · 84 · 72 · 64 · 60 · 52 · 48 · 32 · 26–28 · 18–20 | −0.05em at ≥72, else −0.04em | — | bone |
| **Label** (mono) | Azeret Mono 500 | 11 standard · 10 small | 0.12em | UPPERCASE | steel (tints: pulse for NOW, good, watch, bone) |
| **Reading** (mono) | Azeret Mono 400 | 12.5 · 14 for input text | 0.06em (0.04em inputs) | UPPERCASE in rows | key steel, value bone |
| **Body** | Archivo wdth 100, wght 400 | 14–14.5, line height 1.45 | 0 | Sentence | steel |
| **Status time** | Archivo wdth 100, wght 600 | 16 | 0 | — | bone |

Watch roles (pt, frames halved): label 11 (10 summary/face), headline 54 (start hero) · 32 (summary) · 25 (set reps) · 20 (rest next) · 17 (row/button), number 75 (weight) · 70 (rest) · 84 (face time) · 25 (face stats), status time Archivo 600 14.

Headlines use line height 0.92–0.94. SwiftUI cannot set a line height below the font's natural one with `lineSpacing`; render multi-line headlines as a `VStack(spacing: 0)` of one `Text` per line, each with `.frame(height: size * 0.92, alignment: .bottom)`, and check against the frame screenshot.

Dynamic Type relative styles: headline → `.largeTitle`, number → `.largeTitle`, label → `.caption2`, reading → `.footnote`, body → `.body`. Hero numbers stop growing at `.accessibility1`; mono labels may grow without limit.

## Spacing and layout

- Phone side gutter **24**. Status row: 18 top, 30 sides.
- Pulse line sits 14 below the status row, full bleed (390 wide, 40 tall).
- Section: 14–16 top margin, a 1 px `rule` line on top, 12 top padding. Sections are separated by rules, never by cards.
- Reading rows: 7 vertical padding (6 in the digest), 1 px `rule` below, none under the last row.
- List rows: 52 (sessions, exercises), 54–58 (food), 46 (set table), 42 (score parts), 36 (vitals).
- Primary button bottom edge: 17 above the tab bar (bottom 100 from screen bottom with the 83 tab bar); 38 from the bottom on sheets and full-screen flows; 44 on setup.
- Sheets: top at 104 so the pulse line stays visible above them, corner radius 20 (top only), background `sheet`, 1 px `rule` top inset, grabber 36×4 radius 2 `future`, 10 top padding. Dim behind: black 55 %. Half sheets (start choice, log weight) are 486 tall from the bottom.
- Radii: buttons and inputs **12** (continuous). Mini buttons 10. Set-table fields 8. Watch buttons 12 pt (24 px in the @2x frames). No other radii except the sheet's 20.
- No cards, fills, gradients, glows or shadows. The only "surfaces" are sheets, the toast and widgets.

## Components

Every component gets a `#Preview` with fixture data covering each state listed. Put fixtures in `VitalisUI/Previews/Fixtures.swift`.

### PrimaryButton

Height 52 (digest 54), full width inside the gutters, radius 12, fill `pulse`, label Action 20 in `ground`. **At most one per screen** (rule 2). Pressed: opacity 0.8. Disabled: not used; hide the button instead. Optional trailing value (e.g. "640" on the usual-meal button in `BwU_mhJYzc`): label left, value right, 18 horizontal padding. Optional leading icon 20 pt (Start on Watch).

### SecondaryButton

Same shape, no fill, inset stroke 1.5 `future`, bone label. Sizes: 52 full width; 40–44 tall with 16–22 horizontal padding ("+ Log weight", "Remind me", "Finish", "Start"); 36×36 icon square (day back/forward; the disabled direction uses a `rule` ring and `disabled` chevron). **Mini**: 34 tall, radius 10, Label 11 bone (rest −15S / SKIP / +15S).

### MonoLabel

`Text(...).vLabel(.standard | .small, tint: .steel | .pulse | .good | .watch | .bone)`. Always uppercase. Used for every caption, section label, unit and status.

### ReadingRow

```
[KEY (reading, steel)]                [VALUE (reading, bone or tint) ↑/↓]
──────────────────────────────── 1 px rule
```

Props: `key`, `value`, `tint: .none | .good | .watch`, `arrow: .up | .down | nil`, `showsRule`. Arrows are the characters ↑ ↓ in the value's tint. Tint follows the metric's *better* direction (server semantics in `docs/api.md`: HRV higher is better, resting HR lower is better), not the arrow direction: resting HR 57 ↑ is `watch`.

### TabBar (custom)

Replaces the system `TabView` chrome (use `TabView` with `.toolbar(.hidden, for: .tabBar)` or a plain switch; either is fine).

- Height 83 including the home-indicator area, top 1 px `rule`, background `ground`.
- Five equal columns: TODAY · SLEEP · BODY · TRAIN · EAT. Labels only, no icons. Label 10 mono 500, 0.12em, uppercase, 16 from the top edge.
- Inactive `steel`, active `bone` plus a **22×2 `pulse` bar** centred on the column, sitting on the top edge (16 above the label).
- The 10 pt labels are under the 11 pt floor the design checker flags. Keep 10 at default size but let them scale with Dynamic Type; never clip.
- Hidden during full-screen flows (live workout, scanner, setup).

### PulseLine

The signature. One per screen, at the top, below the status row (rule 1).

Geometry (phone, 390×40): baseline y = 12. Past is a solid `pulse` stroke from x = 0 to the now point, width 2.6, round caps and joins. Each event is a symmetric V: (x−16, 12) → (x, 34) → (x+16, 12). Now is a filled `pulse` circle r 4.5 on the baseline. Future is a dashed `future` stroke width 2, dash [2, 6], from now to the trailing edge. A screen with nothing to come (digest at wake) still draws the dotted tail.

| Variant | Stroke | Dip half-width / depth | Now dot r | Future dash |
|---|---|---|---|---|
| phone | 2.6 | 16 / 22 | 4.5 | 2 pt, [2, 6] |
| watch | 1.5 | 7 / 8 | 2.5 | 1.5 pt, [1.5, 4.5] |
| widget (small) | 2.2 | 9 / 10 | 3.5 | 1.6 pt, [2, 5] |
| progress (setup/backfill) | 2.6 | 16 / 26 | 4.5 | 2 pt, [2, 6] |

```swift
public struct PulseLine: View {
    public var events: [Double]   // 0...1 positions along the width
    public var now: Double        // 0...1
    public var style: Style       // .phone, .watch, .widget, .progress
}
```

Draw with `Canvas` (or a `Shape` for past + one for future). Events after `now` are not drawn.

- **TBD (time → x):** the frames are not on one linear clock (Home puts 09:41 at 64 %, the digest puts 07:05 at 18 %). Decide the window (proposal: wake time → planned bedtime) before wiring real times.
- **TBD (which events dip):** the brand rule says "a beat, a set, a meal, now". Decide the event list per screen (proposal: wake, weigh-in, meals, workout on Today; one dip per logged set on the Watch set entry). On setup screens the now-dot marks the step, and the dip marks the previous step.
- Accessibility: hidden (`accessibilityHidden(true)`); screens state time and sync status in text already.

### MuscleMap

Front + back anatomical figure. Path data: [`assets/muscle-map-paths.json`](assets/muscle-map-paths.json), extracted from the Draft component `vt-muscle-map`.

**Attribution (required).** The paths derive from **react-native-body-highlighter** by ELABBASSI Hicham (github.com/HichamELBSI/react-native-body-highlighter), **MIT License, Copyright (c) 2022 ELABBASSI Hicham** (licence and copyright line verified 24 Oct 2026). Keep the MIT notice: put the full MIT licence text with that copyright line in a header comment of the generated Swift file and in `VitalisUI/MuscleMap/LICENSE-react-native-body-highlighter.txt`, and add it to Settings → Acknowledgements.

JSON shape: `viewBox` `[20, 150, 1408, 1215]`; `base`: 12 path strings (head, hands, feet, knees and other non-muscle parts); `muscles`: 17 path strings keyed by slug. Slugs match the server's `MUSCLES` list (`app/src/exercises.ts`) one to one, except the server writes `lower back` / `middle back` with a space where the JSON uses `lower-back` / `middle-back`.

**Convert to SwiftUI `Path`s** with a one-off generator (`apple/scripts/gen-muscle-map.py`, run by hand, output committed as `VitalisUI/MuscleMap/MuscleMapPaths.swift`). The data uses only absolute `M L C Q A Z` commands with implicit repeats. `A` has no `Path` equivalent: convert every arc to cubic Béziers in the generator (standard endpoint → centre parameterisation). Of 176 arcs, 147 have r = 1 and 26 have r = 2 (corner rounding), one r = 3, one r = 183 and one r = 910 (near-straight). Add a unit test that the generated paths' bounding boxes fall inside the viewBox and that all 17 muscles are present.

Rendering:
- `view: .front | .back | .both`. The figure pair spans the viewBox; front is x 20…724, back is x 724…1428 (from the component CSS: single views render the SVG at 200 % width, shifted −100 % for back). Aspect: both 1408 : 1215, single 704 : 1215. Size by width.
- Base paths fill `muscleBase`, muscles fill by heat, all stroked with `ground` at **3 viewBox units** (4 on the Watch summary). Scale the stroke with the figure; never below 0.5 pt.
- Heat levels:

| Level | Hex | Meaning (Train legend in `d68BO9oR4S`) |
|---|---|---|
| 0 | `#222222` | Not trained / no data |
| 1 | `#F4F1EC` | Fresh |
| 2 | `#8C8C8C` | Recovering |
| 3 | `#FF7A5E` | Partly loaded |
| 4 | `#FF5233` | Loaded |

- API: `MuscleMap(heat: [Muscle: Int], view: .both)` with `enum Muscle: String, CaseIterable` (17 cases, raw values = JSON slugs).
- Sizes in frames (width, both views): Home 130, Train 220, session detail 230, empty Train 250, Welcome 290, Watch summary 145 pt.
- **TBD (heat rule):** days-since-trained → heat thresholds are not defined anywhere, and the server's `daysSinceTrained` covers only its 11 `MAJOR_MUSCLES` (no abductors, adductors, forearms, lower back, neck, traps). Decide thresholds and how the six minor muscles get a value. The Watch summary uses heat for *this session's* load instead; that mapping is in 02.
- Accessibility: one element, label built from the heat ("Fresh: quadriceps, hamstrings, glutes, calves. Loaded: chest.").

### Other shared pieces

- **StatusRow**: time (status time role) left, MonoLabel right with sync freshness (`SYNCED 09:39`, `LAST SYNC WED` in `watch`, `SYNC PAUSED`, `WORKOUT · LIVE`, `STEP 1 OF 4`). On iOS the system status bar already shows time: render only the right-hand label, aligned to the status bar, and drop the drawn time.
- **ScreenHeader**: MonoLabel context line, then Headline 46, optional trailing SecondaryButton aligned to the headline's bottom.
- **ProgressTrack**: 2 pt `track`, fill `bone` (or `watch` when flagged).
- **RangeBar** (vitals): 92 wide, 2 pt `track` line, 4 pt `disabled` band for the usual range, 8 pt dot `bone` (tinted `good`/`watch` when outside).
- **WeekBars**: 7 columns 28 wide, 6 pt bars `barIdle`, today `bone`, mono 10 day letters under, value labels above.
- **Toast**: see 03 (Eat, Undo).

## The five rules (brand board `fDbT_3oo7i`)

1. **One line per screen.** It runs flat; a dip only means an event: a beat, a set, a meal, now.
2. **Red is rationed.** Only the line, the single primary action and "now". Screens may have no red action (Sleep, Body, Session detail have none).
3. **No fills, no gradients, no glow.** Lines and type on black. Cards only when grouping truly helps (in practice: sheets, the toast and widgets).
4. **Big numbers, quiet words.** Numbers light and large; labels small mono; sentences short.
5. **The body is bone and red.** Fresh muscle is bone, loaded muscle is red.

Known exception in an approved frame: the digest's second headline line ("Ready to push.") is set in `pulse`. Build it as drawn.

## Platform rules

- **Dark only.** `UIUserInterfaceStyle = Dark` in both Info.plists and `.preferredColorScheme(.dark)` at the root. No light variants.
- **Logo and icon**: the V is one heartbeat (flat line, one symmetric dip, back up) followed by "italis" in Archivo wdth 112, wght 600, tracking −3/92 em. App icon: the dip mark in `pulse` on black (default), black on `pulse` (alt), iOS tinted variant from the same mark. Export the mark as a vector PDF asset.
- **VoiceOver**: every number is read with its label and unit ("Recovery 78, ready"). Group label + value pairs with `.accessibilityElement(children: .combine)`. Colour never carries meaning alone: arrows and words ("READY", "18 MIN LATE") already do.
- **Dynamic Type**: test at `.xxxLarge` and `.accessibility2`. Layouts must reflow (rows wrap, grids stack), not truncate numbers.
- **Haptics**: Watch Crown detents (02), set logged, Undo shown. No haptics on plain navigation.
- **Previews required** for every component and every screen state named in briefs 01–03, using fixtures only (no HealthKit, no network in previews).

## Acceptance checklist

- [ ] `VitalisUI` builds for iOS and watchOS; both apps link it.
- [ ] Both fonts register on iOS and watchOS; a preview shows Archivo at wdth 62/800, wdth 125/200 and Azeret Mono 400/500 visibly different.
- [ ] OFL texts and the MIT licence are bundled; Settings → Acknowledgements lists all three.
- [ ] No hex literal, font name or point size outside `VitalisUI` (grep the app targets).
- [ ] PulseLine previews: phone at now = 0.18 with one past dip, now = 0.64 with two; watch with three set dips; widget; progress at each setup step. Matches `PwXZkuGWcu`, `kh6EtZFCP9`, `pCSw4PpAhl` side by side.
- [ ] MuscleMap renders all 17 muscles, each heat level, front/back/both, at 130 and 290 pt, with no gaps between seams. Matches `PwXZkuGWcu` and `d68BO9oR4S`.
- [ ] TabBar matches `PwXZkuGWcu`: 83 tall, five mono labels, 22×2 red bar over the active tab.
- [ ] Primary and secondary buttons match the frames at 52 and 40 heights; pressed state visible.
- [ ] Previews pass at Dynamic Type `.xxxLarge` and `.accessibility2` without truncated numbers.
- [ ] Nothing light-mode: forcing light appearance changes nothing.
