# reverse request 078 pre-push dry run of tap078.py (pure text; no product code, no Node). usage:
#   dryrun078.py <tap078.py> <real 076 A stdout> <real 076 B stdout> <real 075 B stdout> <work dir>
# From core20-076 dryrun076.py. Real Node 24 samples (076 A/B and 075 B raw TAP) must give FAIL (exit 3, wrong names/
# TRACE) with no YAML problem and no internal error; synthetic 078-shaped positives (R1 numeric-key map "0", R2 bare
# "expected:" followed by same-indent "actual:") must PASS; every negative, including the R1/R2 shape negatives, must
# FAIL (exit 3).
import json
import os
import subprocess
import sys

TAP, S076A, S076B, S075B, WD = sys.argv[1:6]
os.makedirs(WD, exist_ok=True)
R1N = 'R1: first image-only human prompt stays empty after same-turn steer'
R2N = 'R2: synthetic version3 checkpoint is rejected and full public log replays'
C1N = 'C1: text prompt, new turn and current checkpoint round trip preserve outline'
NEW = [R1N, R2N, C1N]
LEGACY = ['prompt final: public turnOutline preserves scalar text and UTF16 budgets',
          'response final: public turnOutline preserves scalar text and UTF16 budgets',
          'prompt inner: public turnOutline preserves scalar text and UTF16 budgets',
          'response inner: public turnOutline preserves scalar text and UTF16 budgets',
          'ASCII budgets: public turnOutline preserves scalar text and UTF16 budgets',
          'short Unicode: public turnOutline preserves scalar text and UTF16 budgets',
          'complete pair before cut: public turnOutline preserves scalar text and UTF16 budgets',
          'multiblock whitespace and response commit preserve three wire changes',
          'actual version2 checkpoint requires replay and leaves source events unchanged']
STEER = {'turn': 1, 'seq': 0, 'prompt': 'later steering text', 'response': ''}
EMPTY = {'turn': 1, 'seq': 0, 'prompt': '', 'response': ''}
F = '/home/runner/work/_temp/tree-A/runtime/tests/turn-outline-first-human.test.mjs'


def tap_escape(s):
    return s.replace('\\', '\\\\').replace('#', '\\#')


def evs(n):
    return [{'seq': k, 'type': 'turn/start' if k == 0 else 'x', 'data': {'turn': 1}} for k in range(n)]


def obs(stage, value):
    return {'stage': stage, 'value': value, 'checkpoint': {'turnOutline': {'ver': 4, 'seq': 1, 'val': {'turns': value, 'draft': '', 'promptSeen': True}}}}


def trace(stage, name, mutate=None):
    tr = {'case': name, 'acceptedEvents': [], 'observations': [], 'changes': [], 'loggerMessages': [], 'fixtureFailures': []}
    if name == R1N:
        if stage == 'A':
            tr['acceptedEvents'] = evs(8); tr['observations'] = [obs('before first semantic oracle', [dict(STEER)])]
            tr['changes'] = [{'seq': 0, 'value': [dict(EMPTY)]}, {'seq': 7, 'value': [dict(STEER)]}]
        else:
            tr['acceptedEvents'] = evs(10)
            tr['observations'] = [obs('before first semantic oracle', [dict(EMPTY)]), obs('settled response', [dict(EMPTY, response='first response')])]
            tr['changes'] = [{'seq': 0, 'value': [dict(EMPTY)]}, {'seq': 9, 'value': [dict(EMPTY, response='first response')]}]
    elif name == R2N:
        tr['acceptedEvents'] = evs(6)
        tr['observations'] = [obs('actual public checkpoint independent of synthetic row', [dict(STEER if stage == 'A' else EMPTY)])]
        tr['syntheticVersion3Checkpoint'] = {'turnOutline': {'ver': 3, 'seq': 5, 'val': {'turns': [dict(STEER)], 'draft': ''}}}
        if stage == 'A':
            tr['oldCheckpointView'] = {'turnOutline': [dict(STEER)]}
        else:
            tr['oldCheckpointView'] = {}
            tr['restored'] = {'snapshot': {'values': {'turnOutline': [dict(EMPTY)]}}, 'checkpoint': {'turnOutline': {'ver': 4}}}
    else:
        tr['acceptedEvents'] = evs(17)
        tr['observations'] = [obs(s, []) for s in ['empty current checkpoint', 'draft keeps first human text', 'draft current checkpoint',
                                                    'ended current turn', 'ended current checkpoint', 'genuinely new turn']]
    if mutate:
        mutate(tr)
    return tr


