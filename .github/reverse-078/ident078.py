# reverse request 078 identity checks (temp branch only, never merged). All comparisons in Python; exit code decides.
# Copied from core20-076 ident076.py (helpers git/regular_bytes/source/plain/head/node_modules/dsh_prefix/ignored/
# patch_names/strict_json/chain/teq and the seven modes kept). Changed for 078 only: paths (22z turn-outline inner, new
# first-human test, modified Unicode test), the ten fixed base inputs, the five direct-import lock rows and effective
# sources, the unpinned official types.d.ts (A) / its new pin (B), counts A 120/170/89 and B 121/172/90, the new inner at
# rank 90, and the raw-diff/status rules for a modified tracked path. Expected values come from requestfromweb-078.txt
# (hard-coded below) and are cross-checked with the verified 078-identities.json (data only). Loads no product code.
# usage:
#   ident078.py pre       <tree> <identities.json>
#   ident078.py post      <tree> <raw> <a|b|brec> <label> <out diff file> <out status file> <identities.json>
#   ident078.py pristine  <prefix> <label>
#   ident078.py prefix    <tree> <prefix> <a|b> <label> <identities.json> <expected tree pins.json sha256>
#   ident078.py pins      <original pins.json> <recorded pins.json> <identities.json>
#   ident078.py patchlog  <tree> <patch-dsh stdout> <strict|record> <label>
#   ident078.py prerecord <tree>
import hashlib
import json
import os
import pathlib
import re
import stat
import subprocess
import sys

BASE = 'e5d931cd84c21e833cf1f9dcbed6061008168f5e'
VER = '0.2.2-rc.1'
NEW_KEY = 'zzzzzzzzzzzzzzzzzzzzzz-turn-outline-first-human.diff'
INNER = 'runtime/patches/' + NEW_KEY
TEST = 'runtime/tests/turn-outline-first-human.test.mjs'
UNI = 'runtime/tests/turn-outline-unicode.test.mjs'
PINS = 'runtime/patches/pins.json'
CORE = 'runtime/session-deletion/core.mjs'
PINS_ORIG = (79781, 'a0df85fd547d5e8da8b9ef20ff90e4c52fa7157f5030de66fbca170cc5b947ad', '5454cdd89828ffb91634e7098bc26530a779c848')
# path: (bytes, sha256, git blob, numstat added, numstat removed)
FINAL = {INNER: (4098, '05fb1b92472d7edc397e7dedff3d47f5f8521269dc592f659a54ca24c1795b0b', '1080aab3a55ceff73a7045fe3044987344ac114a', 110, 0),
         TEST: (11015, 'a9b52252aaf0564b515fc997b261b1c3e8097743547ce902510b3b0f1c882fe9', '4efa6d5408375719f8f1447abc8bb5241a290433', 197, 0),
         UNI: (5416, '81f5d526e601c9db1f43852eba25f4cf4d71c5d8ffb2cd0191faeefa3a0759d7', '65a96553ec51bd0371a910e62176c8d1b6d541bd', 1, 1)}
ADDED = {INNER, TEST}
BASE_BLOB = {PINS: PINS_ORIG[2], UNI: '0263c9710d2aa3688942f006fa471e51d1b66be4'}
GROUP_PATHS = {'a': [TEST], 'b': [INNER, TEST, UNI], 'brec': [PINS, INNER, TEST, UNI]}
# (path, bytes, sha256, git blob, mode) - request/identities base_repository_inputs (10 rows)
BASE_INPUTS = [('.github/workflows/ci.yml', 11295, '0e14d0492da3d036b719bf9acd13aa99b91d5a609a9c733a5856019deeee88ff', '5a946dcba10deda36642e853d90a7e8f874516c8', '100644'),
               ('runtime/build-runtime.sh', 27283, '1ddfc945b7a59fe9243178303d982b04caf6f4178787a5b09a4a5dc1bbfb88ab', '0301703703b1b734f8f68c81e756ff86c3fb299d', '100755'),
               ('runtime/lib/rtbuild.py', 71221, '32dd9e3fcb034950043c826b92e757b8b3cd4840d61d01f62ab3af199db3486e', '970ec4ed2db8cea218d4b7566d8c4f3b709641d3', '100644'),
               ('runtime/locks/dsh-0.2.2-rc.1/package.json', 126, 'ff39278b4a4eb3b92cb77f4b281be810bfebe24b4c9ce50b67e25959ea9c067f', 'e47e090d78c80c36dab075657581995022a20d7b', '100644'),
               ('runtime/locks/dsh-0.2.2-rc.1/package-lock.json', 410906, '9809a7a64fd5d40df441a30fb4407c037802162d75e8a8e39dc0ef2569bec2ab', '358ffdc4821b4929a16a2e464aac4115f10bc2c9', '100644'),
               (PINS, 79781, 'a0df85fd547d5e8da8b9ef20ff90e4c52fa7157f5030de66fbca170cc5b947ad', '5454cdd89828ffb91634e7098bc26530a779c848', '100644'),
               (CORE, 9564, '85d4678533627422d4c00cd7a92b6e5c1a97172a40b3b432338e0ffa579bcfe8', '58b7d30cc8f453cbabea1f2c28fb28c5785df4a7', '100644'),
               (UNI, 5416, '17f6cb4a1859084d58b0bda2daf01c01d57a3b5fcbfd75b81a37c0038e1d7f3f', '0263c9710d2aa3688942f006fa471e51d1b66be4', '100644'),
               ('runtime/tests/fixtures/turn-outline-v2-checkpoint.json', 2605, '7e03ca69dd1e4e9010c57e6a0f3ab08d662fe1251555abadf9f9092cb7159e7c', '6575ce99212f93bab044f62ac5154caf51402dc9', '100644'),
               ('runtime/tests/fixtures/native-static/assets/img/dot.png', 69, 'c06303dd848a80e9e774747ca5f185ba68129bb55e4842c72ed477340fc8100c', '1ecf6a95a27195aff6c0fe5bece265d6c1b70f6b', '100644')]
