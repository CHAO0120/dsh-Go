#!/usr/bin/env python3
"""Read-only, bounded Dart/ArkTS channel inventory; not a Dart compiler.

Literal calls are compared with handlers reached from that channel's
setMethodCallHandler. Dynamic names stay UNKNOWN. A scoped exit status never
turns the complete inventory into a product/runtime PASS.
"""
import argparse
from collections import Counter, defaultdict
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re
from urllib.parse import unquote, urljoin, urlparse

FORKS = ('file_picker', 'flutter_secure_storage', 'image_picker', 'path_provider',
         'shared_preferences', 'url_launcher', 'webview_flutter')
CHANNELS = ('MethodChannel', 'EventChannel', 'BasicMessageChannel')
INVOKES = ('invokeMethod', 'invokeListMethod', 'invokeMapMethod')
# SystemChannels names in the fixed Flutter framework. This classifies the
# transport owner, not device support or a particular method's implementation.
SYSTEM_CHANNELS = {'flutter/navigation','flutter/backgesture','flutter/platform',
    'flutter/status_bar','flutter/processtext','flutter/textinput','flutter/scribe',
    'flutter/spellcheck','flutter/undomanager','flutter/keyevent','flutter/lifecycle',
    'flutter/system','flutter/accessibility','flutter/platform_views','flutter/platform_views_2',
    'flutter/skia','flutter/mousecursor','flutter/displaymetrics','flutter/restoration',
    'flutter/deferredcomponent','flutter/localization','flutter/menu','flutter/contextmenu',
    'flutter/keyboard','flutter/sensitivecontent','flutter/nativevsync'}

@dataclass(frozen=True)
class Token:
    value: str
    kind: str
    line: int

def lex(source):
    """Remove comments without interpreting Dart or interpolated strings."""
    result = []
    pattern = re.compile(r'''//[^\n]*|/\*[\s\S]*?\*/|(?:r)?(?:"""[\s\S]*?"""|\x27\x27\x27[\s\S]*?\x27\x27\x27|"(?:\\.|[^"\\])*"|\x27(?:\\.|[^\x27\\])*\x27|`(?:\\.|[^`\\])*`)|/(?:\\.|\[(?:\\.|[^\]\\])*\]|[^/\\\n])+/[a-z]*|[A-Za-z_$][\w$]*|\d+|===|!==|==|!=|=>|\?\.|&&|\|\||[^\s]''')
    cursor = 0
    while cursor < len(source):
        match = pattern.match(source, cursor)
        if match is None:
            cursor += 1
            continue
        raw = match.group()
        end = match.end()
        is_regex = raw.startswith('/') and len(raw)>1 and not raw.startswith(('//','/*'))
        if is_regex and result and result[-1].value not in ('(', '[', '{', '=', ',', ':', '!', 'return', 'case', '=>', '&&', '||', '?'):
            raw = '/'
            end = cursor + 1
            is_regex = False
        cursor = end
        if raw.startswith(('//', '/*')):
            continue
        line = source.count('\n', 0, match.start()) + 1
        if is_regex:
            result.append(Token(raw, 'regexp', source.count('\n', 0, match.start()) + 1))
            continue
        text = raw[1:] if raw.startswith(('r"', "r'")) else raw
        if text[0] in "\"'`":
            width = 3 if text.startswith(('"""', "'''")) else 1
            value = text[width:-width]
            kind = 'dynamic-string' if '$' in value else 'string'
            # Channel/method names do not need general string evaluation.
            if '\\' in value:
                kind = 'escaped-string'
            result.append(Token(value, kind, line))
        else:
            result.append(Token(raw, 'id' if re.fullmatch(r'[A-Za-z_$][\w$]*', raw) else 'punct', line))
    return result

