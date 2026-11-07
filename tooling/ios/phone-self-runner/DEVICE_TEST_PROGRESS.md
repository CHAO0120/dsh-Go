# iPhone development checkpoint — 2026-11-07

Progress checkpoint on `feat/ios-foundation`, based on `75ab577806d8cdbaa948e97b363df0877ff235ea`.
This is an experimental development build, not a completed release validation.

## Changes

- Use the authenticated RPPairing transport without requiring a legacy lockdown heartbeat.
- Resolve custom XCTest archive UID fields and accept iOS 26's contextless activities only after the selected test starts. The app still decrypts a fresh per-run payload and checks its run ID.
- Correlate process termination and process-status replies; do not release the native owner without confirming its exact PID exited.
- Expose the iOS phone-control settings and connect authenticated conversation ownership to task completion, service shutdown and the existing return-to-app preference.
- Allow the last tool result to retire before completion; stop the owned runner when its active call is cancelled.
- Resolve Settings aliases and names from a private, setup-time app inventory. Reject unknown names before activation and check that the target app entered the foreground.
- Wait briefly for DSH Go's foreground transition before stopping the runner on return.
- Disable release LTO for the Apple native library to avoid linking newer Rust LLVM bitcode with an older Xcode linker.

## Validation completed

- iPhone 13, iOS 26.0; Xcode 26.2; Rust 1.99.1; Flutter 3.47.7.
- Native start → encrypted readiness → confirmed exit, twice consecutively in one app process.
- Device installation and signature verification of the main app and XCTest helper.
- Settings entry and return preference visible on the device.
- Settings opened and screen read using its bundle ID. Pinduoduo opened, read and operated using its bundle ID.
- Private app inventory retained in the helper's data container; Pinduoduo's name mapping checked against the installed device inventory.
- 48 Flutter phone channel, ownership, completion, visibility and iOS settings checks passed.
- Changed Dart files: analyzer reported no issues.
- 11 native Rust tests, 1 upstream archive regression test, 8 build-input checks and 7 Swift app-name resolution checks passed.
- Main app and helper rebuilt after the final foreground-wait changes.

## Still pending on the device

- A fresh conversation opening both Settings and Pinduoduo by their Chinese names after the inventory fix. Earlier conversations contain cancelled calls and stale screen identifiers from app updates.
- A complete task automatically returning to the correct conversation with the final foreground-wait implementation. Earlier logs show a return request accepted and runner exit confirmed, but do not prove the app had completed its foreground transition.
- Behavior after device reboot, developer-image remounting, VPN reconnect and development-profile expiration.

## Reproduction and privacy

Use the existing native build and helper setup instructions in [README.md](README.md).
On systems where helper-side app enumeration is unavailable, upload a local app-name inventory with `tooling/ios/install-phone-app-catalog.py` and refresh it after installing new apps.

`DSH_PHONE_SELF_RUNNER_DIAGNOSTICS` enables bounded local startup/task-stage logs.
`DSH_PHONE_PREFLIGHT=1` runs two bootstrap-and-stop checks without issuing phone UI actions.
Normal launches do not run that preflight; actual phone control still requires the in-app user grant.

Pairing records, private keys, signing profiles, developer account details, device identifiers, app inventories, conversations, screenshots, logs, IPAs and build caches are intentionally excluded from this checkpoint.

## Latest branch validation — 2026-11-08

Updated to `edb3bdc128a26b180758c2b431903560c026fa22` and rebuilt the composed runtime, iSH and N-API frameworks with Xcode 26.2.

- Fixed the generated runtime test's temporary-directory handling on macOS: resolve `/var` aliases before passing inherited preload paths to Node. Without this, the exact module-path check disables the Node Worker route and three cases fail. The unchanged production runtime passes all 22 cases with both JIT and jitless after this fixture correction.
- Extended the real iOS Simulator guest smoke from 9 to 13 scenarios. All 15 approval decisions passed, including independent workspace and Linux-root decisions in the same persisted turn. Real iSH rejects a default root write, does not create a file when root permission is rejected, permits an approved one-call write, then rejects another write while preserving the approved contents.
- Passed 74 routing/cancellation/root-grant/suspension checks, 10 POSIX crash-marker cases, the production Swift channel/installer contract with the verified Alpine archive, 6 standalone Dart guest contracts, 48 Flutter phone regressions and full Flutter analysis. The smoke driver's 4 oracle/model checks also passed. These targeted checks do not represent the full repository suite.
- Built, signed, installed and launched version `1.0.12+1` on iPhone 13 / iOS 26.0 without uninstalling the existing app. Local Flutter required Swift Package Manager to be enabled and plugin metadata regenerated before this build.
- The new device phone preflight launched PhoneRunner but timed out waiting for XCTest readiness (`ERR_PHONE_XCTEST_SESSION`). Cleanup confirmed the launched PID exited. A normal app launch succeeded afterwards. The Mac was locked when the computer-control tool tried to inspect device UI; fresh Settings/Pinduoduo and automatic-return checks remain pending. Simulator results do not establish that phone control works on this device.

The runtime fixture still requires a separately installed, OHOS-patched locked DSH prefix via `IOS_GUEST_TEST_PREFIX`, plus generated process dependencies. The simulator smoke uses the production Swift-installed fixed Alpine fixture and an isolated local scripted model; it does not use account credentials or user conversations. Use a fresh installation copy for each smoke run because the approved root-write scenario intentionally persists a synthetic file.
