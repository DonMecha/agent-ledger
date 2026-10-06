#!/usr/bin/env python3
"""j — 帳面(log.jsonl)の唯一の書き込み口と、そこからの導出ビュー。

なぜ在るか(3行):
  記録の正本を追記専用ログ1本(log.jsonl)に集め、状態文書を手で維持しない運用にするため。
  書き込みをこのCLIに限ることで、採番・時刻・ロックが揃い、複数セッション同居でも壊れない。
  「いま何をすべきか」「収支」「出荷」は保存せず、毎回ここから導出する。

帳面の場所: 環境変数 J_ROOT のディレクトリ(未指定なら現在のディレクトリ)の log.jsonl。
事業の一覧: J_ROOT/projects/<事業>.md があれば now に並ぶ(任意)。
金額の単位: 環境変数 J_UNIT(既定は「円」)。
動作確認: j selftest(一時ディレクトリの隔離帳面で全コマンドを通す)。

使い方:
  j <種別> [-p 事業] [本文...]          種別: decision money ship ask answer promise sys
  j money -3000 "サーバー代" [--ref 領収の在処]     金額は符号付き整数(収入は正)
  j ship -p game "体験版を公開" --channel itch --ref URL
  j answer --re <askのid> "回答の逐語"
  j promise -p game "体験版のDL 100件以上"    数値予測の記録
  j now [-p 事業]                      再入ビュー(対象指定時も未分類・全体収支・全占有を表示)
  j money --month 2026-08 / j ships     収支表 / 出荷一覧
  j claim <事業> / j release            セッションの占有宣言(TTL 4時間の紳士協定)
  j who                                現在の帳面識別子(J_WHO > Cursor > Codex > tmux > manual)
  j selftest
  j <種別> --help                    使い方だけ表示し、記帳しない
  j sys -- --help                    -- 以降は文字どおりの本文として記帳
"""
import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta

TYPES = ("decision", "money", "ship", "ask", "answer", "promise", "sys")
CLAIM_TTL_H = 4


def root():
    return os.environ.get("J_ROOT") or os.getcwd()


def unit():
    return os.environ.get("J_UNIT", "円")


def log_path():
    return os.path.join(root(), "log.jsonl")


def who():
    w = os.environ.get("J_WHO")
    if w:
        return w
    if os.environ.get("CURSOR_CONVERSATION_ID"):
        return "cursor:" + os.environ["CURSOR_CONVERSATION_ID"]
    if os.environ.get("CODEX_THREAD_ID"):
        return "codex:" + os.environ["CODEX_THREAD_ID"]
    if os.environ.get("TMUX"):
        try:
            return "tmux:" + subprocess.run(
                ["tmux", "display-message", "-p", "#S"],
                capture_output=True, text=True, timeout=3).stdout.strip()
        except Exception:
            pass
    return "manual"


def append(ev):
    ev = {k: v for k, v in ev.items() if v not in (None, "")}
    path = log_path()
    with open(path, "a", encoding="utf-8") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        ts = datetime.now()
        ev = {"id": ts.strftime("%Y%m%d-%H%M%S") + f"-{time.time_ns() % 1_000_000_000:09d}",
              "ts": ts.strftime("%Y-%m-%d %H:%M:%S"), **ev}
        f.write(json.dumps(ev, ensure_ascii=False) + "\n")
        # バッファを残して解錠すると、後続の記録が先に確定してしまう。
        f.flush()
        os.fsync(f.fileno())
        fcntl.flock(f, fcntl.LOCK_UN)
    return ev["id"]


def read_all():
    if not os.path.exists(log_path()):
        return []
    out = []
    with open(log_path(), encoding="utf-8") as f:
        fcntl.flock(f, fcntl.LOCK_SH)
        for line in f:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


def parse(args):
    """フラグ(-p/--project --re --channel --ref --month)と符号付き整数と本文に分ける。"""
    opt, text, amount = {}, [], None
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--":
            text.extend(args[i + 1:])
            break
        elif a in ("-p", "--project"):
            opt["project"] = args[i + 1]; i += 2
        elif a in ("--re", "--channel", "--ref", "--month"):
            opt[a[2:]] = args[i + 1]; i += 2
        elif re.fullmatch(r"[+-]?\d+", a) and amount is None:
            amount = int(a); i += 1
        else:
            text.append(a); i += 1
    return opt, " ".join(text), amount


def active_claims(events, now=None):
    now = now or datetime.now()
    claims = {}
    for ev in events:
        if ev.get("type") != "sys":
            continue
        t = ev.get("text", "")
        ts = datetime.strptime(ev["ts"], "%Y-%m-%d %H:%M:%S")
        if t.startswith("claim "):
            claims[(ev.get("who"), t[6:])] = ts
        elif t == "release":
            claims = {k: v for k, v in claims.items() if k[0] != ev.get("who")}
    return {k: v for k, v in claims.items() if now - v < timedelta(hours=CLAIM_TTL_H)}