def pairs(tokens):
    result, stack = {}, []
    for i, token in enumerate(tokens):
        if token.kind != 'punct':
            continue
        if token.value in ('(', '[', '{'):
            stack.append((token.value, i))
        elif token.value in (')', ']', '}'):
            if not stack or {'(': ')', '[': ']', '{': '}'}[stack[-1][0]] != token.value:
                continue
            _, start = stack.pop()
            result[start] = i
            result[i] = start
    return result

def args(tokens, opening, matching):
    end = matching.get(opening)
    if end is None:
        return []
    pieces, start, i = [], opening + 1, opening + 1
    while i < end:
        if tokens[i].value in ('(', '[', '{') and i in matching:
            i = matching[i] + 1
            continue
        if tokens[i].value == ',':
            pieces.append(tokens[start:i]); start = i + 1
        i += 1
    pieces.append(tokens[start:end])
    return pieces

def literal(part):
    return part[0].value if len(part) == 1 and part[0].kind == 'string' else None

def expression(part):
    return ' '.join(t.value for t in part)[:160]

def call_open(tokens, start):
    i = start
    if i < len(tokens) and tokens[i].value == '<':
        depth = 1; i += 1
        while i < len(tokens) and depth:
            if tokens[i].value == '<': depth += 1
            elif tokens[i].value == '>': depth -= 1
            i += 1
    return i if i < len(tokens) and tokens[i].value == '(' else None

def receiver(tokens, dot):
    if dot < 1:
        return None
    if tokens[dot - 1].kind == 'id':
        if dot >= 3 and tokens[dot - 2].value in ('.', '?.') and tokens[dot - 3].value == 'this':
            return 'this.' + tokens[dot - 1].value
        return tokens[dot - 1].value
    return None

def constructions(tokens, native=False):
    matching = pairs(tokens)
    rows = []
    for i, token in enumerate(tokens):
        if token.kind != 'id' or token.value not in CHANNELS:
            continue
        opening = call_open(tokens, i + 1)
        if opening is None:
            continue
        arguments = args(tokens, opening, matching)
        slot = 1 if native else 0
        name = literal(arguments[slot]) if len(arguments) > slot else None
        # Only bind the syntactically adjacent assignment, never all variables
        # or channels in the same source file.
        j = i - 1
        if j >= 0 and tokens[j].value in ('new', 'const'):
            j -= 1
        variable = None
        binding = 'assignment'
        # Constructor defaults preserve the caller's explicit injection. The
        # row records only the declared default channel, never a runtime value.
        if j >= 2 and tokens[j].value == '?' and tokens[j-1].value == '?':
            j -= 3
            binding = 'constructor-default'
        if j >= 1 and tokens[j].value == '=':
            lhs = j - 1
            # ArkTS local variable type annotation.
            if tokens[lhs].value in CHANNELS and lhs >= 2 and tokens[lhs - 1].value == ':': lhs -= 2
            variable = tokens[lhs].value
            if lhs >= 2 and tokens[lhs - 1].value == '.' and tokens[lhs - 2].value == 'this':
                variable = 'this.' + variable
        rows.append({'channel': name, 'kind': token.value, 'variable': variable,
                     'line': token.line, 'start': i, 'end': matching.get(opening),
                     'binding':binding, 'expression': expression(arguments[slot]) if len(arguments) > slot else ''})
    return rows

