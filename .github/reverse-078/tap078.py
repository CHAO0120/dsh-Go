# reverse request 078 result gates A and B (temp branch only, never merged). Reads the TAP/stderr files only; loads no
# product code and installs nothing. usage: tap078.py <A|B> <node stdout file> <node stderr file> <node exit code>
# The TAP/YAML/strict-JSON parser (tap_unescape, quoted, yscalar, parse_yaml, dict_of, parse_tap, strict_json) is
# copied byte-for-byte from core20-076 tap076.py (= 075; Node 24 YAML "~"/null/empty, quoted strings with util.inspect
# escapes, block scalars, nested maps). A bare "key:" with no indented children parses to {} and "key: ~" / "key: null"
# to None; the gates below never map None to {}. The gates are new for 078:
#   * Verdicts are only PASS (exit 0) or FAIL (exit 3; exit 4 = FAIL from an internal error of this script, traceback
#     printed). There is no UNDETERMINED: any unrecognised line/structure is a FAIL reason printed verbatim.
#   * Gate A: Node exit 1; "TAP version 13"; exactly the three frozen new names once each (set; points 1..3), plan 1..3,
#     summary tests 3 / suites 0 / pass 1 / fail 2 / cancelled 0 / skipped 0 / todo 0; no nested point, no SKIP/TODO.
#     R1 and R2 are the only "not ok" and must be the frozen semantic reds: failureType testCodeFailure, code
#     ERR_ASSERTION, name AssertionError, error first logical line "Expected values to be strictly deep-equal:",
#     operator absent or deepStrictEqual, first test-file stack frame line 139 / 165, location 127 / 147.
#     R1 actual/expected: Node 24 jsToYaml writes the one-element array as a map with exactly the numeric key "0"; only
#     that exact shape is converted to a list. R2 expected: the raw block must hold a bare "expected:" line with no
#     children immediately followed by the same-indent "actual:" line ("expected: ~"/"null"/"{}" are rejected); R2
#     actual is {turnOutline: <numeric-key map "0">}. Both are cross-checked with the TRACE (R1 first-oracle
#     observation, R2 oldCheckpointView). C1 plain ok.
#   * Gate B: Node exit 0; exactly the 3 new + 9 legacy Unicode names, each once (set; file order not assumed), all
#     plain ok; plan 1..12; summary tests 12 / suites 0 / pass 12 / fail 0 / cancelled 0 / skipped 0 / todo 0.
#   * TRACE (both): every top-level "# TURN_OUTLINE_TRACE <json>" comment anywhere in the stream (before or after a
#     point) is bound by its "case" field; exactly one per new case, none for any other name; lossless TAP unescape;
#     strict JSON (duplicate keys, NaN, Infinity rejected); fixtureFailures and loggerMessages are real empty arrays;
#     acceptedEvents/observations/changes present (and R2 syntheticVersion3Checkpoint/oldCheckpointView, B R2 restored);
#     every TRACE is printed in full (sorted keys).
#   * stderr: printed in full (repr per line). Empty, or only Node process-warning lines, is accepted; else FAIL.
import json
import re
import sys
import traceback

reasons = []


def want(cond, why):
    if not cond:
        reasons.append(why)
    return cond


# ---------------------------------------------------------------- TAP text escapes (Node tapEscape inverse)
def tap_unescape(s):
    m = {'\\': '\\', '#': '#', 'b': '\b', 'f': '\f', 't': '\t', 'n': '\n', 'r': '\r', 'v': '\v'}
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == '\\':
            if i + 1 >= len(s) or s[i + 1] not in m:
                return None, 'unknown TAP escape at %d in %r' % (i, s)
            out.append(m[s[i + 1]])
            i += 2
            continue
        if c == '#':
            return None, 'unescaped "#" at %d in %r' % (i, s)
        out.append(c)
        i += 1
    return ''.join(out), None


# ---------------------------------------------------------------- YAML (Node jsToYaml shape)
NULLS = ('~', 'null', 'Null', 'NULL')
BLOCK = ('|', '|-', '|+', '>', '>-', '>+')
ESC = {'n': '\n', 't': '\t', 'r': '\r', 'b': '\b', 'f': '\f', 'v': '\v', '0': '\0', '\\': '\\', "'": "'", '"': '"', '`': '`'}


