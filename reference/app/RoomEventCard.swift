// 暗格 · 聊天页正中卡（SwiftUI 参考）
//
// 它干什么：消息正文开头如果有记号行 [[room:WHO|VERB|NAME|CATEGORY|SURPRISE]]，
// 这条消息就不画普通气泡，而是在聊天页正中画一张暗色小卡：「AI 给她穿了 / 物件名 / AI 现写的那句话」。
// 在整条链里：后端（room_api.py 的 marker）往正文开头写记号，app 拉到消息后在这里解析、画卡。
// 两头都会写记号：她点签发出去的消息（WHO=her），AI 用了东西落的消息（WHO=ai）。
// 要接的：字体 SourceHanSerifSC-Regular 是我们打进 app 的思源宋，换成你们的；
// 底图资产 room-chip 是我们自己的底图（一张深色花瓣图，靠右裁），换成你们自己的。
// 颜色、字距、尺寸都是照设计稿调出来的，可以直接用。

import SwiftUI
import UIKit

// MARK: - 卡片记号 [[room:WHO|VERB|NAME|CATEGORY|SURPRISE]]

/// 记号的解析结果：WHO her/ai，VERB 是成品动词照抄，SURPRISE 1 = 藏着的东西第一次用。
struct RoomEvent: Equatable, Sendable {
    let who: String
    let verb: String
    let name: String
    let category: String
    let surprise: Bool

    /// 卡上显示的称呼：换成你们家的
    var whoDisplay: String {
        switch who {
        case "ai": return "AI"
        case "her": return "她"
        default: return who
        }
    }
}

/// 正文开头的记号：只认行首整行，一行一个，可以连着多行。
/// 解析失败的那一行起全部当普通文字（不崩、不吞字）。
enum RoomEventMarker {
    /// 把正文拆成（记号列，剩下的文字）。没有记号时 events 为空、rest 是原文。
    static func parse(_ content: String) -> (events: [RoomEvent], rest: String) {
        var events: [RoomEvent] = []
        var remaining = content[...]
        while remaining.hasPrefix("[[room:") {
            let lineEnd = remaining.firstIndex(of: "\n") ?? remaining.endIndex
            guard let event = parseLine(String(remaining[..<lineEnd])) else { break }
            events.append(event)
            remaining = lineEnd < remaining.endIndex
                ? remaining[remaining.index(after: lineEnd)...]
                : remaining[remaining.endIndex...]
        }
        return (events, String(remaining))
    }

    /// 轻量探针：正文以记号开头就不参与气泡合并、不当会话标题
    static func hasCards(_ content: String) -> Bool {
        content.hasPrefix("[[room:") && !parse(content).events.isEmpty
    }

    private static let lineRegex: NSRegularExpression? = {
        do {
            return try NSRegularExpression(
                pattern: #"\A\[\[room:([^|\]]*)\|([^|\]]*)\|([^|\]]*)\|([^|\]]*)\|([01])\]\]\z"#
            )
        } catch {
            NSLog("[RoomEventCard] 记号正则编译失败 %@", String(describing: type(of: error)))
            return nil
        }
    }()

    private static func parseLine(_ line: String) -> RoomEvent? {
        guard let regex = lineRegex else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range) else { return nil }
        func field(_ index: Int) -> String? {
            Range(match.range(at: index), in: line).map { String(line[$0]) }
        }
        guard let who = field(1), let verb = field(2), let name = field(3),
              let category = field(4), let surprise = field(5),
              who == "ai" || who == "her",
              !verb.isEmpty, !name.isEmpty else { return nil }
        return RoomEvent(who: who, verb: verb, name: name, category: category, surprise: surprise == "1")
    }
}

// MARK: - 正中卡

/// 暗色小卡：236 宽定死，高随内容；底图 room-chip 铺满靠右裁 + 左暗渐变。
/// 卡宽写死、背景 GeometryReader 只量卡内部已定的尺寸，不往上报（往上报会让列表反复重排）。
struct RoomEventCard: View {
    let event: RoomEvent
    /// 只有 AI 的卡有：它现写的那句话
    let words: String?
    /// 消息自己的时间（跟气泡同一套格式，外面排好版传进来）
    let timeText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(event.whoDisplay) \(event.verb)")
                .font(RoomChipFont.serif(10.5, text: "\(event.whoDisplay) \(event.verb)"))
                .tracking(2)
                .foregroundStyle(RoomChipColor.cream.opacity(0.7))