def dart_inventory(path, label):
    tokens = lex(path.read_text()); matching = pairs(tokens)
    constructors = constructions(tokens)
    bindings = defaultdict(set)
    for row in constructors:
        if row['variable'] and row['channel']:
            bindings[row['variable']].add(row['channel'])
            bindings[row['variable'].removeprefix('this.')].add(row['channel'])
    calls, callbacks = [], []
    for i, token in enumerate(tokens):
        if token.value not in (*INVOKES, 'setMethodCallHandler', 'receiveBroadcastStream', 'send') or i < 1 or tokens[i - 1].value not in ('.', '?.'):
            continue
        opening = call_open(tokens, i + 1)
        if opening is None: continue
        argv = args(tokens, opening, matching)
        variable = receiver(tokens, i - 1)
        related=[row for row in constructors if row['variable'] in (variable,'this.'+str(variable))]
        if token.value=='send' and not any(row['kind']=='BasicMessageChannel' for row in related):
            continue
        names = bindings.get(variable, set())
        # Inline const MethodChannel('...').invokeMethod(...).
        if i >= 2 and tokens[i - 2].value == ')':
            names = {row['channel'] for row in constructors if row['end'] == i - 2 and row['channel']}
        channel = next(iter(names)) if len(names) == 1 else None
        row = {'source': label, 'line': token.line, 'channel': channel,
               'receiver': variable, 'api': token.value,
               'method': literal(argv[0]) if argv and token.value in INVOKES else None,
               'expression': expression(argv[0]) if argv else '',
               'channelExpressions':[row['expression'] for row in related],
               'possibleChannels':sorted(names or {row['channel'] for row in constructors if row['channel']})}
        if token.value == 'setMethodCallHandler':
            row['classification'] = 'NATIVE_TO_DART_CALLBACK'; callbacks.append(row)
        elif token.value == 'receiveBroadcastStream':
            row['classification'] = 'EVENT_STREAM'; calls.append(row)
        elif token.value == 'send':
            row['classification'] = 'BASIC_MESSAGE_OR_PIGEON'; calls.append(row)
        else:
            row['classification'] = 'LITERAL' if channel and row['method'] else 'UNKNOWN_DYNAMIC'
            calls.append(row)
    return calls, callbacks, constructors

def method_bodies(tokens):
    """Local method declarations only; no cross-file or virtual dispatch claim."""
    matching = pairs(tokens); result = defaultdict(list)
    for i, token in enumerate(tokens):
        if token.kind != 'id' or token.value in ('if', 'while', 'switch', 'for', 'catch', 'with'):
            continue
        if i and tokens[i-1].value in ('.', '?.', 'new'):
            continue
        opening = call_open(tokens, i + 1)
        if opening is None or opening not in matching: continue
        end = matching[opening] + 1
        if end < len(tokens) and tokens[end].value == ':':
            end += 1
            while end < len(tokens) and tokens[end].value not in ('{', ';', '=', '=>'):
                end += 1
        if end < len(tokens) and tokens[end].value == '{' and end in matching:
            result[token.value].append(tokens[end+1:matching[end]])
    return result

def reached_bodies(seed, methods):
    result = list(seed); pending = [seed]; seen = set()
    while pending:
        body = pending.pop()
        for i in range(len(body)-3):
            if body[i].value == 'this' and body[i+1].value in ('.', '?.') and body[i+3].value == '(':
                name = body[i+2].value
                if name not in seen and len(methods.get(name, [])) == 1:
                    seen.add(name); next_body = methods[name][0]
                    pending.append(next_body); result.extend(next_body)
    return result, sorted(seen)

def dispatch_methods(tokens):
    """Collect dispatch switch/guard/table keys, not unrelated switch cases."""
    names, matching = set(), pairs(tokens)
    for i in range(len(tokens)):
        if tokens[i].value == 'switch' and i+1 in matching:
            cond = tokens[i+2:matching[i+1]]
            if expression(cond) not in ('call . method', 'methodCall . method'):
                continue
            start = matching[i+1]+1
            if start not in matching: continue
            j, end = start+1, matching[start]
            while j < end:
                if tokens[j].value == 'case' and j+1 < end and tokens[j+1].kind == 'string': names.add(tokens[j+1].value)
                if tokens[j].value == '{' and j in matching: j = matching[j]+1
                else: j += 1
        if i+4 < len(tokens) and tokens[i].value in ('call', 'methodCall') and tokens[i+1].value == '.' and tokens[i+2].value == 'method' and tokens[i+3].value in ('==', '===', '!=', '!==') and tokens[i+4].kind == 'string':
            names.add(tokens[i+4].value)
        if tokens[i].value == '[' and i in matching:
            end = matching[i]
            tail = expression(tokens[end+1:end+8])
            if tail in ('. includes ( call . method )', '. includes ( methodCall . method )'):
                values = args(tokens, i, matching)
                names.update(literal(v) for v in values if literal(v) is not None)
    return sorted(names)

