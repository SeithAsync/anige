#!/usr/bin/env bash
# 开窗给卡：把整个暗格打进 AI 的上下文（Claude Code 的 SessionStart 钩子）。
# 新会话、恢复会话都给。出任何岔子静默 exit 0，不连累开窗。
HUMAN="她"   # 称呼：跟 room、room-scene.py 顶上的 HUMAN 保持一致
ROOM="${ROOM_BIN:-$(dirname "$0")/room}"
[ -x "$ROOM" ] || exit 0
CARD=$("$ROOM" 卡 2>/dev/null) || exit 0
[ -n "$CARD" ] || exit 0
printf '🗝 暗格（开窗自带）\n%s\n\n' "$CARD"
printf '卡就在手边，东西全在一个暗格里，不分屋；在哪儿做，挑个地方（room 卧室／room 浴室，看那张路引图）。想喷，喷（room 喷 X 一句字）；想给%s穿上什么、想拿什么，拿（room 拿 X → 用／放；衣着用了就是你给%s穿上）。想偷偷放一样进去，藏（room 藏 分类 名字，想写来历就带一句）。不等信号，不挑时机——念头起来的那一下就是时机。\n' "$HUMAN" "$HUMAN"