def tline(tr, raw=None):
    return '# TURN_OUTLINE_TRACE ' + tap_escape(raw if raw is not None else json.dumps(tr, separators=(',', ':')))


R1_BLOCK = ['  ---', '  duration_ms: 31.5', "  type: 'test'", "  location: '%s:127:1'" % F, "  failureType: 'testCodeFailure'",
            '  error: |-', '    Expected values to be strictly deep-equal:', '    + actual - expected', '    ', '      [', '        {',
            "    +     prompt: 'later steering text',", "    -     prompt: '',", "          response: '',", '          seq: 0,',
            '          turn: 1', '        }', '      ]', '    ', "  code: 'ERR_ASSERTION'", "  name: 'AssertionError'",
            '  expected:', '    0:', '      turn: 1', '      seq: 0', "      prompt: ''", "      response: ''",
            '  actual:', '    0:', '      turn: 1', '      seq: 0', "      prompt: 'later steering text'", "      response: ''",
            "  operator: 'deepStrictEqual'", '  stack: |-',
            '    TestContext.<anonymous> (file://%s:139:10)' % F,
            '    async Test.run (node:internal/test_runner/test:1409:7)',
            '    async Test.processPendingSubtests (node:internal/test_runner/test:974:7)', '  ...']
R2_BLOCK = ['  ---', '  duration_ms: 12.25', "  type: 'test'", "  location: '%s:147:1'" % F, "  failureType: 'testCodeFailure'",
            '  error: |-', '    Expected values to be strictly deep-equal:', '    + actual - expected', '    ', '    + {',
            '    +   turnOutline: [', '    +     {', "    +       prompt: 'later steering text',", "    +       response: '',",
            '    +       seq: 0,', '    +       turn: 1', '    +     }', '    +   ]', '    + }', '    - {}', '    ',
            "  code: 'ERR_ASSERTION'", "  name: 'AssertionError'", '  expected:', '  actual:', '    turnOutline:', '      0:',
            '        turn: 1', '        seq: 0', "        prompt: 'later steering text'", "        response: ''",
            "  operator: 'deepStrictEqual'", '  stack: |-',
            '    TestContext.<anonymous> (file://%s:165:10)' % F,
            '    async Test.run (node:internal/test_runner/test:1409:7)',
            '    async Test.processPendingSubtests (node:internal/test_runner/test:974:7)', '  ...']


def build(stage, traces=None, blocks=None, statuses=None, extra=None, summary=None, plan=None, names=None, trace_before=False):
    blocks = blocks or {}
    lines = ['TAP version 13']
    cases = NEW + (LEGACY if stage == 'B' else [])
    if names:
        cases = names
    fails = 0
    for i, n in enumerate(cases):
        st = 'not ok' if (stage == 'A' and n in (R1N, R2N)) else 'ok'
        if statuses and n in statuses:
            st = statuses[n]
        fails += st == 'not ok'
        lines.append('# Subtest: ' + n)
        t = None
        if n in NEW:
            t = traces[n] if traces is not None and n in traces else tline(trace(stage, n))
        if trace_before and t is not None:
            lines += t if isinstance(t, list) else [t]
        lines.append('%s %d - %s' % (st, i + 1, n))
        if n in blocks:
            lines += blocks[n]
        elif st == 'not ok' and stage == 'A' and n == R1N:
            lines += R1_BLOCK
        elif st == 'not ok' and stage == 'A' and n == R2N:
            lines += R2_BLOCK
        elif st == 'not ok':
            lines += ['  ---', '  duration_ms: 3.1', "  type: 'test'", "  failureType: 'testCodeFailure'", "  error: 'boom'", "  code: 'ERR_TEST_FAILURE'", '  ...']
        else:
            lines += ['  ---', '  duration_ms: 20.25', "  type: 'test'", '  ...']
        if not trace_before and t is not None:
            lines += t if isinstance(t, list) else [t]
    if extra:
        lines += extra
    n = len(cases)
    lines.append('1..%d' % (plan if plan is not None else n))
    sm = summary or {'tests': n, 'suites': 0, 'pass': n - fails, 'fail': fails, 'cancelled': 0, 'skipped': 0, 'todo': 0, 'duration_ms': 845.6}
    for k2 in ('tests', 'suites', 'pass', 'fail', 'cancelled', 'skipped', 'todo', 'duration_ms'):
        lines.append('# %s %s' % (k2, sm[k2]))
    return '\n'.join(lines) + '\n'


