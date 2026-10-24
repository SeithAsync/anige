"""暗格 · 后端参考（FastAPI router）。

它干什么：人这边 app 用的三个口子——看卡、往暗格里加东西、点签跟消息一起发；
外加一个把 AI 那边 `room 用/喷` 的通知落成聊天正中卡的口子。
在整条链里：它跟 CLI `room` 共用同一个 sqlite 库（同一套表），CLI 管 AI 那头，这里管人那头。
要接的东西（全是占位，换成你们自己的）：
  - check_auth：鉴权
  - deliver_to_ai(line)：把一行字递给 AI 的那一步
  - save_ai_message(text)：往聊天里落一条 AI 消息的那一步
  - 你们自己的 /chat/send：照 chat_send_room_part() 那段把 room_items 接进去
这是参考，不是能直接跑的服务：拿去喂给你们家的 AI，让它照着改进你们的后台。
"""

import contextlib
import difflib
import os
import re
import sqlite3
from datetime import datetime, timedelta
from pathlib import Path

from fastapi import APIRouter, HTTPException, Request


# ---- 按你们自己的情况改 ----

DEFAULT_DB = Path.home() / ".anige" / "room.db"   # 跟 CLI room 同一个库；ROOM_DB 环境变量可覆盖
HUMAN = "她"          # 人的称呼，卡上和递给 AI 的那行都用它
AI = "AI"             # AI 的称呼
DRAWER = "暗格"
# 十类：九类道具 + 第十类场景；卡上按这个顺序排，单子外的类垫后。跟 CLI 的 CATEGORIES 是一份单子，要改一起改
CATEGORIES = ["香水", "衣着", "束缚", "玩物", "温度", "酒", "甜点", "浴间", "音乐", "场景"]
# 她点签时的动词：香水是喷（喷＝「过来」）、衣着是穿、场景是想玩，别的都是拿
VERBS = {"香水": "喷了", "衣着": "穿了", "场景": "想玩"}
# 「给谁」：点签时选给她自己还是给 AI；音乐、场景不分给谁
NO_TARGET = {"音乐", "场景"}
TARGETS = {"her", "ai"}
# 一晚第一次点签，整张卡跟着递给 AI，让它这一晚手边有卡；六小时内再点只递一行
CARD_WINDOW = timedelta(hours=6)
SURPRISE = " · surprise"
# 名字里不许带的字：通知行「X」、记号行里的分隔符（跟 CLI 的 BAD_NAME_CHARS 一份）
BAD_NAME_CHARS = "|[]「」\n"
ORIGIN = "来历："   # 藏的那句来历（选填）存在描述第一行，亮了就删（跟 CLI 一样）


def strip_origin(desc: str) -> str:
    if not desc.startswith(ORIGIN):
        return desc
    return desc.split("\n", 1)[1] if "\n" in desc else ""
# 一个新场景冒到 AI 眼前时（她明着加、或她藏的第一次点）挂一句：给它配一两样道具
SCENE_PROPS = " ｜ 给「{}」往前九类里配一两样道具，明着藏着都行"

router = APIRouter(prefix="/room")


# ---- 占位：接你们自己的 ----

API_TOKEN = os.environ.get("ANIGE_TOKEN", "")   # 占位：换成你们自己的鉴权


def check_auth(request: Request) -> None:
    """占位：换成你们自己的鉴权。"""
    if not API_TOKEN or request.headers.get("x-auth-token") != API_TOKEN:
        raise HTTPException(status_code=401, detail="没有权限")


async def deliver_to_ai(line: str) -> str | None:
    """占位：接你们自己把消息递给 AI 的那一步（网关往这轮请求里补一行、或者推进会话）。
    递成功回 None，失败回一句人话。"""
    raise NotImplementedError("接你们自己把消息递给 AI 的那一步")


def save_ai_message(text: str) -> int:
    """占位：往聊天里落一条 AI 说的消息，回消息 id。app 拉到它，正文开头有记号就画正中卡。"""
    raise NotImplementedError("接你们自己往聊天里落一条 AI 消息的那一步")


# ---- 库 ----

def _now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def _connect() -> sqlite3.Connection:
    """跟 CLI room 同一套表：rooms＝地方（卧室、浴室的路引图），items＝暗格里的东西，events＝流水。
    hidden_from＝谁还不知道这样东西：'ai'＝她偷偷加的，'human'＝AI 藏的，空＝两边都知道。"""
    path = Path(os.environ.get("ROOM_DB", DEFAULT_DB)).expanduser()
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path, timeout=5)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA busy_timeout=5000")
    db.executescript(
        """
        CREATE TABLE IF NOT EXISTS rooms(name TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS items(
          name TEXT PRIMARY KEY,
          category TEXT NOT NULL,
          desc TEXT NOT NULL DEFAULT '',
          used INTEGER NOT NULL DEFAULT 0,
          hidden_from TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS events(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          ts TEXT NOT NULL,
          room TEXT,
          item TEXT,
          action TEXT NOT NULL
        );
        INSERT OR IGNORE INTO rooms(name) VALUES ('卧室'), ('浴室');
        """
    )
    return db