TOL = 'node_modules/@deepseek-ai/dsh-session-turn-outline/lib/'
IDX, TYPES = TOL + 'index.js', TOL + 'types/types.d.ts'
IDX_OFFICIAL = '724f09b4c13de7cfb2b0a5ed5ccf776217e9e7d08ec6f458be8784e65069d78a'  # official npm bytes, before the Unicode pin
IDX_A, IDX_B = (6088, '8df29b7ad951745340ec6d9a8af4abc77bc9b9a3d570ce4e5b0dba30e60f0e7b'), (6358, '2a6a0d9df0d403d29bac5e9d35f7d36548577c1189d18c52437013f4a43f27a9')
TYPES_PRISTINE, TYPES_FINAL = (2175, '79d16b1eddadde75e1680e61364b16043086d11989ee4473e3e3f5e1490f8e15'), (2373, '9c131aebc460fc639ec669c43a823802dd1adb4885d75e35986cf145664672e0')
NEW_PIN = {VER: {IDX: {'before': IDX_A[1], 'after': IDX_B[1]}, TYPES: {'before': TYPES_PRISTINE[1], 'after': TYPES_FINAL[1]}}}
# five direct imports of the new test: package -> (effective lib/index.js bytes, sha256) in A
DIRECT = {'cordis': (64573, 'b8b87360ebc67df2d0aabea214b8ed30d4bde3767e354ebb1b85fc6c15b45a05'),
          'dsh-session': (98637, '39c4181a4c132f42c7d639d2fdeac9a7794e92a127c789f87eb7c0f7f7db5925'),
          'dsh-session-projection': (26811, '6ed6c37be5e1bea75b0e8b01c4a58fa819297d25158107a6e051d4048c8f601b'),
          'dsh-session-turn-outline': IDX_A,
          'dsh-llm': (115365, 'd46febb9df41fb1aa818e1c0ed23507a8e82a1b7ef4a7a8dd24f29be86177c94')}
COMPANION = ('node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/dsh-go-deletion.mjs', 9564,
             '85d4678533627422d4c00cd7a92b6e5c1a97172a40b3b432338e0ffa579bcfe8')
COUNTS = {'a': (120, 170, 89), 'b': (121, 172, 90)}
NATIVE = ['@deepseek-ai/node-addon-system', '@deepseek-ai/node-addon-system-linux-x64']
PRED, SUCC, RANK = 'zzzzzzzzzzzzzzzzzzzzzz-context-summary-unicode.diff', 'zzzzzzzzzzzzzzzzzzzzzzz-image-display-name-unicode.diff', 90
ZERO = '0' * 40
bad = []


def fail(why):
    bad.append(why)


def sha(b):
    return hashlib.sha256(b).hexdigest()


def git(tree, *args, raw=False):
    r = subprocess.run(['git', '-c', 'core.autocrlf=false', '-C', tree, *args], capture_output=True)
    print('GIT %s exit=%d' % (' '.join(args), r.returncode))
    if r.returncode != 0:
        fail('git ' + ' '.join(args)); sys.stdout.write(r.stderr.decode('utf-8', 'replace'))
    return r.stdout if raw else r.stdout.decode('utf-8')


def regular_bytes(p, label):
    st = os.lstat(p) if os.path.lexists(p) else None
    if st is None or not stat.S_ISREG(st.st_mode):
        print('NOT_A_REGULAR_FILE %s %s (%s)' % (label, p, 'missing' if st is None else oct(st.st_mode)))
        fail(label + ' not a regular file')
        return None, None
    return pathlib.Path(p).read_bytes(), st


def source(tree, rel, label, want):
    b, st = regular_bytes(os.path.join(tree, rel), label)
    if b is None:
        return
    blob = git(tree, 'hash-object', '--no-filters', rel).strip()
    perm = stat.S_IMODE(st.st_mode)
    ok = (len(b), sha(b), blob) == want[:3] and b.count(b'\r') == 0 and b.endswith(b'\n') and not (perm & 0o111)
    print('%s %s %s bytes=%d sha256=%s git_blob=%s cr=%d tail_lf=%s lines=%d perm=%o (want %d/%s/%s, non-executable)' % (
        'MATCH' if ok else 'MISMATCH', label, rel, len(b), sha(b), blob, b.count(b'\r'), b.endswith(b'\n'), b.count(b'\n'), perm, *want[:3]))
    if not ok:
        fail(label)


def plain(tree, rel, n, h, label, mode=None):
    b, st = regular_bytes(os.path.join(tree, rel), rel)
    if b is None:
        return
    ok = (len(b), sha(b)) == (n, h)
    extra = ''
    if mode is not None:
        ex = bool(stat.S_IMODE(st.st_mode) & 0o100)
        okm = ex == (mode == '100755')
        extra = ' worktree_exec_bit=%s (want %s)' % (ex, mode == '100755')
        ok = ok and okm
    print('%s %s_%s bytes=%d sha256=%s (want %d/%s)%s' % ('MATCH' if ok else 'MISMATCH', label, rel, len(b), sha(b), n, h, extra))
    if not ok:
        fail('%s %s' % (label, rel))


def head(tree):
    h = git(tree, 'rev-parse', 'HEAD').strip()
    print('HEAD=%s expected=%s %s' % (h, BASE, 'MATCH' if h == BASE else 'MISMATCH'))
    if h != BASE:
        fail('HEAD')


