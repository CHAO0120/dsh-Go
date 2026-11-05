#!/usr/bin/env python3
"""Unit tests for `rtbuild.py patch-dsh` (strict unified-diff application, per-version pins).

    python3 -I runtime/tests/test_patch_dsh.py
"""
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True   # runtime/lib/__pycache__ is tracked; do not rewrite it
HERE = os.path.dirname(os.path.abspath(__file__))
RTBUILD = os.path.join(HERE, "..", "lib", "rtbuild.py")
spec = importlib.util.spec_from_file_location("rtbuild", RTBUILD)
rtbuild = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rtbuild)

REL = "node_modules/@x/web/lib/index.js"
ORIGINAL = "".join("line %d\n" % i for i in range(1, 41)).replace("line 20\n", "\tif (route) {\n\t\tawait route.handler(req, res);\n\t}\n")
DIFF = """# comment lines before the first header are ignored
--- a/%s
+++ b/%s
@@ -19,4 +19,5 @@
 line 19
 \tif (route) {
+\t\tif (await guard(req, res)) return;
 \t\tawait route.handler(req, res);
 \t}
@@ -40,1 +41,2 @@
 line 40
+-- a removed-looking added line
""" % (REL, REL)
sha = lambda text: hashlib.sha256(text.encode()).hexdigest()


def read(path):
    with open(path) as f:
        return f.read()


def load(path):
    with open(path) as f:
        return json.load(f)