def trm(stage, name, fn):
    return {name: tline(trace(stage, name, fn))}


def rep(block, old, new):
    out = [l.replace(old, new) for l in block]
    assert out != block, (old, new)
    return out


def r2_expected(lines_for_expected):
    k = R2_BLOCK.index('  expected:')
    return R2_BLOCK[:k] + lines_for_expected + R2_BLOCK[k + 1:]


A, B = 'A', 'B'
cases = []  # (id, stage, stdout text or path, stderr text, rc, expected verdict)
cases.append(('REAL076A_as_A', A, ('path', S076A), '', '1', 'FAIL'))
cases.append(('REAL076B_as_B', B, ('path', S076B), '', '0', 'FAIL'))
cases.append(('REAL075B_as_B', B, ('path', S075B), '', '0', 'FAIL'))
cases.append(('P1_A_expected', A, build(A), '', '1', 'PASS'))
cases.append(('P2_B_expected', B, build(B), '', '0', 'PASS'))
cases.append(('P3_A_no_operator', A, build(A, blocks={R1N: [l for l in R1_BLOCK if 'operator' not in l], R2N: [l for l in R2_BLOCK if 'operator' not in l]}), '', '1', 'PASS'))
cases.append(('P4_B_node_warning_stderr', B, build(B), "(node:2345) ExperimentalWarning: something is experimental\n(Use `node --trace-warnings ...` to show where the warning was created)\n", '0', 'PASS'))
cases.append(('P5_A_trace_before_point', A, build(A, trace_before=True), '', '1', 'PASS'))
cases.append(('P6_B_legacy_file_first', B, build(B, names=LEGACY + NEW), '', '0', 'PASS'))
cases.append(('P7_B_trace_after_plan', B, build(B, traces={C1N: None}).replace('1..12\n', '1..12\n' + tline(trace(B, C1N)) + '\n'), '', '0', 'PASS'))
cases.append(('P8_B_trace_in_legacy_region', B, build(B, traces={R2N: None}).replace('# Subtest: ' + LEGACY[5], tline(trace(B, R2N)) + '\n# Subtest: ' + LEGACY[5]), '', '0', 'PASS'))
# R1 / R2 shape negatives
cases.append(('N01_A_R2_expected_tilde', A, build(A, blocks={R2N: r2_expected(['  expected: ~'])}), '', '1', 'FAIL'))
cases.append(('N02_A_R2_expected_null', A, build(A, blocks={R2N: r2_expected(['  expected: null'])}), '', '1', 'FAIL'))
cases.append(('N03_A_R2_expected_braces', A, build(A, blocks={R2N: r2_expected(['  expected: {}'])}), '', '1', 'FAIL'))
cases.append(('N04_A_R2_expected_with_child', A, build(A, blocks={R2N: r2_expected(['  expected:', '    turnOutline:', '      0:', '        turn: 1'])}), '', '1', 'FAIL'))
N05L = [l for l in R2_BLOCK if l != '  expected:']
N05L = N05L[:N05L.index("  operator: 'deepStrictEqual'")] + ['  expected:'] + N05L[N05L.index("  operator: 'deepStrictEqual'"):]
cases.append(('N05_A_R2_expected_not_followed_by_actual', A, build(A, blocks={R2N: N05L}), '', '1', 'FAIL'))
cases.append(('N06_A_R2_expected_missing', A, build(A, blocks={R2N: [l for l in R2_BLOCK if l != '  expected:']}), '', '1', 'FAIL'))
cases.append(('N07_A_R1_actual_yaml_sequence', A, build(A, blocks={R1N: R1_BLOCK[:27] + ['  actual:', '    - turn: 1', '      seq: 0', "      prompt: 'later steering text'", "      response: ''"] + R1_BLOCK[33:]}), '', '1', 'FAIL'))
cases.append(('N08_A_R1_actual_key1', A, build(A, blocks={R1N: R1_BLOCK[:28] + ['    1:'] + R1_BLOCK[29:]}), '', '1', 'FAIL'))
cases.append(('N09_A_R1_actual_two_keys', A, build(A, blocks={R1N: R1_BLOCK[:33] + ['    1:', '      turn: 2', '      seq: 9', "      prompt: 'x'", "      response: ''"] + R1_BLOCK[33:]}), '', '1', 'FAIL'))
cases.append(('N10_A_R1_seq_string', A, build(A, blocks={R1N: R1_BLOCK[:30] + ["      seq: '0'"] + R1_BLOCK[31:]}), '', '1', 'FAIL'))
cases.append(('N11_A_R1_actual_tilde', A, build(A, blocks={R1N: R1_BLOCK[:27] + ['  actual: ~'] + R1_BLOCK[33:]}), '', '1', 'FAIL'))
cases.append(('N12_A_R1_expected_wrong_prompt', A, build(A, blocks={R1N: rep(R1_BLOCK, "      prompt: ''", "      prompt: 'x'")}), '', '1', 'FAIL'))
cases.append(('N13_A_R1_stack_line140', A, build(A, blocks={R1N: rep(R1_BLOCK, '.test.mjs:139:10', '.test.mjs:140:10')}), '', '1', 'FAIL'))
cases.append(('N14_A_R2_location148', A, build(A, blocks={R2N: rep(R2_BLOCK, '.test.mjs:147:1', '.test.mjs:148:1')}), '', '1', 'FAIL'))
cases.append(('N15_A_R2_wrong_operator', A, build(A, blocks={R2N: rep(R2_BLOCK, "'deepStrictEqual'", "'strictEqual'")}), '', '1', 'FAIL'))
cases.append(('N16_A_R1_fixture_error', A, build(A, blocks={R1N: ['  ---', '  duration_ms: 10001', "  type: 'test'", "  location: '%s:127:1'" % F,
              "  failureType: 'testCodeFailure'", "  error: 'TURN_OUTLINE_FIXTURE: setup failed'", "  code: 'ERR_TEST_FAILURE'", "  name: 'FixtureError'",
              '  stack: |-', '    fixture (file://%s:124:11)' % F, '  ...']}), '', '1', 'FAIL'))