def node_modules(tree):
    found = []
    for root, dirs, files in os.walk(tree):
        if '.git' in dirs:
            dirs.remove('.git')
        for d in list(dirs) + [f for f in files if f == 'node_modules']:
            if d == 'node_modules':
                found.append(os.path.relpath(os.path.join(root, d), tree))
        dirs[:] = [d for d in dirs if d != 'node_modules']
    print('NODE_MODULES_IN_TREE=%d %s (gate: must be 0; product tree only, the prefix is separate)' % (len(found), found))
    if found:
        fail('node_modules in tree')


def dsh_prefix():
    for k in ('DSH_PREFIX', 'DSH_TEST_PREFIX'):
        print('ENV %s=%s (must be unset for this check; the test command sets it inline only)' % (k, os.environ.get(k, '<unset>')))
        if k in os.environ:
            fail(k + ' set')


def ignored(tree):
    ign = [l for l in git(tree, 'status', '--porcelain=v1', '--untracked-files=all', '--ignored').splitlines() if l.startswith('!! ')]
    print('INFO_IGNORED_ENTRIES=%d %s (information)' % (len(ign), ign))


def patch_names(tree):
    d = os.path.join(tree, 'runtime', 'patches')
    return sorted(n for n in os.listdir(d) if n.endswith('.diff'))


def base_order(ident):
    rows = ident['patch_chain']['normal_diff_order']
    ok = ([r['rank'] for r in rows] == list(range(1, len(rows) + 1)) and all(r['path'].startswith('runtime/patches/') and r['git_mode'] == '100644' for r in rows)
          and sum(r['rc1_target_count'] for r in rows) == 170)
    if not ok:
        print('IDENTITIES_NORMAL_DIFF_ORDER_SHAPE=MISMATCH'); fail('identities normal_diff_order shape')
    return [r['path'][len('runtime/patches/'):] for r in rows]


def patch_dir(tree, grp, ident):
    names = patch_names(tree)
    base_order = globals()['base_order'](ident)
    want = list(base_order) if grp == 'a' else sorted(list(base_order) + [NEW_KEY])
    ok = names == want and len(names) == COUNTS[grp][0] and len(base_order) == 120 and base_order == sorted(base_order)
    rank = names.index(NEW_KEY) + 1 if NEW_KEY in names else None
    print('PATCH_DIR %s diff_count=%d (want %d) order_equals_identities=%s identities_base_order_sorted=%s new_inner_rank=%s %s' % (
        grp, len(names), COUNTS[grp][0], names == want, base_order == sorted(base_order), rank, 'MATCH' if ok else 'MISMATCH'))
    if not ok:
        fail('patch dir')
    if grp == 'a':
        if NEW_KEY in names:
            fail('new inner present in A')
    else:
        ci = ident['patch_chain']['candidate_inner']
        pred = names[rank - 2] if rank and rank > 1 else None
        succ = names[rank] if rank and rank < len(names) else None
        okr = (rank == RANK == ci['rank_after_insertion_1based'] and 'runtime/patches/' + str(pred) == ci['predecessor'] and pred == PRED
               and 'runtime/patches/' + str(succ) == ci['successor'] and succ == SUCC and ci['path'] == INNER)
        print('NEW_INNER_POSITION rank=%s predecessor=%s successor=%s (want %d / %s / %s) %s' % (rank, pred, succ, RANK, PRED, SUCC, 'MATCH' if okr else 'MISMATCH'))
        if not okr:
            fail('new inner rank/neighbours')


def strict_json(b):
    def hook(pairs):
        keys = [k for k, _ in pairs]
        if len(keys) != len(set(keys)):
            raise ValueError('duplicate key in %r' % keys)
        return dict(pairs)

    def nonfinite(x):
        raise ValueError('non-finite number %s' % x)
    return json.loads(b.decode('utf-8'), object_pairs_hook=hook, parse_constant=nonfinite)


def walk(pins, names):
    terminal, items, last = {}, 0, {}
    for name in names:
        want = pins['patches'].get(name, {}).get(VER)
        if want is None:
            print('NO_PIN %s' % name); fail('patch without pin %s' % name); continue
        for rel, pin in want.items():
            items += 1
            if rel in terminal and terminal[rel] != pin['before']:
                print('BROKEN_CHAIN %s %s' % (name, rel)); fail('broken chain %s' % rel)
            terminal[rel] = pin['after']
            last[rel] = name
    return terminal, items, last


def chain(tree):
    pins = strict_json(pathlib.Path(tree, PINS).read_bytes())
    terminal, items, last = walk(pins, patch_names(tree))
    return pins, terminal, items, last


def teq(a, b):
    if type(a) is not type(b):
        return False
    if isinstance(a, dict):
        return sorted(a) == sorted(b) and all(teq(a[k], b[k]) for k in a)
    if isinstance(a, list):
        return len(a) == len(b) and all(teq(x, y) for x, y in zip(a, b))
    return a == b


def lock_rows(lockb, ident, label):
    lock = strict_json(lockb)['packages']
    rows = {r['package']: r['lock_row'] for r in ident['direct_imports']}
    good = 0
    for k, row in rows.items():
        entry = lock.get(k)
        ok = entry is not None and teq(entry, row)
        good += ok
        print('%s LOCK_ROW_%s %s version=%s integrity=%s typed_equal_identities=%s' % (
            'MATCH' if ok else 'MISMATCH', label, k, None if entry is None else entry.get('version'),
            None if entry is None else entry.get('integrity'), ok))
        if not ok:
            fail('lock row ' + k)
    want_keys = sorted('node_modules/@deepseek-ai/' + p for p in DIRECT)
    print('LOCK_ROWS_%s total=%d match=%d (want 5: %s)' % (label, len(rows), good, sorted(rows) == want_keys))
    if len(rows) != 5 or good != 5 or sorted(rows) != want_keys:
        fail('lock rows count')
    return lock