def quoted(v, problems, where):
    q = v[0]
    if len(v) < 2 or v[-1] != q:
        problems.append('%s: unterminated %s-quoted scalar %r' % (where, q, v))
        return v
    inner, out, i = v[1:-1], [], 0
    while i < len(inner):
        c = inner[i]
        if c == '\\' and i + 1 < len(inner):
            n = inner[i + 1]
            if n in ESC:
                out.append(ESC[n]); i += 2; continue
            mx = re.match(r'x([0-9A-Fa-f]{2})', inner[i + 1:])
            mu = re.match(r'u([0-9A-Fa-f]{4})', inner[i + 1:])
            mb = re.match(r'u\{([0-9A-Fa-f]{1,6})\}', inner[i + 1:])
            if mx:
                out.append(chr(int(mx.group(1), 16))); i += 1 + len(mx.group(0)); continue
            if mu:
                out.append(chr(int(mu.group(1), 16))); i += 1 + len(mu.group(0)); continue
            if mb:
                out.append(chr(int(mb.group(1), 16))); i += 1 + len(mb.group(0)); continue
            problems.append('%s: unknown escape \\%s in %r' % (where, n, v))
            out.append(c); i += 1; continue
        if c == "'" and q == "'" and i + 1 < len(inner) and inner[i + 1] == "'":
            out.append("'"); i += 2; continue  # YAML-style '' inside single quotes
        out.append(c)
        i += 1
    return ''.join(out)


def yscalar(v, problems, where):
    if v == '' or v in NULLS:
        return None
    if v in ('true', 'false'):
        return v == 'true'
    if re.fullmatch(r'-?\d+', v):
        return int(v)
    if re.fullmatch(r'-?(\d+\.\d*|\.\d+|\d+)([eE][-+]?\d+)?', v):
        return float(v)
    if v[0] in '\'"`':
        return quoted(v, problems, where)
    return v  # plain scalar (e.g. <Circular>, [Function: x], NaN, 1n, ISO dates): kept verbatim as text


def parse_yaml(lines, base, problems, where):
    # lines: list of (lineno, text). Keys sit at exactly `base` spaces. Returns an ordered list of (key, value).
    out, seen, i = [], set(), 0
    key_re = re.compile(r'^(?P<key>[^ ].*?):(?: (?P<val>.*))?$')
    while i < len(lines):
        ln, text = lines[i]
        ind = len(text) - len(text.lstrip(' '))
        m = key_re.match(text[base:]) if ind == base else None
        if not m:
            problems.append('%s line %d: unexpected YAML line %r (want a key at indent %d)' % (where, ln, text, base))
            i += 1
            continue
        key, val = m.group('key'), m.group('val')
        if key in seen:
            problems.append('%s line %d: duplicate YAML key %r' % (where, ln, key))
        seen.add(key)
        cont, j = [], i + 1
        while j < len(lines):
            t2 = lines[j][1]
            i2 = len(t2) - len(t2.lstrip(' '))
            if i2 > base or (t2.strip() == '' and val in BLOCK):
                cont.append(lines[j]); j += 1
            else:
                break
        if val is None or val == '':
            if cont:
                value = dict_of(parse_yaml(cont, base + 2, problems, '%s.%s' % (where, key)), problems, '%s.%s' % (where, key))
            else:
                value = {} if val is None else None
        elif val in BLOCK:
            body = []
            for (l3, t3) in cont:
                if t3.strip() != '' and not t3.startswith(' ' * (base + 2)):
                    problems.append('%s line %d: block scalar line under-indented %r' % (where, l3, t3))
                body.append(t3[base + 2:] if len(t3) >= base + 2 else '')
            value = (' '.join(body) if val[0] == '>' else '\n'.join(body))
            if val.endswith('+') or val in ('|', '>'):
                value += '\n'
        else:
            if cont:
                problems.append('%s line %d: scalar %r followed by indented lines %r' % (where, ln, key, [t for _, t in cont]))
            value = yscalar(val, problems, '%s line %d key %s' % (where, ln, key))
        out.append((key, value))
        i = j
    return out


def dict_of(pairs, problems, where):
    d = {}
    for k, v in pairs:
        d[k] = v  # duplicates already reported
    return d