cases.append(('N17_A_R2_ok', A, build(A, statuses={R2N: 'ok'}), '', '1', 'FAIL'))
cases.append(('N18_A_C1_red', A, build(A, statuses={C1N: 'not ok'}), '', '1', 'FAIL'))
cases.append(('N19_A_exit0', A, build(A), '', '0', 'FAIL'))
cases.append(('N20_A_R1_trace_disagrees_tap', A, build(A, traces=trm(A, R1N, lambda t: t['observations'][0].__setitem__('value', [dict(EMPTY)]))), '', '1', 'FAIL'))
cases.append(('N21_A_R2_oldview_empty', A, build(A, traces=trm(A, R2N, lambda t: t.__setitem__('oldCheckpointView', {}))), '', '1', 'FAIL'))
cases.append(('N22_A_R2_synthetic_seq6', A, build(A, traces=trm(A, R2N, lambda t: t['syntheticVersion3Checkpoint']['turnOutline'].__setitem__('seq', 6))), '', '1', 'FAIL'))
cases.append(('N23_A_summary_wrong', A, build(A, summary={'tests': 3, 'suites': 0, 'pass': 1, 'fail': 2, 'cancelled': 1, 'skipped': 0, 'todo': 0, 'duration_ms': 9}), '', '1', 'FAIL'))
cases.append(('N24_A_skip_directive', A, build(A).replace('ok 3 - ' + C1N, 'ok 3 - ' + C1N + ' # SKIP'), '', '1', 'FAIL'))
cases.append(('N25_A_malformed_yaml', A, build(A, blocks={R1N: R1_BLOCK[:5] + ['  error |-'] + R1_BLOCK[6:]}), '', '1', 'FAIL'))
# B and TRACE negatives
cases.append(('N26_B_R2_oldview_nonempty', B, build(B, traces=trm(B, R2N, lambda t: t.__setitem__('oldCheckpointView', {'turnOutline': [dict(STEER)]}))), '', '0', 'FAIL'))
cases.append(('N27_B_R2_no_restored', B, build(B, traces=trm(B, R2N, lambda t: t.pop('restored'))), '', '0', 'FAIL'))
cases.append(('N28_B_loggerMessages_nonempty', B, build(B, traces=trm(B, C1N, lambda t: t.__setitem__('loggerMessages', [{'phase': 'body', 'type': 'warn', 'name': 'x', 'args': ['y']}]))), '', '0', 'FAIL'))
cases.append(('N29_B_fixtureFailures_missing', B, build(B, traces=trm(B, R1N, lambda t: t.pop('fixtureFailures'))), '', '0', 'FAIL'))
cases.append(('N30_B_fixtureFailures_null', B, build(B, traces=trm(B, R1N, lambda t: t.__setitem__('fixtureFailures', None))), '', '0', 'FAIL'))
cases.append(('N31_B_duplicate_trace_C1', B, build(B, traces={C1N: [tline(trace(B, C1N)), tline(trace(B, C1N))]}), '', '0', 'FAIL'))
cases.append(('N32_B_trace_legacy_case', B, build(B).replace('# Subtest: ' + LEGACY[3], tline(trace(B, C1N, lambda t: t.__setitem__('case', LEGACY[3]))) + '\n# Subtest: ' + LEGACY[3]), '', '0', 'FAIL'))
cases.append(('N33_B_trace_duplicate_key', B, build(B, traces={R1N: tline(None, json.dumps(trace(B, R1N), separators=(',', ':'))[:-1] + ',"case":"x"}')}), '', '0', 'FAIL'))
cases.append(('N34_B_trace_NaN', B, build(B, traces={R2N: tline(None, json.dumps(trace(B, R2N), separators=(',', ':')).replace('"ver":4', '"ver":NaN'))}), '', '0', 'FAIL'))
cases.append(('N35_B_trace_unescaped_hash', B, build(B, traces={C1N: '# TURN_OUTLINE_TRACE ' + json.dumps(trace(B, C1N, lambda t: t.__setitem__('note', 'a#b')), separators=(',', ':'))}), '', '0', 'FAIL'))
cases.append(('N36_B_missing_trace_R2', B, build(B, traces={R2N: None}), '', '0', 'FAIL'))
cases.append(('N37_B_legacy_not_ok', B, build(B, statuses={LEGACY[8]: 'not ok'}), '', '1', 'FAIL'))
cases.append(('N38_B_extra_case', B, build(B, names=NEW + LEGACY + ['extra case']), '', '0', 'FAIL'))
cases.append(('N39_B_missing_legacy', B, build(B, names=NEW + LEGACY[:8]), '', '0', 'FAIL'))
cases.append(('N40_B_stderr_error', B, build(B), 'Error: something broke\n', '0', 'FAIL'))
cases.append(('N41_B_watchdog_124', B, build(B), '', '124', 'FAIL'))
cases.append(('N42_B_truncated_stdout', B, build(B)[:3000], '', '0', 'FAIL'))
cases.append(('N43_B_empty_stdout', B, '', '', '0', 'FAIL'))
cases.append(('N44_B_nested_subtest', B, build(B).replace('# Subtest: ' + LEGACY[0], '    # Subtest: inner\n    ok 1 - inner\n# Subtest: ' + LEGACY[0]), '', '0', 'FAIL'))
cases.append(('N45_B_R1_changes_three', B, build(B, traces=trm(B, R1N, lambda t: t['changes'].append({'seq': 9, 'value': []}))), '', '0', 'FAIL'))
cases.append(('N46_B_C1_stage_missing', B, build(B, traces=trm(B, C1N, lambda t: t['observations'].pop())), '', '0', 'FAIL'))