def identities_cross(ident):
    m = {r['repository_path']: r for r in ident['base_repository_inputs']}
    ok = len(m) == 10 and all(p in m and (m[p]['bytes'], m[p]['sha256'], m[p]['git_blob'], m[p]['git_mode'], m[p]['e5d_tree_match']) == (n, h, bl, md, True)
                              for p, n, h, bl, md in BASE_INPUTS)
    print('BASE_INPUTS_REQUEST_EQUALS_IDENTITIES=%s (10 rows: bytes/sha256/git_blob/mode)' % ok)
    if not ok:
        fail('base inputs vs identities')
    cs = ident['candidate_sources']
    byp = {(c.get('repository_path') or c.get('target')): c for c in cs}
    ok2 = (len(cs) == 4 and all(p in byp and (byp[p]['bytes'], byp[p]['sha256']) == FINAL[p][:2] for p in (TEST, UNI))
           and (byp[IDX]['bytes'], byp[IDX]['sha256']) == IDX_B and (byp[TYPES]['bytes'], byp[TYPES]['sha256']) == TYPES_FINAL)
    inner = ident['raw_sources']['inner']
    ok2 = ok2 and (inner['repository_path'], inner['bytes'], inner['sha256'], inner['git_blob'], inner['git_mode']) == (INNER, *FINAL[INNER][:3], '100644')
    print('CANDIDATE_SOURCES_AND_INNER_REQUEST_EQUALS_IDENTITIES=%s' % ok2)
    if not ok2:
        fail('candidate sources vs identities')
    be = {r['target']: (r['bytes'], r['sha256']) for r in ident['base_effective_target_sources']}
    xu = ident['patch_chain']['A_extra_unpinned_identity']
    ok3 = be == {IDX: IDX_A, TYPES: TYPES_PRISTINE} and (xu['target'], xu['bytes'], xu['sha256']) == (TYPES, *TYPES_PRISTINE)
    pc = ident['patch_chain']
    re_ = pc['record_expected_only']
    ok4 = (teq({VER: re_['only_target_pairs']}, NEW_PIN) and re_['only_added_patch_key'] == NEW_KEY and re_['only_version'] == VER
           and (re_['normal_diff_count'], re_['rc1_pair_rows'], re_['terminal_targets']) == (121, 172, 90)
           and (pc['A']['normal_diff_count'], pc['A']['rc1_pair_rows'], pc['A']['terminal_targets']) == (120, 170, 89))
    ta, tb = pc['A_terminal_target_sha256'], pc['B_predicted_terminal_target_sha256']
    ok5 = (len(ta) == 89 and len(tb) == 90 and ta.get(IDX) == IDX_A[1] and TYPES not in ta and tb.get(IDX) == IDX_B[1]
           and tb.get(TYPES) == TYPES_FINAL[1] and set(tb) == set(ta) | {TYPES} and all(tb[k] == v for k, v in ta.items() if k != IDX))
    di = {r['package'].split('/')[-1]: (r['current_effective_source']['bytes'], r['current_effective_source']['sha256']) for r in ident['direct_imports']}
    ok6 = di == DIRECT
    co = ident['companion']
    ok7 = (co['prefix_path'], co['source']['bytes'], co['source']['sha256']) == COMPANION
    print('IDENTITIES_EFFECTIVE_SOURCES=%s NEW_PIN_REQUIREMENT_AND_COUNTS=%s TERMINALS_89_90_ONLY_INDEX_CHANGED_TYPES_ADDED=%s DIRECT_IMPORTS_5=%s COMPANION=%s' % (
        ok3, ok4, ok5, ok6, ok7))
    if not (ok3 and ok4 and ok5 and ok6 and ok7):
        fail('identities targets/pin/direct/companion')


# ------------------------------------------------------------------ modes
mode = sys.argv[1]
if mode == 'pre':
    tree, ident = sys.argv[2], json.load(open(sys.argv[3], encoding='utf-8'))
    head(tree)
    st = git(tree, 'status', '--porcelain=v1', '--untracked-files=all', raw=True)
    print('STATUS_BYTES=%d (must be 0: tracked and non-ignored untracked)' % len(st))
    if st:
        sys.stdout.write(st.decode('utf-8', 'replace')); fail('clean')
    identities_cross(ident)
    for rel, n, h, blob_w, mode_w in BASE_INPUTS:
        plain(tree, rel, n, h, 'BASE_INPUT', mode_w)
        lt = git(tree, 'ls-tree', '--full-tree', BASE, '--', rel).strip()
        want_lt = '%s blob %s\t%s' % (mode_w, blob_w, rel)
        print('%s BASE_TREE_ENTRY %s (want %s)' % ('MATCH' if lt == want_lt else 'MISMATCH', lt.replace('\t', '<TAB>'), want_lt.replace('\t', '<TAB>')))
        if lt != want_lt:
            fail('base tree entry ' + rel)
    lock_rows(pathlib.Path(tree, 'runtime/locks/dsh-0.2.2-rc.1/package-lock.json').read_bytes(), ident, 'TREE')
    for rel in sorted(ADDED):
        ex = os.path.lexists(os.path.join(tree, rel))
        print('NEW_PATH_PRESENT_BEFORE_APPLY %s=%s (must be False)' % (rel, ex))
        if ex:
            fail('present before apply ' + rel)
    patch_dir(tree, 'a', ident)
    lt = {l.split('\t')[1]: l.split('\t')[0] for l in git(tree, 'ls-tree', '--full-tree', BASE, '--', 'runtime/patches/').splitlines() if l.endswith('.diff')}
    rows = ident['patch_chain']['normal_diff_order']
    okb = len(lt) == 120 and all(lt.get(r['path']) == '100644 blob %s' % r['git_blob'] for r in rows)
    print('%s BASE_TREE_INNER_DIFFS count=%d mode_blob_equal_identities=%s' % ('MATCH' if okb else 'MISMATCH', len(lt), okb))
    if not okb:
        fail('base inner diff blobs')
    ignored(tree)
    node_modules(tree)
    dsh_prefix()
