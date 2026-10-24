// 暗格 · 屋卡（SwiftUI 参考）
//
// 它干什么：她在 app 里打开的那张卡——十类清单，每样带次数；点一样，要分给谁的先亮「给她」「给 AI」两颗，
// 点完挂成输入框上方的小签（不当场发）；右下「加一样」能明着加，也能偷偷加（偷偷加可以写一句来历）。
// 在整条链里：GET /room/card 拉卡 → 点签交给 PendingRoomItem.swift 的 addPendingRoomItem → 跟消息一起发；
// 加一样走 POST /room/add。
// 要接的：RoomAPI 是占位，换成你们自己的网络层；字体名换成你们的；
// 底图资产 room-bg（竖长的深色花图）、room-grain（颗粒平铺图）是我们自己的底图，换成你们的。
// 不用系统 sheet：iOS 26 的半屏抽屉会浮起留边，所以自绘面板——左右铺满、高 0.8 屏、底边贴屏、
// 上两角圆 28，背后黑 0.35 遮罩，点遮罩或顶上下拖关。颜色、字号、两列算法都是照设计稿调的，可以直接用。

import SwiftUI
import UIKit

struct RoomSheet: View {
    /// 点了一枚签：交给聊天页挂小签；返回 true＝挂上了（屋卡收起），false＝挂满 6 枚（屋卡提示、不收）
    let onPick: (PendingRoomItem) -> Bool
    /// 关面板：内部先播滑走动画再回调
    let onDismiss: () -> Void

    @State private var groups: [RoomCardGroup] = []
    /// 「加一样」的格子单：接口给的 categories，没拉到就用兜底单
    @State private var serverCategories: [String] = []
    @State private var loadError: String?
    @State private var flashingItem: String?
    /// 点了一枚要分给谁的签：签底下亮出「给她」「给 AI」两颗，点哪颗才挂上
    @State private var choosingItem: String?
    @State private var itemNotice: RoomItemNotice?
    @State private var noticeTask: Task<Void, Never>?
    // 自绘面板三态：进场/拖动/出场
    @State private var isOffscreen = true
    @State private var dimmerOpacity = 0.0
    @State private var dragOffset: CGFloat = 0
    // 「加一样」小面板
    @State private var showingAdd = false
    @State private var addName = ""
    @State private var addCategory: String?
    @State private var addSecret = false
    /// 偷偷加时的一句来历（选填）：它从哪儿长出来的、留给什么时候；亮了后端自动删
    @State private var addOrigin = ""
    @State private var addError: String?
    @State private var addSubmitting = false
    @State private var keyboardHeight: CGFloat = 0
    @FocusState private var addFieldFocused: Bool