# ---------------------------------------------------------------- TAP stream
POINT = re.compile(r'^( *)(not ok|ok) (\d+)(?: - (.*))?$')


def parse_tap(text):
    lines = text.split('\n')
    if lines and lines[-1] == '':
        lines = lines[:-1]
    else:
        want(False, 'stdout does not end with a newline (last line %r)' % (lines[-1] if lines else None))
    want(bool(lines) and lines[0] == 'TAP version 13', 'first stdout line %r (want "TAP version 13")' % (lines[0] if lines else None))
    points, regions, summary, plan, outside, cur = [], [], {}, None, [], None
    i = 1 if lines and lines[0] == 'TAP version 13' else 0
    while i < len(lines):
        line = lines[i]
        m = POINT.match(line)
        if m:
            indent, status, num, rest = m.group(1), m.group(2), int(m.group(3)), m.group(4)
            if rest is None:
                want(False, 'line %d: test point without " - name": %r' % (i + 1, line)); rest = ''
            name, directive = rest, ''
            dm = re.search(r' # (SKIP|TODO)\b.*$', rest, re.I)
            if dm:
                name, directive = rest[:dm.start()], dm.group(0)[3:]
            un, prob = tap_unescape(name)
            if prob:
                want(False, 'line %d: test name: %s' % (i + 1, prob)); un = name
            j, block = i + 1, None
            if j < len(lines) and lines[j] == indent + '  ---':
                block, j = [], j + 1
                while j < len(lines) and lines[j] != indent + '  ...':
                    block.append((j + 1, lines[j])); j += 1
                if j >= len(lines):
                    want(False, 'line %d: unterminated YAML block of %r (raw kept)' % (i + 1, un))
                j += 1
            p = {'indent': len(indent), 'status': status, 'num': num, 'name': un, 'directive': directive, 'block': block, 'line': i + 1}
            points.append(p)
            if p['indent'] == 0:
                if cur is None or cur['point'] is not None or cur['name'] != un:
                    want(False, 'line %d: top-level point %r without its own "# Subtest:" header' % (i + 1, un))
                    cur = {'name': un, 'point': p, 'comments': [], 'line': i + 1, 'synthetic': True}
                    regions.append(cur)
                else:
                    cur['point'] = p
            else:
                want(False, 'line %d: nested test point %r' % (i + 1, line))
            i = j
            continue
        ms = re.match(r'^( *)# Subtest: (.*)$', line)
        if ms:
            un, prob = tap_unescape(ms.group(2))
            if prob:
                want(False, 'line %d: subtest name: %s' % (i + 1, prob)); un = ms.group(2)
            if ms.group(1):
                want(False, 'line %d: nested subtest header %r' % (i + 1, line))
                if cur is not None:
                    cur['comments'].append((i + 1, line))
            else:
                if cur is not None and cur['point'] is None:
                    want(False, 'line %d: subtest %r has no test point before the next header' % (cur['line'], cur['name']))
                cur = {'name': un, 'point': None, 'comments': [], 'line': i + 1}
                regions.append(cur)
            i += 1
            continue
        mp = re.match(r'^( *)1\.\.(\d+)$', line)
        if mp:
            if mp.group(1):
                want(False, 'line %d: nested plan %r' % (i + 1, line))
            else:
                want(plan is None, 'line %d: second top-level plan' % (i + 1))
                plan = int(mp.group(2))
                cur = None
            i += 1
            continue
        if line.startswith('#'):
            sm = re.match(r'^# (tests|suites|pass|fail|cancelled|skipped|todo|duration_ms) (\S+)$', line)
            if cur is None and plan is not None and sm:
                want(sm.group(1) not in summary, 'line %d: duplicate summary %s' % (i + 1, sm.group(1)))
                summary[sm.group(1)] = sm.group(2)
            elif cur is not None:
                cur['comments'].append((i + 1, line))
            else:
                outside.append((i + 1, line))
            i += 1
            continue
        if line.startswith(' ') and line.lstrip(' ').startswith('#'):
            want(False, 'line %d: indented (nested) comment %r' % (i + 1, line))
            i += 1
            continue
        if line.startswith('Bail out!'):
            want(False, 'line %d: %r' % (i + 1, line))
        else:
            want(False, 'line %d: unrecognised TAP line %r' % (i + 1, line))
        i += 1
    return points, regions, summary, plan, outside