elif mode == 'post':
    tree, rawp, grp, label, outp, outs, identp = sys.argv[2:9]
    ident = json.load(open(identp, encoding='utf-8'))
    head(tree)
    diff = git(tree, 'diff', '--full-index', '--binary', '--no-ext-diff', BASE, '--', raw=True)
    pathlib.Path(outp).write_bytes(diff)
    rb = pathlib.Path(rawp).read_bytes()
    if grp == 'brec':
        print('DIFF_VS_BASE_%s bytes=%d sha256=%s (complete diff, pins.json change included; saved unfiltered)' % (label, len(diff), sha(diff)))
        ex = git(tree, 'diff', '--full-index', '--binary', '--no-ext-diff', BASE, '--', '.', ':(exclude)%s' % PINS, raw=True)
        same = ex == rb
        print('DIFF_VS_BASE_EXCLUDING_EXACT_PINS_PATH_%s bytes=%d sha256=%s raw=%s raw_bytes=%d raw_sha256=%s %s' % (
            label, len(ex), sha(ex), os.path.basename(rawp), len(rb), sha(rb), 'BYTE_EQUAL_RAW' if same else 'DIFFERS'))
        pd = git(tree, 'diff', '--full-index', '--binary', '--no-ext-diff', BASE, '--', PINS, raw=True)
        cat = diff == pd + ex or diff == ex + pd
        print('DIFF_PINS_ONLY_%s bytes=%d sha256=%s (concatenation check: whole == pins part + rest %s)' % (label, len(pd), sha(pd), cat))
        if not cat:
            fail('whole diff is not pins part plus FULL part')
    else:
        same = diff == rb
        print('DIFF_VS_BASE_%s bytes=%d sha256=%s raw=%s raw_bytes=%d raw_sha256=%s %s' % (
            label, len(diff), sha(diff), os.path.basename(rawp), len(rb), sha(rb), 'BYTE_EQUAL_RAW' if same else 'DIFFERS'))
    if not same:
        fail('diff != raw')
    paths = GROUP_PATHS[grp]
    names = git(tree, 'diff', '--name-only', BASE, '--').split()
    print('CHANGED_PATHS_VS_BASE=%s %s' % (names, 'MATCH' if names == sorted(paths) else 'MISMATCH'))
    if names != sorted(paths):
        fail('paths')
    want_raw = []
    for p in sorted(paths):
        if p in ADDED:
            want_raw.append(':000000 100644 %s %s A\t%s' % (ZERO, ZERO, p))
        else:
            want_raw.append(':100644 100644 %s %s M\t%s' % (BASE_BLOB[p], ZERO, p))
    rawd = git(tree, 'diff', '--raw', '--no-abbrev', BASE, '--').splitlines()
    print('RAWDIFF=%s %s' % ([l.replace('\t', '<TAB>') for l in rawd], 'MATCH' if rawd == want_raw else 'MISMATCH'))
    if rawd != want_raw:
        fail('raw diff/mode')
    num = git(tree, 'diff', '--numstat', BASE, '--').splitlines()
    want_num = ['%d\t%d\t%s' % (FINAL[p][3], FINAL[p][4], p) for p in sorted(paths) if p != PINS]
    num_cmp = [l for l in num if not l.endswith('\t' + PINS)]
    print('NUMSTAT=%s %s%s' % ([l.replace('\t', '<TAB>') for l in num], 'MATCH' if num_cmp == want_num else 'MISMATCH',
                               ' (pins.json numstat is information only)' if grp == 'brec' else ''))
    if num_cmp != want_num:
        fail('numstat')
    stb = git(tree, 'status', '--porcelain=v1', '--untracked-files=all', raw=True)
    pathlib.Path(outs).write_bytes(stb)
    want_st = ''.join(' %s %s\n' % ('A' if p in ADDED else 'M', p) for p in sorted(paths)).encode()
    print('STATUS_RAW bytes=%d sha256=%s lines=%s %s (raw-byte comparison, unfiltered)' % (
        len(stb), sha(stb), stb.decode('utf-8', 'replace').splitlines(), 'BYTE_EQUAL' if stb == want_st else 'DIFFERS'))
    if stb != want_st:
        fail('status')
    for p in sorted(ADDED):
        ita = git(tree, 'ls-files', '--stage', '--', p).splitlines()
        if p in paths:
            print('INDEX_ENTRY %s=%s (intent-to-add entry from git add -N)' % (p, [l.replace('\t', '<TAB>') for l in ita]))
            if len(ita) != 1 or not ita[0].startswith('100644 '):
                fail('index entry ' + p)
        else:
            print('ABSENT_IN_GROUP %s present=%s index=%s (must be absent)' % (p, os.path.lexists(os.path.join(tree, p)), ita))
            if os.path.lexists(os.path.join(tree, p)) or ita:
                fail('unexpected path ' + p)
    staged = git(tree, 'diff', '--cached', '--name-only', BASE, '--').split()
    print('INFO_INDEX_VS_BASE_NAMES=%s (intent-to-add only; nothing staged with content)' % staged)
    for p in sorted(paths):
        if p != PINS:
            source(tree, p, 'FINAL_%s' % label, FINAL[p])
    for rel, n, h, _, mode_w in BASE_INPUTS:
        if rel in paths:
            continue  # changed by this group's raw (Unicode test in B, pins after record); checked above
        plain(tree, rel, n, h, 'INPUT_%s' % label, mode_w)
    lock_rows(pathlib.Path(tree, 'runtime/locks/dsh-0.2.2-rc.1/package-lock.json').read_bytes(), ident, 'TREE_' + label)
    patch_dir(tree, 'a' if grp == 'a' else 'b', ident)
    ignored(tree)
    node_modules(tree)
    dsh_prefix()
