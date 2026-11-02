#!/usr/bin/env bash
# Really compiles the ArkTS of app/ohos on Linux with public tools, no Huawei login:
# hvigor -> restool -> ets-loader in strict ArkTS mode -> es2abc -> unsigned HAP.
#
#   tooling/ohos/check-arkts.sh --sdk <OpenHarmony SDK dir> [options]
#
#   --sdk DIR     holds ets/ js/ native/ toolchains/ of API 26 (or $OHOS_SDK)
#   --work DIR    scratch dir, about 500 MB (default ~/.cache/dsh-ohos-arkts-check)
#   --source DIR  the ohos project to check (default app/ohos of this checkout)
#   --debug       debug embedding and buildMode (default release, as build-hap.sh)
#   --with-forks  also compile the plugin forks of pubspec_overrides.ohos.yaml
#   --werror      warnings in the project's own files also fail the check
#   --clean       delete --work first, downloads included
#
# Needs curl, python3, tar, node and java (JAVA_HOME or PATH; $NODE overrides node).
# Exit: 0 clean, 1 diagnostics or a failed build, 2 bad input or environment.
# Writes <work>/diagnostics.txt, <work>/hvigor.log and the unsigned HAP.
#
# It works on a temporary copy, never on the source. What the copy changes:
# - runtimeOS OpenHarmony: the HarmonyOS SDK is behind a login (app/ohos/README.md says
#   what that costs); this needs compileSdkVersion, modelVersion 6.0.0 and deviceTypes
#   "default" too
# - no externalNativeOptions: the native libs have their own build, so `libdsh_host.so`
#   is checked against its .d.ts and the HAP doesn't run
# - no flutter-hvigor-plugin and no Dart: oh_modules is laid out by hand (ohpm isn't
#   public) and GeneratedPluginRegistrant.ets is written here
set -euo pipefail

HVIGOR_VERSION=6.26.9
HVIGOR_REGISTRY=https://repo.harmonyos.com/npm
HVIGOR_SHA512=0b6579ffc2b7358c0c59ec3008a6e743722a616e32a714a1ab9a6899a0b48be80031809359df1f1010ad5e85d11014e36d31e30ce97acd06783520fd25d19837
PLUGIN_SHA512=54b84b5f857fd53376fbaabe358ba8bb0fafac786813306de25e391da048bddc9406a249a18505e4354daeeb360b798c521cc7d589ebe86b24c709336f064853
EMBEDDING_BASE=https://atomgit.com/oh-flutter/flutter_flutter/releases/download/3.47.9-ohos-1.0.0
EMBEDDING_DEBUG_SHA256=90ebf7067ad3c91a53d564a38b1ee1130df8a34a01797bb4fcf8bd26bf9397ef
EMBEDDING_RELEASE_SHA256=20903e3b9197004b0181e3a2acc9243d04e5b10fa63d19453969dfc97dc87e42
SDK_API=26
SDK_TESTED=26.0.0.38

die() { echo "check-arkts: $*" >&2; exit 2; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SDK="${OHOS_SDK:-}"
WORK="${XDG_CACHE_HOME:-$HOME/.cache}/dsh-ohos-arkts-check"
SOURCE="$REPO/app/ohos"
MODE=release
FORKS=0
WERROR=0
CLEAN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sdk) SDK="${2:?--sdk needs a directory}"; shift 2 ;;
    --work) WORK="${2:?--work needs a directory}"; shift 2 ;;
    --source) SOURCE="${2:?--source needs a directory}"; shift 2 ;;
    --debug) MODE=debug; shift ;;
    --with-forks) FORKS=1; shift ;;
    --werror) WERROR=1; shift ;;
    --clean) CLEAN=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

NODE="${NODE:-node}"
JAVA="${JAVA_HOME:+$JAVA_HOME/bin/}java"
for tool in curl python3 tar sha256sum sha512sum "$NODE" "$JAVA"; do
  command -v "$tool" >/dev/null || die "$tool not found"
done
[ -n "$SDK" ] || die "--sdk is required"
SDK="$(cd "$SDK" && pwd)" || die "no such SDK dir"
SOURCE="$(cd "$SOURCE" && pwd)" || die "no such source dir"
for part in ets js native toolchains; do
  [ -f "$SDK/$part/oh-uni-package.json" ] || die "$SDK/$part/oh-uni-package.json is missing"