def cmd_now(events, project=None):
    now = datetime.now()
    lines = [f"== NOW {now:%Y-%m-%d %H:%M} =="]
    scoped = [e for e in events if not project or not e.get("project") or e.get("project") == project]
    if project:
        lines.append(f"対象: {project} + 未分類（収支・占有は全体。全件は j now）")
    answered = {e.get("re") for e in events if e.get("type") == "answer"}
    asks = [e for e in scoped if e.get("type") == "ask" and e["id"] not in answered]
    lines.append(f"\n■ 未回答の問い ({len(asks)}件)")
    for e in asks:
        lines.append(f"  [{e['id']}] ({e.get('project','-')}) {e.get('text','')}")
    recent = [e for e in scoped if e.get("type") in ("decision", "answer")][-5:]
    lines.append("\n■ 直近の決定・回答")
    for e in recent:
        lines.append(f"  {e['ts']} {e['type']} ({e.get('project','-')}) {e.get('text','')[:100]}")
    month = now.strftime("%Y-%m")
    money = [e for e in events if e.get("type") == "money" and e["ts"].startswith(month)]
    total = sum(e.get("amount", 0) for e in money)
    lines.append(f"\n■ 今月の金 ({month}): {total:+,}{unit()} ({len(money)}件)")
    pdir = os.path.join(root(), "projects")
    if os.path.isdir(pdir):
        lines.append("\n■ 事業 (projects/*.md)")
        ships = {}
        for e in events:
            if e.get("type") == "ship" and e.get("project"):
                ships[e["project"]] = e["ts"][:10]
        for fn in sorted(os.listdir(pdir)):
            if fn.endswith(".md"):
                name = fn[:-3]
                if project and name != project:
                    continue
                mt = datetime.fromtimestamp(os.path.getmtime(os.path.join(pdir, fn)))
                lines.append(f"  {name:12s} 最終更新 {mt:%Y-%m-%d} / 最終出荷 {ships.get(name, 'なし')}")
    claims = active_claims(events, now)
    lines.append(f"\n■ 占有中のセッション ({len(claims)}件)")
    for (w, proj), ts in claims.items():
        lines.append(f"  {proj} ← {w} ({ts:%H:%M} から)")
    return "\n".join(lines)


def cmd_money(events, month=None):
    month = month or datetime.now().strftime("%Y-%m")
    rows = [e for e in events if e.get("type") == "money" and e["ts"].startswith(month)]
    out = [f"== 金 {month} =="]
    for e in rows:
        out.append(f"  {e['ts'][:10]} {e.get('amount', 0):+8,}{unit()} ({e.get('project','-')}) {e.get('text','')}")
    out.append(f"  合計 {sum(e.get('amount', 0) for e in rows):+,}{unit()}")
    return "\n".join(out)


def cmd_ships(events):
    out = ["== 出荷 =="]
    for e in events:
        if e.get("type") == "ship":
            out.append(f"  {e['ts'][:10]} ({e.get('project','-')}) {e.get('text','')}"
                       + (f" [{e['channel']}]" if e.get("channel") else ""))
    return "\n".join(out)