def strict_json(s):
    def hook(pairs):
        keys = [k for k, _ in pairs]
        if len(keys) != len(set(keys)):
            raise ValueError('duplicate key in %r' % keys)
        return dict(pairs)

    def nonfinite(x):
        raise ValueError('non-finite number %s' % x)
    return json.loads(s, object_pairs_hook=hook, parse_constant=nonfinite)




R1N = 'R1: first image-only human prompt stays empty after same-turn steer'
R2N = 'R2: synthetic version3 checkpoint is rejected and full public log replays'
C1N = 'C1: text prompt, new turn and current checkpoint round trip preserve outline'
NEW_NAMES = [R1N, R2N, C1N]
SHORT = {R1N: 'R1', R2N: 'R2', C1N: 'C1'}
LEGACY = ['prompt final: public turnOutline preserves scalar text and UTF16 budgets',
          'response final: public turnOutline preserves scalar text and UTF16 budgets',
          'prompt inner: public turnOutline preserves scalar text and UTF16 budgets',
          'response inner: public turnOutline preserves scalar text and UTF16 budgets',
          'ASCII budgets: public turnOutline preserves scalar text and UTF16 budgets',
          'short Unicode: public turnOutline preserves scalar text and UTF16 budgets',
          'complete pair before cut: public turnOutline preserves scalar text and UTF16 budgets',
          'multiblock whitespace and response commit preserve three wire changes',
          'actual version2 checkpoint requires replay and leaves source events unchanged']
ROW_STEER = {'turn': 1, 'seq': 0, 'prompt': 'later steering text', 'response': ''}
ROW_EMPTY = {'turn': 1, 'seq': 0, 'prompt': '', 'response': ''}
SYN3 = {'turnOutline': {'ver': 3, 'seq': 5, 'val': {'turns': [dict(ROW_STEER)], 'draft': ''}}}
C1_STAGES = ['empty current checkpoint', 'draft keeps first human text', 'draft current checkpoint', 'ended current turn',
             'ended current checkpoint', 'genuinely new turn']
TRACE_PFX = '# TURN_OUTLINE_TRACE '
REQ = ['case', 'acceptedEvents', 'observations', 'changes', 'loggerMessages', 'fixtureFailures']
SUMMARY_KEYS = ['tests', 'suites', 'pass', 'fail', 'cancelled', 'skipped', 'todo', 'duration_ms']
WARN = re.compile(r'^\(node:\d+\) (\[[A-Z0-9_]+\] )?[A-Za-z]*Warning: .*$|^\(Use `node --trace-[a-z-]+ \.\.\.` to show where the warning was created\)$')
TESTFILE = '/runtime/tests/turn-outline-first-human.test.mjs:'
RED_FIRST_LINE = 'Expected values to be strictly deep-equal:'
RED_LINES = {'R1': (127, 139), 'R2': (147, 165)}


def typed_eq(a, b):
    if type(a) is not type(b):
        return False
    if isinstance(a, dict):
        return sorted(a) == sorted(b) and all(typed_eq(a[k], b[k]) for k in a)
    if isinstance(a, list):
        return len(a) == len(b) and all(typed_eq(x, y) for x, y in zip(a, b))
    return a == b


def is_int(x):
    return type(x) is int


def one_elem_map(v):
    # Node 24 jsToYaml: a one-element array is written as a map whose only key is "0". Only that exact shape converts.
    if isinstance(v, dict) and list(v) == ['0'] and isinstance(v['0'], dict):
        return [v['0']]
    return None


def stage_values(tr, stage):
    obs = tr.get('observations')
    return [o.get('value') for o in obs if isinstance(o, dict) and o.get('stage') == stage] if isinstance(obs, list) else []


def seqs_ok(tr, n):
    ev = tr.get('acceptedEvents')
    return (isinstance(ev, list) and len(ev) == n and all(isinstance(e, dict) and is_int(e.get('seq')) and e.get('seq') == k for k, e in enumerate(ev)))