done
read -r api version < <(python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d["apiVersion"], d["version"])' "$SDK/ets/oh-uni-package.json")
[ "$api" = "$SDK_API" ] || die "SDK API is $api, this check is pinned to API $SDK_API"
[ "$version" = "$SDK_TESTED" ] || echo "check-arkts: SDK $version, tested with $SDK_TESTED" >&2

[ "$CLEAN" = 0 ] || rm -rf "$WORK"
mkdir -p "$WORK/dl"
WORK="$(cd "$WORK" && pwd)"

# Downloads are checked against the pins on every run, cached or not.
fetch() { # url file algorithm hash
  [ -f "$WORK/dl/$2" ] || { curl -fsSL --retry 2 -o "$WORK/dl/$2.part" "$1" && mv "$WORK/dl/$2.part" "$WORK/dl/$2"; } ||
    die "download failed: $1"
  echo "$4  $WORK/dl/$2" | "$3sum" -c --status || die "$2 doesn't match its pinned hash"
}

# --- hvigor: unpacked by hand so that no npm config or install script is involved.
TOOLS="$WORK/tools/$HVIGOR_VERSION"
fetch "$HVIGOR_REGISTRY/@ohos/hvigor/-/@ohos/hvigor-$HVIGOR_VERSION.tgz" "hvigor-$HVIGOR_VERSION.tgz" sha512 "$HVIGOR_SHA512"
fetch "$HVIGOR_REGISTRY/@ohos/hvigor-ohos-plugin/-/@ohos/hvigor-ohos-plugin-$HVIGOR_VERSION.tgz" \
  "hvigor-ohos-plugin-$HVIGOR_VERSION.tgz" sha512 "$PLUGIN_SHA512"
for pkg in hvigor hvigor-ohos-plugin; do
  if [ ! -f "$TOOLS/node_modules/@ohos/$pkg/package.json" ]; then
    mkdir -p "$TOOLS/node_modules/@ohos/$pkg"
    tar -xzf "$WORK/dl/$pkg-$HVIGOR_VERSION.tgz" -C "$TOOLS/node_modules/@ohos/$pkg" --strip-components=1
  fi
done

# --- embedding: flutter_ohos and libflutter.so, published by oh-flutter without a login.
if [ "$MODE" = debug ]; then ZIP=ohos-arm64-artifacts.zip; SUM="$EMBEDDING_DEBUG_SHA256"
else ZIP=ohos-arm64-release-artifacts.zip; SUM="$EMBEDDING_RELEASE_SHA256"; fi
fetch "$EMBEDDING_BASE/$ZIP" "$ZIP" sha256 "$SUM"
HAR="$WORK/embedding/$MODE"
if [ ! -f "$HAR/flutter/package/oh-package.json5" ]; then
  rm -rf "$HAR"; mkdir -p "$HAR/flutter" "$HAR/native"
  python3 -I -m zipfile -e "$WORK/dl/$ZIP" "$HAR"
  tar -xzf "$HAR/flutter_embedding_$MODE.har" -C "$HAR/flutter"
  tar -xzf "$HAR/arm64_v8a_$MODE.har" -C "$HAR/native"
fi

# --- SDK: hvigor looks in <root>/<api>/ and also wants a previewer; symlinks, no copy.
SDK_ROOT="$WORK/sdk"
rm -rf "$SDK_ROOT"; mkdir -p "$SDK_ROOT/26.0.0/previewer"
for part in ets js native toolchains; do ln -s "$SDK/$part" "$SDK_ROOT/26.0.0/$part"; done
sed 's/"Ets"/"Previewer"/; s/"path": "ets"/"path": "previewer"/' "$SDK/ets/oh-uni-package.json" \
  > "$SDK_ROOT/26.0.0/previewer/oh-uni-package.json"

# --- the copy
PROJECT="$WORK/project"
rm -rf "$PROJECT" "$WORK/forks" "$WORK/home"; mkdir -p "$PROJECT" "$WORK/forks" "$WORK/home"
tar -C "$SOURCE" --exclude=./node_modules --exclude=./oh_modules --exclude=./entry/oh_modules \
  --exclude=./build --exclude=./entry/build --exclude=./.hvigor --exclude=./entry/.cxx --exclude=./.vendor \
  --exclude=./entry/libs --exclude=./local.properties --exclude=./entry/src/main/resources/rawfile/flutter_assets \
  -cf - . | tar -xf - -C "$PROJECT"
ln -s "$TOOLS/node_modules" "$PROJECT/node_modules"
ln -s "$TOOLS/node_modules" "$WORK/forks/node_modules"
echo "sdk.dir=$SDK_ROOT" > "$PROJECT/local.properties"

