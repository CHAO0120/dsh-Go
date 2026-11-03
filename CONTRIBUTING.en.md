# Contributing

[中文](CONTRIBUTING.md) · [Project overview](README.en.md)

## No external pull requests for now

This repository currently **does not accept any external pull requests** (code, docs, configuration or templates).

- External PRs are closed automatically by the intake check, see `.github/workflows/pr-gate.yml`.
- For feature ideas, improvements or bug reports, please [open an issue](https://github.com/ccch1mneyyy/dsh-Go/issues/new/choose) with the use case and expected behavior.
- Internal PRs by the maintainer (and maintainer agents) are unaffected.

This is temporary; this page will be updated when external PRs reopen.

## Welcome

Contributions through issues are welcome — bug reports, documentation and translation improvements, tests, or plugin work. For larger changes to protocols, data formats or permissions, explain the problem and proposed approach before implementation so work can be coordinated.

## Report an issue

Use the repository's bug report or feature request template. Include the app version, Android version, host connection type and minimal repeatable steps. Add a screenshot or short recording for interface issues, after reviewing and redacting private information.

For credential exposure, unauthorized access or actions, and other security issues, follow [SECURITY.en.md](SECURITY.en.md) for private reporting.

## Set up development

Follow [README.en.md](README.en.md) to prepare the toolchain and runtime. Ordinary app development does not require the maintainer's signing key, beta-channel token or production deployment credentials.

- Flutter/Dart: use the repository's Flutter version and the app's Dart SDK requirement.
- Android: use JDK 17 and match the runtime ABI to the APK flavor.
- Plugin SDK: use Node.js 22.19 or later. The SDK is used from `sdk/plugin-kit/` and is not published to npm.

## Keep changes focused

Use one PR for one independently reviewable problem. Explain the old behavior, its trigger and the resulting behavior. Keep unrelated renames, formatting and directory moves out of the change.

- Maintain interface text in the existing Chinese and English structure. Prefer existing components and icons.
- Add tests that cover behavior changes. For text or layout-only changes, provide relevant checks or screenshots.
- When changing a client, bridge or plugin protocol, check compatibility and the callers on the other side.
- Edit generator inputs, then regenerate their outputs.
- For new or adapted third-party content, record the project, version or commit, source files and license. Keep required attribution, license text and modification notices. Check compatibility with the destination directory's license. Moving a file does not change its license.

## Automated PR tests and documentation exemptions

Prefer focused regression tests while developing on a phone. Before merging, [PR Tests](.github/workflows/pr-tests.yml) runs the standard automated suites; the phone does not need to repeat the full run.

- **Code, configuration or mixed changes:** run the complete default Flutter suite (including existing goldens), both Dart packages, the plugin SDK including TypeScript, unit and host bridge integration tests against an isolated, hash-verified patched DSH, Python tooling/asset tests, and Android JVM unit tests for both debug flavors. A failed, cancelled, unexpectedly skipped or missing required job fails the aggregate gate.
- **Documentation-only changes:** only explicitly allowlisted paths and ordinary non-executable files in the [classification policy](.github/scripts/pr-tests/policy.mjs) qualify for a heavy-test exemption: the root project/contribution/security/license files, specified SDK READMEs, the PR template, Markdown and PNG/JPEG/WebP under `docs/`, and corresponding bundled guide help pages. Classification regressions, localization-input validation, guide synchronization/validation and SDK skill synchronization/loading tests remain required. An exemption is not a full-test pass.
- **No exemption:** UI ARB files, dependencies and lockfiles, CI/build configuration, runtime patches, agent instructions and skill entry points (including the guide's `SKILL.md`), other runtime assets, and unknown paths. Any mixed-in non-documentation change requires full tests. Both old and new rename paths are checked; symlinks and executable-bit changes cannot qualify as documentation. Titles, labels and line counts do not decide exemptions.

An empty or unreadable complete diff never grants an exemption. Main-branch pushes, manual runs and merge-queue runs always use the full plan. The stable aggregate check is **PR test gate**; the workflow itself has no path filters, so documentation PRs also produce that check.

For initial deployment, merge the workflow and confirm the check actually runs before an administrator makes **PR test gate** required for `main` in branch protection/rulesets and requires the latest revision to pass. Adding a workflow alone does not prevent merges. Maintainers must still review CI/policy changes: an ordinary required check name is not an independent trust boundary against malicious workflow edits. The existing external-PR intake gate continues to run default-branch code only, never PR-head code.

"Full" means the default automated suites above. It does not include live tests requiring real credentials, opt-in previews without baselines, complete rootfs/PRoot/direct release acceptance, or Android device tests. Record these skips honestly. CI does not replace installing a new build and verifying touch, keyboard, permissions, phone control, installation or startup behavior on a device.

## Common checks

Run these commands from the repository root for local reproduction and focused regressions; PR CI coverage follows the policy above. Record actual commands, CI links and results in the PR. If a device, asset or dependency is unavailable, say what was not run and why.

**Flutter app:**

```bash
(cd app && flutter pub get && flutter analyze && flutter test)
```

**Dart communication packages:**

```bash
(cd packages/dsh_client && dart pub get && dart analyze && dart test)
(cd packages/dsh_remote && dart pub get && dart analyze && dart test)
```

**Plugin SDK:**

```bash
(cd sdk/plugin-kit && npm install && npm test)
```

The SDK type check requires its TypeScript development dependency. That test is skipped when TypeScript is not installed. Review the output and distinguish a skip from a pass. See [SDK maintenance](sdk/plugin-kit/README.en.md) for generator and synchronization steps.

**Interface text:** edit the Chinese and English ARB files in `app/lib/l10n/parts/`, then generate and check:

```bash
python3 app/tool/l10n_merge.py
python3 app/tool/l10n_merge.py --check
```

**User guide:** edit `docs/guide/`, then synchronize the app's bundled guide skill:

```bash
python3 app/tool/guide_sync.py
python3 app/tool/guide_sync.py --check
```

**Plugin authoring skill:** edit `sdk/plugin-kit/skill/` or the relevant SDK inputs, then synchronize:

```bash
node sdk/plugin-kit/scripts/sync-skill.mjs
node sdk/plugin-kit/scripts/sync-skill.mjs --check
```

For APK validation, use the build entry point in the README. For changes to Android processes, PRoot, direct startup, phone control or update installation, record the ABI, Android version, startup mode and device used. Desktop test results do not establish device behavior.

Online checks, deployments and publishing scripts under `services/` and `infra/` are not part of routine contribution checks. When changing a companion service, confirm that tests target your own local environment; do not run examples with production credentials.

## Open a PR

Complete the default PR template in Chinese or English:

1. The problem, why the change is needed and the resulting behavior.
2. Related issues, affected modules and compatibility effects.
3. Checks actually run, their results and remaining verification gaps.
4. Before-and-after screenshots or recordings for UI changes, using test data with private content removed.
5. Sources and licenses of new content, and any notices that must be updated.

Review the diff for credentials, personal configuration, real conversations, device serial numbers, build caches and private operations notes. Review diagnostic files and logs manually as well; automatic redaction is not a guarantee.

Keep discussion focused on problems, evidence and implementation, and respect different user environments. Contributors remain responsible for understanding, validating and maintaining AI-assisted changes.