def trace_gate(stage, label, tr, ln, region, tap_actual):
    tag = '%s %s' % (stage, label)
    if not isinstance(tr, dict):
        want(False, '%s TRACE is not a JSON object: %r' % (tag, type(tr).__name__)); return
    missing = [k for k in REQ if k not in tr]
    want(not missing, '%s TRACE missing fields %s' % (tag, missing))
    ff, lm = tr.get('fixtureFailures'), tr.get('loggerMessages')
    want(isinstance(ff, list) and ff == [], '%s fixtureFailures=%s (want a present, typed empty array)' % (tag, json.dumps(ff)))
    want(isinstance(lm, list) and lm == [], '%s loggerMessages=%s (want a present, typed empty array)' % (tag, json.dumps(lm)))
    for k in ('acceptedEvents', 'observations', 'changes'):
        want(isinstance(tr.get(k), list), '%s %s is not an array: %s' % (tag, k, json.dumps(tr.get(k))[:300]))
    obs = tr.get('observations') if isinstance(tr.get('observations'), list) else []
    want(all(isinstance(o, dict) and isinstance(o.get('stage'), str) and 'value' in o and 'checkpoint' in o for o in obs),
         '%s observations entries are not {stage, value, checkpoint}' % tag)
    checks = []
    if label == 'R1':
        first = stage_values(tr, 'before first semantic oracle')
        ev = tr.get('acceptedEvents') if isinstance(tr.get('acceptedEvents'), list) else []
        checks += [(len(first) == 1, 'exactly one "before first semantic oracle" observation'),
                   (seqs_ok(tr, 8 if stage == 'A' else 10), 'acceptedEvents seq 0..%d consecutive' % (7 if stage == 'A' else 9)),
                   (len(ev) > 7 and isinstance(ev[0], dict) and ev[0].get('seq') == 0 and isinstance(ev[7], dict) and ev[7].get('seq') == 7,
                    'boundary seq0 and steer seq7')]
        if stage == 'A':
            checks += [(len(first) == 1 and typed_eq(first[0], [dict(ROW_STEER)]), 'first-oracle TRACE value == typed one-element array (steer prompt)'),
                       (len(first) == 1 and tap_actual is not None and typed_eq(first[0], tap_actual), 'first-oracle TRACE value == TAP actual (numeric-key map 0 -> array)')]
        else:
            settled = stage_values(tr, 'settled response')
            checks += [(len(first) == 1 and typed_eq(first[0], [dict(ROW_EMPTY)]), 'first-oracle TRACE value == empty prompt row'),
                       (len(settled) == 1 and typed_eq(settled[0], [dict(ROW_EMPTY, response='first response')]), 'settled response row'),
                       (isinstance(tr.get('changes'), list) and len(tr.get('changes')) == 2, 'two raw turnOutline changes')]
    elif label == 'R2':
        ocv = tr.get('oldCheckpointView', 'ABSENT')
        checks += [('syntheticVersion3Checkpoint' in tr and typed_eq(tr.get('syntheticVersion3Checkpoint'), SYN3), 'syntheticVersion3Checkpoint == ver3/seq5/anchor0/draft empty'),
                   (len(stage_values(tr, 'actual public checkpoint independent of synthetic row')) == 1, 'separate actual public checkpoint observation retained'),
                   (seqs_ok(tr, 6), 'acceptedEvents seq 0..5 consecutive')]
        if stage == 'A':
            checks += [(typed_eq(ocv, {'turnOutline': [dict(ROW_STEER)]}), 'oldCheckpointView == {turnOutline: [steer row]}'),
                       (tap_actual is not None and typed_eq(ocv, tap_actual), 'oldCheckpointView == TAP actual (turnOutline numeric-key map 0 -> array)'),
                       ('restored' not in tr, 'no restored field (red precedes it)')]
        else:
            checks += [(typed_eq(ocv, {}), 'oldCheckpointView == {} (version3 rejected)'),
                       (isinstance(tr.get('restored'), dict), 'restored present')]
    else:
        checks += [([o.get('stage') for o in obs if isinstance(o, dict)] == C1_STAGES, 'C1 observation stages %s' % C1_STAGES)]
    for ok, why in checks:
        want(ok, '%s TRACE check failed: %s' % (tag, why))
    print('TRACE %s line=%d region=%r fixtureFailures=%s loggerMessages=%s acceptedEvents=%d observations=%s changes=%d extra_keys=%s' % (
        tag, ln, region, json.dumps(ff), json.dumps(lm), len(tr.get('acceptedEvents') or []),
        [o.get('stage') for o in obs if isinstance(o, dict)], len(tr.get('changes') or []), sorted(k for k in tr if k not in REQ)))
    print('TRACE %s checks=%s' % (tag, [(why, bool(ok)) for ok, why in checks]))
    print('TRACE_JSON %s %s' % (tag, json.dumps(tr, sort_keys=True, ensure_ascii=True)))