# <override key> <module name> <ohos dir in the repo> <plugin class>. URL and tag come
# from pubspec_overrides.ohos.yaml, so a bumped tag can't drift away from this check.
FORK_TABLE='file_picker file_picker ohos FilePickerPlugin
flutter_secure_storage flutter_secure_storage_ohos flutter_secure_storage_ohos/ohos FlutterSecureStorageOhosPlugin
image_picker image_picker_ohos packages/image_picker/image_picker_ohos/ohos ImagePickerPlugin
path_provider path_provider ohos PathProviderPlugin
shared_preferences shared_preferences ohos SharedPreferencesPlugin
url_launcher url_launcher_ohos packages/url_launcher/url_launcher_ohos/ohos UrlLauncherPlugin
webview_flutter webview_flutter_ohos packages/webview_flutter/webview_flutter_ohos/ohos WebViewFlutterPlugin'
FORK_MODULES=""
if [ "$FORKS" = 1 ]; then
  command -v git >/dev/null || die "git not found"
  while read -r key name dir class; do
    read -r url ref < <(python3 -I -c '
import re, sys
text = open(sys.argv[1]).read()
block = re.search(r"^  %s:\n((?:    .*\n)+)" % re.escape(sys.argv[2]), text, re.M).group(1)
print(re.search(r"url: (\S+)", block).group(1), re.search(r"ref: (\S+)", block).group(1))' \
      "$SOURCE/pubspec_overrides.ohos.yaml" "$key") || die "$key is not in pubspec_overrides.ohos.yaml"
    clone="$WORK/dl/forks/$(basename "$url" .git)@$ref"
    if [ ! -d "$clone/.git" ]; then
      mkdir -p "$WORK/dl/forks"
      git -c advice.detachedHead=false clone -q --depth 1 --branch "$ref" --filter=blob:none --sparse "$url" "$clone" ||
        die "clone failed: $url $ref"
    fi
    git -C "$clone" sparse-checkout add "$dir"
    [ -f "$clone/$dir/oh-package.json5" ] || die "$url $ref has no $dir"
    mkdir -p "$WORK/forks/$name"
    (cd "$clone/$dir" && tar --exclude=./build --exclude=./oh_modules -cf - .) | tar -xf - -C "$WORK/forks/$name"
    FORK_MODULES+="$name $class"$'\n'
  done <<< "$FORK_TABLE"
fi

EMBEDDING_VERSION="$(python3 -I - "$PROJECT" "$HAR" "$MODE" "$FORK_MODULES" <<'PY'
import json, os, re, shutil, sys

project, har, mode, fork_lines = sys.argv[1:5]
forks = [line.split() for line in fork_lines.splitlines() if line.strip()]
work = os.path.dirname(project)

def edit(rel, *subs):
    path = os.path.join(project, rel)
    with open(path) as f:
        text = f.read()
    for pattern, repl in subs:
        text, n = re.subn(pattern, repl, text, flags=re.S)
        if n == 0:
            sys.exit(f"check-arkts: {rel} no longer matches {pattern!r}; update this script")
    with open(path, "w") as f:
        f.write(text)

def write(rel, text):
    with open(os.path.join(project, rel), "w") as f:
        f.write(text)

edit("build-profile.json5",
     (r'"runtimeOS": "HarmonyOS"', '"runtimeOS": "OpenHarmony"'),
     (r'"compatibleSdkVersion": ("[^"]+")', r'"compileSdkVersion": \1,\n        "compatibleSdkVersion": \1'))
edit("entry/build-profile.json5",
     (r'"runtimeOS": "HarmonyOS"', '"runtimeOS": "OpenHarmony"'),
     (r'"externalNativeOptions": \{.*?\},\s*', ''))
edit("hvigor/hvigor-config.json5", (r'"modelVersion": "[^"]+"', '"modelVersion": "6.0.0"'))
edit("oh-package.json5",
     (r'"modelVersion": "[^"]+"', '"modelVersion": "6.0.0"'),
     (r'"devDependencies": \{.*?\}', '"devDependencies": {}'))
edit("entry/src/main/module.json5", (r'"phone"', '"default"'))
write("hvigorfile.ts",
      "import { appTasks } from '@ohos/hvigor-ohos-plugin';\n"
      "export default { system: appTasks, plugins: [] }\n")
names = ", ".join(f"'{name}'" for name, _ in forks)
write("hvigorconfig.ts",
      "import { hvigor } from '@ohos/hvigor';\n"
      f"for (const n of [{names}] as string[]) {{\n"
      "  hvigor.getHvigorConfig().includeNode(n, '../forks/' + n);\n"
      "}\n")

# Same layout as ohpm: a store under the root, links from the module that depends on it.
with open(os.path.join(har, "flutter/package/oh-package.json5")) as f:
    version = json.load(f)["version"]
def store(name, src):
    path = os.path.join(project, "oh_modules/.ohpm", f"{name.replace('/', '+')}@{version}/oh_modules", name)
    shutil.copytree(src, path, symlinks=True)
    return path
def link(path, target):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    os.symlink(target, path)
embedding = store("@ohos/flutter_ohos", os.path.join(har, "flutter/package"))
native = store("flutter_native_arm64_v8a", os.path.join(har, "native/package"))
oh_modules = os.path.join(project, "entry/oh_modules")
link(os.path.join(oh_modules, "@ohos/flutter_ohos"), embedding)
link(os.path.join(oh_modules, "flutter_native_arm64_v8a"), native)
link(os.path.join(oh_modules, "libdsh_host.so"), "../src/main/cpp/types/libdsh_host")
deps = [f'"@ohos/flutter_ohos": "file:{har}/flutter_embedding_{mode}.har"',
        f'"flutter_native_arm64_v8a": "file:{har}/arm64_v8a_{mode}.har"']
for name, _ in forks:
    link(os.path.join(oh_modules, name), os.path.join(work, "forks", name))
    link(os.path.join(work, "forks", name, "oh_modules/@ohos/flutter_ohos"), embedding)
    deps.append(f'"{name}": "file:../../forks/{name}"')
edit("entry/oh-package.json5", (r'"dependencies": \{', '"dependencies": {\n    ' + ",\n    ".join(deps) + ","))

# The text flutter_tools generates (flutter_plugins.dart, _arktsPluginRegistryTemplate).
imports = "".join(f"import {cls} from '{name}';\n" for name, cls in forks)
adds = "".join(f"      flutterEngine.getPlugins()?.add(new {cls}());\n" for _, cls in forks)
write("entry/src/main/ets/plugins/GeneratedPluginRegistrant.ets", f"""import {{ FlutterEngine, Log }} from '@ohos/flutter_ohos';
{imports}
const TAG = "GeneratedPluginRegistrant";

export class GeneratedPluginRegistrant {{

  static registerWith(flutterEngine: FlutterEngine) {{
    try {{
{adds}    }} catch (e) {{
      Log.e(
        TAG,
        "Tried to register plugins with FlutterEngine ("
          + flutterEngine
          + ") failed.");
      Log.e(TAG, "Received exception while registering", e);
    }}
  }}
}}
""")
print(version)
PY
)"