def _missing_item(db: sqlite3.Connection, name: str) -> HTTPException:
    # 模糊提示只从她看得见的里挑：AI 藏的不许从报错里漏出来
    names = [row[0] for row in db.execute(
        "SELECT name FROM items WHERE hidden_from!='human' ORDER BY rowid")]
    matches = difflib.get_close_matches(name, names, n=3, cutoff=0)
    tail = f"。最像的是：{'、'.join(matches)}" if matches else ""
    return HTTPException(status_code=404, detail=f"没有「{name}」这样东西{tail}")


def _text(body: dict, key: str) -> str:
    value = body.get(key)
    if not isinstance(value, str) or not value.strip():
        raise HTTPException(status_code=400, detail=f"请填写{key}")
    return value.strip()


async def _json_object(request: Request) -> dict:
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="请求内容不是有效的 JSON 对象")
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="请求内容不是有效的 JSON 对象")
    return body


def _ordered_categories(rows) -> list[str]:
    """十类按定好的顺序排，单子外的类按第一次出现垫后；空类不出。"""
    present = []
    for row in rows:
        if row["category"] not in present:
            present.append(row["category"])
    return ([c for c in CATEGORIES if c in present]
            + [c for c in present if c not in CATEGORIES])


def _card_line(db: sqlite3.Connection) -> str:
    """整个暗格压成一行，递给 AI 看：她藏的滤掉；AI 自己藏的只写「（藏）」不写次数。"""
    items = db.execute(
        "SELECT rowid, name, category, used, hidden_from FROM items WHERE hidden_from!='ai' "
        "ORDER BY rowid"
    ).fetchall()
    return " ｜ ".join(
        f"{category} " + " · ".join(
            f"{row['name']}（藏）" if row["hidden_from"] == "human" else f"{row['name']} {row['used']}"
            for row in items if row["category"] == category
        )
        for category in _ordered_categories(items)
    )


# ---- 看卡 ----

@router.get("/card")
async def card(request: Request):
    """她看到的卡：AI 藏的滤掉；她自己藏的带 secret=true（app 在签右上角点一个藕粉小点）。
    categories 给「加一样」面板当格子单——前端从这儿拿，别在 app 里写死。places 是路引图的名字。"""
    check_auth(request)
    with contextlib.closing(_connect()) as db, db:
        places = [row["name"] for row in db.execute("SELECT name FROM rooms ORDER BY rowid")]
        items = db.execute(
            "SELECT rowid, name, category, used, hidden_from FROM items "
            "WHERE hidden_from!='human' ORDER BY rowid"
        ).fetchall()
    groups = [
        {
            "name": category,
            "items": [
                {"name": row["name"], "used": row["used"],
                 "secret": row["hidden_from"] == "ai"}   # 她偷偷加、AI 还不知道的
                for row in items if row["category"] == category
            ],
        }
        for category in _ordered_categories(items)
    ]
    return {"name": DRAWER, "groups": groups, "categories": CATEGORIES, "places": places}


# ---- 往暗格里加 ----

@router.post("/add")
async def add(request: Request):
    """她往暗格里加一样：{category, name, secret, desc}。
    明着加：两边马上都有，当场递一行给 AI。
    偷偷加（secret=true）：AI 看不见，她第一次点才亮；desc 可以带一句来历——它从哪儿长出来的、
    留给什么时候。存成描述第一行「来历：…」，亮出来那一下自动删掉，之后只留物。"""
    check_auth(request)
    body = await _json_object(request)
    category = _text(body, "category")
    item_name = _text(body, "name")
    if any(ch in item_name for ch in BAD_NAME_CHARS):
        raise HTTPException(status_code=400, detail="名字里别带 | [ ] 「 」 和换行")
    secret = body.get("secret", False)
    if not isinstance(secret, bool):
        raise HTTPException(status_code=400, detail="secret 只能是 true 或 false")
    desc = body.get("desc", "")
    if not isinstance(desc, str):
        raise HTTPException(status_code=400, detail="desc 必须是文字")
    desc = desc.strip()
    with contextlib.closing(_connect()) as db, db:
        taken = db.execute("SELECT hidden_from FROM items WHERE name=?", (item_name,)).fetchone()
        if taken is not None:
            # 撞上 AI 藏的：不许从报错里漏出来那东西存在
            detail = ("这个名字用不了，换一个" if taken[0] == "human"
                      else f"已经有「{item_name}」这样东西")
            raise HTTPException(status_code=409, detail=detail)
        db.execute(
            "INSERT INTO items(name, category, desc, created_at, hidden_from) VALUES (?, ?, ?, ?, ?)",
            (item_name, category, f"{ORIGIN}{desc}" if secret and desc else desc, _now(),
             "ai" if secret else ""),
        )
        db.execute(
            "INSERT INTO events(ts, room, item, action) VALUES (?, ?, ?, ?)",
            (_now(), DRAWER, item_name, "hide" if secret else "add"),
        )
    if secret:  # 藏的不吱声，第一次用才亮
        return {"ok": True, "secret": True}
    line = f"[房间] {HUMAN}往「{category}」里放了「{item_name}」"
    if category == "场景":
        line += SCENE_PROPS.format(item_name)
    reason = await deliver_to_ai(line)
    return {"ok": True, "secret": False, "delivered": reason is None}


