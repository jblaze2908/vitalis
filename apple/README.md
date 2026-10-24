# Vitalis Apple companion — phase 1

Swift 6, iOS 18.0 and watchOS 11.0, generated with XcodeGen. No third-party app or package dependencies. The iPhone exports raw HealthKit samples, deletions and Apple's merged daily statistics to the contract in `../docs/native-sync.md`. The watch app is an embedded, single-target SwiftUI placeholder.

This implementation was written on Linux without Swift or Xcode. Swift syntax, YAML and plist checks have been performed; **the apps and XCTest suite have not been compiled or run**. The first Mac build is the next validation step.

## Mac setup

Install Xcode 26 and its iOS/watchOS simulator runtimes. Open Xcode once, accept its license, select it as the active developer directory, and sign into your Apple Account under Xcode Settings → Accounts.

From the repository root:

```sh
brew install xcodegen
cp apple/Config/Signing.example.xcconfig apple/Config/Signing.xcconfig
```

Edit the ignored `Signing.xcconfig`: set `DEVELOPMENT_TEAM` to your team ID and `BUNDLE_PREFIX` to a unique reverse-DNS prefix. Both targets inherit these values; their bundle IDs are `$(BUNDLE_PREFIX).vitalis` and `$(BUNDLE_PREFIX).vitalis.watchkitapp`.

```sh
cd apple && xcodegen && open Vitalis.xcodeproj
```