# --- the build
LOG="$WORK/hvigor.log"
echo "check-arkts: hvigor $HVIGOR_VERSION, SDK $version, embedding $EMBEDDING_VERSION ($MODE), forks: $FORKS"
rc=0
(cd "$PROJECT" && env -u DEVECO_SDK_HOME HVIGOR_USER_HOME="$WORK/home" OHOS_BASE_SDK_HOME="$SDK_ROOT" \
  PATH="$(dirname "$(command -v "$JAVA")"):$PATH" \
  "$NODE" --max-old-space-size=2048 node_modules/@ohos/hvigor/bin/hvigor.js \
  --mode module -p product=default -p module=entry@default -p buildMode="$MODE" assembleHap \
  --no-daemon --no-parallel --no-incremental) > "$LOG" 2>&1 || rc=$?

HAP="$PROJECT/entry/build/default/outputs/default/entry-default-unsigned.hap"
ABC_TEXT="$WORK/modules.abc.txt"
rm -f "$ABC_TEXT"
if [ "$rc" = 0 ] && [ -f "$HAP" ]; then
  python3 -I -c '
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extract("ets/modules.abc", sys.argv[2])' "$HAP" "$WORK/abc"
  "$SDK/toolchains/ark_disasm" "$WORK/abc/ets/modules.abc" "$ABC_TEXT" >/dev/null || rm -f "$ABC_TEXT"
fi

# --- diagnostics: every one, grouped by file; a file that never reached the bytecode counts.
python3 -I - "$LOG" "$PROJECT" "$WORK" "$rc" "$HAP" "$ABC_TEXT" "$WERROR" "hvigor $HVIGOR_VERSION; SDK $version; embedding $EMBEDDING_VERSION ($MODE); forks $FORKS" <<'PY'
import collections, json, os, re, sys, zipfile