elif mode == 'pristine':
    prefix, label = sys.argv[2:4]
    for rel, want_p, what in ((TYPES, TYPES_PRISTINE, 'official unpinned types.d.ts'), (IDX, (None, IDX_OFFICIAL), 'official index.js before the Unicode pin')):
        b, _ = regular_bytes(os.path.join(prefix, rel), rel)
        if b is not None:
            ok = sha(b) == want_p[1] and (want_p[0] is None or len(b) == want_p[0])
            print('%s PRISTINE_%s %s bytes=%d sha256=%s tail_lf=%s (want %s/%s, %s, before any patch-dsh)' % (
                'MATCH' if ok else 'MISMATCH', label, rel, len(b), sha(b), b.endswith(b'\n'), want_p[0], want_p[1], what))
            if not ok:
                fail('pristine ' + rel)
elif mode == 'prefix':
    tree, prefix, grp, label, identp, pins_sha = sys.argv[2:8]
    ident = json.load(open(identp, encoding='utf-8'))
    print('PREFIX=%s TREE=%s GROUP=%s' % (prefix, tree, grp.upper()))
    for rel, n, h, _, _ in BASE_INPUTS[3:5]:
        pb, _ = regular_bytes(os.path.join(prefix, os.path.basename(rel)), 'prefix ' + os.path.basename(rel))
        tb, _ = regular_bytes(os.path.join(tree, rel), 'tree ' + rel)
        ok = pb is not None and pb == tb and (len(pb), sha(pb)) == (n, h)
        print('%s PREFIX_COPY_%s %s bytes=%s sha256=%s byte_equal_tree=%s (want %d/%s)' % (
            'MATCH' if ok else 'MISMATCH', label, os.path.basename(rel), None if pb is None else len(pb),
            None if pb is None else sha(pb), pb == tb, n, h))
        if not ok:
            fail('prefix copy ' + rel)
    tp = pathlib.Path(tree, PINS).read_bytes()
    ok = sha(tp) == pins_sha
    print('%s TREE_PINS_%s %s bytes=%d sha256=%s (want sha256 %s)' % ('MATCH' if ok else 'MISMATCH', label, PINS, len(tp), sha(tp), pins_sha))
    if not ok:
        fail('tree pins identity')
    pins, terminal, items, last = chain(tree)
    n_diff, n_items, n_targets = COUNTS[grp]
    print('PATCH_CHAIN_%s diffs=%d (want %d) pin_items=%d (want %d) final_targets=%d (want %d)' % (
        label, len(patch_names(tree)), n_diff, items, n_items, len(terminal), n_targets))
    if len(patch_names(tree)) != n_diff or items != n_items or len(terminal) != n_targets:
        fail('chain counts')
    expect = ident['patch_chain']['A_terminal_target_sha256'] if grp == 'a' else ident['patch_chain']['B_predicted_terminal_target_sha256']
    good = 0
    for rel in sorted(terminal):
        b, _ = regular_bytes(os.path.join(prefix, rel), rel)
        h = None if b is None else sha(b)
        okf = h == terminal[rel] == expect.get(rel)
        good += okf
        print('%s FINAL_TARGET_%s %s sha256=%s chain=%s identities=%s last_patch=%s' % (
            'MATCH' if okf else 'MISMATCH', label, rel, h, terminal[rel], expect.get(rel), last[rel]))
        if not okf:
            fail('final target ' + rel)
    print('FINAL_TARGETS_%s total=%d match=%d (chain from tree pins.json == prefix file == identities expectation)' % (label, len(terminal), good))
    if set(terminal) != set(expect):
        fail('final target set differs from identities')
    for pkg, want_d in DIRECT.items():
        if pkg == 'dsh-session-turn-outline' and grp == 'b':
            want_d = IDX_B
        rel = 'node_modules/@deepseek-ai/%s/lib/index.js' % pkg
        b, _ = regular_bytes(os.path.join(prefix, rel), rel)
        if b is not None:
            okd = (len(b), sha(b)) == want_d
            print('%s DIRECT_IMPORT_%s %s bytes=%d sha256=%s pinned_target=%s (want %d/%s; full-byte check)' % (
                'MATCH' if okd else 'MISMATCH', label, rel, len(b), sha(b), rel in terminal, *want_d))
            if not okd:
                fail('direct import ' + pkg)
    b, _ = regular_bytes(os.path.join(prefix, TYPES), TYPES)
    if b is not None:
        want_t = TYPES_PRISTINE if grp == 'a' else TYPES_FINAL
        okt = (len(b), sha(b)) == want_t and ((TYPES not in terminal) if grp == 'a' else (terminal.get(TYPES) == TYPES_FINAL[1]))
        print('%s TYPES_%s %s bytes=%d sha256=%s tail_lf=%s in_pinned_targets=%s (want %d/%s, %s; full-byte check)' % (
            'MATCH' if okt else 'MISMATCH', label, TYPES, len(b), sha(b), b.endswith(b'\n'), TYPES in terminal, *want_t,
            'separate unpinned official source, no 90th pin' if grp == 'a' else 'recorded new pinned target'))
        if not okt:
            fail('types target')
    comp, cst = regular_bytes(os.path.join(prefix, COMPANION[0]), 'companion')
    tcore = pathlib.Path(tree, CORE).read_bytes()
    if comp is not None:
        okc = comp == tcore and (len(comp), sha(comp)) == COMPANION[1:]
        print('%s COMPANION_%s %s bytes=%d sha256=%s perm=%o byte_equal_tree_core=%s (want %d/%s)' % (
            'MATCH' if okc else 'MISMATCH', label, COMPANION[0], len(comp), sha(comp), stat.S_IMODE(cst.st_mode), comp == tcore, *COMPANION[1:]))
        if not okc:
            fail('companion')
    lock = lock_rows(pathlib.Path(prefix, 'package-lock.json').read_bytes(), ident, 'PREFIX_' + label)
    names = ['@deepseek-ai/' + k for k in DIRECT] + ['@deepseek-ai/dsh', '@deepseek-ai/dsh-session-persistence-jsonl'] + NATIVE
    seen = set()
    for name in names:
        if name in seen:
            continue
        seen.add(name)
        entry = lock.get('node_modules/' + name, {})
        p = os.path.join(prefix, 'node_modules', *name.split('/'), 'package.json')
        pb, _ = regular_bytes(p, 'package.json of ' + name)
        v = None if pb is None else json.loads(pb.decode('utf-8')).get('version')
        okp = v is not None and v == entry.get('version') and (name not in NATIVE or v == '0.1.2')
        print('%s PACKAGE_%s %s installed=%s lock=%s optional=%s resolved=%s integrity=%s package_json_sha256=%s' % (
            'MATCH' if okp else 'MISMATCH', label, name, v, entry.get('version'), entry.get('optional', False),
            entry.get('resolved'), entry.get('integrity'), None if pb is None else sha(pb)))
        if not okp:
            fail('package ' + name)
    rows = []
    d = os.path.join(prefix, 'node_modules', '@deepseek-ai', 'node-addon-system-linux-x64')
    for root, dirs, files in os.walk(d):
        dirs.sort()
        for f in sorted(files):
            p = os.path.join(root, f)
            st = os.lstat(p)
            rows.append((os.path.relpath(p, d).replace(os.sep, '/'), st.st_size, stat.S_IMODE(st.st_mode),
                         sha(pathlib.Path(p).read_bytes()) if stat.S_ISREG(st.st_mode) else '-', stat.S_ISREG(st.st_mode)))
    natives = [r for r in rows if r[0].endswith('.node') and r[4] and r[1] > 0]
    print('NATIVE_FILES_%s=%d %s (gate: at least one non-empty regular *.node file in the linux-x64 package)' % (
        label, len(natives), [(r[0], r[1], r[3]) for r in natives]))
    if not natives:
        fail('no native .node file')
    hidden = pathlib.Path(prefix, 'node_modules', '.package-lock.json')
    if hidden.is_file():
        print('INFO_HIDDEN_LOCK node_modules/.package-lock.json bytes=%d sha256=%s' % (hidden.stat().st_size, sha(hidden.read_bytes())))