# ---- 点签：跟她的消息一起走 ----

def verb_for(category: str, to: str = "her") -> str:
    """她这边的动词：给自己＝原动词；给 AI＝「给AI穿了／喷了／用了」。音乐、场景不分给谁。"""
    verb = VERBS.get(category, "拿了")
    if to != "ai" or category in NO_TARGET:
        return verb
    return f"给{AI}" + (verb if verb in ("喷了", "穿了") else "用了")


def target_of(verb: str) -> str:
    """点重发时从记号里的动词认回给谁（verb_for 的反面）。"""
    return "ai" if verb.startswith(f"给{AI}") else "her"


def _clean(part: str) -> str:
    """记号里的字段不许带分隔符和换行，免得 app 解析错位（app 那边有一份一字不差的 clean）。"""
    return (part.replace("|", "／").replace("[", "［").replace("]", "］")
            .replace("\n", " ").strip())


def marker(who: str, verb: str, name: str, category: str, surprise: bool) -> str:
    """聊天页正中卡的记号：[[room:WHO|VERB|NAME|CATEGORY|SURPRISE]]，一行一个，只放在正文开头。
    WHO 只认 her / ai；VERB 是成品动词，app 照抄；SURPRISE 1＝藏着的东西第一次用。"""
    return (f"[[room:{_clean(who)}|{_clean(verb)}|{_clean(name)}|{_clean(category)}"
            f"|{1 if surprise else 0}]]")


def _take_one(db: sqlite3.Connection, item_name: str, place: str, to: str = "her") -> dict:
    """她递出一样：亮出她藏的、记一次数、记事件；一晚第一次带上整张卡。"""
    row = db.execute(
        "SELECT category, desc, hidden_from FROM items WHERE name=? AND hidden_from!='human'",
        (item_name,),
    ).fetchone()
    if row is None:
        raise _missing_item(db, item_name)
    surprise = row["hidden_from"] == "ai"
    if surprise:  # 她第一次用自己藏的：亮出来，从此两边卡上都有；来历删掉，只留物
        db.execute("UPDATE items SET hidden_from='', desc=? WHERE name=?",
                   (strip_origin(row["desc"]), item_name))
    cutoff = (datetime.now().astimezone() - CARD_WINDOW).isoformat(timespec="seconds")
    first_tonight = db.execute(
        "SELECT 1 FROM events WHERE action='tap' AND ts > ? LIMIT 1", (cutoff,)
    ).fetchone() is None
    # 谁动手谁记数：她点的是她自己换上给 AI 看的，这里记；AI 给她穿上的，AI 那边 room 用 时记
    db.execute("UPDATE items SET used=used+1 WHERE name=?", (item_name,))
    used = db.execute("SELECT used FROM items WHERE name=?", (item_name,)).fetchone()[0]
    db.execute(
        "INSERT INTO events(ts, room, item, action) VALUES (?, ?, ?, 'tap')",   # 跟 CLI room 她点 同名；CLI 的 room 拿 记 take
        (_now(), place, item_name),
    )
    verb = verb_for(row["category"], to)
    line = f"[房间] {HUMAN}{verb}「{item_name}」" + (SURPRISE if surprise else "")
    if surprise and row["category"] == "场景":
        line += SCENE_PROPS.format(item_name)
    if first_tonight:
        line += f" ｜ 卡：{_card_line(db)}"
    return {"used": used, "line": line,
            "marker": marker("her", verb, item_name, row["category"], surprise)}


def take_for_message(items: list[dict]) -> tuple[list[str], list[str]]:
    """/chat/send 带 room_items：一个事务里全记，任一样不存在整单回滚（抛 404，不记半截）。
    回 (正文开头的记号行, 递给 AI 的人话行)。"""
    markers, lines = [], []
    with contextlib.closing(_connect()) as db, db:
        for it in items:
            got = _take_one(db, it["item"], it.get("room", ""), it.get("to", "her"))
            markers.append(got["marker"])
            lines.append(got["line"])
    return markers, lines