log, project, work, rc, hap, abc_text, werror, tools = sys.argv[1:9]
rc = int(rc)
with open(log, errors="replace") as f:
    text = re.sub(r"\x1b\[[0-9;]*m", "", f.read())

def short(path):
    for old, new in ((project + "/", ""), (work + "/forks/", "forks/")):
        path = path.replace(old, new)
    return re.sub(r"oh_modules/\.ohpm/[^/]+/oh_modules/@ohos/", "", path)

errors, tool_errors = set(), []
for code, msg in re.findall(r"^(?:\d+ |> hvigor )?ERROR: (\d{8}) [^\n]*\nError Message: ([^\n]*)", text, re.M):
    m = re.match(r"(.*?) At File: (.+?):(\d+):(\d+)\s*$", msg)
    if m:
        errors.add((short(m[2]), int(m[3]), int(m[4]), code, short(m[1])))
    elif (code, short(msg)) not in tool_errors:
        tool_errors.append((code, short(msg)))
for code, msg in re.findall(r"^Error Code: (\d+)\n[^\n]*\nError Message: ([^\n]*)", text, re.M):
    if (code, short(msg)) not in tool_errors:
        tool_errors.append((code, short(msg)))
failed = sorted(set(re.findall(r"ERROR: Failed :(\S+?)\.\.\.", text)))

warnings = set()
for path, line, col, msg in re.findall(r"^(?:\d+ )?WARN: ArkTS:WARN File: (.+?):(\d+):(\d+)\n((?:[^\n]+\n?)*)", text, re.M):
    warnings.add((short(path), int(line), int(col), short(" ".join(msg.split()))))

# Only what the entry points reach gets compiled; say so if a source file was left out.
missing = []
if os.path.exists(abc_text):
    with open(abc_text, errors="replace") as f:
        records = set(re.findall(r"^\.record (\S+)", f.read(), re.M))
    bundle = zipfile.ZipFile(hap).read("module.json")
    bundle = json.loads(bundle)["app"]["bundleName"]
    root = os.path.join(project, "entry/src/main")
    for base, _, names in os.walk(os.path.join(root, "ets")):
        for name in names:
            if name.endswith(".ets"):
                rel = os.path.relpath(os.path.join(base, name), root)
                if f"{bundle}.entry.{rel[:-4].replace(os.sep, '.')}" not in records:
                    missing.append("entry/src/main/" + rel)

own = lambda d: d[0].startswith("entry/")
own_warnings = sorted(w for w in warnings if own(w))
dep_warnings = sorted(w for w in warnings if not own(w))
ok = rc == 0 and os.path.exists(hap) and os.path.exists(abc_text) and not errors and not tool_errors and not missing
if ok and werror == "1" and own_warnings:
    ok = False

out = [f"# {tools}", f"# hvigor exit {rc}; failed tasks: {', '.join(failed) or 'none'}",
       f"# errors {len(errors)}; tool errors {len(tool_errors)}; not compiled {len(missing)}; "
       f"warnings: own files {len(own_warnings)}, dependencies {len(dep_warnings)}",
       f"# HAP: {hap if os.path.exists(hap) else 'not produced'}", ""]
def section(title, items):
    out.append(f"== {title} ({len(items)})")
    groups = collections.defaultdict(list)
    for item in items:
        groups[item[0]].append(item)
    for path in sorted(groups):
        out.append(f"-- {path} ({len(groups[path])})")
        out.extend(f"{i[1]}:{i[2]} " + " ".join(str(p) for p in i[3:]) for i in sorted(groups[path]))
    out.append("")
section("ERRORS", sorted(errors))
if tool_errors:
    out.append(f"== TOOL ERRORS ({len(tool_errors)})")
    out.extend(f"{c} {m}" for c, m in tool_errors)
    out.append("")
if missing:
    out.append(f"== NOT COMPILED: no record in modules.abc ({len(missing)})")
    out.extend(sorted(missing))
    out.append("")
section("WARNINGS IN OWN FILES", own_warnings)
section("WARNINGS IN DEPENDENCIES", dep_warnings)
with open(os.path.join(work, "diagnostics.txt"), "w") as f:
    f.write("\n".join(out))

head = out[:out.index(f"== WARNINGS IN OWN FILES ({len(own_warnings)})")]
print("\n".join(head))
if rc != 0 and not errors and not tool_errors:
    print(f"hvigor failed with nothing this script could parse; see {log}")
print(f"check-arkts: {'OK' if ok else 'FAILED'}; all diagnostics in {work}/diagnostics.txt")
sys.exit(0 if ok else 1)
PY
