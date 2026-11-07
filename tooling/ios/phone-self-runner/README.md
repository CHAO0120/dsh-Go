# Optional on-device XCTest owner

This is an **opt-in experiment**, not a replacement for the default Mac-started
PhoneRunner. The native library connects to this device's developer services and
starts an already installed, signed PhoneRunner xctrunner. Screen elements,
clicks, scrolling and typing still use the existing XCTest tools; there is no
image-only/CoreDevice HID fallback here.

## Build and verification

Install rustup. The local [toolchain file](rust-toolchain.toml) pins Rust 1.99.1.
No Rust tools or network downloads are needed by a normal, non-opted-in app build.

Portable checks (Rust, a C compiler, Python 3 and Git required):

```sh
bash tooling/ios/build-phone-self-runner.sh --check
```

This verifies the upstream archive, applies the local patch, runs the Rust tests,
builds the actual static library, links/runs a C ABI smoke executable, and runs
preparation/attribution tests. It does **not** run XCTest, iOS code or an iPhone.

On a Mac with Xcode selected:

```sh
bash tooling/ios/build-phone-self-runner.sh
```

The script builds device arm64 plus simulator arm64/x86_64 libraries under the
ignored `app/ios/PhoneSelfRunnerNative/` directory and publishes
`PhoneSelfRunner.xcconfig` **last**. The generated config sets
`DSH_PHONE_SELF_RUNNER_ENABLED = YES`, adds the Swift compilation condition and
selects the library by platform/architecture. Removing that generated config
before rebuilding disables the optional path again; a normal checkout contains
only the output directory's gitignore.

The script also emits `LICENSE.idevice.txt`, `SOURCE.json`, and
`THIRD_PARTY_CRATES.json` for the app's optional resource phase. The latter is a
sanitized inventory of the actual locked Cargo metadata, not a complete license
audit. Transitive license texts, notices and distribution obligations still need
release review; this experiment does not claim that work is complete.

The Mac cross-build, XCTest signing, installation, real device launch, encrypted
activity delivery and process-exit confirmation have **not** been verified from
the Linux development environment. Follow the overall setup guide in
[phone-self-runner.md](../phone-self-runner.md) before trying a device.

## Required device state

- iOS 17 or newer, Developer Mode enabled and device unlocked.
- LocalDevVPN (or an equivalent supported self-loopback route) enabled.
- A valid **remote pairing** plist imported by the user. This is idevice's
  `RpPairingFile`: `public_key` and `private_key` are 32-byte data fields,
  `identifier` is a string, and `alt_irk` is optional. A traditional lockdown
  HostID/HostCertificate pairing plist is not interchangeable.
- A compatible developer disk image **already mounted**. This version checks for
  `com.apple.dt.testmanagerd.remote` and `com.apple.instruments.dtservicehub` and
  returns `ERR_PHONE_DDI_REQUIRED` if unavailable. It does not download, personalize
  or mount a DDI; do not promise permanent Mac independence after a reboot.
- The matching signed PhoneRunner xctrunner and target app already installed.