            Text(event.name)
                .font(RoomChipFont.serif(19, text: event.name))
                .tracking(3)
                .foregroundStyle(RoomChipColor.name)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 7)

            Rectangle()
                .fill(RoomChipColor.cream.opacity(0.42))
                .frame(width: 22, height: 0.8)
                .padding(.top, 9)
                .padding(.bottom, 8)

            if let words, !words.isEmpty {
                Text(words)
                    .font(RoomChipFont.serif(12.5, text: words))
                    .tracking(0.4)
                    .lineSpacing(RoomChipFont.wordsLineSpacing)
                    .foregroundStyle(RoomChipColor.cream.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 150, alignment: .leading)   // 右边留给底图上的花
            }

            HStack(spacing: 0) {
                if event.surprise {
                    Circle()
                        .fill(RoomChipColor.surpriseDot)
                        .frame(width: 4, height: 4)
                    Text("surprise")
                        .font(RoomChipFont.serif(9, text: "surprise").italic())
                        .tracking(1.2)
                        .foregroundStyle(RoomChipColor.surpriseText)
                        .padding(.leading, 5)
                }
                Spacer(minLength: 0)
                Text(timeText)
                    .font(RoomChipFont.serif(9, text: timeText))
                    .tracking(1)
                    .foregroundStyle(RoomChipColor.cream.opacity(0.5))
            }
            .padding(.top, 6)
        }
        .padding(EdgeInsets(top: 13, leading: 15, bottom: 10, trailing: 15))
        .frame(width: 236, alignment: .leading)
        .background {
            // 底图锁 GeometryReader + frame + clipped：不许裸 scaledToFill，否则图会把卡撑大
            GeometryReader { geo in
                ZStack {
                    Image("room-chip")   // 你们自己的底图
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .trailing)
                        .clipped()

                    // 左暗渐变：rgba(18,8,13,.55) → .2@55% → 0，压住左边让字读得清
                    LinearGradient(
                        stops: [
                            .init(color: RoomChipColor.shade.opacity(0.55), location: 0),
                            .init(color: RoomChipColor.shade.opacity(0.2), location: 0.55),
                            .init(color: RoomChipColor.shade.opacity(0), location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(RoomChipColor.stroke, lineWidth: 0.5)
        }
        .shadow(color: RoomChipColor.shadow, radius: 18, y: 6)
    }
}

// MARK: - 卡与小签共用：字与色

/// 字体：思源宋子集缺字时整段回落系统宋体，不出方框（换成你们的字体名）
enum RoomChipFont {
    static let fontName = "SourceHanSerifSC-Regular"   // 换成你们打进 app 的字体

    static func serif(_ size: CGFloat, text: String) -> Font {
        if !text.isEmpty, !covers(text) {
            return .custom("Songti SC", size: size)
        }
        return .custom(fontName, size: size)
    }

    /// words 行高 1.75：lineSpacing = 1.75×字号 − 字体自带行高
    static let wordsLineSpacing: CGFloat = {
        let size: CGFloat = 12.5
        let uiFont = UIFont(name: fontName, size: size) ?? UIFont.systemFont(ofSize: size)
        return max(0, size * 1.75 - uiFont.lineHeight)
    }()

    private static func covers(_ text: String) -> Bool {
        guard let uiFont = UIFont(name: fontName, size: 12) else { return false }
        let set = CTFontCopyCharacterSet(uiFont as CTFont) as CharacterSet
        return text.unicodeScalars.allSatisfy { set.contains($0) }
    }
}

enum RoomChipColor {
    static let cream = Color(hex: 0xFEFEFC)        // 奶白
    static let name = Color(hex: 0xF3BECC)         // 物件名·藕粉
    static let surpriseDot = Color(hex: 0xF2A5C2)  // surprise 4pt 圆点
    static let surpriseText = Color(hex: 0xF9CDDB) // surprise 斜体
    static let shade = Color(hex: 0x12080D)        // 左暗渐变 rgb(18,8,13)
    static let stroke = Color(hex: 0xF9CDDB).opacity(0.16)
    static let shadow = Color(hex: 0x1E0A12).opacity(0.26)
    static let chipBack = Color(hex: 0x1A0F14)     // 输入框上方小签的暗底
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