def red_gate(label, fields, p):
    # A: the two frozen semantic reds. operator may be absent; the main assertion evidence may not.
    decl, oracle = RED_LINES[label]
    err = fields.get('error')
    first = err.split('\n')[0] if isinstance(err, str) else None
    stack = fields.get('stack')
    frames = [l.strip() for l in stack.split('\n')] if isinstance(stack, str) else []
    tf = [l for l in frames if TESTFILE in l]
    loc = fields.get('location')
    op = fields.get('operator', 'ABSENT')
    block = p['block'] or []
    ind = ' ' * (p['indent'] + 2)
    raw = [t for _, t in block]
    tap_actual = None
    if label == 'R1':
        a, e = one_elem_map(fields.get('actual')), one_elem_map(fields.get('expected'))
        tap_actual = a
        shape = [(a is not None and typed_eq(a, [dict(ROW_STEER)]), 'actual == numeric-key map {0: steer row} (typed)'),
                 (e is not None and typed_eq(e, [dict(ROW_EMPTY)]), 'expected == numeric-key map {0: empty-prompt row} (typed)'),
                 ((ind + 'actual:') in raw and (ind + '  0:') in raw, 'raw block carries "actual:" and the nested "0:" key line')]
    else:
        ex = fields.get('expected', 'ABSENT')
        k = raw.index(ind + 'expected:') if (ind + 'expected:') in raw else -1
        bare = k >= 0 and k + 1 < len(raw) and raw[k + 1] == ind + 'actual:'
        tl = fields.get('actual').get('turnOutline') if isinstance(fields.get('actual'), dict) else None
        a = one_elem_map(tl)
        tap_actual = {'turnOutline': a} if a is not None and isinstance(fields.get('actual'), dict) and list(fields.get('actual')) == ['turnOutline'] else None
        shape = [(type(ex) is dict and ex == {}, 'expected parsed to an empty map (not None/~/null)'),
                 (bare, 'raw block: bare "expected:" line immediately followed by same-indent "actual:"'),
                 (not any(t.startswith(ind + 'expected: ') for t in raw), 'no "expected: <scalar>" line'),
                 (tap_actual is not None and typed_eq(tap_actual, {'turnOutline': [dict(ROW_STEER)]}), 'actual == {turnOutline: numeric-key map {0: steer row}} (typed)')]
    checks = [(fields.get('failureType') == 'testCodeFailure', 'failureType testCodeFailure'),
              (fields.get('code') == 'ERR_ASSERTION', 'code ERR_ASSERTION'),
              (fields.get('name') == 'AssertionError', 'name AssertionError'),
              (first == RED_FIRST_LINE, 'error first logical line %r' % RED_FIRST_LINE),
              (op in ('ABSENT', 'deepStrictEqual'), 'operator absent or deepStrictEqual'),
              (bool(tf) and re.search(re.escape(TESTFILE) + r'%d:\d+\)?$' % oracle, tf[0]) is not None, 'first test-file stack frame is line %d' % oracle),
              (isinstance(loc, str) and re.search(re.escape(TESTFILE) + r'%d:\d+$' % decl, loc) is not None, 'location is the line %d declaration' % decl),
              (fields.get('type') == 'test', 'type test')] + shape
    for ok, why in checks:
        want(ok, 'A %s is not the frozen semantic red: %s' % (label, why))
    print('%s_RED failureType=%r code=%r name=%r error_first_line=%r actual=%s expected=%s operator=%r first_test_file_frame=%r location=%r' % (
        label, fields.get('failureType'), fields.get('code'), fields.get('name'), first, json.dumps(fields.get('actual')),
        json.dumps(fields.get('expected')), op, tf[0] if tf else None, loc))
    print('%s_RED checks=%s' % (label, [(why, bool(ok)) for ok, why in checks]))
    return tap_actual