def native_class_inventory(tokens, label, registered, class_name):
    matching = pairs(tokens); methods = method_bodies(tokens)
    constructors = constructions(tokens, native=True)
    bindings = defaultdict(list)
    for row in constructors:
        if row['variable']: bindings[row['variable']].append(row)
    rows = []
    for i, token in enumerate(tokens):
        if token.value not in ('setMethodCallHandler','setStreamHandler') or i<1:
            continue
        opening = call_open(tokens,i+1)
        if opening is None: continue
        argv=args(tokens,opening,matching)
        if not argv or expression(argv[0]) in ('null','undefined'): continue
        variable=receiver(tokens,i-1)
        for channel in bindings.get(variable,[]):
            seed=argv[0]
            if expression(seed)=='this':
                name='onMethodCall' if token.value=='setMethodCallHandler' else 'onListen'
                bodies=methods.get(name,[]); seed=bodies[0] if len(bodies)==1 else []
            reached, chain=reached_bodies(seed,methods)
            rows.append({'channel':channel['channel'],'kind':channel['kind'],'source':label,
                         'line':token.line,'class':class_name,'registration':'EXPLICIT_ENTRY' if class_name in registered else 'UNCONFIRMED_REGISTRATION',
                         'methods':dispatch_methods(reached),'handlerChain':chain,
                         'handlerResolved':bool(seed),'scope':'source dispatch recognition; not success/capability/device behavior'})
    return rows

def native_inventory(path, label, registered):
    tokens=lex(path.read_text()); matching=pairs(tokens); rows=[]
    for i, token in enumerate(tokens[:-1]):
        if token.value!='class': continue
        name=tokens[i+1].value; start=i+2
        while start<len(tokens) and tokens[start].value!='{': start+=1
        if start in matching:
            rows.extend(native_class_inventory(tokens[start+1:matching[start]],label,registered,name))
    return rows

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def package_roots(config):
    base=config.resolve().as_uri()
    return {row['name']:Path(unquote(urlparse(urljoin(base,row['rootUri'])).path))
            for row in json.loads(config.read_text())['packages']}