class PatchDsh(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.prefix = os.path.join(self.tmp.name, "prefix")
        self.patches = os.path.join(self.tmp.name, "patches")
        os.makedirs(os.path.join(self.prefix, os.path.dirname(REL)))
        os.makedirs(self.patches)
        self.target = os.path.join(self.prefix, REL)
        with open(self.target, "w") as f:
            f.write(ORIGINAL)
        with open(os.path.join(self.patches, "guard.diff"), "w") as f:
            f.write(DIFF)
        self.write_pins({"schema": 2, "patches": {},
                         "targetSets": {"android": ["guard.diff"], "ohos": ["guard.diff"]}})

    def write_pins(self, pins):
        with open(os.path.join(self.patches, "pins.json"), "w") as out:
            json.dump(pins, out)

    def tearDown(self):
        self.tmp.cleanup()

    def run_cli(self, *extra):
        return subprocess.run([sys.executable, "-I", RTBUILD, "patch-dsh", "--prefix", self.prefix,
                               "--patches", self.patches, *extra],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                              env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})

    def test_parse_hunks(self):
        files = rtbuild.parse_unified_diff(DIFF)
        self.assertEqual([f[0] for f in files], [REL])
        (old1, new1), (old2, new2) = files[0][1]
        self.assertIn("\t\tif (await guard(req, res)) return;\n", new1)
        self.assertNotIn("guard", old1)
        self.assertEqual(new2, "line 40\n-- a removed-looking added line\n")

    def test_record_then_apply_pinned(self):
        r = self.run_cli("--target", "android", "--dsh-version", "1.0.0", "--record")
        self.assertEqual(r.returncode, 0, r.stdout)
        pins = load(os.path.join(self.patches, "pins.json"))
        pin = pins["patches"]["guard.diff"]["1.0.0"][REL]
        self.assertEqual(pin["before"], sha(ORIGINAL))
        patched = read(self.target)
        self.assertEqual(pin["after"], sha(patched))
        self.assertIn("guard(req, res)", patched)
        # idempotent on an already patched tree
        r = self.run_cli("--target", "android", "--dsh-version", "1.0.0")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("already patched", r.stdout)
        # a fresh original applies to exactly the pinned result, by replacing the file (hard links survive)
        with open(self.target + ".orig", "w") as f:
            f.write(ORIGINAL)
        os.replace(self.target + ".orig", self.target)
        link = self.target + ".link"
        os.link(self.target, link)
        r = self.run_cli("--target", "android", "--dsh-version", "1.0.0", "--out", os.path.join(self.tmp.name, "applied.json"))
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertEqual(sha(read(self.target)), pin["after"])
        self.assertEqual(read(link), ORIGINAL)
        self.assertEqual(load(os.path.join(self.tmp.name, "applied.json")), ["guard.diff"])

    def test_unpinned_version_fails(self):
        self.run_cli("--target", "android", "--dsh-version", "1.0.0", "--record")
        with open(self.target, "w") as f:
            f.write(ORIGINAL)
        r = self.run_cli("--target", "android", "--dsh-version", "1.0.1")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no pin for DSH 1.0.1", r.stdout)
        self.assertEqual(read(self.target), ORIGINAL)

    def test_drifted_original_fails(self):
        self.run_cli("--target", "android", "--dsh-version", "1.0.0", "--record")
        with open(self.target, "w") as f:
            f.write(ORIGINAL + "// upstream change\n")
        r = self.run_cli("--target", "android", "--dsh-version", "1.0.0")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("differs from the vetted", r.stdout)

    def chain_fixture(self, broken=False):
        first = rtbuild.apply_hunks(ORIGINAL, rtbuild.parse_unified_diff(DIFF)[0][1], "first")
        second_diff = "--- a/%s\n+++ b/%s\n@@ -1,1 +1,1 @@\n-line 1\n+later reviewed patch\n" % (REL, REL)
        final = first.replace("line 1\n", "later reviewed patch\n", 1)
        with open(os.path.join(self.patches, "zz-later.diff"), "w") as out:
            out.write(second_diff)
        pins = {"schema": 2, "targetSets": {
            "android": ["guard.diff", "zz-later.diff"], "ohos": ["guard.diff", "zz-later.diff"]}, "patches": {
            "guard.diff": {"1.0.0": {REL: {"before": sha(ORIGINAL), "after": sha(first)}}},
            "zz-later.diff": {"1.0.0": {REL: {"before": "0" * 64 if broken else sha(first), "after": sha(final)}}},
        }}
        with open(os.path.join(self.patches, "pins.json"), "w") as out:
            json.dump(pins, out)
        return first, final

    def test_ordered_hash_chain_is_idempotent_at_final_and_intermediate(self):
        first, final = self.chain_fixture()
        for starting in (ORIGINAL, first, final):
            with open(self.target, "w") as out:
                out.write(starting)
            result = self.run_cli("--target", "android", "--dsh-version", "1.0.0")
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertEqual(read(self.target), final)

    def test_broken_hash_chain_fails_before_writing_any_file(self):
        self.chain_fixture(broken=True)
        result = self.run_cli("--target", "android", "--dsh-version", "1.0.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("broken patch hash chain", result.stdout)
        self.assertEqual(read(self.target), ORIGINAL)

    def test_unknown_hash_is_not_accepted_by_chain_idempotency(self):
        _, final = self.chain_fixture()
        with open(self.target, "w") as out:
            out.write(final + "unexpected modification\n")
        result = self.run_cli("--target", "android", "--dsh-version", "1.0.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("differs from the vetted", result.stdout)

    def test_record_refuses_ambiguous_or_missing_context(self):
        with open(self.target, "w") as f:
            f.write(ORIGINAL + ORIGINAL)          # every hunk matches twice
        r = self.run_cli("--target", "android", "--dsh-version", "2.0.0", "--record")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("matches 2 places", r.stdout)
        with open(self.target, "w") as f:
            f.write(ORIGINAL.replace("await route.handler", "await route.run"))
        r = self.run_cli("--target", "android", "--dsh-version", "2.0.0", "--record")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("matches 0 places", r.stdout)
        self.assertEqual(load(os.path.join(self.patches, "pins.json"))["patches"], {})

    def test_shipped_patch_parses_against_pins(self):
        shipped = os.path.join(HERE, "..", "patches")
        pins = load(os.path.join(shipped, "pins.json"))
        for name in sorted(n for n in os.listdir(shipped) if n.endswith(".diff")):
            files = rtbuild.parse_unified_diff(read(os.path.join(shipped, name)))
            self.assertTrue(files and all(hunks for _, hunks in files), name)
            for version, by_file in pins["patches"][name].items():
                self.assertEqual(sorted(by_file), sorted(rel for rel, _ in files), (name, version))

    @unittest.skipUnless(os.environ.get("DSH_FS_LOCAL_ORIGINAL_JS"),
                         "set DSH_FS_LOCAL_ORIGINAL_JS to the unpatched npm 0.2.1-rc.2 lib/index.js")
    def test_shipped_exclusive_create_patch_applies_and_rejects_drift(self):
        shipped = os.path.join(HERE, "..", "patches")
        name = "fs-create-exclusive.diff"
        rel = "node_modules/@deepseek-ai/dsh-fs-local/lib/index.js"
        pins = load(os.path.join(shipped, "pins.json"))
        pin = pins["patches"][name]["0.2.1-rc.2"][rel]
        with open(os.environ["DSH_FS_LOCAL_ORIGINAL_JS"], "rb") as source:
            original = source.read()
        self.assertEqual(hashlib.sha256(original).hexdigest(), pin["before"])
        target = os.path.join(self.prefix, rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "wb") as out:
            out.write(original)
        os.remove(os.path.join(self.patches, "guard.diff"))
        with open(os.path.join(self.patches, name), "w") as out:
            out.write(read(os.path.join(shipped, name)))
        with open(os.path.join(self.patches, "pins.json"), "w") as out:
            json.dump({"schema": 2, "targetSets": {"android": [name], "ohos": [name]},
                       "patches": {name: pins["patches"][name]}}, out)

        result = self.run_cli("--target", "android", "--dsh-version", "0.2.1-rc.2")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(sha(read(target)), pin["after"])
        again = self.run_cli("--target", "android", "--dsh-version", "0.2.1-rc.2")
        self.assertEqual(again.returncode, 0, again.stdout)
        self.assertIn("already patched", again.stdout)
        with open(target, "wb") as out:
            out.write(original + b"// upstream drift\n")
        changed = self.run_cli("--target", "android", "--dsh-version", "0.2.1-rc.2")
        self.assertNotEqual(changed.returncode, 0)
        self.assertIn("differs from the vetted", changed.stdout)
        with open(target, "rb") as source:
            self.assertEqual(source.read(), original + b"// upstream drift\n")

    def target_fixture(self, same_file=True):
        first, second = self.chain_fixture()
        name = "zzz-feature.diff"  # Its target is metadata, not a filename heuristic.
        rel = REL if same_file else "node_modules/@x/other/lib/index.js"
        before = second if same_file else "feature off\n"
        after = before + "feature on\n"
        import difflib
        with open(os.path.join(self.patches, name), "w") as out:
            out.write("".join(difflib.unified_diff(before.splitlines(True), after.splitlines(True),
                                                  fromfile="a/" + rel, tofile="b/" + rel)))
        if not same_file:
            path = os.path.join(self.prefix, rel)
            os.makedirs(os.path.dirname(path))
            with open(path, "w") as out:
                out.write(before)
        pins = load(os.path.join(self.patches, "pins.json"))
        pins["targetSets"]["ohos"].append(name)
        pins["patches"][name] = {"1.0.0": {rel: {"before": sha(before), "after": sha(after)}}}
        self.write_pins(pins)
        return first, second, rel, after

    def fixture_state(self):
        """Capture payload, pins, reports, and any accidental temporary-file writes."""
        state = {}
        for parent, dirs, files in os.walk(self.tmp.name):
            for name in [".", *sorted(dirs), *sorted(files)]:
                path = os.path.normpath(os.path.join(parent, name))
                stat = os.lstat(path)
                item = [stat.st_mode, stat.st_dev, stat.st_ino, stat.st_mtime_ns]
                if os.path.isfile(path):
                    with open(path, "rb") as source:
                        item.append(hashlib.sha256(source.read()).hexdigest())
                state[os.path.relpath(path, self.tmp.name)] = item
        return state

    def test_missing_target_rejects_pinned_apply_before_any_write(self):
        self.target_fixture()
        out = os.path.join(self.tmp.name, "applied.json")
        report = os.path.join(self.tmp.name, "target.json")
        for path in (out, report):
            with open(path, "w") as stream:
                stream.write("existing report must not be replaced\n")
        before = self.fixture_state()
        result = self.run_cli("--dsh-version", "1.0.0", "--out", out, "--target-report", report)
        after = self.fixture_state()
        self.assertEqual(result.returncode, 2, result.stdout + "\nfixture changed: " + str(after != before))
        self.assertIn("required: --target", result.stdout)
        self.assertEqual(after, before)

    def test_missing_target_rejects_record_before_creating_outputs(self):
        # A valid, explicitly registered but not yet pinned set would otherwise be recorded.
        before = self.fixture_state()
        result = self.run_cli("--dsh-version", "1.0.0", "--record",
                              "--out", os.path.join(self.tmp.name, "new-applied.json"),
                              "--target-report", os.path.join(self.tmp.name, "new-target.json"))
        after = self.fixture_state()
        self.assertEqual(result.returncode, 2, result.stdout + "\nfixture changed: " + str(after != before))
        self.assertIn("required: --target", result.stdout)
        self.assertEqual(after, before)

    def test_invalid_or_valueless_target_rejects_before_any_write(self):
        self.target_fixture()
        before = self.fixture_state()
        for flags in (["--target", "linux"], ["--target"]):
            with self.subTest(flags=flags):
                result = self.run_cli("--dsh-version", "1.0.0", *flags)
                self.assertEqual(result.returncode, 2, result.stdout)
                self.assertIn("--target", result.stdout)
                self.assertEqual(self.fixture_state(), before)

    def test_explicit_android_uses_only_declared_common_set(self):
        _, android, rel, ohos = self.target_fixture()
        report = os.path.join(self.tmp.name, "target.json")
        result = self.run_cli("--target", "android", "--dsh-version", "1.0.0", "--target-report", report)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(read(self.target), android)
        value = load(report)
        self.assertEqual({key: value[key] for key in ['schema', 'target', 'dshVersion', 'selected', 'excluded']},
                         {"schema": 1, "target": "android", "dshVersion": "1.0.0",
                          "selected": ["guard.diff", "zz-later.diff"], "excluded": ["zzz-feature.diff"]})
        self.assertRegex(value['inputSha256'], r'^[0-9a-f]{64}$')
        result = self.run_cli("--dsh-version", "1.0.0", "--target", "ohos")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(read(os.path.join(self.prefix, rel)), ohos)
        again = self.run_cli("--dsh-version", "1.0.0", "--target", "ohos")
        self.assertEqual(again.returncode, 0, again.stdout)
        self.assertIn("already patched", again.stdout)

    def test_every_known_intermediate_of_three_stage_chain_is_accepted(self):
        first, second, _, final = self.target_fixture()
        for initial in (ORIGINAL, first, second, final):
            with self.subTest(initial=sha(initial)):
                with open(self.target, "w") as out:
                    out.write(initial)
                result = self.run_cli("--dsh-version", "1.0.0", "--target", "ohos")
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(read(self.target), final)

    def test_android_refuses_ohos_final_state_on_shared_file(self):
        _, _, _, final = self.target_fixture()
        with open(self.target, "w") as out:
            out.write(final)
        result = self.run_cli("--dsh-version", "1.0.0", "--target", "android")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("target android", result.stdout)
        self.assertEqual(read(self.target), final)

    def test_android_refuses_excluded_changes_before_any_selected_write(self):
        _, _, rel, final = self.target_fixture(same_file=False)
        with open(os.path.join(self.prefix, rel), "w") as out:
            out.write(final)
        result = self.run_cli("--dsh-version", "1.0.0", "--target", "android")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("excludes changes", result.stdout)
        self.assertEqual(read(self.target), ORIGINAL)
        self.assertEqual(read(os.path.join(self.prefix, rel)), final)

    def test_unknown_diff_is_rejected_even_when_recording(self):
        with open(os.path.join(self.patches, "new.diff"), "w") as out:
            out.write(DIFF)
        for flags in ([], ["--record"]):
            result = self.run_cli("--target", "android", "--dsh-version", "1.0.0", *flags)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unregistered=['new.diff']", result.stdout)
            self.assertEqual(read(self.target), ORIGINAL)

    def test_missing_or_duplicated_target_entries_are_rejected(self):
        initial = load(os.path.join(self.patches, "pins.json"))
        for name in ("missing.diff", "guard.diff"):
            pins = json.loads(json.dumps(initial))
            pins["targetSets"]["ohos"].append(name)
            self.write_pins(pins)
            result = self.run_cli("--target", "android", "--dsh-version", "1.0.0", "--record")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(read(self.target), ORIGINAL)

    def test_legacy_schema_cannot_silently_classify_new_patches_as_android(self):
        self.write_pins({"schema": 1, "patches": {}})
        result = self.run_cli("--target", "android", "--dsh-version", "1.0.0", "--record")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("explicit targetSets", result.stdout)
        self.assertEqual(read(self.target), ORIGINAL)

    def test_missing_later_pin_is_rejected_before_first_patch_changes_bytes(self):
        self.chain_fixture()
        pins = load(os.path.join(self.patches, "pins.json"))
        pins["patches"]["zz-later.diff"] = {}
        self.write_pins(pins)
        result = self.run_cli("--target", "android", "--dsh-version", "1.0.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no pin for DSH 1.0.0", result.stdout)
        self.assertEqual(read(self.target), ORIGINAL)

    def test_android_input_fingerprint_excludes_unselected_patch_bytes(self):
        self.target_fixture()
        report = os.path.join(self.tmp.name, "fingerprint.json")

        def fingerprint():
            result = self.run_cli("--dsh-version", "1.0.0", "--target", "android", "--target-report", report)
            self.assertEqual(result.returncode, 0, result.stdout)
            return load(report)['inputSha256']

        original = fingerprint()
        feature = os.path.join(self.patches, "zzz-feature.diff")
        with open(feature, "a") as out:
            out.write("# OHOS-only patch note changes; Android input fingerprint stays stable.\n")
        self.assertEqual(fingerprint(), original)
        common = os.path.join(self.patches, "guard.diff")
        with open(common, "a") as out:
            out.write("# Common patch source change is a new Android build input.\n")
        self.assertNotEqual(fingerprint(), original)


if __name__ == "__main__":
    unittest.main(verbosity=2)