def selftest():
    identity_env = dict(os.environ, CODEX_THREAD_ID="codex-fixture", CURSOR_CONVERSATION_ID="cursor-fixture")
    identity_env.pop("J_WHO", None)
    identity_env.pop("TMUX", None)
    for overrides, expected in (({}, "cursor:cursor-fixture"),
                                ({"J_WHO": "legacy:keep"}, "legacy:keep"),
                                ({"CURSOR_CONVERSATION_ID": ""}, "codex:codex-fixture")):
        result = subprocess.run([sys.executable, os.path.abspath(__file__), "who"],
                                env=dict(identity_env, **overrides), capture_output=True, text=True, check=True)
        assert result.stdout.strip() == expected, "CLI識別子の優先順位が変わった"
    with tempfile.TemporaryDirectory() as td:
        os.environ["J_ROOT"] = td
        os.environ["J_WHO"] = "selftest"
        os.makedirs(os.path.join(td, "projects"))
        open(os.path.join(td, "projects", "demo.md"), "w").close()
        aid = append({"type": "ask", "project": "demo", "text": "問い"})
        append({"type": "answer", "re": aid, "text": "回答"})
        append({"type": "money", "amount": -500, "text": "テスト費用"})
        append({"type": "ship", "project": "demo", "text": "テスト出荷", "channel": "test"})
        append({"type": "sys", "text": "claim demo", "who": who()})
        evs = read_all()
        assert len(evs) == 5, f"5行のはずが{len(evs)}行"
        assert len({e["id"] for e in evs}) == 5, "idが重複"
        view = cmd_now(evs)
        assert "未回答の問い (0件)" in view, "answer済みのaskが未回答扱い"
        assert "demo" in view and "最終出荷" in view, "事業一覧に出ない"
        assert "-500" in cmd_money(evs), "金の集計に出ない"
        assert "テスト出荷" in cmd_ships(evs), "出荷一覧に出ない"
        assert ("selftest", "demo") in active_claims(evs), "claimが見えない"
        old = json.loads(json.dumps(evs[4]))
        old["ts"] = "2020-01-01 00:00:00"
        assert not active_claims(evs[:4] + [old]), "TTL切れのclaimが残る"
        # 対象外の回答で閉じた問い、未分類、他事業の占有と収支を確認。
        stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        rows = [
            {"id": "q", "type": "ask", "project": "demo", "text": "closed-question"},
            {"id": "a", "type": "answer", "project": "other", "re": "q"},
            {"id": "u", "type": "ask", "text": "unassigned-question"},
            {"id": "o", "type": "ask", "project": "other", "text": "other-question"},
            {"id": "d", "type": "ask", "project": "demo", "text": "demo-question"},
            {"id": "c", "type": "sys", "text": "claim other", "who": "other-session", "ts": stamp},
            {"id": "m", "type": "money", "project": "other", "amount": -1234, "ts": stamp},
        ]
        rows = [{"ts": stamp, **row} for row in rows]
        scoped = cmd_now(rows, "demo")
        assert all(t in scoped for t in ("unassigned-question", "demo-question", "other-session", "-1,234"))
        assert all(t not in scoped for t in ("closed-question", "other-question"))
        assert "other-question" in cmd_now(rows), "無指定の全体表示が欠落"
        # ヘルプ照会は記帳も占有変更もしてはならない。実CLIで隔離帳面を照合する。
        with open(log_path(), "rb") as f:
            before = f.read()
        script = os.path.abspath(__file__)
        for cmd in (*TYPES, "now", "ships", "claim", "release", "who", "selftest"):
            for flag in ("-h", "--help"):
                result = subprocess.run([sys.executable, script, cmd, flag],
                                        capture_output=True, text=True, timeout=3)
                assert result.returncode == 0 and "使い方:" in result.stdout, (cmd, flag)
        with open(log_path(), "rb") as f:
            assert f.read() == before, "ヘルプ照会で帳面が変わった"
        result = subprocess.run([sys.executable, script, "promise", "数値予測1件"],
                                capture_output=True, text=True, timeout=3)
        assert result.returncode == 0 and read_all()[-1]["type"] == "promise", result.stderr
        result = subprocess.run([sys.executable, script, "sys", "--", "--help", "-3000"],
                                capture_output=True, text=True, timeout=3)
        assert result.returncode == 0, result.stderr
        literal = read_all()[-1]
        assert literal["text"] == "--help -3000" and "amount" not in literal
        result = subprocess.run([sys.executable, script, "decision"],
                                capture_output=True, text=True, timeout=3)
        assert result.returncode != 0, "空の本文が記帳された"
        missing = os.path.join(td, "missing")
        result = subprocess.run([sys.executable, script, "money", "--help"],
                                env={**os.environ, "J_ROOT": missing},
                                capture_output=True, text=True, timeout=3)
        assert result.returncode == 0 and not os.path.exists(missing), "helpが帳面の存在に依存"
    print("selftest OK (now/money/ships/claim/TTL・対象別表示と事業をまたぐ回答・全種別help非記帳)")


def main():
    args = sys.argv[1:]
    # -- の後ろにある同じ文字列は本文。help判定は読取・記帳・占有操作より先。
    options = args[:args.index("--")] if "--" in args else args
    if not args or any(arg in ("-h", "--help") for arg in options):
        print(__doc__)
        return
    cmd = args[0]
    if cmd == "selftest":
        selftest()
        return
    if cmd == "who":
        print(who())
        return
    events = read_all() if cmd in ("now", "money", "ships") else None
    if cmd == "now":
        parser = argparse.ArgumentParser(prog="j now")
        parser.add_argument("-p", "--project")
        opt = parser.parse_args(args[1:])
        if opt.project is not None and (not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", opt.project) or
                not os.path.isfile(os.path.join(root(), "projects", opt.project + ".md"))):
            parser.error("projects/<事業>.md がある事業を指定してください")
        print(cmd_now(events, opt.project))
    elif cmd == "money":
        # 金は「書く」と「見る」が同じ語。金額か本文が付いていれば記帳、無ければ収支表。
        opt, text, amount = parse(args[1:])
        if amount is not None or text:
            ev_id = append({"type": "money", "amount": amount, "text": text,
                            "who": who(), **{k: v for k, v in opt.items() if k != "month"}})
            print(ev_id)
        else:
            print(cmd_money(events, opt.get("month")))
    elif cmd == "ships":
        print(cmd_ships(events))
    elif cmd == "claim":
        if len(args) < 2:
            sys.exit("使い方: j claim <事業>")
        append({"type": "sys", "text": f"claim {args[1]}", "who": who()})
        print(f"占有: {args[1]} ({who()})")
    elif cmd == "release":
        append({"type": "sys", "text": "release", "who": who()})
        print(f"解放 ({who()})")
    elif cmd in TYPES:
        opt, text, amount = parse(args[1:])
        if not text and amount is None:
            sys.exit("本文が空です")
        if cmd == "answer" and not opt.get("re"):
            sys.exit("answer には --re <askのid> が必要です")
        ev_id = append({"type": cmd, "amount": amount, "text": text, "who": who(), **opt})
        print(ev_id)
    else:
        sys.exit(f"知らない種別: {cmd} (使えるのは {' '.join(TYPES)} / now money ships claim release who selftest)")


if __name__ == "__main__":
    main()