allok = True
for cid, stage, so, se, rc, exp in cases:
    po = so[1] if isinstance(so, tuple) else os.path.join(WD, cid + '.stdout')
    pe = os.path.join(WD, cid + '.stderr')
    if not isinstance(so, tuple):
        open(po, 'w', encoding='utf-8', newline='\n').write(so)
    open(pe, 'w', encoding='utf-8', newline='\n').write(se)
    r = subprocess.run([sys.executable, '-I', TAP, stage, po, pe, rc], capture_output=True)
    out = r.stdout.decode('utf-8', 'replace').replace('\r', '')
    open(os.path.join(WD, cid + '.gate.txt'), 'w', encoding='utf-8', newline='\n').write(out)
    verdict = 'PASS' if r.returncode == 0 else 'FAIL' if r.returncode == 3 else 'INTERNAL_ERROR(%d)' % r.returncode
    yp = sum(1 for l in out.split('\n') if l.startswith('YAML_PROBLEM'))
    reasons = [l for l in out.split('\n') if l.startswith('FAIL_REASON')]
    ok = verdict == exp and (not cid.startswith('REAL') or yp == 0)
    allok &= ok
    print('%s %s stage=%s rc=%s verdict=%s expected=%s yaml_problems=%d reasons=%d first=%s' % (
        'OK ' if ok else 'BAD', cid, stage, rc, verdict, exp, yp, len(reasons), reasons[0][:170] if reasons else '-'))
print('DRYRUN078=%s cases=%d' % ('ALL_AS_EXPECTED' if allok else 'MISMATCH', len(cases)))
sys.exit(0 if allok else 1)
