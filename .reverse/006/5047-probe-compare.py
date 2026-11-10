#!/usr/bin/env python3
"""仅验证辅助：原生产基底 + 共同兼容 probe，与候选各运行一次。"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

BASE = "1c5b220093295f8d069f6bfb06d8b4fc97b9e9c2"
DIRECT = Path("runtime/tests/direct")
RUNTIME = Path("app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/runtime")
PRODUCTION = [RUNTIME / name for name in (
    "DshProcess.kt", "LogRedactor.kt", "ProotTempFiles.kt", "LaunchDiagnostics.kt",
    "DirectLaunch.kt", "L2sMigration.kt", "RuntimeProcessOwnership.kt", "SpeechGuest.kt")]
PROBES = [DIRECT / "cleanup-probe/CleanupObservationProbe.kt"] + [
    DIRECT / "startup-probe" / (name + ".kt") for name in (
        "StartupPolicyProbe", "ProcessRetryProbe", "ProcessScopeProbe",
        "ProcessCaptureProbe", "ProotTempCleanupProbe")]
THREE = "override fun onLog(line: String, stream: String, storageLine: String)"
TWO = "override fun onLog(line: String, stream: String)"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def production(repo):
    # The baseline has no LogRedactor; a candidate may have it untracked after git apply.
    return {str(name): sha((repo / name).read_bytes()) if (repo / name).is_file() else None
            for name in PRODUCTION}


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def proc_observation():
    """只保存成败/errno，不保存字段内容；这是旁证，不是生产失败瞬间的扫描。"""
    uid = os.stat("/proc/self").st_uid
    result = {"at": datetime.now(timezone.utc).isoformat(), "observerPid": os.getpid(),
              "uid": uid, "gid": os.getegid(), "kernel": os.uname().release,
              "scope": "side observation, not the production scan at its failure instant",
              "sameUid": [], "uidErrors": []}

    def attempt(read):
        try:
            read()
            return {"ok": True}
        except OSError as exc:
            return {"ok": False, "errno": exc.errno, "type": type(exc).__name__}

    try:
        pids = sorted(int(p.name) for p in Path("/proc").iterdir() if p.name.isdigit())
    except OSError as exc:
        result["enumerationError"] = {"errno": exc.errno, "type": type(exc).__name__}
        return result
    for pid in pids:
        if pid == os.getpid():
            continue
        directory = Path("/proc") / str(pid)
        try:
            owner = directory.stat().st_uid
        except OSError as exc:
            result["uidErrors"].append({"pid": pid, "errno": exc.errno, "type": type(exc).__name__})
            continue
        if owner != uid:
            continue
        row = {"pid": pid, "uid": uid}
        for field in ("stat", "cmdline", "environ"):
            row[field] = attempt(lambda p=directory / field: p.read_bytes())
        row["cwd"] = attempt(lambda: os.readlink(directory / "cwd"))
        result["sameUid"].append(row)
    return result


def logged(command, repo, folder, name):
    started = datetime.now(timezone.utc).isoformat()
    completed = subprocess.run(command, cwd=repo, text=True, encoding="utf-8",
                               errors="replace", capture_output=True)
    (folder / (name + ".stdout.log")).write_text(completed.stdout, encoding="utf-8")
    (folder / (name + ".stderr.log")).write_text(completed.stderr, encoding="utf-8")
    write_json(folder / (name + ".command.json"), {
        "argv": list(map(str, command)), "started": started,
        "finished": datetime.now(timezone.utc).isoformat(), "exit": completed.returncode})
    return completed


def excerpt(text, lines=40, chars=10000):
    chosen = "\n".join(text.splitlines()[:lines])
    return {"text": chosen[:chars], "truncated": len(chosen) > chars or len(text.splitlines()) > lines}


def case_result(folder, name):
    stdout = (folder / (name + ".stdout.log")).read_text(encoding="utf-8")
    stderr = (folder / (name + ".stderr.log")).read_text(encoding="utf-8")
    values = []
    for line in stdout.splitlines():
        try:
            value = json.loads(line)
            if isinstance(value, dict):
                values.append(value)
        except ValueError:
            pass
    result = {"case": name, "stderrHead": excerpt(stderr)}
    if values:
        value = values[-1]
        logs = value.get("logs")
        if isinstance(logs, list) and (len(logs) > 20 or any(len(str(s)) > 2000 for s in logs)):
            value["logs"] = [str(s)[:2000] for s in logs[-20:]]
            value["logsExcerpted"] = True
            value["originalLogCount"] = len(logs)
        result["json"] = value
    else:
        result["stdoutHead"] = excerpt(stdout)
    return result


def observation_summary(data):
    return {"at": data["at"], "uidErrors": data["uidErrors"],
            "sameUidCount": len(data["sameUid"]), "enumerationError": data.get("enumerationError"),
            "fieldErrors": [{"pid": row["pid"], "field": field, **value}
                            for row in data["sameUid"] for field, value in row.items()
                            if isinstance(value, dict) and not value["ok"]]}


def arm(label, repo, out):
    folder = out / label
    folder.mkdir()
    pre = proc_observation()
    write_json(folder / "proc-before.json", pre)
    startup_out = folder / "startup-policy"
    startup = logged([sys.executable, str(repo / DIRECT / "startup-policy.py"),
                      "--output", str(startup_out)], repo, folder, "startup")
    summary_path = startup_out / "summary.json"
    summary = json.loads(summary_path.read_text()) if summary_path.is_file() else None
    commands_path = startup_out / "commands.json"
    commands = json.loads(commands_path.read_text()) if commands_path.is_file() else []
    failures = [case_result(startup_out, row["case"]) for row in commands if row["exit"] != 0]
    jar = folder / "cleanup-probe.jar"
    compiled = logged(["bash", str(repo / DIRECT / "compile-cleanup-probe.sh"), str(jar)],
                      repo, folder, "cleanup-compile")
    cleanup = None
    if compiled.returncode == 0:
        cleanup = logged(["java", "-jar", str(jar), str(folder / "cleanup-roots")],
                         repo, folder, "cleanup")
    post = proc_observation()
    write_json(folder / "proc-after.json", post)
    passed = []
    if cleanup is not None:
        for line in cleanup.stdout.splitlines():
            try:
                value = json.loads(line)
                if isinstance(value, dict) and value.get("pass") is True:
                    passed.append(value)
            except ValueError:
                pass
    result = {"arm": label, "startupExit": startup.returncode, "startupSummary": summary,
              "startupCasesRecorded": len(commands), "startupFailures": failures,
              "startupStderrHead": excerpt(startup.stderr), "cleanupCompileExit": compiled.returncode,
              "cleanupCompileStderrHead": excerpt(compiled.stderr),
              "cleanupExit": None if cleanup is None else cleanup.returncode,
              "cleanupPassCount": len(passed), "cleanupPassed": passed,
              "cleanupStderrHead": None if cleanup is None else excerpt(cleanup.stderr),
              "procBefore": observation_summary(pre), "procAfter": observation_summary(post)}
    result["passed"] = (startup.returncode == 0 and summary is not None and
                        summary.get("passed") == 26 and summary.get("failed") == 0 and
                        len(commands) == 26 and compiled.returncode == 0 and
                        cleanup is not None and cleanup.returncode == 0 and len(passed) == 6)
    write_json(folder / "result.json", result)
    print(json.dumps(result, ensure_ascii=False), flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--check-only", action="store_true", help="只检查输入，不运行或改文件")
    args = parser.parse_args()
    baseline, candidate, out = (p.resolve() for p in (args.baseline, args.candidate, args.output))
    if baseline == candidate or baseline in candidate.parents or candidate in baseline.parents:
        parser.error("两臂必须是互不包含的独立 repo 路径")
    if any(out == p or p in out.parents or out in p.parents for p in (baseline, candidate)):
        parser.error("输出目录必须位于两 repo 外，且不能包含 repo")
    if out.exists():
        parser.error("输出目录必须尚不存在")
    for repo in (baseline, candidate):
        if not repo.is_dir() or Path(git(repo, "rev-parse", "--show-toplevel")).resolve() != repo:
            parser.error("参数必须指向 repo 根目录")
    if git(baseline, "rev-parse", "HEAD") != BASE:
        parser.error("baseline HEAD 不是指定的原生产基底")
    if git(baseline, "status", "--porcelain", "--untracked-files=all"):
        parser.error("baseline 必须为干净、可临时修改测试文件的独立 worktree")
    before = {"baseline": production(baseline), "candidate": production(candidate)}
    original, compatible = {}, {}
    for name in PROBES:
        original[name] = (baseline / name).read_bytes()
        text = (candidate / name).read_bytes().decode("utf-8")
        if text.count(THREE) != 1 or len(re.findall(r"\bstorageLine\b", text)) != 1:
            parser.error("不能仅删第三参以兼容该 probe: " + str(name))
        if text.count("override fun onStartupFailure(") != 1:
            parser.error("共同 probe 必须实现 startupFailure: " + str(name))
        compatible[name] = text.replace(THREE, TWO).encode("utf-8")
    plan = {"baselineHead": BASE, "candidateHead": git(candidate, "rev-parse", "HEAD"),
            "arms": {"baseline": "原生产基底 + 候选共同 probe，仅适配 onLog 参数个数",
                     "candidate": "候选生产代码 + 原候选 probe"},
            "productionBefore": before,
            "harness": [{"path": str(p), "original": sha(original[p]),
                         "candidate": sha((candidate / p).read_bytes()),
                         "compatibleBaseline": sha(compatible[p])} for p in PROBES]}
    if args.check_only:
        print(json.dumps(plan, ensure_ascii=False))
        return 0
    if not sys.platform.startswith("linux") or os.geteuid() == 0:
        parser.error("实际运行只接受 Linux 非 root，禁止以提权改变观测条件")
    out.mkdir(parents=True)
    write_json(out / "plan.json", plan)
    results = []
    try:
        for name, data in compatible.items():
            (baseline / name).write_bytes(data)
        results.append(arm("baseline", baseline, out))
        results.append(arm("candidate", candidate, out))
    finally:
        for name, data in original.items():
            (baseline / name).write_bytes(data)
        unchanged = {"baseline": production(baseline) == before["baseline"],
                     "candidate": production(candidate) == before["candidate"],
                     "baselineTrackedAndUntrackedClean": not bool(git(baseline, "status", "--porcelain", "--untracked-files=all"))}
        write_json(out / "restoration.json", unchanged)
        print(json.dumps({"restoration": unchanged}), flush=True)
        if not all(unchanged.values()):
            raise RuntimeError("生产输入改变或 baseline 未恢复；检查 restoration.json，不得当成功")
    ok = len(results) == 2 and all(r["passed"] for r in results)
    write_json(out / "summary.json", {"passed": ok, "arms": [{"arm": r["arm"], "passed": r["passed"]} for r in results]})
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.CalledProcessError, RuntimeError) as exc:
        print("5047 helper error: " + str(exc), file=sys.stderr)
        raise SystemExit(2)