def main():
    stage, tap_path, err_path, rc_s = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    want(stage in ('A', 'B'), 'unknown stage %r' % stage)
    stage = stage if stage in ('A', 'B') else 'B'
    want(re.fullmatch(r'\d+', rc_s) is not None, 'node exit code %r is not a number' % rc_s)
    rc = int(rc_s) if re.fullmatch(r'\d+', rc_s) else None
    ob = open(tap_path, 'rb').read()
    eb = open(err_path, 'rb').read()
    try:
        text = ob.decode('utf-8')
    except UnicodeDecodeError as e:
        want(False, 'stdout is not UTF-8: %s' % e); text = ob.decode('utf-8', 'replace')
    print('STAGE=%s NODE_EXIT=%s STDOUT_BYTES=%d STDERR_BYTES=%d STDOUT_CR=%d' % (stage, rc_s, len(ob), len(eb), ob.count(b'\r')))
    want(rc == (1 if stage == 'A' else 0), 'node exit %s (want %d)' % (rc_s, 1 if stage == 'A' else 0))
    et = eb.decode('utf-8', 'replace')
    for k, l in enumerate(et.split('\n')):
        if l == '' and k == len(et.split('\n')) - 1:
            continue
        ok = WARN.match(l) is not None
        print('STDERR line=%d %s %r' % (k + 1, 'NOTE_NODE_WARNING' if ok else 'UNRECOGNISED', l))
        want(ok, 'stderr line %d is not a Node process warning: %r' % (k + 1, l))
    points, regions, summary, plan, outside = parse_tap(text)
    top = [p for p in points if p['indent'] == 0]
    print('PLAN=%s SUMMARY %s' % (plan, ' '.join('%s=%s' % (k, summary.get(k, '?')) for k in SUMMARY_KEYS)))
    print('TEST_POINTS total=%d top_level=%d nested=%d regions=%d' % (len(points), len(top), len(points) - len(top), len(regions)))
    for p in points:
        print('POINT line=%d indent=%d %s %d%s - %s' % (p['line'], p['indent'], p['status'], p['num'],
              (' # ' + p['directive']) if p['directive'] else '', p['name']))
    names = [p['name'] for p in top]
    n_all = 3 if stage == 'A' else 12
    want_names = NEW_NAMES if stage == 'A' else NEW_NAMES + LEGACY
    want(sorted(names) == sorted(want_names) and len(names) == n_all, 'case names %s (want exactly the set %s)' % (names, want_names))
    want(len(names) == len(set(names)), 'duplicate case names')
    want([p['num'] for p in top] == list(range(1, len(top) + 1)), 'top-level numbering %s (want 1..%d)' % ([p['num'] for p in top], len(top)))
    print('INFO order=%s numbering=%s' % ([SHORT.get(n, 'legacy%d' % LEGACY.index(n) if n in LEGACY else '?') for n in names], [p['num'] for p in top]))
    want(plan == n_all, 'plan %s (want 1..%d)' % (plan, n_all))
    want(all(k in summary for k in SUMMARY_KEYS), 'TAP summary incomplete: %s' % sorted(summary))
    exp = ((('tests', 3), ('suites', 0), ('pass', 1), ('fail', 2), ('cancelled', 0), ('skipped', 0), ('todo', 0)) if stage == 'A' else
           (('tests', 12), ('suites', 0), ('pass', 12), ('fail', 0), ('cancelled', 0), ('skipped', 0), ('todo', 0)))
    for k, v in exp:
        want(summary.get(k) == str(v), 'summary %s=%s (want %s)' % (k, summary.get(k), v))
    tap_actual = {}
    for p in points:
        label = SHORT.get(p['name']) or ('legacy' if p['name'] in LEGACY else 'UNKNOWN')
        want(not p['directive'], '%s has directive %r' % (p['name'], p['directive']))
        red = stage == 'A' and label in ('R1', 'R2') and p['indent'] == 0
        want(p['status'] == ('not ok' if red else 'ok'), '%s is %s (want %s)' % (p['name'], p['status'], 'not ok (frozen red)' if red else 'plain ok'))
        problems, fields = [], {}
        if p['block'] is None:
            want(False, '%s has no YAML diagnostic block' % p['name'])
        else:
            fields = dict_of(parse_yaml(p['block'], p['indent'] + 2, problems, 'yaml(%s)' % label), problems, label)
        print('CASE label=%s line=%d %s%s - %s yaml=%s' % (label, p['line'], p['status'], (' # ' + p['directive']) if p['directive'] else '',
              p['name'], json.dumps(fields, sort_keys=True, ensure_ascii=True, default=repr)))
        for pr in problems:
            print('YAML_PROBLEM %s %s' % (label, pr))
            want(False, 'YAML block of %s: %s' % (p['name'], pr))
        if problems and p['block'] is not None:
            for ln, t in p['block']:
                print('YAML_RAW %s line=%d %r' % (label, ln, t))
        if p['status'] == 'ok' and p['block'] is not None:
            want(fields.get('type') == 'test', '%s YAML type=%r (want test)' % (p['name'], fields.get('type')))
            want(type(fields.get('duration_ms')) in (int, float), '%s YAML duration_ms=%r (want a number)' % (p['name'], fields.get('duration_ms')))
            extra = sorted(k for k in fields if k not in ('type', 'duration_ms'))
            if extra:
                print('NOTE %s ok block carries extra YAML keys %s' % (label, extra))
        if p['status'] != 'ok':
            print('NOT_OK %s failureType=%r code=%r name=%r location=%r expected=%s actual=%s operator=%r' % (
                label, fields.get('failureType'), fields.get('code'), fields.get('name'), fields.get('location'),
                json.dumps(fields.get('expected'), default=repr), json.dumps(fields.get('actual'), default=repr), fields.get('operator', 'ABSENT')))
            print('NOT_OK %s error=%r stack=%r' % (label, fields.get('error'), fields.get('stack')))
            if red and p['block'] is not None:
                for ln, t in p['block']:
                    print('RED_RAW %s line=%d %r' % (label, ln, t))
                tap_actual[label] = red_gate(label, fields, p)
    # TRACE: read every top-level comment of the original stream; bind each TRACE by its own "case" field.
    allc = [(ln, c, r['name']) for r in regions for ln, c in r['comments']] + [(ln, c, None) for ln, c in outside]
    allc.sort()
    total, per = 0, {s: 0 for s in SHORT.values()}
    for ln, c, region in allc:
        if not c.startswith('# TURN_OUTLINE_TRACE'):
            print('NOTE region=%r line=%d %r' % (region, ln, c))
            continue
        total += 1
        if not c.startswith(TRACE_PFX):
            want(False, 'TRACE line %d has no single space before the JSON: %r' % (ln, c[:200])); continue
        raw, prob = tap_unescape(c[len(TRACE_PFX):])
        if prob:
            want(False, 'TRACE line %d: %s' % (ln, prob)); continue
        try:
            tr = strict_json(raw)
        except ValueError as e:
            want(False, 'TRACE line %d is not strict JSON (%s): %r' % (ln, e, raw[:400])); continue
        case = tr.get('case') if isinstance(tr, dict) else None
        label = SHORT.get(case)
        if label is None:
            want(False, 'TRACE line %d binds to case %r, which is not one of the three new cases' % (ln, case)); continue
        per[label] += 1
        if region != case:
            print('NOTE TRACE line=%d case=%r physically in region %r (bound by its case field)' % (ln, case, region))
        trace_gate(stage, label, tr, ln, region, tap_actual.get(label) if stage == 'A' else None)
    for l in SHORT.values():
        want(per[l] == 1, '%s has %d TURN_OUTLINE_TRACE lines bound to it (want exactly 1)' % (l, per[l]))
    print('TRACE_TOTAL=%d per_case=%s (want 3, one each)' % (total, per))
    want(total == 3, 'TURN_OUTLINE_TRACE total %d (want 3)' % total)
    for k, why in enumerate(reasons):
        print('FAIL_REASON %d %s' % (k + 1, why))
    print('GATE_078_%s=%s reasons=%d' % (stage, 'PASS' if not reasons else 'FAIL', len(reasons)))
    return 0 if not reasons else 3


if __name__ == '__main__':
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException:
        print('GATE_078=FAIL (internal error of the gate script; traceback below; the raw TAP/stderr are kept unchanged)')
        traceback.print_exc(file=sys.stdout)
        for k, why in enumerate(reasons):
            print('FAIL_REASON %d %s' % (k + 1, why))
        sys.exit(4)
