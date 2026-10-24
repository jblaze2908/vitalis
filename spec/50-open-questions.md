# 50 · Open questions (owner decisions only)

Everything else is decided in this package (user decisions, or design decisions / v1 defaults labelled as such). Each question below has a **recommended default** so no task is blocked: executors build to the default and the owner can change it later.

## Q1. LLM provider and key for Describe

Describe (`POST /v2/food/describe`, [10 §7](10-server-api.md#post-v2fooddescribe--write)) needs an LLM on the server. The owner must provide an API key on the Vitalis host and approve one new npm dependency.

- **Recommended default:** Anthropic Messages API through the official `@anthropic-ai/sdk` package (adds one direct dependency: pin an exact version at least 7 days old, per the 7-day release-age rule, and keep `package-lock.json`), structured output with `client.messages.parse()` + `zodOutputFormat()` (zod is already a dependency), model `claude-opus-5-5` in `VITALIS_DESCRIBE_MODEL` (the current default model per Anthropic's API guidance as of Oct 2026; a cheaper model is the owner's call), key in `ANTHROPIC_API_KEY`. Check `stop_reason` for `refusal` and return 502 `describe_failed`.
- **Until answered:** ship `VITALIS_DESCRIBE=off` (app hides Describe) and `fixture` for tests (task S-18).

## Q2. App Groups on the free Personal Team

Widgets, Watch complications and the shared response cache need an App Group (`group.$(BUNDLE_PREFIX).vitalis`). Whether a free Personal Team can provision App Groups for the app, the Watch app and two widget extensions is untested (decision log → Risks; `apple/briefs/README.md` → Signing caveats).

- **Recommended default:** test it first in task W-03 with a throwaway build. If it fails, ship without widgets and complications (nothing else depends on the App Group; the cache falls back to the app container) and revisit with a paid developer account.

## Q3. Contact e-mail for Open Food Facts

Open Food Facts requires a `User-Agent` with a contact e-mail ([OFF API docs](https://openfoodfacts.github.io/openfoodfacts-server/api/)). It is sent from the server only.

- **Recommended default:** a dedicated address set in `VITALIS_CONTACT_EMAIL` on the host; if unset, the server sends `Vitalis/<version> (self-hosted)` and logs a startup warning. The address is never committed to the repo.

## Q4. Physical Watch registration

Watch builds fail until a physical Watch is registered to the team (`apple/briefs/README.md`). Tasks W-01 and W-02 can be built and tested in the watchOS simulator; device-only checks (double tap, wrist-down rest timing, real heart rate) wait for this.

- **Recommended default:** develop in the simulator; the owner pairs and registers the Watch before W-02 is signed off.

## Q5. Count food logged in other apps

Fuel counts only food logged in Vitalis ([11 §8.2](11-scoring.md#82-calorie-target)). HealthKit `dietary*` samples from other apps (and those Vitalis itself writes) are stored raw but not counted, to avoid double counting.

- **Recommended default:** Vitalis entries only. Changing it later means counting HealthKit dietary energy whose source is not Vitalis, per day, as an extra line in `GET /v2/food/day`.

## Q6. Units

v1 is metric only (kg, km, kcal), matching the existing catalog (`app/src/catalog.ts`).

- **Recommended default:** kg and kcal only. Pounds or kJ would be a display setting in the app plus a `units` target key; no server maths changes.
