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
    # Catch sites: cd, input/readwrite descriptor, direct input redirection, cat.
    index = 'index.js'
    cat = 'chunks/chunk-MHDZERK4.js'
    change(index, 'catch{return T(`bash: cd: ${n}: No such file or directory\n`)}', 'catch(ohosError){return T(`bash: cd: ${n}: ${' + denial('ohosError') + '?"EACCES: Permission denied":"No such file or directory"}\n`)}')
    change(index, 'catch{if(!n)return{error:L("",`bash: ${t}: No such file or directory\n`,1)};', 'catch(ohosError){if(' + denial('ohosError') + ')return{error:L("",`bash: ${t}: EACCES: Permission denied\n`,1)};if(!n)return{error:L("",`bash: ${t}: No such file or directory\n`,1)};')
    change(index, '}catch{return{error:L("",`bash: ${t}: No such file or directory\n`,1)}}}}var Ip=', '}catch(ohosError){return{error:L("",`bash: ${t}: ${' + denial('ohosError') + '?"EACCES: Permission denied":"No such file or directory"}\n`,1)}}}}var Ip=')
    change(index, 'catch{return h(L("",`bash: ${v}: No such file or directory\n`,1),y)}}else if(g.operator==="<>")', 'catch(ohosError){return h(L("",`bash: ${v}: ${' + denial('ohosError') + '?"EACCES: Permission denied":"No such file or directory"}\n`,1),y)}}else if(g.operator==="<>")')
    change(cat, '$(T),h+=`cat: ${y}: No such file or directory\n`,d=1', '$(T),h+=`cat: ${y}: ${' + denial('T') + '?"EACCES: Permission denied":"No such file or directory"}\n`,d=1')
    change(index, 'let A=b+v;A!==""&&(p.kind==="file"', 'let A=b+(d==="binary"?Ut(v):v);A!==""&&(p.kind==="file"')
    change(index, 'case"live-stdout":l+=A;break;case"live-stderr":c+=A;break;', 'case"live-stdout":l+=!N&&d==="binary"?Ut(A):A;break;case"live-stderr":c+=N&&d==="binary"?Qf(A):A;break;')
    change(index, 'case"file":await k(P,A,N?h(A):Du(A));break;', 'case"file":await k(P,A,N?h(A):"utf8");break;')
    change(index, 'case"descriptor":await vo(e,P.source.entry,P.source.descriptors,A,N?h(A):Du(A));break;', 'case"descriptor":await vo(e,P.source.entry,P.source.descriptors,A,N?h(A):"utf8");break;')
    change(index, 'v=M(y.stdout),k=M(y.stderr),A=Math.min(v,b);', 'v=d==="binary"?y.stdout.length:M(y.stdout),k=M(y.stderr),A=Math.min(v,b);')
    change(index, 'r.appendResult(i,ii(i))', 'r.appendResult(i)')
    change(index, 'n.appendResult(f,ii(f))', 'n.appendResult(f)')
    change(index, 't.stdout=jf(t.stdout),t.stderr=jf(t.stderr),t', 'Kf(t)!=="bytes"&&(t.stdout=jf(t.stdout)),t.stderr=jf(t.stderr),t')
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
    change(accumulator, 's&&(t==="stdout"?this.stdoutChunks:this.stderrChunks).push(s)', 's&&(t==="stdout"?this.stdoutChunks:this.stderrChunks).push(t==="stdout"&&r==="text"?ohosEncode(s):s)')
    change(accumulator, 'build(t,s){return{stdout:this.stdoutChunks.join(""),', 'build(t,s){let ohosRaw=this.stdoutChunks.join(""),ohosText=ohosDecode(ohosRaw),ohosValid=ohosEncode(ohosText)===ohosRaw;return{stdout:ohosValid?ohosText:ohosRaw,')
    change(accumulator, 'exitCode:t,...s,internalOutputAccounting:', 'exitCode:t,...s,stdoutKind:ohosValid?"text":"bytes",stdoutEncoding:ohosValid?void 0:"binary",internalOutputAccounting:')
    change(accumulator, 'get stdout(){return this.stdoutChunks.join("")}', 'get stdout(){return ohosDecode(this.stdoutChunks.join(""))}')
    change(accumulator, 'get stderr(){return this.stderrChunks.join("")}', 'ohosResetAfterDelivery(){this.stdoutChunks.length=0,this.stderrChunks.length=0,this.stdoutBytes=0,this.stderrBytes=0}get stderr(){return this.stderrChunks.join("")}')
    notice = ('/* Modified for dsh-go OHOS: permission diagnostics, typed output and statement delivery.\n'
              ' * Derived from just-bash 3.6.0; Apache-2.0. See LICENSE and PROVENANCE.json. */\n')
    return {name: (notice + text).encode('utf-8') for name, text in texts.items()}