Use XcodeGen 2.46.0 or newer. Generated projects, signing values, user data and DerivedData are ignored. The watch dependency explicitly copies into `PlugIns` for Xcode 26's modern watch application/Foundation extension layout; see [XcodeGen's reported embedding issue](https://github.com/yonaskolb/XcodeGen/issues/1613). No generated project edits should be necessary.

## Build and test on a Mac

Run these commands from `apple/` after generating the project. Both simulator builds disable code signing:

```sh
xcodebuild -project Vitalis.xcodeproj -scheme Vitalis -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build

xcodebuild -project Vitalis.xcodeproj -scheme VitalisWatch -configuration Debug \
  -sdk watchsimulator -destination 'generic/platform=watchOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build

xcrun simctl list devices available
```

Choose an installed iPhone simulator's UDID from the last command (iOS 18 or later), substitute it below, and run the tests:

```sh
IOS_SIMULATOR_UDID='REPLACE_WITH_SIMULATOR_UDID'
xcodebuild -project Vitalis.xcodeproj -scheme Vitalis -configuration Debug \
  -destination "platform=iOS Simulator,id=$IOS_SIMULATOR_UDID" \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test
```

The tests cover golden wire shapes for quantity/sleep/workout/deletion/daily-stat payloads, registered-unit compatibility, timestamp offsets, the IEEE CRC-32 vector, gzip decoding with independent system zlib, batching, durable retry IDs/cursors, rejected objects and anchor commits. The hosted test process suppresses app launch sync/observer registration; individual tests construct their own samples and storage. HealthKit background behavior and real history still require a physical phone.

## Device build and install

Connect and trust an iPhone, enable Developer Mode, and choose its UDID in Xcode's destinations. `-showdestinations` lists the identifiers accepted by `xcodebuild`; `devicectl` lists connected devices.

```sh
xcodebuild -project Vitalis.xcodeproj -scheme Vitalis -showdestinations
xcrun devicectl list devices
DEVICE_UDID='REPLACE_WITH_IPHONE_UDID'

xcodebuild -project Vitalis.xcodeproj -scheme Vitalis -configuration Debug \
  -destination "platform=iOS,id=$DEVICE_UDID" -derivedDataPath DerivedData \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build

xcrun devicectl device install app --device "$DEVICE_UDID" \
  DerivedData/Build/Products/Debug-iphoneos/Vitalis.app
```

Open the installed app on the phone. To build the watch target directly for a paired watch, use its UDID:

```sh
WATCH_UDID='REPLACE_WITH_WATCH_UDID'
xcodebuild -project Vitalis.xcodeproj -scheme VitalisWatch -configuration Debug \
  -destination "platform=watchOS,id=$WATCH_UDID" -derivedDataPath DerivedData \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
```

Install the embedded watch app through the iPhone Watch app/Xcode's paired-watch destination. Its only screen says “Workouts coming soon”. It does not request permission or write workouts yet.

Personal Team profiles expire after **7 days**; rebuild and reinstall to renew. Apple currently allows three installed development apps per device with a Personal Team: delete old sideloaded apps if you exceed the cap. Provisioning, HealthKit entitlements and background delivery must be checked with the actual signature. The Sync screen shows immediate/hourly registration success or failure, including the error text; foreground manual export can still be tested if background delivery fails. See [Apple's Personal Team limits](https://developer.apple.com/help/account/basics/about-your-developer-account).

## Connect and export

1. In Settings, enter the base URL of your Vitalis server and its write token. Use HTTPS for a remote server. Local HTTP hosts are permitted by the local-network ATS exception; accept the local-network prompt when applicable.
2. Save settings, then tap **Test connection**. The app makes `GET /v2/sync/status` and displays its JSON, without assuming an undocumented response shape. Redirects are rejected; configure the final server URL.
3. On Sync, tap **Allow Health access** and enable the read types you want to export. Correlations are authorized through their member quantities. No write access is requested on iPhone. HealthKit deliberately hides read denials, so a successful permission dialog does not mean every type was granted.
4. Tap **Sync now**, leave the app foregrounded for the initial backfill, and inspect batches and per-type background delivery. The first query for each type has a nil anchor; 5,000-object pages continue until a short page. Repeated syncs resume from the persisted anchors. Completing the Health permission sheet explicitly queues a fresh history pass, preserving local history; this covers newly allowed historical samples because HealthKit does not disclose which read grants changed.

The token is stored only in Keychain as a generic password with `AfterFirstUnlockThisDeviceOnly` accessibility. It is not written to defaults, logs, source or the export journal. The settings form necessarily holds the token in memory while editing it.

To change servers, finish the active sync, use **Reset local export state**, save the new URL/token, then sync again. The reset removes local anchors, pending envelopes and history and starts a full backfill; it does not delete server rows or the token. Without a reset, the exporter refuses to apply the old server's anchors to a new server. A replayed UUID replaces the existing server row.

## Persistence and lifecycle

One `SyncEngine` actor serializes all pipelines. UI state is main-actor isolated; network payloads are Sendable values. HealthKit callback accumulation is locked behind a small continuation bridge with cancellation support. Observer and BGTask callback transfer boxes are the other explicit unchecked Sendable boundaries.

Anchors are securely archived under Application Support/Vitalis. History and staged envelopes are JSON there, with `completeUntilFirstUserAuthentication` file protection and backup exclusion. The install ID and server URL are ordinary defaults; only the token uses Keychain. When protected data is unavailable, sync is skipped with a visible error. A locked launch keeps this reason in memory and records it in history when protected storage becomes writable.

A page is serialized into capped on-disk envelopes before uploading. A pending-page manifest retains its new anchor and original batch IDs. After each HTTP 200, receipt history and then the upload cursor are saved. Crashes between receipt and cursor writes re-send the same idempotency ID. After all envelopes succeed, the anchor is written and the journal is removed. Earlier successful envelopes, including their rejected objects, are skipped on ordinary retry. On transport/protocol/storage failures the worker stops; type-specific HealthKit failures leave that type's anchor intact and allow other types to proceed. The next trigger retries it.

Each envelope has at most 5,000 objects (daily stats included) and 200,000 series/route/heartbeat/ECG points. A page retains only its base HKSample objects and one serialized envelope in memory; large series are not all accumulated across a page. Bodies use Apple's raw DEFLATE implementation with a gzip header and IEEE CRC-32/ISIZE trailer. Each request has a 60-second timeout. Rejections are shown in the last 20 batches and do not prevent anchor advancement after HTTP 200.

Observer queries are registered during launch. Immediate delivery is requested first and hourly is attempted on failure. Quantity-member notifications also enqueue their correlation pipeline. Each observer's completion is called after its requested pipelines finish, including failure and expiration paths. A BGProcessingTask is registered at launch and rescheduled for catch-up; iOS chooses the actual run time. Expiration cancels active HealthKit queries/network requests and retains unfinished anchors. A foreground launch, protected-data availability and the manual button also trigger catch-up.

## Contract decisions and open ambiguities

- **One sample exceeding 200,000 points:** the contract replaces a route/ECG/series row by UUID and has no append/chunk protocol. Splitting the sample would overwrite its own earlier points. This implementation reports the oversized sample, retains that type's anchor and never truncates. A lossless chunking protocol or explicit oversized-single-object exception is needed to export such a type past that page.
- **Route linkage when workouts are unreadable:** no general `HKQuery.predicateForObjectsAssociated(with:)` reverse-workout API exists in the documented iOS 18 surface. The code queries overlapping workouts and uses the documented `predicateForObjects(from: workout)` plus the route UUID to prove the association. With no readable association, it sends `workout_uuid: null` and logs the condition while preserving all route points. The contract does not specify nullability for this case.
- **Untyped enum fields:** workout event `type`, ECG classification/symptoms and state-of-mind kind are sent as raw integers. Workout names cover every documented iOS 18 activity enum; future unknowns get `unknown_<rawValue>`. The contract gives examples but does not define these enum encodings or the `source.os_version` shape; OS version is `major.minor.patch`.
- **Duplicate receipts after a crash:** the client expects the documented receipt shape even for `duplicate: true`. To recover rejection details when a crash occurred before local receipt persistence, the server should return the original counts/rejections for the idempotent batch; the contract does not explicitly guarantee that detail.
- **`GET /v2/sync/status`:** the response is described without an exact JSON schema. The connection test displays arbitrary JSON; the regular Sync screen uses the local persisted history.
- **Deletion-only daily statistics:** HKDeletedObject supplies no original time range. The contract asks for days touched by samples but does not specify how deletion-only pages invalidate old merged days. Current daily-stat refresh covers upsert sample intervals; raw deletion tombstones are always sent. A future date index or server-driven daily-stat refresh contract is needed to recompute historical days touched only by deletions.
- **Local day boundaries:** sample intervals are treated as touching both start and end calendar days, even if the end is exactly midnight. Statistics use Apple's default source-priority merge, a local-midnight anchor and one-calendar-day intervals; daily-stat fields with no value are explicit nulls. Percentages use HealthKit's own `%` unit conversion, without manual rescaling.
- **`other` payloads and attachments:** audiograms, glasses/contact prescriptions and GAD-7/PHQ-9 assessments are exported with their structured sample fields under `payload`. The contract gives no detailed schema for these. Attached prescription images/PDFs are not HKSample objects and have no upload/attachment field in this protocol, so they are not transferred. Audiogram fields use the iOS 18.0 sensitivity-point API; the richer test/clamping structures added in 18.1 are outside this SDK baseline.

## Device verification points

There are exactly two `// VERIFY:` sites, both in `Vitalis/HealthReader.swift`:

- `beats(_:)`: confirm heartbeat callback behavior at completion on a real phone. Accumulation uses the declared sample count so a final beat and a separate done sentinel both preserve the expected count.
- `workoutUUID(for:)`: verify exact association matching for replaced routes and partial permissions. Candidate dates only narrow the search; UUID association determines the link.

Both use documented public APIs. The marks cover runtime behavior which cannot be exercised on Linux. First-build compiler errors and any runtime HealthKit entitlement errors should be sent back with the full diagnostic and Xcode/SDK version.

## Deliberately excluded types

- Clinical/FHIR records, verifiable clinical records and CDA medical documents (clinical types were excluded from the brief).
- Characteristics such as date of birth, biological sex, blood type, skin type and wheelchair-use settings: these are not anchored samples and do not have the sample/deletion contract.
- Activity summaries: the protocol requires raw samples and its specific quantity `daily_stats`, rather than activity-ring summary export.
- Medication concepts/dose-event types and category/quantity additions newer than iOS 18.0, including menopausal state, bleeding after menopause, hypertension events and heart-rate-variability RMSSD. The registry intentionally targets the iOS 18.0 SDK surface.
- Write-only types and phase-2 Watch workout recording. No read request includes a correlation directly; its member quantities provide permission instead.

All documented iOS 18.0 readable quantity/category identifiers are explicitly listed by area in `HealthTypes.swift`. Unavailable types are skipped with a diagnostic, and unknown quantity units are selected only after compatibility checks and logged.

## File tree

```text
apple/
├── Config/
│   └── Signing.example.xcconfig
├── Vitalis/
│   ├── AppModel.swift
│   ├── HealthQuery.swift
│   ├── HealthReader.swift
│   ├── HealthSerializer.swift
│   ├── HealthTypes.swift
│   ├── Info.plist
│   ├── SettingsView.swift
│   ├── SyncEngine.swift
│   ├── SyncView.swift
│   ├── Vitalis.entitlements
│   └── VitalisApp.swift
├── VitalisKit/
│   ├── Sources/
│   │   └── VitalisKit/
│   │       ├── APIClient.swift
│   │       ├── Batcher.swift
│   │       ├── Gzip.swift
│   │       ├── Models.swift
│   │       ├── Settings.swift
│   │       ├── SyncHistory.swift
│   │       └── SyncStorage.swift
│   └── Package.swift
├── VitalisTests/
│   ├── AnchorCommitTests.swift
│   ├── BatchingTests.swift
│   ├── GzipTests.swift
│   └── SerializerTests.swift
├── VitalisWatch/
│   ├── Info.plist
│   ├── VitalisWatch.entitlements
│   └── VitalisWatchApp.swift
├── .gitignore
├── README.md
└── project.yml
```