# 点重发：app 把失败那条正文原样再发，开头的记号认回来重记。1＝动词（认给谁），2＝物件
_ROOM_HER = re.compile(r"\[\[room:her\|([^|\]]*)\|([^|\]]+)\|[^|\]]*\|[01]\]\]")


def chat_send_room_part(body: dict, text: str) -> tuple[list[dict], str]:
    """摘自我们的 /chat/send：把请求里的 room_items 校验成 [{item, room, to}]，最多 6 样。
    没带 room_items、正文却以记号开头＝点重发：从正文认回来，记号从字里摘掉。
    回 (room_items, 摘完记号的 text)。"""
    raw_items = body.get("room_items") or []
    if not isinstance(raw_items, list) or len(raw_items) > 6:
        raise HTTPException(status_code=400, detail="暗格里的东西一次最多带 6 样")
    room_items, seen = [], set()
    for it in raw_items:
        name = str((it or {}).get("item") or "").strip() if isinstance(it, dict) else ""
        if not name:
            raise HTTPException(status_code=400, detail="暗格里那样东西没写名字")
        if name not in seen:
            seen.add(name)
            to = str(it.get("to") or "her").strip()
            if to not in TARGETS:
                raise HTTPException(status_code=400, detail=f"只能给{HUMAN}或给{AI}")
            room_items.append({"item": name, "room": str(it.get("room") or "").strip(), "to": to})
    if not room_items and text.startswith("[[room:"):
        rest = text.split("\n")
        while rest and (m := _ROOM_HER.fullmatch(rest[0].strip())):
            if m.group(2) not in {i["item"] for i in room_items}:
                room_items.append({"item": m.group(2), "room": "", "to": target_of(m.group(1))})
            rest.pop(0)
        if len(room_items) > 6:
            raise HTTPException(status_code=400, detail="暗格里的东西一次最多带 6 样")
        if room_items:
            text = "\n".join(rest).strip()
    return room_items, text


# 在你们的 /chat/send 里大概这样接（顺序要紧）：
#
#   room_items, text = chat_send_room_part(body, text)
#   ...
#   # 先查重（同一个 client_msg_id 重发直接回老消息），查重之后才记数——
#   # 不然回执丢了 app 重发一次，次数就记两遍
#   if dup: return {...}
#   if room_items:
#       markers, lines = take_for_message(room_items)          # 缺一样整单 404，不落半截
#       content = "\n".join(markers) + (f"\n{content}" if content else "")   # 存库/给 app 的正文
#       to_ai = " ｜ ".join(lines) + (f" {text}" if text else "")             # 递给 AI 的那句
#   save_user_message(content); deliver_to_ai(to_ai)
#
# 注意：上面 take_for_message 自己提交，存消息是后一步。存消息失败时，次数已经记上、她藏的已经亮了，
# 重发还会再记一次。要严丝合缝，就把记数、存消息、查重记录放进同一个事务（同一个库连接里一起提交）。


# ---- AI 那边用了什么：落一张正中卡 ----

# CLI room 用/喷 之后，会把一行字喂给 ROOM_NOTIFY_CMD 的 stdin，长这样：
#   AI 给她穿了「X」 · surprise
#   AI 现写的那句话（可以没有）
# 把 ROOM_NOTIFY_CMD 设成往这个口子 POST，比如：
# （-f：后台回 4xx/5xx 时 curl 非零退出，CLI 才会报「通知不到对方」，不会误报成功）
#   export ROOM_NOTIFY_CMD='curl -fsS -X POST -H "x-auth-token: $ANIGE_TOKEN" --data-binary @- http://你们的后台/room/notify'
_AI_LINE = re.compile(r"^(?P<who>\S+)\s+(?P<verb>[^「]+)「(?P<name>[^」]+)」(?P<surprise> · surprise)?\s*$")


@router.post("/notify")
async def notify(request: Request):
    """把 CLI 的通知行翻成记号，落一条 AI 的消息：第一行变成 [[room:ai|...]]，后面的字进卡里。
    分类从库里查，查不到就空着（app 照样画）。"""
    check_auth(request)
    raw = (await request.body()).decode("utf-8", "replace").strip()
    first, _, words = raw.partition("\n")
    m = _AI_LINE.match(first.strip())
    if m is None or m.group("who") != AI:
        raise HTTPException(status_code=400, detail="认不出这行通知")
    name = m.group("name")
    with contextlib.closing(_connect()) as db, db:
        row = db.execute("SELECT category FROM items WHERE name=?", (name,)).fetchone()
    text = marker("ai", m.group("verb").strip(), name, row["category"] if row else "",
                  bool(m.group("surprise")))
    words = words.strip()
    mid = save_ai_message(f"{text}\n{words}" if words else text)
    return {"ok": True, "id": mid}