def fork_inventory(roots):
    rows=[]
    for name in FORKS:
        root=roots.get(name); row={'package':name,'root':str(root) if root else None,'status':'UNKNOWN_MISSING_PACKAGE','findings':[],'sources':[]}
        if root is None or not (root/'pubspec.yaml').is_file(): rows.append(row);continue
        pub=root/'pubspec.yaml'; text=pub.read_text()
        row['sources'].append({'path':str(pub),'sha256':sha(pub)})
        entry=root/'lib'/f'{name}.dart'
        row['dartEntry']={'path':str(entry),'sha256':sha(entry)} if entry.is_file() else None
        if entry.is_file():row['sources'].append(row['dartEntry'])
        row['ohosDeclaration']=bool(re.search(r'^\s{6}ohos:\s*$',text,re.M))
        row['status']='OH_DECLARATION_ONLY' if row['ohosDeclaration'] else 'NO_OH_DECLARATION'
        for path in sorted((root/'lib').rglob('*.dart')):
            source=path.read_text(); tokens=lex(source); flat=expression(tokens) if len(tokens)<50 else ' '.join(t.value for t in tokens)
            if 'TargetPlatform' in source or 'UnsupportedError' in source or 'Platform.is' in source or 'operatingSystem' in source or 'registerWith' in source:
                row['sources'].append({'path':str(path),'sha256':sha(path)})
            if 'defaultTargetPlatform' in flat and 'UnsupportedError' in flat and 'TargetPlatform . ohos' not in flat:
                selectors=method_bodies(tokens).get('_selectOptions',[])
                row['findings'].append({'path':str(path),
                    'kind':'OH_SELECT_OPTIONS_MISSING_BRANCH' if len(selectors)==1 else 'REVIEW_PLATFORM_SELECTOR_WITH_UNSUPPORTED',
                    'selector':'_selectOptions' if len(selectors)==1 else None,
                    'scope':'source branch inventory; independent from MethodChannel registration'})
            if name=='file_picker' and path.name=='file_picker_ohos.dart' and 'toFilePath' in flat and 'readAsByteStream' in flat and 'File (' in flat:
                row['findings'].append({'path':str(path),'kind':'OH_PICKER_URI_IS_NOT_LOCAL_FILE_CONTRACT','scope':'URI-to-local-File path requires an application copy/stream alternative; source evidence, no device claim'})
        # A federated declaration is not evidence that its selected Dart entry
        # and native package were present; show the actual dependency resolution.
        match=re.search(r'^\s{6}ohos:\s*\n\s{8}default_package:\s*(\w+)',text,re.M)
        channel_root=root
        if match:
            delegate=match.group(1); row['delegate']=delegate
            row['delegateRoot']=str(roots[delegate]) if delegate in roots else None
            if delegate not in roots: row['status']='UNKNOWN_DELEGATE_NOT_IN_CONFIG'
            else:
                channel_root=roots[delegate]
                for path in sorted((roots[delegate]/'lib').rglob('*.dart')):
                    body=path.read_text()
                    if 'registerWith' in body or 'TargetPlatform' in body or 'UnsupportedError' in body:
                        row['sources'].append({'path':str(path),'sha256':sha(path)})
                        row['findings'].append({'path':str(path),'kind':'FEDERATED_ENTRY_SOURCE','scope':'registered declaration, not runtime registration proof'})
        # Include the selected OH Dart package and any provided platform
        # interface. A missing delegate/interface remains visible, never guessed
        # from a sibling checkout or a package name alone.
        dart_roots=[channel_root]
        interface=name+'_platform_interface'
        if interface in text:
            if interface in roots: dart_roots.append(roots[interface])
            else: row['findings'].append({'kind':'UNKNOWN_PLATFORM_INTERFACE_SOURCE','package':interface})
        native_rows=[]; declarations=[]
        for path in sorted((channel_root/'ohos').rglob('*.ets')):
            body=path.read_text()
            if not any(kind in body for kind in CHANNELS):continue
            row['sources'].append({'path':str(path),'sha256':sha(path)})
            native_rows.extend(native_inventory(path,str(path),set()))
            declarations.extend({'channel':c['channel'],'expression':c['expression'],'kind':c['kind'],'path':str(path),'line':c['line']}
                                for c in constructions(lex(body),native=True))
        fork_calls=[]; fork_callbacks=[]
        for dart_root in dict.fromkeys(dart_roots):
            for path in sorted((dart_root/'lib').rglob('*.dart')):
                body=path.read_text()
                if not any(word in body for word in (*INVOKES,*CHANNELS)):continue
                row['sources'].append({'path':str(path),'sha256':sha(path)})
                calls,callbacks,_=dart_inventory(path,str(path));fork_callbacks.extend(callbacks)
                for call in calls:
                    matches=[item for item in native_rows if item['channel']==call['channel'] and call['channel']]
                    if call['classification']=='BASIC_MESSAGE_OR_PIGEON':call['status']='PIGEON_MESSAGE_REQUIRES_GENERATED_PROTOCOL_REVIEW'
                    elif not call['channel'] or not call['method']:call['status']='UNKNOWN_DYNAMIC'
                    elif any(call['method'] in item['methods'] for item in matches):call['status']='DECLARED_FORK_HANDLER_PRESENT'
                    elif not matches:call['status']='MISSING_OR_UNRESOLVED_FORK_CHANNEL'
                    else:call['status']='MISSING_FORK_METHOD'
                    fork_calls.append(call)
        row['dartCalls']=fork_calls
        row['callCounts']=dict(Counter(item['status'] for item in fork_calls))
        row['nativeToDartCallbacks']=fork_callbacks
        row['nativeHandlers']=native_rows
        row['nativeChannelDeclarations']=declarations
        row['channelScope']='fork source correspondence only; pubspec/registrant and device execution are separate'
        row['sources']=list({item['path']:item for item in row['sources']}.values())
        rows.append(row)
    return rows