    var body: some View {
        GeometryReader { geo in
            let panelHeight = geo.size.height * 0.8
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.35)
                    .opacity(dimmerOpacity)
                    .ignoresSafeArea()
                    .onTapGesture { dismissPanel() }

                panel(bottomInset: geo.safeAreaInsets.bottom)
                    .frame(width: geo.size.width, height: panelHeight)
                    .offset(y: (isOffscreen ? panelHeight : 0) + dragOffset)
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .task { await loadCard() }
        // 键盘跟手：外层 ignoresSafeArea 把键盘安全区也吃了，改用通知量键盘高，小面板底内距跟着抬
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                keyboardHeight = max(0, UIScreen.main.bounds.height - frame.minY)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.3)) {
                isOffscreen = false
                dimmerOpacity = 1
            }
        }
    }

    // MARK: - 面板

    private func panel(bottomInset: CGFloat) -> some View {
        ZStack(alignment: .top) {
            // 背景图锁 GeometryReader + frame + clipped，禁裸 scaledToFill（会把面板撑出屏）。
            // 底图做成 1:2 竖长图，fill 就等于按宽铺，顶对齐、只裁底
            GeometryReader { geo in
                ZStack {
                    Image("room-bg")   // 你们自己的底图
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                        .clipped()

                    // 颗粒层：只平铺不缩放，一缩放就糊；浓淡只调 RoomGrain.opacity
                    Image("room-grain")   // 你们自己的颗粒图
                        .resizable(resizingMode: .tile)
                        .blendMode(.overlay)
                        .opacity(RoomGrain.opacity)
                        .allowsHitTesting(false)
                }
                .compositingGroup()
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
            }

            // 背景不滚，内容滚：顶上把手钉在 ScrollView 外
            VStack(alignment: .leading, spacing: 0) {
                dragZone

                if let loadError {
                    Text(loadError)
                        .font(.custom(RoomChipFont.fontName, size: 13))
                        .foregroundStyle(RoomColor.cream.opacity(0.6))
                        .padding(.horizontal, 28)
                        .padding(.top, 30)
                    Spacer()
                } else {
                    ScrollView {
                        groupsView(bottomInset: bottomInset)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if showingAdd {
                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.25)
                        .onTapGesture { closeAddPanel() }
                        .transition(.opacity)
                    addPanel(bottomInset: bottomInset)
                        .transition(.move(edge: .bottom))
                }
            }
        }
        .background(Color(red: 0.09, green: 0.05, blue: 0.07))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous))
    }

    /// 顶上把手 + 一截空白当拖拽区；下拖手势只挂这一块，不跟 ScrollView 抢
    private var dragZone: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(RoomColor.cream.opacity(0.35))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
            Color.clear.frame(height: 24)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(dragToDismiss)
    }

    /// 松手时下移 > 120pt 或预测落点 > 240pt 就关，否则弹回
    private var dragToDismiss: some Gesture {
        DragGesture()
            .onChanged { value in dragOffset = max(0, value.translation.height) }
            .onEnded { value in
                if value.translation.height > 120 || value.predictedEndTranslation.height > 240 {
                    dismissPanel()
                } else {
                    withAnimation(.easeOut(duration: 0.3)) { dragOffset = 0 }
                }
            }
    }

    private func dismissPanel() {
        withAnimation(.easeOut(duration: 0.25)) {
            isOffscreen = true
            dragOffset = 0
            dimmerOpacity = 0
        }
        Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(260)) } catch { return }
            onDismiss()
        }
    }

    // MARK: - 十类清单

    private let columnGap: CGFloat = 12

    private func groupsView(bottomInset: CGFloat) -> some View {
        let columnWidths = cardColumnWidths
        return VStack(alignment: .leading, spacing: 18) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.name)
                        .font(.custom(RoomChipFont.fontName, size: 16))
                        .tracking(2)
                        .foregroundStyle(RoomColor.cream)

                    // 音乐一组单列（歌名长），别的两列
                    if group.name == "音乐" {
                        let width = max(capsuleWidth(for: group.items), columnWidths.full)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(group.items) { item in
                                capsuleButton(item: item, category: group.name, width: width)
                            }
                        }
                    } else {
                        twoColumnGrid(items: group.items, category: group.name, widths: columnWidths)
                    }
                }
            }

            HStack {
                Spacer()
                Button { openAddPanel() } label: { entryLabel("加一样") }
                    .buttonStyle(.plain)
            }
            .padding(.trailing, 24)
        }
        .padding(.leading, 28)
        .padding(.bottom, bottomInset + 16)   // 让开 home 条
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 两列算法

    /// 一组里先把短签按顺序分成两半（奇数时左列多一枚），前一半自上而下放左列、后一半放右列，
    /// 逐行横着配对；长签排在短签之后，各占一整行。
    private func twoColumnRows(items: [RoomCardItem]) -> [[RoomCardItem]] {
        var shorts: [RoomCardItem] = []
        var longs: [RoomCardItem] = []
        for item in items {
            if Self.isShort(item.name) { shorts.append(item) } else { longs.append(item) }
        }
        let leftCount = (shorts.count + 1) / 2
        let left = Array(shorts.prefix(leftCount))
        let right = Array(shorts.suffix(shorts.count - leftCount))
        var rows: [[RoomCardItem]] = []
        for index in 0..<leftCount {
            rows.append(index < right.count ? [left[index], right[index]] : [left[index]])
        }
        for item in longs { rows.append([item]) }
        return rows
    }

    /// 短签门槛：名字宽度 ≤ 4.5（中文一字算 1，其余算 0.5）。393pt 宽的机器上并列签只容得下 4 个 12pt 中文字，
    /// 再长就会被截成「…」，所以长的独占一行。
    private static func isShort(_ name: String) -> Bool {
        var width = 0.0
        for scalar in name.unicodeScalars {
            width += scalar.value >= 0x2E80 ? 1 : 0.5
        }
        return width <= 4.5
    }

    /// 两列宽整张卡统一：短签宽取所有两列组里最长的短签，整行宽 = 2 × 短签宽 + 列距；
    /// 长签自然宽超过整行宽时整行放宽到它、短签跟着均分，名字不截。
    private var cardColumnWidths: (pair: CGFloat, full: CGFloat) {
        let items = groups.filter { $0.name != "音乐" }.flatMap(\.items)
        let shortWidth = capsuleWidth(for: items.filter { Self.isShort($0.name) })
        let longWidth = capsuleWidth(for: items.filter { !Self.isShort($0.name) })
        let full = max(shortWidth * 2 + columnGap, longWidth)
        return ((full - columnGap) / 2, full)
    }

    private func twoColumnGrid(
        items: [RoomCardItem],
        category: String,
        widths: (pair: CGFloat, full: CGFloat)
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(twoColumnRows(items: items).enumerated()), id: \.offset) { _, row in
                if row.count == 1, !Self.isShort(row[0].name) {
                    capsuleButton(item: row[0], category: category, width: widths.full)
                } else {
                    // 顶对齐：一枚签底下亮出「给谁」两颗时，旁边那枚不跟着往下沉
                    HStack(alignment: .top, spacing: columnGap) {
                        ForEach(row) { item in
                            capsuleButton(item: item, category: category, width: widths.pair)
                        }
                    }
                }
            }
        }
        .frame(width: widths.full, alignment: .leading)
    }

    // MARK: - 签

    /// 签宽：左 10 + 名字（12pt、字距 1.2）+ 至少 8 + 次数（Didot 11）+ 右 10，取组内最宽一枚做统一宽
    private func capsuleWidth(for items: [RoomCardItem]) -> CGFloat {
        let nameFont = UIFont(name: RoomChipFont.fontName, size: 12) ?? .systemFont(ofSize: 12)
        let countFont = UIFont(name: "Didot", size: 11) ?? .systemFont(ofSize: 11)
        var widest: CGFloat = 0
        for item in items {
            let nameWidth = (item.name as NSString).size(withAttributes: [.font: nameFont, .kern: 1.2]).width
            let countWidth = ("\(item.used)" as NSString).size(withAttributes: [.font: countFont]).width
            widest = max(widest, 10 + ceil(nameWidth) + 8 + ceil(countWidth) + 10)
        }
        return widest
    }

    private func capsuleButton(item: RoomCardItem, category: String, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if PendingRoomItem.noTarget.contains(category) {
                    take(item, category: category, to: "her")
                } else {
                    // 再点一次同一枚＝不挂了，收起两颗钮
                    withAnimation(.easeOut(duration: 0.15)) {
                        choosingItem = choosingItem == item.name ? nil : item.name
                    }
                }
            } label: {
                capsuleLabel(
                    name: item.name,
                    used: item.used,
                    accented: item.used > 0 || flashingItem == item.name || choosingItem == item.name,
                    secret: item.secret
                )
                .frame(width: width)
            }
            .buttonStyle(.plain)

            if choosingItem == item.name {
                HStack(spacing: 6) {
                    targetButton("给她") { take(item, category: category, to: "her") }
                    targetButton("给 AI") { take(item, category: category, to: "ai") }
                }
                .frame(width: width)
                .transition(.opacity)
            }

            // 挂满等提示：签下面 12pt 米色 60%，三秒自收（不弹 alert）
            if let itemNotice, itemNotice.name == item.name {
                Text(itemNotice.text)
                    .font(.custom(RoomChipFont.fontName, size: 12))
                    .foregroundStyle(RoomColor.cream.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: width, alignment: .leading)
            }
        }
    }

    /// 「给谁」两颗：跟签一个描边一个字体，矮一号（高 24、字 11），各占签宽一半
    private func targetButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.custom(RoomChipFont.fontName, size: 11))
                .tracking(1.2)
                .foregroundStyle(RoomColor.accentText)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(RoomColor.accentStroke, lineWidth: 0.5)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    /// 细线胶囊：0.5pt 描边、圆角 14、高 28；用过的（used>0）或刚点的亮藕粉：描边 #D38CA5、字 #F3BECC；
    /// 否则描边 #95857D、字 #FEFEFC、数字 #F9CDDB
    private func capsuleLabel(name: String, used: Int, accented: Bool, secret: Bool) -> some View {
        HStack(spacing: 0) {
            Text(name)
                .font(.custom(RoomChipFont.fontName, size: 12))
                .tracking(1.2)
                .foregroundStyle(accented ? RoomColor.accentText : RoomColor.cream)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text("\(used)")
                .font(.custom("Didot", size: 11))
                .foregroundStyle(accented ? RoomColor.accentText : RoomColor.number)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(accented ? RoomColor.accentStroke : RoomColor.stroke, lineWidth: 0.5)
        }
        .overlay(alignment: .topTrailing) {
            // 她偷偷加的：右上角 4pt 藕粉小点＝「AI 还不知道」；她第一次点、发出去之后后端摘掉，下次打开就没了
            if secret {
                Circle()
                    .fill(RoomColor.accentStroke)
                    .frame(width: 4, height: 4)
                    .offset(x: 2, y: -2)
            }
        }
        .animation(.easeOut(duration: 0.15), value: accented)
    }

    private func entryLabel(_ title: String) -> some View {
        Text(title)
            .font(.custom(RoomChipFont.fontName, size: 13))
            .tracking(1.5)
            .foregroundStyle(RoomColor.cream)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(RoomColor.stroke, lineWidth: 0.6)
            }
    }

    // MARK: - 加一样面板

    private static let fallbackCategories = ["香水", "衣着", "束缚", "玩物", "温度", "酒", "甜点", "浴间", "音乐", "场景"]
    private var addCategories: [String] {
        serverCategories.isEmpty ? Self.fallbackCategories : serverCategories
    }

    private var addNameTrimmed: String { addName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var addOriginTrimmed: String { addOrigin.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// 名字空或者提交中：「加进去」灰掉
    private var addDisabled: Bool {
        addNameTrimmed.isEmpty || addSubmitting
    }

    private func openAddPanel() {
        addName = ""
        addCategory = nil
        addSecret = false
        addOrigin = ""
        addError = nil
        addSubmitting = false
        withAnimation(.easeOut(duration: 0.25)) { showingAdd = true }
        // 进场动画走完再弹键盘
        Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            addFieldFocused = true
        }
    }

    private func closeAddPanel() {
        addFieldFocused = false
        withAnimation(.easeOut(duration: 0.25)) { showingAdd = false }
    }

    private func addPanel(bottomInset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                Capsule()
                    .fill(RoomColor.cream.opacity(0.35))
                    .frame(width: 36, height: 5)
                HStack {
                    Spacer()
                    Button { closeAddPanel() } label: {
                        Text("收起")
                            .font(.custom(RoomChipFont.fontName, size: 12))
                            .foregroundStyle(RoomColor.cream.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)

            // 名字（后端 400/409 的 detail 原话显示在输入框下面，面板不收）
            VStack(alignment: .leading, spacing: 4) {
                underlinedField("叫什么", text: $addName, focus: $addFieldFocused)
                if let addError {
                    Text(addError)
                        .font(.custom(RoomChipFont.fontName, size: 12))
                        .foregroundStyle(RoomColor.cream.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            addSection("放哪一格") {
                // 十格一行排不下：五个一行折两行
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(stride(from: 0, to: addCategories.count, by: 5)), id: \.self) { start in
                        HStack(spacing: 8) {
                            ForEach(addCategories[start..<min(start + 5, addCategories.count)], id: \.self) { category in
                                addOptionChip(category, selected: addCategory == category) {
                                    addCategory = category
                                }
                            }
                        }
                    }
                }
            }

            // 偷偷加：AI 看不见，她第一次用才让它知道
            VStack(alignment: .leading, spacing: 2) {
                Toggle(isOn: $addSecret.animation(.easeOut(duration: 0.2))) {
                    Text("偷偷加")
                        .font(.custom(RoomChipFont.fontName, size: 13))
                        .foregroundStyle(RoomColor.cream)
                }
                .tint(RoomColor.accentStroke)
                Text("第一次用才让它知道")
                    .font(.custom(RoomChipFont.fontName, size: 12))
                    .foregroundStyle(RoomColor.cream.opacity(0.6))
            }

            // 藏可以写一句来历：藏和用之间往往隔好几个窗口，写下来到时候才想得起为什么藏；不写也能藏
            if addSecret {
                underlinedField("一句来历（可不写）：它从哪儿来、留给什么时候", text: $addOrigin, focus: nil)
                    .transition(.opacity)
            }

            Button { Task { await postAdd() } } label: {
                Text("加进去")
                    .font(.custom(RoomChipFont.fontName, size: 13))
                    .tracking(1.5)
                    .foregroundStyle(RoomColor.cream)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(RoomColor.stroke, lineWidth: 0.6)
                    }
            }
            .buttonStyle(.plain)
            .opacity(addDisabled ? 0.35 : 1)
            .disabled(addDisabled)
        }
        .padding(.horizontal, 28)
        .padding(.top, 4)
        // 让开键盘/home 条的那段留在底色里：底色一直铺到屏幕底，下面的签不从缝里露出来
        .padding(.bottom, 16 + max(keyboardHeight, bottomInset))
        .frame(maxWidth: .infinity, alignment: .leading)
        // 不透明：半透明时底下的签会透上来跟表单叠在一起
        .background(Color(red: 0.09, green: 0.05, blue: 0.07))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20, style: .continuous))
    }

    /// 只有一条下划线的输入框，占位字淡米色
    /// focus 给了就把键盘焦点绑在这个输入框上（名字那格用，进面板自动弹键盘）
    private func underlinedField(
        _ placeholder: String,
        text: Binding<String>,
        focus: FocusState<Bool>.Binding?
    ) -> some View {
        ZStack(alignment: .leading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.custom(RoomChipFont.fontName, size: 14))
                    .foregroundStyle(RoomColor.cream.opacity(0.35))
            }
            if let focus {
                plainField(text).focused(focus)
            } else {
                plainField(text)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(RoomColor.cream.opacity(0.3)).frame(height: 0.5)
        }
    }

    private func plainField(_ text: Binding<String>) -> some View {
        TextField("", text: text)
            .font(.custom(RoomChipFont.fontName, size: 14))
            .foregroundStyle(RoomColor.cream)
            .submitLabel(.done)
            .onSubmit { addFieldFocused = false }
            .onChange(of: text.wrappedValue) { _, _ in addError = nil }
    }

    private func addSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.custom(RoomChipFont.fontName, size: 12))
                .foregroundStyle(RoomColor.cream.opacity(0.6))
            content()
        }
    }

    /// 细描边单选签：选中态跟亮藕粉的签同款
    private func addOptionChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.custom(RoomChipFont.fontName, size: 12))
                .tracking(1.2)
                .foregroundStyle(selected ? RoomColor.accentText : RoomColor.cream)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(selected ? RoomColor.accentStroke : RoomColor.stroke, lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 数据

    @MainActor
    private func loadCard() async {
        do {
            let card: RoomCardResponse = try await RoomAPI.shared.get("/room/card")
            groups = card.groups
            serverCategories = card.categories
            loadError = nil
        } catch {
            NSLog("[RoomSheet] /room/card failed: %@", String(describing: type(of: error)))
            loadError = "暗格没回话，等会儿再进来看看"
        }
    }

    /// 点一枚签（要分给谁的点完两颗之一才到这儿）：藕粉闪 0.3s，挂成输入框上方的小签——
    /// 不在这里记数，跟她的字一起发出去才作数。挂上了屋卡收起。
    private func take(_ item: RoomCardItem, category: String, to: String) {
        choosingItem = nil
        flashingItem = item.name
        Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            if flashingItem == item.name { flashingItem = nil }
        }
        let pending = PendingRoomItem(item: item.name, room: "", category: category, secret: item.secret, to: to)
        if onPick(pending) {
            dismissPanel()
        } else {
            showNotice(item: item.name, text: "小签最多挂 6 样，先发送或叉掉一枚")
        }
    }

    private func showNotice(item: String, text: String) {
        noticeTask?.cancel()
        itemNotice = RoomItemNotice(name: item, text: text)
        noticeTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            if itemNotice?.name == item { itemNotice = nil }
        }
    }

    @MainActor
    private func postAdd() async {
        guard let category = addCategory else {
            addError = "还没选放哪一格"
            return
        }
        addSubmitting = true
        defer { addSubmitting = false }
        do {
            let _: RoomAddResponse = try await RoomAPI.shared.post(
                "/room/add",
                body: RoomAddBody(category: category, name: addNameTrimmed, secret: addSecret,
                                  desc: addSecret ? addOriginTrimmed : "")
            )
            closeAddPanel()
            await loadCard()
        } catch RoomAPIError.server(let detail) {
            addError = detail   // 后端的人话（撞名之类）原样给她看
        } catch {
            // 物件名是私密的：日志只记错误类型，不记正文
            NSLog("[RoomSheet] /room/add failed: %@", String(describing: type(of: error)))
            addError = "暗格没搭上话，等会儿再试"
        }
    }
}

