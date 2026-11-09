# reverse request 078 packet check (temp branch only, never merged). Reads bytes and JSON only; loads no product code.
# From core20-076 inputs076.py with the 078 packet values: five members in the request order, the self-referential
# 078-identities.json member bound to the external identity given in requestfromweb-078.txt (91037 B / bf093214363d...),
# the identities spec read from packet_plan_only (names/mode), raw_sources FULL_NOPINS/TESTONLY and pending_bindings
# README/formal_source_review (bytes/sha256). Verifies the v2 zip (size/SHA256, CRC via testzip), exactly five regular
# root-level members in the stated order, extracts them byte-for-byte (no text conversion) into a NEW empty directory
# outside the product trees, then checks every member's size/SHA256 against BOTH this script's copy of the request values
# and the identities JSON, CR=0/tail LF of the text members, and that FULL without its inner-diff section and without its
# Unicode-test section equals TESTONLY byte-for-byte.
# usage: inputs078.py <zip> <new output dir>      exit 0 only if every check holds.
import hashlib
import json
import os
import stat
import sys
import zipfile

ZIP = (43469, '88bf420089a070a6075b7b6fcf2f95d0e648e8d5583b9aba94be081d7959516c')
FULL = '2622-turn-outline-first-human-FULL-NOPINS-LF.patch'
TESTONLY = '2622-turn-outline-first-human-TESTONLY-LF.patch'
IDENT = '078-identities.json'
REVIEW = '2622-NOPINS-review-only-PASS_SCOPED.md'
MEMBERS = [(FULL, 17081, 'df7ca1546f2644a77f3e9c5e71d4cd6e0203106025ad7aca50a22b989b59869e'),
           (TESTONLY, 11519, '3469bebc86721311d45a26ea8dfa41b16bfe304badcd64f10985a367e7d48d84'),
           ('README.md', 3587, '9b8727efcf05c83aa53df6454a7fe839126c11764769dfc940baba4fcad6c8c4'),
           (IDENT, 91037, 'bf093214363df5b20b2171023ba96ca8f0e64fbb59855e8b73fe832525fa4353'),
           (REVIEW, 17097, 'd187ac6b6274fe4bfad5c4957862007acb8c0c35b12fdceeb3551bf1ef3e6a6c')]
INNER = 'runtime/patches/zzzzzzzzzzzzzzzzzzzzzz-turn-outline-first-human.diff'
UNI = 'runtime/tests/turn-outline-unicode.test.mjs'
bad = []


def check(cond, why):
    if not cond:
        bad.append(why)
    return cond


z, out = sys.argv[1], sys.argv[2]
b = open(z, 'rb').read()
h = hashlib.sha256(b).hexdigest()
print('ZIP bytes=%d sha256=%s %s' % (len(b), h, 'MATCH' if (len(b), h) == ZIP else 'MISMATCH'))
check((len(b), h) == ZIP, 'zip identity')
zf = zipfile.ZipFile(z)
t = zf.testzip()
print('ZIP_TESTZIP(CRC)=%s' % ('OK' if t is None else 'BAD member %r' % t))
check(t is None, 'crc')
infos = zf.infolist()
names = [i.filename for i in infos]
print('MEMBERS_IN_ORDER=%s' % names)
check(names == [m[0] for m in MEMBERS], 'member order/names')
check(len(set(names)) == len(names), 'duplicate member')
for i in infos:
    n = i.filename
    mode = i.external_attr >> 16
    safe = n and '/' not in n and chr(92) not in n and ':' not in n and n not in ('.', '..') and not n.startswith('.')
    regular = (not i.is_dir()) and (mode == 0 or stat.S_ISREG(mode))
    print('MEMBER %s size=%d compress_size=%d crc=%08x mode=%o root_level_safe=%s regular=%s' % (
        n, i.file_size, i.compress_size, i.CRC, mode, bool(safe), regular))
    check(safe and regular, 'unsafe or non-regular member %s' % n)