The fixed upstream CLI defines the compatible creation command in
[tools/src/rppairing.rs](https://github.com/jkcoxson/idevice/blob/3854a5df4a5a6dee71ffce4d8befc2ea356a8065/tools/src/rppairing.rs):

```sh
idevice-tools --udid DEVICE_UDID rppairing pair HOSTNAME OUTPUT.plist
```

That command uses USB/CoreDeviceProxy and may require an on-device trust action.
It has not been run against a real device here. Runtime startup only verifies an
existing record; it never requests a PIN, silently repairs pairing or rewrites the
record. Treat the pairing file as a sensitive host identity: do not log it, attach
it to an issue or include it in diagnostic exports.

## ABI and ownership

The stable declarations are in
[dsh_phone_self_runner.h](include/dsh_phone_self_runner.h). `start` copies a bounded
JSON configuration and returns a nonzero handle only after claiming a singleton
owner. Another live/stopping/faulted owner returns zero. `stop(handle)` only
signals that exact owner and never blocks the calling thread.

Configuration keys are `runId`, `pairingFile`, `host`, `port`, `runnerBundleId`,
`targetBundleId`, and `publicKeyBase64`. Only a self-loopback IP route is accepted.
The public key must be 2048-bit RSA PKCS#1 DER, base64 encoded. No custom runner
environment, RPC token or private RSA key can be supplied through configuration.

The only app-specific runner environment values are the nonsecret
`DSH_PHONE_RUN_ID` and `DSH_PHONE_PUBLIC_KEY`. The runner generates its own RPC
token in memory, seals the endpoint using RSA-OAEP-SHA256, and sends
`DSH_PHONE_READY_V1:<ciphertext>` as an XCTest activity title. The listener consumes
that activity through the authenticated testmanagerd session, strips the prefix
and delivers only ciphertext to Swift. It never prints readiness or pairing data.

Callbacks execute on the native worker thread; both strings are borrowed for the
call's duration and must be copied before dispatching elsewhere. Callback kinds:

| Kind | Meaning |
| --- | --- |
| 0 | Native worker starting; not ready for actions |
| 1 | Encrypted endpoint from the expected serving test; Swift must decrypt/validate |
| 2 | Stopped; native resources released and launched device PID confirmed absent |
| 3 | Failed; no runner launched, or launched PID cleanup was confirmed |
| 4 | `ERR_PHONE_STOP_UNCONFIRMED`; native resources released, device exit unknown |

A fresh native lifetime gets a fresh handle. Pre-launch connection and initialization
waits are bounded and cancellable. A submitted launch instead waits up to 30 seconds
for its PID reply; cancellation cannot pretend the RPC was undone. Missing/error
launch replies fault the owner rather than allowing an overlapping start.
Once a valid nonzero 32-bit PID is known, cleanup only
kills/queries that exact PID, never a process newly found by bundle ID. A `kind 4`
fault retains the small singleton slot until the app restarts, so a subsequent
start cannot overlap an unconfirmed old runner. Swift must not treat it as normal
stopped/failed state or replay an uncertain phone action through another backend.

## Dependency provenance

The sole upstream source is
[jkcoxson/idevice](https://github.com/jkcoxson/idevice), MIT, fixed at
`3854a5df4a5a6dee71ffce4d8befc2ea356a8065` (0.1.68). The full source archive SHA256
is `bb3c171161476dac94c190a4867bf4a670663643d5dfa5b8b38086948fbc3042`.
[pins](source-pins.json) and [Cargo.lock](Cargo.lock) are checked in; generated
upstream source and build outputs are ignored. No external dsh-Go PR was merged
or copied.

The documented [local source patch](idevice-rsd-xctest.patch):

1. Adds a provider-free RSD XCTest entry point using the upstream session/launch/
   dispatch helpers, so an already authenticated RPPairing tunnel can be used.
2. Confirms shutdown via strict `isRunningPid` boolean responses; a malformed or
   missing reply is not treated as proof of process exit.
3. Removes an upstream debug statement that printed the full remote pairing plist.
4. Resolves UID fields of custom XCTest archive objects, including the test
   identifier components and encrypted readiness activity title.
5. Uses a correlated SIGKILL request and process-status reply before releasing
   the owner. A sent kill request alone is never proof that the PID exited.

The RPPairing transport does not require the legacy lockdown Marco/Polo
heartbeat. On iOS 26, activity identifiers can be `none/none`; those activities
are accepted only after the selected test starts on this paired session. The
app must still decrypt the fresh per-run RSA payload and verify its run ID.

The iOS Settings → Phone control page exposes the master switch and the
existing return-after-completion preference. The authenticated bridge supplies
the exact conversation owner to the turn-end controller. At completion, only
the existing authorized endpoint can bring DSH Go forward; no runner is started
for that return. The owner then stops its runner and confirms process exit.

Some iOS versions deny app enumeration inside the signed helper. After installing
it, `python3 tooling/ios/install-phone-app-catalog.py --device <device> --runner-bundle-id
<helper-bundle> --output <private-json-path>` installs a local name-to-bundle
inventory. Run it again after adding apps that the helper cannot find. Bundle IDs
and the Settings name do not require that inventory. Unknown names fail before
activation, rather than being passed to XCTest as invalid bundle IDs.

The preparer rejects archive traversal, unknown links, wrong checksums and changed
prepared source. The one pinned README symlink is materialized as a regular file;
no archive-controlled filesystem links are created. The upstream MIT license and
attribution remain in the prepared source and are copied into build output.
