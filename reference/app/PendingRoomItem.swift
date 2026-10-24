// 暗格 · 点签挂输入框、跟消息一起发（SwiftUI 片段拼起来的参考）
//
// 它干什么：屋卡上点一样，不当场发，而是挂成输入框上方的一枚小签（「眼罩 → AI」），
// 等她把话打完、按发送，小签跟这句话一起走 POST /chat/send 的 room_items；次数由后端在那一刻记。
// 在整条链里：屋卡（RoomSheet）→ 这里（挂签、发送）→ 后端 take_for_message → 正文开头落记号 → 正中卡（RoomEventCard）。
// 这个文件是拼出来的：原来散在我们的 ChatViewModel（状态和发送）、ChatAPI（请求体）、ChatView（小签条、画卡）、
// 会话列表（预览）四个文件里，这里只摘跟暗格有关的部分，用 MARK 分开，标了原来在哪类文件里。
// 要接的：你们自己的聊天 ViewModel / 网络层 / 消息行视图，把对应几段塞进去。不能单独编译。

import SwiftUI

// MARK: - 模型（原在 RoomEventCard 同文件）

/// 输入框上方挂的小签：{item, room, category, secret, to}，发送时拼 room_items + 本地回显记号。
struct PendingRoomItem: Identifiable, Equatable, Sendable {
    let id = UUID()
    let item: String
    let room: String
    let category: String
    let secret: Bool
    /// 给谁：her＝给她自己，ai＝给 AI；音乐、场景不分给谁，一律 her
    var to: String = "her"

    /// 音乐、场景点了直接挂签，不弹「给她／给 AI」
    static let noTarget: Set<String> = ["音乐", "场景"]
    var hasTarget: Bool { !Self.noTarget.contains(category) }

    /// 她这边的动词（跟后端 verb_for 一致）：香水→喷了，衣着→穿了，场景→想玩，其他→拿了；
    /// 给 AI 的前面挂「给AI」，拿了换成用了（卡上只写称呼，不写你/我/自己——「自己」会跟着说话的人翻面）
    var verb: String {
        let base: String
        switch category {
        case "香水": base = "喷了"
        case "衣着": base = "穿了"
        case "场景": base = "想玩"
        default: base = "拿了"
        }
        guard to == "ai", hasTarget else { return base }
        return "给AI" + (base == "喷了" || base == "穿了" ? base : "用了")
    }

    /// 小签上的字：分给谁的带方向「眼罩 → AI」
    var chipLabel: String {
        guard hasTarget else { return item }
        return "\(item) → \(to == "ai" ? "AI" : "她")"
    }

    /// 本地回显的记号行（发出去之前先画上卡）；服务端回来的正文为准
    var markerLine: String {
        let fields = [verb, item, category].map(Self.clean)
        return "[[room:her|\(fields[0])|\(fields[1])|\(fields[2])|\(secret ? 1 : 0)]]"
    }

    /// 跟后端 _clean 一字不差：分隔符和方括号换全角、换行换空格、去首尾空白
    static func clean(_ part: String) -> String {
        part.replacingOccurrences(of: "|", with: "／")
            .replacingOccurrences(of: "[", with: "［")
            .replacingOccurrences(of: "]", with: "］")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 请求体（原在网络层 ChatAPI）

/// 小签跟发送一起走：{item, room, to}，最多 6 样（后端 400/404 的 detail 原话显示给她）
struct SentRoomItem: Encodable, Equatable, Sendable {
    let item: String
    let room: String
    let to: String
}

/// /chat/send 的请求体里多一个可选字段 room_items（没挂签时不带）
struct SendRequest: Encodable {
    let text: String
    let conversationID: Int
    let roomItems: [SentRoomItem]?
    let clientMsgID: String

    enum CodingKeys: String, CodingKey {
        case text
        case conversationID = "conversation_id"
        case roomItems = "room_items"
        case clientMsgID = "client_msg_id"
    }
}

// MARK: - 状态与发送（原在聊天 ViewModel）

/// 下面是一个 ObservableObject 里跟暗格有关的几段，示意用；
/// 你们的 ViewModel 里本来就有 input / send / retry，照着把小签接进去。
@MainActor
final class RoomPendingModel: ObservableObject {
    @Published private(set) var pendingRoomItems: [PendingRoomItem] = []

    /// 屋卡上点一样挂上来：同一样不重复挂，最多 6 枚；返回 false 叫屋卡提示她
    @discardableResult
    func addPendingRoomItem(_ item: PendingRoomItem) -> Bool {
        guard pendingRoomItems.count < 6 else { return false }
        guard !pendingRoomItems.contains(where: { $0.item == item.item && $0.room == item.room }) else {
            return true   // 已挂着：当挂上处理，屋卡照常收起
        }
        pendingRoomItems.append(item)
        return true
    }

    func removePendingRoomItem(id: UUID) {
        pendingRoomItems.removeAll { $0.id == id }
    }

    /// 发送按钮可不可以点：只挂了签、一个字没打，也能发
    func canSend(input: String) -> Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingRoomItems.isEmpty
    }

    /// 发送那一下的顺序（摘自 send / sendUploaded / performSend）：
    /// 1. 按发送就把小签摘下来（跟附件一样）；
    /// 2. 本地先存一条「发送中」的消息，正文＝记号行 + 她的字（markerLine 先画上卡）；
    /// 3. 请求里带 room_items；
    /// 4. 失败了：消息标「未发出 · 点重发」，正文带着记号——点重发时原样再发正文，后端从记号认回小签重记；
    ///    本地都没存下来（还没生成消息）就把小签放回输入框上方，别跟着丢。
    func send(input: String, post: (SendRequest) async throws -> Void) async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let roomItems = pendingRoomItems
        pendingRoomItems = []
        let shown = renderedOutgoingText(text: text, roomItems: roomItems)
        _ = shown   // ← 存成本地回显消息
        do {
            try await post(SendRequest(
                text: text,
                conversationID: 0,   // 你们的会话 id
                roomItems: roomItems.isEmpty ? nil : roomItems.map {
                    SentRoomItem(item: $0.item, room: $0.room, to: $0.to)
                },
                clientMsgID: UUID().uuidString   // 回执丢了重发用同一个编号，后端查重之后才记数
            ))
        } catch {
            // 标失败；小签随这条失败消息走（正文带记号），把 detail 原话（比如「没有这样东西」）提示给她
        }
    }