def has_sequence(values, sequence):
    return any(values[i:i+len(sequence)]==sequence for i in range(len(values)-len(sequence)+1))

def class_default_bindings(tokens, class_name, declarations):
    """Match only fixed direct members of the named consumer, never its methods."""
    matching=pairs(tokens)
    classes=[]
    for i in range(len(tokens)-1):
        if tokens[i].value!='class' or tokens[i+1].value!=class_name:continue
        opening=next((j for j in range(i+2,len(tokens)) if tokens[j].value=='{'),None)
        if opening is not None and opening in matching:classes.append((opening,matching[opening]))
    starts=[]
    if len(classes)==1:
        opening,end=classes[0];i=opening+1
        while i<end:
            starts.append(i)
            if tokens[i].kind=='punct' and tokens[i].value in ('(', '[', '{') and i in matching:
                i=matching[i]+1
            else:i+=1
    values=[token.value for token in tokens]
    rows=[]
    for declaration in declarations:
        wanted=[token.value for token in lex(declaration)]
        rows.append({'declaration':declaration,
                     'matched':any(values[i:i+len(wanted)]==wanted for i in starts)})
    return rows

def application_overrides(source):
    """Recognize only this repository's explicit ADD15 defaults, not all Dart."""
    def values(relative):
        path=source/relative
        return [t.value for t in lex(path.read_text())] if path.is_file() else []
    wrapper='app/lib/secrets/secure_storage.dart'
    tokens=values(wrapper)
    secret_guard=(has_sequence(tokens,['_injected','==','null'])
                  and has_sequence(tokens,['Platform','.','operatingSystem',')','==','ohos']))
    # These are the actual five storage-field initializers/getters. An unrelated
    # AppSecureStorage() occurrence must not certify the consumer's default.
    consumers=[
        ('app/lib/remote/secret_store.dart','SecureSecretStore',[
            'SecureSecretStore([FlutterSecureStorage? storage]) : _storage = AppSecureStorage(storage);',
            'final AppSecureStorage _storage;']),
        ('app/lib/forum/forum_auth.dart','SecureForumStore',[
            'SecureForumStore([FlutterSecureStorage? storage]) : _storage = AppSecureStorage(storage);',
            'final AppSecureStorage _storage;']),
        ('app/lib/state/settings_state.dart','SettingsController',[
            'static const _secure = AppSecureStorage();']),
        ('app/lib/state/provider_keys.dart','SecureProviderKeyVault',[
            'const SecureProviderKeyVault([this._injected]);',
            'final FlutterSecureStorage? _injected;',
            'AppSecureStorage get _storage => AppSecureStorage(_injected);']),
        ('app/lib/share_hosted/hosted_links_state.dart','SecureHostedLinkStore',[
            'const SecureHostedLinkStore([this._injected]);',
            'final FlutterSecureStorage? _injected;',
            'AppSecureStorage get _storage => AppSecureStorage(_injected);'])]
    selected=[]
    for path,class_name,declarations in consumers:
        tokens=lex((source/path).read_text()) if (source/path).is_file() else []
        bindings=class_default_bindings(tokens,class_name,declarations)
        selected.append({'source':path,'sha256':sha(source/path) if (source/path).is_file() else None,
                         'class':class_name,'defaultBindings':bindings,
                         'explicitAdapterDefault':all(row['matched'] for row in bindings)})
    picker='app/lib/state/attachments.dart';p=values(picker)
    picker_selector=(has_sequence(p,['Platform','.','operatingSystem'])
                     and has_sequence(p,['==','ohos','?','const','OhosAttachmentPicker','(',')',':','const','DeviceAttachmentPicker','(',')'])
                     and has_sequence(p,['=>','createAttachmentPicker','(',')']))
    return {'secrets':{'status':'EXPLICIT_SOURCE_DEFAULTS' if secret_guard and all(x['explicitAdapterDefault'] for x in selected) else 'MISSING_OR_UNKNOWN_OH_DEFAULT',
                       'wrapper':wrapper,'wrapperSha256':sha(source/wrapper) if (source/wrapper).is_file() else None,
                       'guardRecognized':secret_guard,'consumers':selected},
            'attachments':{'status':'EXPLICIT_SOURCE_DEFAULTS' if picker_selector else 'MISSING_OR_UNKNOWN_OH_DEFAULT',
                           'source':picker,'sha256':sha(source/picker) if (source/picker).is_file() else None},
            'scope':'Recognized default-selector source shapes; arbitrary control flow and injected alternatives are not proven'}

