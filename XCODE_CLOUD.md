# Xcode Cloud setup — Murmur Studio

Walkthrough for setting up automated test + archive runs on Apple's
hosted CI for this project. Quality Infrastructure Phase 2 of the
plan captured in `ROADMAP.md`.

Xcode Cloud is free for paid Apple Developer Program members up to a
generous compute-hour cap. For this project the day-to-day load is
small — tests run on push, archives run on tags — and we're nowhere
near the cap.

## Prerequisites

Already in place:
- Apple Developer Program enrollment (you enrolled before the v1.0
  submission)
- App Store Connect record for Murmur Studio (App ID `6782092325`)
- Repo at `github.com/kvnlng/Murmur` with `main` as the trunk
- Tests green locally: 191 unit + 7 UI = 198 total at the time of
  writing

You don't need any local CLI or Apple-side credential setup — the
workflow is created in App Store Connect's web UI, and Apple manages
all signing certificates and provisioning profiles automatically.

## Initial workflow

1. **App Store Connect** → My Apps → **Murmur Studio**
2. Top tabs → **Xcode Cloud**
3. **Get Started** (first time) or **Manage Workflows** (subsequent)
4. **Connect repository** → GitHub → grant Apple's GitHub App access
   to `kvnlng/Murmur`. Since the repo is private, this step requires
   accepting the OAuth scope; Apple only needs read access plus
   webhook installation.
5. After the repo connects, Xcode Cloud creates a default workflow.
   Edit it.

## Workflow: test on every push to main

**Name:** `Test on main`

**Start conditions:**
- Branch: **main**
- Start: **Branch changes**
- Files and folders changed: (leave empty — run on every push)

**Environment:**
- Xcode: **Latest Release**
- macOS: **Latest Release** (the test action's matrix below will
  also add older versions)

**Actions:**

1. **Test** action
   - Scheme: `Murmur`
   - Destination: configure the matrix:
     - **macOS, Latest Release** (Tahoe 26 / current)
     - **macOS, Sequoia 15.x** (if available — gives one-version-back coverage)
     - Skip **Sonoma 14.x** unless we lower the deployment target
       (currently `MACOSX_DEPLOYMENT_TARGET = 26.5` in pbxproj, so
       older OSes won't even install the build — confirm in the
       Murmur target's Build Settings before adding older
       destinations)
   - Test plan: the default `Murmur` plan picks up both unit and UI
     suites

**Post-actions:**
- **Notify** → Email on success and failure to `long.kevin@gmail.com`

**Save.**

## Workflow: archive + TestFlight on git tag

**Name:** `Archive on tag`

**Start conditions:**
- Tag: **Any Tag** matching `v*` (we tag releases as `v1.1`, `v1.2`,
  etc. per RELEASE.md)
- Start: **Tag changes**

**Environment:** Latest Release / Latest Release.

**Actions:**

1. **Test** — same as the push workflow, but only on the latest macOS
   (don't burn matrix runs on releases)
2. **Archive** action
   - Scheme: `Murmur`
   - Distribution: **App Store Connect**
   - Deployment preparation: **TestFlight Internal Testing**

**Post-actions:**
- **TestFlight Internal Testing** — distributes to the internal
  tester group you set up earlier
- **Notify** → Email on completion

**Save.**

## What's automatic from here

Once both workflows are saved:

- Every push to `main` triggers the test workflow. You'll get an
  email on first failure (success emails are suppressed by default
  unless you opt in). Test runs ~5–10 minutes per OS-version.
- Every `v*` tag triggers an archive that lands in TestFlight
  automatically. The smoke-test checklist in `RELEASE.md` still
  applies — Xcode Cloud just removes the manual upload step.

## Updating the release process

After Xcode Cloud is wired up, the "Archive + TestFlight upload"
section in `RELEASE.md` simplifies to:

1. Bump version numbers (still manual)
2. `git tag v1.1 && git push --tags`
3. Wait for the Xcode Cloud archive email (~10–15 min)
4. Smoke-test the build in the TestFlight app
5. Promote in App Store Connect when ready

No more Product → Archive → Organizer → Distribute clicks.

## Cost / quota notes

- The paid Developer Program tier (which is what we have) includes 25
  compute hours per month
- A typical Murmur test run takes ~5 minutes; an archive takes ~10
- Expected usage: maybe 2 hours/month at our current cadence. Well
  under the cap.
- If we ever cross the cap, the matrix testing is the first thing to
  trim — drop older OS versions and run only Latest Release

## Custom build steps

One script in place:

- **`ci_scripts/ci_post_clone.sh`** — `brew install swiftlint`. The
  Murmur target has a "Run SwiftLint" Run Script Build Phase that
  shells out to the installed binary. We don't use the SwiftLint SPM
  build-tool plugin because (a) it forces a swift-syntax pin that
  blocks other SPM deps like `swift-snapshot-testing`, and (b) Xcode
  Cloud refuses to run SPM plugins without an explicit trust grant
  that has no UI on hosted runners. Brew sidesteps both.

Additional script hooks (currently unused): `ci_pre_xcodebuild.sh` /
`ci_post_xcodebuild.sh` in the same directory if we ever need them.

`Package.resolved` MUST stay tracked in git — Xcode Cloud disables
automatic SPM resolution, so a missing resolved file fails the build
with "a resolved file is required". The `.gitignore` has an explicit
note about this.

## When something fails

- **Build failure:** Xcode Cloud shows the same build log Xcode does.
  Most failures are SwiftLint or Swift compile errors that would have
  caught us locally — fix locally, push, the next run goes green.
- **Test failure:** Open the workflow run in App Store Connect →
  view the failure → click into the failing test to see assertions
  and the device log. UI test failures sometimes need a re-run
  (flakiness from layout timing); persistent failures are real
  regressions.
- **Signing failure:** Xcode Cloud manages signing automatically, so
  these are usually wrong team selected or expired certificates.
  Check `DEVELOPMENT_TEAM = 7G75BYLCSE` in `project.pbxproj`.