elif mode == 'pins':
    op, np_, identp = sys.argv[2:5]
    ident = json.load(open(identp, encoding='utf-8'))
    ob, nb = pathlib.Path(op).read_bytes(), pathlib.Path(np_).read_bytes()
    print('ORIGINAL_PINS bytes=%d sha256=%s (want %d/%s)' % (len(ob), sha(ob), *PINS_ORIG[:2]))
    print('RECORDED_PINS bytes=%d sha256=%s cr=%d tail_lf=%s' % (len(nb), sha(nb), nb.count(b'\r'), nb.endswith(b'\n')))
    if (len(ob), sha(ob)) != PINS_ORIG[:2]:
        fail('original pins identity')
    try:
        o, n = strict_json(ob), strict_json(nb)
    except ValueError as e:
        print('STRICT_JSON_REJECTED %s' % e); fail('strict json: %s' % e); o = n = None
    if o is not None:
        top_ok = isinstance(n, dict) and sorted(n) == sorted(o) and all(teq(n[k], o[k]) for k in o if k != 'patches')
        print('TOP_KEYS original=%s recorded=%s non_patches_values_typed_equal=%s' % (sorted(o), sorted(n) if isinstance(n, dict) else type(n).__name__, top_ok))
        if not top_ok:
            fail('top-level keys/values')
        np_ok = isinstance(n, dict) and isinstance(n.get('patches'), dict)
        added = sorted(set(n['patches']) - set(o['patches'])) if np_ok else None
        removed = sorted(set(o['patches']) - set(n['patches'])) if np_ok else None
        changed = sorted(k for k in o['patches'] if np_ok and k in n['patches'] and not teq(o['patches'][k], n['patches'][k]))
        print('PATCH_KEYS original=%d recorded=%s added=%s removed=%s changed_existing(typed whole value, all versions)=%s' % (
            len(o['patches']), len(n['patches']) if np_ok else None, added, removed, changed))
        if added != [NEW_KEY] or removed or changed:
            fail('patches key set / existing values')
        e = n['patches'].get(NEW_KEY) if np_ok else None
        ok_e = (isinstance(e, dict) and list(e) == [VER] and isinstance(e[VER], dict) and sorted(e[VER]) == sorted([IDX, TYPES])
                and all(isinstance(e[VER][t], dict) and sorted(e[VER][t]) == ['after', 'before']
                        and all(isinstance(e[VER][t][k], str) for k in ('before', 'after')) for t in (IDX, TYPES))
                and teq(e, NEW_PIN) and teq(e[VER], ident['patch_chain']['record_expected_only']['only_target_pairs']))
        print('RECORDED_NEW_ENTRY %s %s' % (json.dumps({NEW_KEY: e}, sort_keys=True), 'MATCH' if ok_e else 'MISMATCH'))
        print('  recorded target order=%s' % (list(e[VER]) if isinstance(e, dict) and isinstance(e.get(VER), dict) else None))
        print('  want %s before=%s after=%s; %s before=%s (official unpinned) after=%s' % (IDX, IDX_A[1], IDX_B[1], TYPES, TYPES_PRISTINE[1], TYPES_FINAL[1]))
        if not ok_e:
            fail('new entry')
        items = sum(len(v.get(VER, {})) for v in n['patches'].values() if isinstance(v, dict)) if np_ok else None
        items_o = sum(len(v.get(VER, {})) for v in o['patches'].values() if isinstance(v, dict))
        print('RC1_ENTRIES original=%d (want 170) recorded=%s (want 172)' % (items_o, items))
        if items_o != 170 or items != 172:
            fail('rc1 entry counts')
        order = base_order(ident)
        to, _, _ = walk(o, list(order))
        tn, _, _ = walk(n, sorted(list(order) + [NEW_KEY])) if np_ok else ({}, 0, {})
        only_new = sorted(set(tn) - set(to))
        diffs = sorted(k for k in to if tn.get(k) != to[k])
        same = sum(1 for k in to if tn.get(k) == to[k])
        okt = (len(to) == 89 and len(tn) == 90 and only_new == [TYPES] and diffs == [IDX] and same == 88
               and teq(to, ident['patch_chain']['A_terminal_target_sha256']) and teq(tn, ident['patch_chain']['B_predicted_terminal_target_sha256']))
        print('TERMINALS original=%d recorded=%d added=%s changed=%s unchanged=%d equal_identities_A_B=%s %s' % (
            len(to), len(tn), only_new, diffs, same, okt, 'MATCH' if okt else 'MISMATCH'))
        if not okt:
            fail('terminal targets')
        whole = teq(dict(n, patches={k: v for k, v in n['patches'].items() if k != NEW_KEY}), o) if np_ok else False
        print('INFO_RECORDED_MINUS_NEW_ENTRY_TYPED_EQUAL_ORIGINAL=%s (consequence of the gates above, not the gate itself)' % whole)
        redump = (json.dumps(n, indent=2, sort_keys=True) + '\n').encode()
        print('INFO_RECORDED_BYTES_EQUAL_CANONICAL_DUMP=%s' % (redump == nb))
