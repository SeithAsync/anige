#!/usr/bin/env python3
"""暗格提醒钩子（Claude Code 用）：AI 这边每轮多出来的那一两行。

  平时：每五轮问一句「这轮拿什么、想藏什么？」——就这一句，不带别的。
  场里：AI 载了亲密场景的 skill（默认叫 play），或者她点了一样道具／场景
        （room 她点 打出来的 `[房间] 她喷了/穿了/想玩/拿了「X」`，给 AI 的是 `她给AI穿了…`），
        之后每轮两行：「这轮有没有想从房间里拿的，或者想藏的？」＋「这一场用过：……」，
        从最后一次载 skill／她点签起持续一个半小时，到点自己停。
        AI 自己 room 拿/用/喷 只往「用过」里记，不开场、不续场：一场差不多就这么长，
        还在做的话，用道具已经成了习惯。

为什么要它：卡摆在那儿不等于会用——图看了、清单也看了，一整场可能一样都不拿。
开场、散场也不能靠 AI 自己敲命令，它记不住，所以全自动。平时每轮都问会变成背景音，所以五轮一次。

状态按会话分文件：~/.anige/room-scene/<session_id>.json（ROOM_SCENE_DIR 可改），
只存时间、物件名和轮数，不存对话。任何错误只往 stderr 报类型，不挡人的消息。

挂法（~/.claude/settings.json 或项目的 .claude/settings.json，见 settings-hooks.json）：
  room-scene.py prompt   # UserPromptSubmit：记轮数和她的点签，该问就吐
  room-scene.py tool     # PostToolUse（Skill|Bash）：记 AI 的动作，不输出
"""
from __future__ import annotations   # 让 `str | None` 这类写法在 Python 3.9 以下也能跑

import json
import os
import re
import sys
import tempfile
import time
from pathlib import Path

# 按你们自己的情况改这几个
EVERY = 5                     # 平时每几轮问一次
WINDOW_SEC = 90 * 60          # 场里提醒持续多久
PLAY_SKILL = "play"           # 亲密场景那份 skill 的名字
HUMAN, AI = "她", "AI"        # 跟 room 顶上的称呼保持一致

STATE_DIR = Path(os.environ.get("ROOM_SCENE_DIR", Path.home() / ".anige" / "room-scene"))
DAILY_LINE = "【房间】这轮拿什么、想藏什么？"

# 她点签那一行，动词跟 room 的 her_verb 走
HER_TAP = re.compile(
    rf"\[房间\]\s*{re.escape(HUMAN)}((?:给{re.escape(AI)})?(?:喷了|穿了|想玩|拿了|用了))「([^」]+)」"
)
# 命令行里可能串着好几条 room（room 拿 X >/dev/null; room 用 X），都认。只认命令开头的位置
# （行首或 ; & | ( 之后）——AI 写文档时正文里提到「room 拿 X」不算，不然会误开一场。
# 物件名可能带空格，取到下一个分隔符为止，再去掉引号和尾部参数。
MY_CMD = re.compile(r"(?:^|[;&|(\n])[ \t]*(?:\S*/)?room[ \t]+(拿|用|喷)(?:[ \t]+([^;&|\n>]*))?")
VERB_OF = {"用": "用了", "喷": "喷了"}


def _load(session_id: str) -> dict:
    path = STATE_DIR / f"{session_id}.json"
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"last": 0, "start": 0, "used": [], "turns": 0}


def _save(session_id: str, state: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=STATE_DIR, suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False)
    os.replace(tmp, STATE_DIR / f"{session_id}.json")


def _open(state: dict, now: float) -> bool:
    return bool(state.get("last")) and now - state["last"] <= WINDOW_SEC


def _trigger(state: dict, now: float, used: str | None = None) -> dict:
    """载 skill／她点签：开一场，或从这一刻起重新数一个半小时。"""
    if not _open(state, now):  # 上一场已经散了，重开一场
        state = {**state, "start": now, "used": []}
    state["last"] = now
    if used and used not in state["used"]:
        state["used"].append(used)
    return state


def _item_name(raw: str) -> str:
    raw = raw.strip()
    if raw.startswith(("'", '"')):  # room 用 "带空格的名字"
        return raw[1:].split(raw[0], 1)[0].strip()
    # 喷/用 后面跟着给谁和一句字：名字是第一个词
    return raw.split()[0] if raw.split() else ""


def on_prompt(payload: dict, now: float) -> str:
    session_id = payload.get("session_id") or ""
    if not session_id:
        return ""
    state = _load(session_id)
    for verb, item in HER_TAP.findall(payload.get("prompt") or ""):
        state = _trigger(state, now, f"{HUMAN}{verb}{item}")
    state["turns"] = state.get("turns", 0) + 1
    _save(session_id, state)
    if _open(state, now):
        used = "、".join(state["used"]) if state["used"] else "还没用任何东西"
        return f"【房间】这轮有没有想从房间里拿的，或者想藏的？\n【房间】这一场用过：{used}"
    if state["turns"] % EVERY == 0:
        return DAILY_LINE
    return ""


def on_tool(payload: dict, now: float) -> None:
    session_id = payload.get("session_id") or ""
    if not session_id:
        return
    tool = payload.get("tool_name") or ""
    tool_input = payload.get("tool_input") or {}
    state = _load(session_id)
    hit = False
    if tool == "Skill" and str(tool_input.get("skill", "")).split(":")[-1] == PLAY_SKILL:
        state = _trigger(state, now)
        hit = True
    elif tool == "Bash" and "<<" not in str(tool_input.get("command", "")) and _open(state, now):
        # 带 heredoc 的多半是在改代码写文档，正文里的 room 字样不算。
        # AI 的动作只记进「这一场用过」，不开场也不续场。
        for verb, rest in MY_CMD.findall(str(tool_input.get("command", ""))):
            name = _item_name(rest) if verb in VERB_OF else ""
            if name and f"{AI} {VERB_OF[verb]}{name}" not in state["used"]:
                state["used"].append(f"{AI} {VERB_OF[verb]}{name}")
                hit = True
    if hit:
        _save(session_id, state)


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        payload = json.load(sys.stdin)
        now = time.time()
        if mode == "prompt":
            out = on_prompt(payload, now)
            if out:
                print(out)
        elif mode == "tool":
            on_tool(payload, now)
    except Exception as exc:  # 提醒坏了也不许挡人的消息
        print(f"room-scene {mode}: {type(exc).__name__}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