check(not os.path.exists(out), 'output dir exists')
os.mkdir(out)
for i in infos:
    data = zf.read(i)
    fd = os.open(os.path.join(out, i.filename), os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_BINARY', 0), 0o644)
    with os.fdopen(fd, 'wb') as f:
        f.write(data)
got = {}
for n, size, sha in MEMBERS:
    p = os.path.join(out, n)
    x = open(p, 'rb').read() if os.path.isfile(p) else b''
    got[n] = x
    hx = hashlib.sha256(x).hexdigest()
    ok = (len(x), hx) == (size, sha)
    print('%s %s bytes=%d sha256=%s cr=%d tail_lf=%s bom=%s (want %d/%s from the request)' % (
        'MATCH' if ok else 'MISMATCH', n, len(x), hx, x.count(b'\r'), x.endswith(b'\n'),
        x.startswith(chr(0xFEFF).encode('utf-8')), size, sha))
    check(ok, 'identity %s' % n)
    check(x.count(b'\r') == 0 and x.endswith(b'\n'), 'CR/tail LF %s' % n)
# identities JSON packet spec: packet_plan_only gives the names/order/mode; raw_sources and pending_bindings give
# bytes/SHA of FULL/TESTONLY/README/review; the identities member itself has self_identity null by design and is bound
# above by the request's external identity.
j = json.loads(got[IDENT].decode('utf-8'))
pp = j['packet_plan_only']
check(pp['members_order'] == [m[0] for m in MEMBERS], 'identities packet order')
check(pp.get('mode') == '100644', 'identities packet mode')
print('IDENTITIES_PACKET_ORDER=%s MODE=%s' % (pp['members_order'] == [m[0] for m in MEMBERS], pp.get('mode')))
okself = j.get('self_identity') is None
print('IDENTITIES_SELF_ENTRY self_identity is null (%s); bound by the request external identity %d/%s instead' % (
    'as designed' if okself else 'UNEXPECTED', MEMBERS[3][1], MEMBERS[3][2]))
check(okself, 'self entry not null')
for key, n, row in (('FULL_NOPINS', FULL, j['raw_sources']['FULL_NOPINS']), ('TESTONLY', TESTONLY, j['raw_sources']['TESTONLY']),
                    ('README', 'README.md', j['pending_bindings']['README']), ('formal_source_review', REVIEW, j['pending_bindings']['formal_source_review'])):
    ok = (row['bytes'], row['sha256']) == (len(got[n]), hashlib.sha256(got[n]).hexdigest()) == dict((m[0], m[1:]) for m in MEMBERS)[n]
    print('IDENTITIES_SPEC %s %s %s' % (key, n, 'MATCH' if ok else 'MISMATCH'))
    check(ok, 'identities spec %s' % key)
check(j.get('base_commit') == 'e5d931cd84c21e833cf1f9dcbed6061008168f5e', 'identities base')
print('IDENTITIES base_commit=%s dsh_version=%s product=%s request_proposal=%s input_revision=%s' % (
    j.get('base_commit'), j.get('dsh_version'), j.get('product'), j.get('request_proposal'), j.get('input_revision', {}).get('number')))
check(j.get('dsh_version') == '0.2.2-rc.1' and j.get('product') == '2622', 'identities version/product')
# FULL minus its inner section and its Unicode-test section must equal TESTONLY.
full = got[FULL]


def cut_section(b, path):
    start = b.find(('diff --git a/%s b/%s\n' % (path, path)).encode())
    if start < 0:
        return None, -1, -1
    nxt = b.find(b'\ndiff --git ', start + 1)
    end = len(b) if nxt < 0 else nxt + 1
    return b[:start] + b[end:], start, end - start


c1, o1, n1 = cut_section(full, INNER)
c2, o2, n2 = cut_section(c1, UNI) if c1 is not None else (None, -1, -1)
eq = c2 is not None and c2 == got[TESTONLY]
print('FULL_WITHOUT_INNER_AND_UNICODE_SECTIONS_EQUALS_TESTONLY=%s (inner section offset=%d bytes=%d; unicode section offset=%d bytes=%d)' % (eq, o1, n1, o2, n2))
check(eq, 'FULL minus inner/unicode != TESTONLY')
print('INPUTS078=%s %s' % ('PASS' if not bad else 'FAIL', bad))
sys.exit(0 if not bad else 1)