elif mode == 'patchlog':
    tree, logp, kind, label = sys.argv[2:6]
    pins = strict_json(pathlib.Path(tree, PINS).read_bytes())
    lines = pathlib.Path(logp).read_bytes().decode('utf-8').splitlines()
    pat = re.compile(r'^(\S+\.diff): patched (\S+) \(([0-9a-f]{12}) -> ([0-9a-f]{12})\)$')
    names = patch_names(tree)
    seen, order_ok, prev, other = [], True, -1, []
    for l in lines:
        m = pat.match(l)
        if m:
            name, rel, b12, a12 = m.groups()
            idx = names.index(name) if name in names else -1
            if idx < prev:
                order_ok = False
            prev = idx
            pin = pins['patches'].get(name, {}).get(VER, {}).get(rel)
            okl = pin is not None and pin['before'][:12] == b12 and pin['after'][:12] == a12
            if not okl:
                print('PATCHLOG_LINE_MISMATCH %s' % l); fail('patch log line %s %s' % (name, rel))
            seen.append((name, rel))
        else:
            other.append(l)
    want = sorted((name, rel) for name in names for rel in pins['patches'].get(name, {}).get(VER, {}))
    print('PATCHLOG_%s kind=%s patched_lines=%d (want %d) unique=%d patches_seen=%d of %d sorted_order=%s already_patched=%d other_lines=%s' % (
        label, kind, len(seen), len(want), len(set(seen)), len({s[0] for s in seen}), len(names), order_ok,
        sum(1 for l in other if l.endswith(' already patched')), other))
    if sorted(seen) != want or len(seen) != len(set(seen)) or not order_ok:
        fail('patch log coverage/order')
    if kind == 'record':
        if len(other) != 1 or not other[0].startswith('recorded pins for DSH %s in ' % VER) or not other[0].endswith('/runtime/lib/../patches/pins.json'):
            fail('record summary line')
    elif other:
        fail('unexpected patch log lines')
elif mode == 'prerecord':
    tree = sys.argv[2]
    pb = pathlib.Path(tree, PINS).read_bytes()
    print('PRE_RECORD_TREE_PINS bytes=%d sha256=%s (want %d/%s)' % (len(pb), sha(pb), *PINS_ORIG[:2]))
    if (len(pb), sha(pb)) != PINS_ORIG[:2]:
        fail('pre-record pins identity')
    pins = strict_json(pb)
    names = patch_names(tree)
    unpinned = [n for n in names if VER not in pins['patches'].get(n, {})]
    terminal, items = {}, 0
    for name in names:
        for rel, pin in pins['patches'].get(name, {}).get(VER, {}).items():
            items += 1
            if rel in terminal and terminal[rel] != pin['before']:
                fail('broken chain %s' % rel)
            terminal[rel] = pin['after']
    print('PRE_RECORD diffs=%d (want 121) rc1_pin_items=%d (want 170) final_targets=%d (want 89) unpinned=%s (want [%s]) new_key_in_pins=%s (want False) types_in_targets=%s (want False)' % (
        len(names), items, len(terminal), unpinned, NEW_KEY, NEW_KEY in pins['patches'], TYPES in terminal))
    if len(names) != 121 or items != 170 or len(terminal) != 89 or unpinned != [NEW_KEY] or NEW_KEY in pins['patches'] or TYPES in terminal:
        fail('pre-record counts')
else:
    print('unknown mode'); sys.exit(2)

print('IDENT_%s=%s %s' % (mode.upper(), 'PASS' if not bad else 'FAIL', bad))
sys.exit(0 if not bad else 1)
