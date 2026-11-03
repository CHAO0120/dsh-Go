"""Local OH-only fixes applied to exactly pinned just-bash 3.6.0 ESM inputs.

Inputs and outputs are reviewed published JavaScript, not an upstream TS
rebuild. Each replacement has one occurrence after whole-file verification.
"""

def rewrite(inputs):
    texts = {name: data.decode('utf-8') for name, data in inputs.items()}

    def denial(error):
        return f'({error}?.code==="EACCES"||({error} instanceof Error&&/^EACCES:/.test({error}.message)))'

    def change(name, before, after):
        if texts[name].count(before) != 1:
            raise ValueError('unique pinned anchor mismatch: ' + before[:100])
        texts[name] = texts[name].replace(before, after)
    def change_many(name, before, after, expected):
        if texts[name].count(before) != expected:
            raise ValueError('fixed pinned anchor count mismatch: ' + before[:100])
        texts[name] = texts[name].replace(before, after)
    # Catch sites: cd, input/readwrite descriptor, direct input redirection, cat.
    index = 'index.js'
    cat = 'chunks/chunk-MHDZERK4.js'
    change(index, 'catch{return T(`bash: cd: ${n}: No such file or directory\n`)}', 'catch(ohosError){return T(`bash: cd: ${n}: ${' + denial('ohosError') + '?"EACCES: Permission denied":"No such file or directory"}\n`)}')
    change(index, 'catch{if(!n)return{error:L("",`bash: ${t}: No such file or directory\n`,1)};', 'catch(ohosError){if(' + denial('ohosError') + ')return{error:L("",`bash: ${t}: EACCES: Permission denied\n`,1)};if(!n)return{error:L("",`bash: ${t}: No such file or directory\n`,1)};')
    change(index, '}catch{return{error:L("",`bash: ${t}: No such file or directory\n`,1)}}}}var Ip=', '}catch(ohosError){return{error:L("",`bash: ${t}: ${' + denial('ohosError') + '?"EACCES: Permission denied":"No such file or directory"}\n`,1)}}}}var Ip=')
    change(index, 'catch{return h(L("",`bash: ${v}: No such file or directory\n`,1),y)}}else if(g.operator==="<>")', 'catch(ohosError){return h(L("",`bash: ${v}: ${' + denial('ohosError') + '?"EACCES: Permission denied":"No such file or directory"}\n`,1),y)}}else if(g.operator==="<>")')
    change(cat, '$(T),h+=`cat: ${y}: No such file or directory\n`,d=1', '$(T),h+=`cat: ${y}: ${' + denial('T') + '?"EACCES: Permission denied":"No such file or directory"}\n`,d=1')
    change(index, 'r.appendResult(i,ii(i))', 'r.appendResult(i)')
    change(index, 'n.appendResult(f,ii(f))', 'n.appendResult(f)')
    change(index, 't.stdout=jf(t.stdout),t.stderr=jf(t.stderr),t', 'Kf(t)!=="bytes"&&(t.stdout=jf(t.stdout)),t.stderrKind!=="bytes"&&(t.stderr=jf(t.stderr)),t')
    # The host enters through the single, literal bash/sh command. Its first
    # nested exec is the requested shell program; only that executeScript call
    # receives the sink. Captures, pipelines, functions, eval/source and nested
    # shells retain their normal result-routing semantics. A completed outer
    # statement is delivered after accounting and redirection, then forgotten
    # by this accumulator; the shared ExecutionScope budget is never reset.
    change(index, 'async exec(t,n){let r=new jr(this.limits,n?.signal),s;', 'async exec(t,n){if(n?.ohosStatementOutput!==void 0&&(typeof n.ohosStatementOutput!=="function"||(t!=="bash"&&t!=="sh")))throw new TypeError("OHOS statement sink requires a literal bash/sh entry");let r=new jr(this.limits,n?.signal),s;')
    change(index, 'this.execInScope(t,n,r,0,n?.signal,!1,!1)', 'this.execInScope(t,n,r,0,n?.signal,!1,!1,n?.ohosStatementOutput)')
    change(index, 'async execInScope(t,n,r,s,i,o=!1,a=!0){', 'async execInScope(t,n,r,s,i,o=!1,a=!0,ohosStatementOutput){')
    change(index, 'exec:(x,C,D=!1)=>this.execInScope(x,C,r,s+1,u.signal,D)', 'exec:(x,C,D=!1)=>this.execInScope(x,C,r,s+1,u.signal,D,!0,ohosStatementOutput)')
    change(index, 'N=await new Nr(k,m).executeScript(b)', 'N=await new Nr(k,m).executeScript(b,s===1?ohosStatementOutput:void 0)')
    change(index, 'async executeScript(t){this.assertDefenseContext("execution");', 'async executeScript(t,ohosStatementOutput){this.assertDefenseContext("execution");')
    change(index, 'r.appendResult(i),n=i.exitCode,this.ctx.state.lastExitCode=n', 'r.appendResult(i),ohosStatementOutput&&(await ohosStatementOutput(r.build(i.exitCode)),r.ohosResetAfterDelivery()),n=i.exitCode,this.ctx.state.lastExitCode=n')
    # Keep arbitrary bytes through aggregation; return text only for an exact
    # UTF-8 round trip so existing Unicode compound-command paths retain shape.
    accumulator = 'chunks/chunk-J2OBOJ64.js'
    change(accumulator, 'import{a as i}from"./chunk-GN6CQ3J4.js";', 'import{a as i,d as ohosDecode,e as ohosEncode}from"./chunk-GN6CQ3J4.js";')
    change(accumulator, 's&&(t==="stdout"?this.stdoutChunks:this.stderrChunks).push(s)', 's&&(t==="stdout"?this.stdoutChunks:this.stderrChunks).push(r==="text"?ohosEncode(s):s)')
    change(accumulator, 'build(t,s){return{stdout:this.stdoutChunks.join(""),', 'build(t,s){let ohosRaw=this.stdoutChunks.join(""),ohosText=ohosDecode(ohosRaw),ohosValid=ohosEncode(ohosText)===ohosRaw;return{stdout:ohosValid?ohosText:ohosRaw,')
    change(accumulator, 'exitCode:t,...s,internalOutputAccounting:', 'exitCode:t,...s,stderrKind:"bytes",stdoutKind:ohosValid?"text":"bytes",stdoutEncoding:ohosValid?void 0:"binary",internalOutputAccounting:')
    # Control-flow transfers use the accumulator's raw byte string. Decoding
    # belongs at an explicitly textual consumer, never at an error boundary.
    change(accumulator, 'get stderr(){return this.stderrChunks.join("")}', 'ohosResetAfterDelivery(){this.stdoutChunks.length=0,this.stderrChunks.length=0,this.stdoutBytes=0,this.stderrBytes=0}get stderr(){return this.stderrChunks.join("")}')
    # stderr is a byte string inside the OH interpreter. Text diagnostics enter
    # through explicit UTF-8 conversion; routing and aggregation never guess
    # encoding from byte values. No shared/npm built-in is modified.
    change(index, 'async function mn(', 'function ohosStderrBytes(t){return t.stderrKind==="bytes"?t.stderr:Ut(t.stderr)}function ohosStderrResult(t){return t.stderrKind==="bytes"?t:{...t,stderr:ohosStderrBytes(t),stderrKind:"bytes"}}function ohosOutputMetadata(t){return{stdoutKind:Kf(t),stderrKind:t.stderrKind,internalOutputAccounting:t.internalOutputAccounting}}async function mn(')
    change(index, 'let{stdout:l,stderr:c,exitCode:u}=t,d=t.stdoutKind==="bytes"||t.stdoutKind===void 0&&t.stdoutEncoding==="binary"?"binary":"utf8",h=b=>d,', 'let l=_t(t),c=ohosStderrBytes(t),u=t.exitCode,d="binary",h=b=>d,')
    change(index, 'case"file":await k(P,A,N?h(A):Du(A));break;', 'case"file":await k(P,A,"binary");break;')
    change(index, 'case"descriptor":await vo(e,P.source.entry,P.source.descriptors,A,N?h(A):Du(A));break;', 'case"descriptor":await vo(e,P.source.entry,P.source.descriptors,A,"binary");break;')
    # A dup keeps the prepared open-description identity. In particular,
    # 2>file 1>&2 must not append stdout and then truncate it with stderr.
    # Equal path names from two independent opens are deliberately not aliases.
    change(index, 'if(l!==""||c!==""){let b=l,v=c;', 'if(i.get(1)===i.get(2)&&["output","readwrite"].includes(i.get(1)?.kind))p=m=S(1);if(l!==""||c!==""){let b=l,v=c;')
    change(index, 'if(t.stdoutKind&&(y.stdoutKind=t.stdoutKind),t.stdoutEncoding==="binary"&&(y.stdoutEncoding="binary"),', 'if(y.stdoutKind="bytes",y.stdoutEncoding="binary",y.stderrKind="bytes",')
    change(index, 'v=M(y.stdout),k=M(y.stderr),A=Math.min(v,b);', 'v=y.stdout.length,k=y.stderr.length,A=Math.min(v,b);')
    change(index, 'l=this.appendOutput("stderr",t.stderr,n,o);', 'l=this.appendOutput("stderr",t.stderr,n,o,t.stderrKind==="bytes"?"bytes":"text");')
    change(index, 'let o=await eo(this.ctx,s);return!o.stdout', 'i=ohosStderrResult(i);let o=await eo(this.ctx,s);return!o.stdout')
    change(index, 'stderr:i.stderr+o.stderr}', 'stderr:i.stderr+o.stderr,stderrKind:"bytes"}')
    change(index, 'r+=_t(a),s+=a.stderr', 'r+=_t(a),s+=ohosStderrBytes(a)')
    change(index, 's=Ut(N.stderr)+_t(N)', 's=ohosStderrBytes(N)+_t(N)')
    change(index, 'l+=N.stderr,c+=', 'l+=ohosStderrBytes(N),c+=')
    change(index, 'stderr:l+i.stderr,internalOutputAccounting:', 'stderr:l+ohosStderrBytes(i),stderrKind:"bytes",internalOutputAccounting:')
    change(index, 'append(t,n){let r=M(t)+M(n);', 'append(t,n){let r=t.length+n.length;')
    change(index, 'appendUnaccounted(t,n){this.ctx.executionScope.appendOutput("stdout",t,"control-flow"),this.ctx.executionScope.appendOutput("stderr",n,"control-flow"),this.append(t,n)}', 'appendUnaccounted(t,n){t=Ut(t),n=Ut(n);this.ctx.executionScope.appendOutput("stdout",t,"control-flow",0,"bytes"),this.ctx.executionScope.appendOutput("stderr",n,"control-flow",0,"bytes"),this.append(t,n)}')
    change(index, 'return{stdout:n,stderr:r,exitCode:t,internalOutputAccounting:{stdout:M(n),stderr:M(r)}}', 'return{stdout:n,stdoutKind:"bytes",stderr:r,stderrKind:"bytes",exitCode:t,internalOutputAccounting:{stdout:n.length,stderr:r.length}}')
    change(index, 'stderr:A+v.stderr}', 'stderr:Ut(A)+ohosStderrBytes(v),stderrKind:"bytes"}')
    change(index, 'let x=(this.ctx.state.expansionStderr||"")+o;return this.ctx.state.expansionStderr="",L("",x,cs(this.ctx.state,[]))', 'let x=(this.ctx.state.expansionStderr||"")+Ut(o);return this.ctx.state.expansionStderr="",{...L("",x,cs(this.ctx.state,[])),stderrKind:"bytes"}')
    change_many(index, 'stderr:this.ctx.state.expansionStderr+r.stderr}', 'stderr:this.ctx.state.expansionStderr+ohosStderrBytes(r),stderrKind:"bytes"}', 2)
    change(accumulator, 'this.append("stderr",t.stderr,t.internalOutputAccounting?.stderr??0)', 'this.append("stderr",t.stderr,t.internalOutputAccounting?.stderr??0,t.stderrKind==="bytes"?"bytes":"text")')
    change(accumulator, 't.prependOutput(this.stdout,this.stderr)', 't.prependOutput(this.stdout,this.stderr,"bytes","bytes")')
    errors = 'chunks/chunk-EFORKKSH.js'
    change(errors, 'import{a as c}from"./chunk-GN6CQ3J4.js";', 'import{a as c,e as ohosEncode}from"./chunk-GN6CQ3J4.js";')
    change(errors, 'prependOutput(t,e){this.stdout=t+this.stdout,this.stderr=e+this.stderr,this.internalOutputAccounting.stdout+=c(t),this.internalOutputAccounting.stderr+=c(e)}', 'prependOutput(t,e,k="text",s="text"){let b=k==="bytes"?e:ohosEncode(e),a=s==="bytes"?t:ohosEncode(t);this.stdout=a+(this.stdoutKind==="bytes"||this.stdoutEncoding==="binary"?this.stdout:ohosEncode(this.stdout)),this.stdoutKind="bytes",this.stderr=b+(this.stderrKind==="bytes"?this.stderr:ohosEncode(this.stderr)),this.stderrKind="bytes",this.internalOutputAccounting.stdout+=a.length,this.internalOutputAccounting.stderr+=b.length}')
    # The published bundle has a fixed set of error/loop transfer sites. Count
    # every rewrite so an upstream shape change cannot silently omit a path.
    import re
    def counted(pattern, replacement, count):
        value, actual = re.subn(pattern, replacement, texts[index])
        if actual != count:
            raise ValueError(f'fixed output transfer count differs: {pattern}: {actual} != {count}')
        texts[index] = value
    counted(r'\.prependOutput\(([a-zA-Z]+)\.stdout,\1\.stderr\)', r'.prependOutput(\1.stdout,\1.stderr,"bytes","bytes")', 6)
    counted(r'L\(([^,()]+),([a-zA-Z]+)\.stderr,([^()]+?)\)', r'({...L(\1,\2.stderr,\3),...ohosOutputMetadata(\2)})', 11)
    counted(r'\{stdout:([a-zA-Z]+)\.stdout,stderr:\1\.stderr,exitCode:([^}]+)\}', r'{stdout:\1.stdout,stderr:\1.stderr,exitCode:\2,...ohosOutputMetadata(\1)}', 9)
    counted(r'append\("stdout",([a-zA-Z]+)\.stdout,\1\.internalOutputAccounting\.stdout\)', r'append("stdout",\1.stdout,\1.internalOutputAccounting.stdout,Kf(\1))', 8)
    counted(r'append\("stdout",([a-zA-Z]+)\.stdout\)', r'append("stdout",\1.stdout,0,Kf(\1))', 1)
    counted(r'append\("stderr",([a-zA-Z]+)\.stderr,\1\.internalOutputAccounting\.stderr\)', r'append("stderr",\1.stderr,\1.internalOutputAccounting.stderr,\1.stderrKind??"text")', 8)
    counted(r'append\("stderr",([a-zA-Z]+)\.stderr\)', r'append("stderr",\1.stderr,0,\1.stderrKind??"text")', 1)
    # The older loop accumulator also receives typed command/error results.
    # Keep both streams as bytes inside it, and preserve already-accounted
    # byte counts when a multi-level break/continue crosses another loop.
    counted(r'\.append\(([a-zA-Z]+)\.stdout,\1\.stderr\)', r'.append(_t(\1),ohosStderrBytes(\1))', 10)
    counted(r't\+=e\.stdout', 't+=_t(e)', 2)
    counted(r'n\+=e\.stderr', 'n+=ohosStderrBytes(e)', 2)
    counted(r'e\.stderr=n', 'e.stderr=n,e.stdoutKind="bytes",e.stderrKind="bytes",e.internalOutputAccounting={stdout:t.length,stderr:n.length}', 2)
    counted(r'h\.stdout=s\.stdout,h\.stderr=s\.stderr', 'h.stdout=s.stdout,h.stderr=s.stderr,h.stdoutKind="bytes",h.stderrKind="bytes",h.internalOutputAccounting={stdout:s.stdout.length,stderr:s.stderr.length}', 2)
    counted(r'\.prependOutput\(t,n\)', '.prependOutput(t,n,"bytes","bytes")', 1)
    counted(r'stdout:([a-zA-Z]+)\.stdout,stderr:kt\(\1\.stderr\)', r'stdout:\1.stdout,stdoutKind:Kf(\1),stderr:kt(\1.stderr),stderrKind:\1.stderrKind', 2)
    change(index, 't.stdout=i.stdout,t.stderr=i.stderr,t.internalOutputAccounting=', 't.stdout=i.stdout,t.stdoutKind=Kf(i),t.stderr=i.stderr,t.stderrKind=i.stderrKind,t.internalOutputAccounting=')
    change(index, 'i.internalOutputAccounting??{stdout:M(i.stdout),stderr:M(i.stderr)}', 'i.internalOutputAccounting??{stdout:_t(i).length,stderr:ohosStderrBytes(i).length}')
    change(index, 'e.errorCause.stdout=e.error.stdout,e.errorCause.stderr=e.error.stderr,e.errorCause', 'e.errorCause.stdout=e.error.stdout,e.errorCause.stdoutKind=Kf(e.error),e.errorCause.stderr=e.error.stderr,e.errorCause.stderrKind=e.error.stderrKind,e.errorCause')
    # Command substitution is explicitly a textual consumer. Both a caught
    # exit and a nested exec result may now carry bytes; decode only here.
    change(index, 'c.stdout?.replace(/\\n+$/,"")??""', 'ii(c).replace(/\\n+$/,"")')
    change(index, 'u.stdout.replace(/\\n+$/,"")', 'ii(u).replace(/\\n+$/,"")')
    change_many(index, 'c.stdout.replace(/\\n+$/,"")', 'ii(c).replace(/\\n+$/,"")', 2)
    change_many(index, 'h.stdout.replace(/\\n+$/,"")', 'ii(h).replace(/\\n+$/,"")', 2)
    change(index, 'function Cr(', 'function ohosControlFlowLimit(t,n,r,s){try{cn(t,n,r,s)}catch(e){if(e instanceof $)e.stdoutKind="bytes",e.stderrKind="bytes",e.internalOutputAccounting={stdout:r.length,stderr:s.length};throw e}}function Cr(')
    counted(r'cn\((`[^`]+`),"iterations",([a-zA-Z]+)\.stdout,\2\.stderr\)', r'ohosControlFlowLimit(\1,"iterations",\2.stdout,\2.stderr)', 4)
    change(index, 'stderr:`${n}${s}\n`,exitCode:1', 'stderr:n+Ut(`${s}\n`),stderrKind:"bytes",exitCode:1')
    change(index, 'c+=`bash: echo: write error: No space left on device\n`,', 'c+=Ut(`bash: echo: write error: No space left on device\n`),')
    change(index, 'v+=`${a?"":"bash: "}${o}: write error: Bad file descriptor\n`,', 'v+=Ut(`${a?"":"bash: "}${o}: write error: Bad file descriptor\n`),')
    notice = ('/* Modified for dsh-go OHOS: permission diagnostics, typed output and statement delivery.\n'
              ' * Derived from just-bash 3.6.0; Apache-2.0. See LICENSE and PROVENANCE.json. */\n')
    return {name: (notice + text).encode('utf-8') for name, text in texts.items()}