def audit(source, roots, required=(), require_group1=False):
    app=source/'app'; native=app/'ohos/entry/src/main/ets'
    entry=native/'entryability/EntryAbility.ets'
    entry_tokens=lex(entry.read_text()) if entry.is_file() else []
    registered=set()
    for i in range(len(entry_tokens)-4):
        if ([x.value for x in entry_tokens[i:i+3]]==['add','(','new']
                and entry_tokens[i+3].kind=='id'
                and 'getPlugins' in [t.value for t in entry_tokens[max(0,i-8):i]]):
            registered.add(entry_tokens[i+3].value)
    dart,callbacks,declared=[],[],[]; sources={}
    for path in sorted((app/'lib').rglob('*.dart')):
        body=path.read_text()
        if not any(x in body for x in (*CHANNELS,*INVOKES,'receiveBroadcastStream','setMethodCallHandler')):continue
        label=path.relative_to(source).as_posix(); sources[label]=sha(path)
        calls,incoming,constructors=dart_inventory(path,label)
        dart.extend(calls);callbacks.extend(incoming)
        declared.extend({'source':label,'line':x['line'],'channel':x['channel'],'kind':x['kind']} for x in constructors)
    handlers=[]
    for path in sorted(native.rglob('*.ets')):
        if 'MethodChannel' not in path.read_text() and 'EventChannel' not in path.read_text():continue
        label=path.relative_to(source).as_posix();sources[label]=sha(path)
        handlers.extend(native_inventory(path,label,registered))
    if entry.is_file():sources[entry.relative_to(source).as_posix()]=sha(entry)
    for row in dart:
        channel=row['channel']; matches=[x for x in handlers if x['channel']==channel and channel is not None]
        row['nativeCandidates']=matches
        if channel in SYSTEM_CHANNELS:
            row['status']='SYSTEM_BUILTIN_NOT_APP_ARKTS'
        elif row['classification']=='UNKNOWN_DYNAMIC':row['status']='UNKNOWN_DYNAMIC'
        elif row['classification']=='BASIC_MESSAGE_OR_PIGEON':row['status']='PIGEON_MESSAGE_REQUIRES_GENERATED_PROTOCOL_REVIEW'
        elif not matches:row['status']='MISSING_CHANNEL'
        elif not any(x['registration']=='EXPLICIT_ENTRY' for x in matches):row['status']='UNCONFIRMED_REGISTRATION'
        elif row['classification']=='EVENT_STREAM':row['status']='EVENT_HANDLER_PRESENT'
        elif any(row['method'] in x['methods'] and x['registration']=='EXPLICIT_ENTRY' for x in matches):row['status']='HANDLER_PRESENT'
        elif any(not x['handlerResolved'] for x in matches):row['status']='UNKNOWN_HANDLER'
        else:row['status']='MISSING_METHOD'
    checks=[]
    if require_group1:
        required=tuple(dict.fromkeys([*required,'dsh/secrets','dsh/attachment-files']))
    for channel in required:
        calls=[row for row in dart if (row['channel']==channel or (row['channel'] is None and channel in row['possibleChannels'])) and row['api'] in INVOKES]
        native_rows=[row for row in handlers if row['channel']==channel]
        errors=[row for row in calls if row['status']!='HANDLER_PRESENT']
        if not calls:errors.append({'status':'NO_DART_CALLS','channel':channel})
        if not native_rows:errors.append({'status':'NO_NATIVE_CHANNEL','channel':channel})
        checks.append({'channel':channel,'status':'PASS_SCOPED' if not errors else 'FAIL','errors':errors})
    overrides=application_overrides(source)
    if require_group1:
        for name in ('secrets','attachments'):
            checks.append({'applicationDefault':name,'status':'PASS_SCOPED' if overrides[name]['status']=='EXPLICIT_SOURCE_DEFAULTS' else 'FAIL','evidence':overrides[name]})
    counts=dict(Counter(row['status'] for row in dart))
    forks=fork_inventory(roots)
    incomplete=any(row['status'] not in ('HANDLER_PRESENT','EVENT_HANDLER_PRESENT','SYSTEM_BUILTIN_NOT_APP_ARKTS') for row in dart)
    incomplete=incomplete or any(row['status'].startswith(('UNKNOWN','NO_OH')) or row['findings'] for row in forks)
    return {'schema':1,'scope':'Mechanical source inventory; no runtime, capability, data-shape, or device guarantee',
            'fullInventoryStatus':'INCOMPLETE' if incomplete else 'LITERAL_DISPATCHES_MATCHED',
            'gateStatus':'FAIL' if any(row['status']=='FAIL' for row in checks) else ('PASS_SCOPED' if checks else 'INVENTORY_ONLY'),
            'required':checks,'counts':counts,'forks':forks,'applicationOverrides':overrides,
            'dartCalls':dart,'nativeToDartCallbacks':callbacks,'channelDeclarations':declared,
            'nativeHandlers':handlers,'entryRegisteredClasses':sorted(registered),'sourceSha256':sources,
            'limitations':['No general Dart or ArkTS control-flow analysis','Dynamic methods/aliases remain UNKNOWN; they are never auto-passed',
                'Callbacks and EventChannel are separate directions, not invokeMethod handlers',
                'A recognized handler can deliberately return unsupported; presence is not functional success',
                'Fork OH declaration/selector findings remain independent of application handler matching']}

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,required=True)
    inputs=parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument('--package-config',type=Path)
    inputs.add_argument('--fork-roots',type=Path,help='Explicit source-review roots JSON, not a pub-resolution receipt')
    parser.add_argument('--require-channel',action='append',default=[])
    parser.add_argument('--require-group1',action='store_true',help='Require both ADD15 channels, registration, and the explicit five-secrets/two-picker defaults')
    parser.add_argument('--report',type=Path,required=True)
    args_=parser.parse_args()
    roots=package_roots(args_.package_config) if args_.package_config else {k:Path(v) for k,v in json.loads(args_.fork_roots.read_text()).items()}
    report=audit(args_.source.resolve(),roots,args_.require_channel,args_.require_group1)
    report['forkInputKind']='resolved-package-config' if args_.package_config else 'explicit-source-review-roots'
    args_.report.parent.mkdir(parents=True,exist_ok=True)
    args_.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({'gateStatus':report['gateStatus'],'fullInventoryStatus':report['fullInventoryStatus'],'counts':report['counts']},ensure_ascii=False))
    return 1 if report['gateStatus']=='FAIL' else 0

if __name__=='__main__':
    raise SystemExit(main())