// MARK: - 接口模型（跟 room_api.py 的 /room/card、/room/add 对上）

private struct RoomCardResponse: Decodable {
    let name: String
    let groups: [RoomCardGroup]
    let categories: [String]
}

private struct RoomCardGroup: Decodable, Identifiable {
    let name: String
    var items: [RoomCardItem]
    var id: String { name }
}

private struct RoomCardItem: Decodable, Identifiable, Hashable {
    let name: String
    let used: Int
    /// 她偷偷加的、AI 还不知道
    let secret: Bool
    var id: String { name }
}

private struct RoomAddBody: Encodable, Sendable {
    let category: String
    let name: String
    let secret: Bool
    /// 偷偷加时的一句来历（选填）
    let desc: String
}

private struct RoomAddResponse: Decodable {
    let ok: Bool
    let secret: Bool?
}

private struct RoomItemNotice {
    let name: String
    let text: String
}

// MARK: - 占位：换成你们自己的网络层

enum RoomAPIError: Error {
    /// 后端回的 detail 人话
    case server(String)
}

/// 占位：换成你们自己的网络层（带上你们的鉴权头，后端 4xx 时把 detail 抛成 .server）
final class RoomAPI {
    static let shared = RoomAPI()

    func get<T: Decodable>(_ path: String) async throws -> T {
        fatalError("接你们自己的网络层：GET \(path)")
    }

    func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        fatalError("接你们自己的网络层：POST \(path)")
    }
}

// MARK: - 屋卡专用色

/// 从设计稿逐像素取样：藕粉只落在亮的签（描边+字）、次数数字上
private enum RoomColor {
    static let cream = Color(hex: 0xFEFEFC)        // 组名/签内字
    static let stroke = Color(hex: 0x95857D)       // 米色描边
    static let accentStroke = Color(hex: 0xD38CA5) // 亮签描边、藏的小点
    static let accentText = Color(hex: 0xF3BECC)   // 亮签字与数字
    static let number = Color(hex: 0xF9CDDB)       // 次数数字（不亮时）
}

/// 颗粒强度总开关：以后只调这一个数（底图自带纹理时设 0，再叠细噪点暗处会发灰）
private enum RoomGrain {
    static let opacity = 0.0
}