    /// 本地回显的正文：记号行在最前，然后是她的字
    func renderedOutgoingText(text: String, roomItems: [PendingRoomItem]) -> String {
        (roomItems.map(\.markerLine) + [text])
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 输入框上方的小签条（原在聊天页 ChatView）

/// 暗底 #1A0F14 90% 胶囊，奶白 12pt 名字 + 右边 ×；排在附件缩略图前面
struct RoomItemChips: View {
    @ObservedObject var model: RoomPendingModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.pendingRoomItems) { item in
                    HStack(spacing: 6) {
                        Text(item.chipLabel)
                            .font(RoomChipFont.serif(12, text: item.chipLabel))
                            .foregroundStyle(RoomChipColor.cream)
                            .lineLimit(1)

                        Button {
                            model.removePendingRoomItem(id: item.id)
                        } label: {
                            Text("×")
                                .font(.system(size: 14))
                                .foregroundStyle(RoomChipColor.cream.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("摘掉 \(item.item)")
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 9)
                    .padding(.vertical, 6)
                    .background(RoomChipColor.chipBack.opacity(0.9), in: Capsule())
                }
            }
            .padding(.horizontal, 6)
        }
    }
}

// 屋卡怎么挂上来（原在 ChatView 根视图上）：不用系统 sheet，自绘面板挂在最上层 overlay，
// 进场/拖动/出场动画都在 RoomSheet 里面。
//
//   .overlay {
//       if isShowingRoom {
//           RoomSheet(
//               onPick: { item in
//                   // 挂上了：收起屋卡、输入框拿焦点；挂满了（false）屋卡自己提示、不收
//                   let accepted = model.addPendingRoomItem(item)
//                   if accepted { inputIsFocused = true }
//                   return accepted
//               },
//               onDismiss: { isShowingRoom = false }
//           )
//       }
//   }

// MARK: - 消息行：有记号就画正中卡（原在消息行视图）

/// 每个记号一张正中卡（竖排间距 8）。AI 的消息：记号后面的字进最后一张卡的 words；
/// 她的消息：记号后面的字照常画在她右边的气泡里，不进卡。
struct RoomEventRows<Bubble: View>: View {
    let content: String
    let isUser: Bool
    let timeText: String
    let bubble: (String) -> Bubble   // 你们的普通气泡

    var body: some View {
        let parsed = RoomEventMarker.parse(content)
        VStack(spacing: 8) {
            ForEach(Array(parsed.events.enumerated()), id: \.offset) { index, event in
                RoomEventCard(
                    event: event,
                    words: isUser || index < parsed.events.count - 1
                        ? nil
                        : parsed.rest.trimmingCharacters(in: .whitespacesAndNewlines),
                    timeText: timeText
                )
                .frame(maxWidth: .infinity)   // 正中：不贴左也不贴右
            }
            if isUser {
                let rest = parsed.rest.trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty { bubble(rest) }
            }
        }
    }
}

// MARK: - 会话列表预览（原在会话列表）

/// 末句预览不露物件名：开头是记号的，一律写「屋里来了一样东西」。锁屏推送本来就不带正文。
func roomSafePreview(_ value: String) -> String {
    let parsed = RoomEventMarker.parse(value)
    guard !parsed.events.isEmpty else { return value }
    return parsed.rest.isEmpty ? "屋里来了一样东西" : "屋里来了一样东西\n\(parsed.rest)"
}
