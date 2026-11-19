import SwiftUI
import AppKit

/// Design tokens (0.6.0). One neutral ramp, one accent.
/// - The accent is the low-saturation fog blue the user chose; it also marks
///   words that were actually spoken. Translations are near-black.
/// - Surfaces step in tone; separators are hairlines of the ink at low opacity.
private enum Palette {
    static let text = Color(red: 31 / 255, green: 35 / 255, blue: 40 / 255)          // #1F2328
    static let secondary = Color(red: 87 / 255, green: 96 / 255, blue: 106 / 255)     // #57606A
    static let metadata = Color(red: 110 / 255, green: 119 / 255, blue: 129 / 255)     // #6E7781
    static let accent = Color(red: 76 / 255, green: 101 / 255, blue: 130 / 255)        // #4C6582 霧藍
    static let translationText = Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255)
    static let frame = Color(red: 246 / 255, green: 246 / 255, blue: 247 / 255)        // sidebar, sheet bars
    static let selection = Color(red: 232 / 255, green: 234 / 255, blue: 237 / 255)
    static let hover = Color(red: 239 / 255, green: 240 / 255, blue: 242 / 255)
    static let edge = Color.black.opacity(0.08)
    static let transcript = Color.white
    /// Alternate rows: a visible neutral step on the white canvas (≈5 L* darker).
    static let transcriptAlternate = Color(red: 238 / 255, green: 240 / 255, blue: 243 / 255)
    static let live = Color(red: 228 / 255, green: 236 / 255, blue: 246 / 255)          // accent-tinted, distinct from stripes
    static let recording = Color(red: 166 / 255, green: 66 / 255, blue: 58 / 255)      // muted red
    static let error = Color(red: 148 / 255, green: 59 / 255, blue: 59 / 255)
}

private enum Metrics {
    static let sidebarWidth: CGFloat = 240
    static let gutter: CGFloat = 92          // timecode column
    static let columnGap: CGFloat = 32       // holds the swap button in the header
    static let actions: CGFloat = 36         // row menu column
    static let rowPadding: CGFloat = 16
    static let barHeight: CGFloat = 52
}

/// Press feedback for custom buttons: a small scale-down, fast ease-out.
private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A navigation row: icon column, label, optional trailing hint.
private struct NavRow: View {
    let title: String
    let symbol: String
    var hint: String? = nil
    let action: () -> Void
    @ViewState<Bool> private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14)).frame(width: 18).foregroundStyle(Palette.secondary)
                Text(title).font(.system(size: 13)).foregroundStyle(Palette.text)
                Spacer(minLength: 4)
                if let hint { Text(hint).font(.system(size: 11)).foregroundStyle(Palette.metadata) }
            }
            .padding(.horizontal, 8).frame(height: 32)
            .background(hovering ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
    }
}

struct ContentView: View {
    @Bindable var model: AppModel
    @Binding var showsVersionHistory: Bool
    @ViewState<Bool> private var sidebarShown = false
    @ViewState<ConversationActions> private var conversationActions = ConversationActions()
    @ViewState<Bool> private var followsLatest = true
    @ViewState<Bool> private var nearBottom = true
    @ViewState<Bool> private var userScrolling = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel, showsVersionHistory: Binding<Bool> = .constant(false)) {
        self.model = model
        _showsVersionHistory = showsVersionHistory
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 960
            HStack(spacing: 0) {
                if !compact {
                    sidebar(compact: false).frame(width: Metrics.sidebarWidth)
                    Palette.edge.frame(width: 1)
                }
                VStack(spacing: 0) {
                    header(compact: compact)
                    notices
                    workArea
                    controlBar
                }
                .background(Palette.transcript)
            }
            .background(Palette.frame)
            .ignoresSafeArea(.container, edges: .top)
            .overlay(alignment: .topLeading) {
                if compact && sidebarShown {
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.12).onTapGesture { sidebarShown = false }
                        sidebar(compact: true)
                            .frame(width: Metrics.sidebarWidth, height: geometry.size.height)
                            .overlay(alignment: .trailing) { Palette.edge.frame(width: 1) }
                    }
                    .transition(.opacity)
                }
            }
            .sheet(isPresented: $model.showsSettings) {
                SettingsView(model: model, availableSize: geometry.size)
            }
            .sheet(isPresented: $model.showsHistory) {
                HistoryView(model: model, availableSize: geometry.size)
            }
            .sheet(isPresented: $model.showsSemanticEnvironment) {
                SemanticEnvironmentView(model: model, availableSize: geometry.size)
            }
            .sheet(isPresented: $showsVersionHistory) {
                VersionHistoryView(availableSize: geometry.size)
            }
            .onChange(of: compact) { _, compact in if !compact { sidebarShown = false } }
        }
        .foregroundStyle(Palette.text).tint(Palette.accent)
        .frame(minWidth: 660, minHeight: 520)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: sidebarShown)
        .onChange(of: model.settings) { _, _ in model.settingsChanged() }
        .onAppear { model.onFirstAppearance() }
        .modifier(ConversationActionDialogs(model: model, actions: $conversationActions))
    }

    // MARK: Sidebar

    private func sidebar(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The window has no title bar: the traffic lights sit in this row.
            HStack {
                Spacer()
                if compact {
                    Button { sidebarShown = false } label: {
                        Image(systemName: "sidebar.left").font(.system(size: 14)).frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderless).foregroundStyle(Palette.secondary)
                    .help("收起側邊欄").accessibilityLabel("收起側邊欄")
                }
            }
            .padding(.horizontal, 16).frame(height: Metrics.barHeight)

            VStack(spacing: 4) {
                NavRow(title: "開始新對話", symbol: "square.and.pencil", hint: "⌘N") {
                    sidebarShown = false
                    model.newConversation()
                }
                .disabled(model.isBusy)
                .help(model.settings.isIncognito ? "開始新對話；無痕模式不儲存歷史" : "保存目前對話並開始新的一筆")
                searchField
            }
            .padding(.horizontal, 8)

            Text("對話").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
                .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 8)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(sidebarConversations) { conversation in
                        ConversationRow(model: model, conversation: conversation,
                                        actions: $conversationActions) { sidebarShown = false }
                    }
                    if sidebarConversations.isEmpty && !model.historySearch.isEmpty {
                        Text("沒有符合的對話").font(.system(size: 12)).foregroundStyle(Palette.metadata)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.automatic)

            Palette.edge.frame(height: 1)
            VStack(spacing: 2) {
                NavRow(title: "語意環境", symbol: "text.book.closed") {
                    sidebarShown = false
                    model.showsSemanticEnvironment = true
                }
                NavRow(title: "設定", symbol: "gearshape", hint: "⌘,") {
                    sidebarShown = false
                    model.showsSettings = true
                }
            }
            .padding(8)
        }
        .background(Palette.frame)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Palette.metadata)
                .frame(width: 18)
            TextField("搜尋", text: $model.historySearch, prompt: Text("搜尋").foregroundStyle(Palette.metadata))
                .textFieldStyle(.plain).font(.system(size: 13))
            if !model.historySearch.isEmpty {
                Button { model.historySearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(Palette.metadata).accessibilityLabel("清除搜尋")
            }
        }
        .padding(.horizontal, 8).frame(height: 32)
        .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .disabled(model.settings.isIncognito)
    }

    /// The current conversation first, then saved ones, filtered by the search field.
    private var sidebarConversations: [Conversation] {
        var list = model.history
        if model.historySearch.isEmpty, let current = model.currentConversation,
           !list.contains(where: { $0.id == current.id }) {
            list.insert(current, at: 0)
        }
        return list.map { saved in
            saved.id == model.currentConversationID ? (model.currentConversation ?? saved) : saved
        }
    }

    // MARK: Header

    private func header(compact: Bool) -> some View {
        HStack(spacing: 12) {
            if compact {
                Button { sidebarShown.toggle() } label: {
                    Image(systemName: "sidebar.left").font(.system(size: 14)).frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless).foregroundStyle(Palette.secondary)
                .help("顯示對話列表").accessibilityLabel("顯示對話列表")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.currentConversation?.hasContent == true ? model.currentConversation?.title ?? "" : "新的對話")
                    .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(headerSubtitle).font(.system(size: 11)).foregroundStyle(Palette.metadata).lineLimit(1)
            }
            .layoutPriority(-1)
            Spacer(minLength: 8)
            Menu {
                if let conversation = model.currentConversation {
                    ForEach(ExportFormat.allCases) { format in
                        Button("匯出 \(format.title)") { model.export(conversation, format: format) }
                    }
                }
            } label: {
                Label("匯出", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(model.currentConversation?.hasContent != true)
            .help("匯出 Markdown 或 TXT 逐字稿（⌘E）").accessibilityLabel("匯出逐字稿")
        }
        .font(.system(size: 13))
        .padding(.leading, compact ? 80 : 16).padding(.trailing, 16).frame(height: Metrics.barHeight)
        .overlay(alignment: .bottom) { Palette.edge.frame(height: 1) }
    }

    private var headerSubtitle: String {
        if model.isDemo { return "示範資料，未連接收音與 API" }
        guard let conversation = model.currentConversation, conversation.hasContent else {
            return model.settings.isIncognito ? "無痕模式，不保存" : "尚未開始"
        }
        let date = conversation.createdAt.formatted(.dateTime.month().day().hour().minute())
        return "\(date) · \(conversation.segments.count) 句" + (model.settings.isIncognito ? " · 無痕模式" : "")
    }

    @ViewBuilder private var notices: some View {
        if let error = model.errorMessage {
            Notice(text: error, isError: true) { model.errorMessage = nil }
        }
        if let info = model.infoMessage {
            Notice(text: info, isError: false) { model.infoMessage = nil }
        }
    }

    // MARK: Transcript

    private var workArea: some View {
        GeometryReader { geometry in
            let columns = geometry.size.width >= 600
            VStack(spacing: 0) {
                columnHeader(columns: columns)
                transcript(columns: columns)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The column titles are the language controls: each side names and chooses its language.
    private func columnHeader(columns: Bool) -> some View {
        HStack(spacing: 0) {
            if columns {
                Text("時間").font(.system(size: 12)).foregroundStyle(Palette.metadata)
                    .frame(width: Metrics.gutter, alignment: .leading).padding(.leading, 20)
                languageMenu(onLeft: true).frame(maxWidth: .infinity, alignment: .leading)
                swapButton.frame(width: Metrics.columnGap)
                languageMenu(onLeft: false).frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: Metrics.actions)
            } else {
                languageMenu(onLeft: true).padding(.leading, 20)
                swapButton.frame(width: 40)
                languageMenu(onLeft: false)
                Spacer()
            }
        }
        .frame(height: 40)
        .background(Palette.transcript)
        .overlay(alignment: .bottom) { Palette.edge.frame(height: 1) }
    }

    private func languageMenu(onLeft: Bool) -> some View {
        let current = onLeft ? model.settings.leftLanguage : model.settings.rightLanguage
        return Menu {
            Picker(onLeft ? "左邊語言" : "右邊語言", selection: Binding(
                get: { TranscriptLanguage.locale(current) },
                set: { model.selectDialogueLanguage($0, onLeft: onLeft) }
            )) {
                ForEach(TranscriptLanguage.sourceChoices.filter { $0 != "auto" }, id: \.self) { language in
                    Text(TranscriptLanguage.name(language)).tag(language)
                }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            Text(TranscriptLanguage.name(current)).font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .disabled(model.isBusy)
        .help(model.isRecording ? "變更語言會停止目前辨識" : (onLeft ? "左側欄的語言" : "右側欄的語言"))
        .accessibilityLabel(onLeft ? "左邊語言" : "右邊語言")
    }

    private var swapButton: some View {
        Button { model.swapLanguages() } label: {
            Image(systemName: "arrow.left.arrow.right").font(.system(size: 12)).frame(width: 28, height: 28)
        }
        .buttonStyle(.borderless).foregroundStyle(Palette.secondary)
        .disabled(!model.canSwapLanguages)
        .help(model.isRecording ? "交換語言會停止目前辨識" : "交換左右語言")
        .accessibilityLabel("交換左右語言")
    }

    @ViewBuilder private func transcript(columns: Bool) -> some View {
        if model.captureState == .loadingHistory {
            Color.clear
        } else if model.currentConversation?.hasContent != true {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array((model.currentConversation?.segments ?? []).enumerated()), id: \.element.id) { index, segment in
                            TranscriptRow(segment: segment, columns: columns,
                                          alternate: !index.isMultiple(of: 2), model: model)
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.visibleRect.maxY >= geometry.contentSize.height - 64
                } action: { _, atBottom in
                    nearBottom = atBottom
                    if userScrolling { followsLatest = atBottom }
                }
                .onScrollPhaseChange { _, phase in
                    userScrolling = phase.isScrolling && phase != .animating
                    if phase == .idle { followsLatest = nearBottom }
                }
                .onChange(of: model.liveContentRevision) { _, _ in
                    if followsLatest { proxy.scrollTo("latest", anchor: .bottom) }
                }
                .overlay(alignment: .bottom) {
                    if !followsLatest && model.isRecording {
                        Button {
                            followsLatest = true
                            proxy.scrollTo("latest", anchor: .bottom)
                        } label: {
                            Label("回到最新", systemImage: "arrow.down").font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 12).frame(height: 28)
                                .background(.white, in: Capsule())
                                .overlay(Capsule().stroke(Palette.edge))
                                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                        }
                        .buttonStyle(PressableStyle()).padding(.bottom, 12)
                    }
                }
                .onChange(of: model.currentConversationID) { _, _ in
                    followsLatest = true
                    proxy.scrollTo("latest", anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("還沒有逐字稿").font(.system(size: 15, weight: .medium))
            Text("按下「開始辨識」後說話。\(TranscriptLanguage.name(model.settings.leftLanguage))放在左欄、\(TranscriptLanguage.name(model.settings.rightLanguage))放在右欄，另一欄同時顯示翻譯。")
                .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 420, alignment: .leading)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Control bar

    private var controlBar: some View {
        HStack(spacing: 16) {
            recordButton
            if model.isRecording { LevelMeter(level: model.audioLevel) }
            sourceMenu
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                statusText(full: true)
                statusText(full: false)
                Color.clear.frame(width: 0)
            }
        }
        .padding(.horizontal, 16).frame(height: 60)
        .background(Palette.frame)
        .overlay(alignment: .top) { Palette.edge.frame(height: 1) }
    }

    private func statusText(full: Bool) -> some View {
        let speech = model.settings.model(for: .speech(model.settings.asrProvider))
        let text = model.settings.model(for: .translation(model.settings.translationProvider))
        return HStack(spacing: 6) {
            Text(model.captureState.title).foregroundStyle(model.isRecording ? Palette.text : Palette.secondary)
            if full {
                Text("·").foregroundStyle(Palette.metadata)
                Text("\(speech) → \(text)").foregroundStyle(Palette.metadata)
            }
        }
        .font(.system(size: 12)).lineLimit(1).fixedSize()
        .help("語音辨識：\(speech)；翻譯與詞彙：\(text)")
    }

    private var sourceMenu: some View {
        Menu {
            Picker("收音來源", selection: $model.settings.audioSource) {
                ForEach(AudioSource.allCases) { source in
                    Label(source.title, systemImage: source.symbol).tag(source)
                }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            Label(model.settings.audioSource.title, systemImage: model.settings.audioSource.symbol)
                .font(.system(size: 13))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .disabled(model.captureState != .idle)
        .help(model.captureState == .idle ? "麥克風或電腦播放的聲音" : "停止辨識後可變更收音來源")
        .accessibilityLabel("收音來源")
    }

    private var recordButton: some View {
        let recording = model.isRecording
        return Button { model.toggleRecording() } label: {
            HStack(spacing: 8) {
                if model.isBusy { ProgressView().controlSize(.small).tint(.white) }
                else { Image(systemName: recording ? "stop.fill" : "mic.fill").font(.system(size: 13)) }
                Text(model.isBusy ? model.captureState.title : recording ? "停止辨識" : "開始辨識")
                    .font(.system(size: 13, weight: .medium))
                Text("⌘R").font(.system(size: 11)).opacity(0.7)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16).frame(height: 36)
            .background(recording ? Palette.recording : Palette.accent, in: RoundedRectangle(cornerRadius: 10))
            .opacity(recordDisabled ? 0.45 : 1)
        }
        .buttonStyle(PressableStyle())
        .disabled(recordDisabled)
        .help(recording ? "停止辨識（⌘R）" : "開始辨識（⌘R）")
        .accessibilityLabel(recording ? "停止辨識" : "開始辨識")
    }

    private var recordDisabled: Bool {
        #if UI_ACCEPTANCE
        model.isBusy
        #else
        model.isBusy || model.isDemo
        #endif
    }
}

/// Live input level: five bars driven by the real microphone level.
private struct LevelMeter: View {
    let level: Float

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                let threshold = Float(index) / 5
                Capsule().fill(level > threshold ? Palette.accent : Palette.accent.opacity(0.2))
                    .frame(width: 3, height: CGFloat(6 + index * 3))
            }
        }
        .frame(height: 20)
        .accessibilityLabel("輸入音量")
        .accessibilityValue("\(Int(level * 100))%")
    }
}

/// One conversation in the sidebar: title and date, actions on hover or right-click.
private struct ConversationRow: View {
    @Bindable var model: AppModel
    let conversation: Conversation
    @Binding var actions: ConversationActions
    let didSelect: () -> Void
    @ViewState<Bool> private var hovering = false

    var body: some View {
        let selected = conversation.id == model.currentConversationID
        HStack(spacing: 4) {
            Button {
                didSelect()
                if !selected { model.selectConversation(conversation.id) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.hasContent ? conversation.title : "新的對話")
                        .font(.system(size: 13, weight: selected ? .medium : .regular)).lineLimit(1)
                    Text(conversation.hasContent
                         ? conversation.createdAt.formatted(.dateTime.month().day().hour().minute())
                         : "尚無逐字稿")
                        .font(.system(size: 11)).foregroundStyle(Palette.metadata).monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Palette.text).disabled(model.isBusy)
            Menu {
                ConversationMenuItems(model: model, conversation: conversation, actions: $actions)
            } label: {
                Image(systemName: "ellipsis").frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(Palette.secondary)
            .opacity(hovering || selected ? 1 : 0)
            .accessibilityLabel("對話操作").help("重新命名、匯出或刪除")
        }
        .padding(.leading, 8).padding(.trailing, 4).frame(height: 44)
        .background(selected ? Palette.selection : hovering ? Palette.hover : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            ConversationMenuItems(model: model, conversation: conversation, actions: $actions)
        }
    }
}

private struct Notice: View {
    let text: String
    let isError: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(isError ? Palette.error : Palette.secondary)
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: dismiss) { Image(systemName: "xmark").frame(width: 20, height: 20) }
                .buttonStyle(.borderless).foregroundStyle(Palette.secondary)
                .help("關閉訊息").accessibilityLabel("關閉訊息")
        }
        .font(.system(size: 12)).foregroundStyle(isError ? Palette.error : Palette.text)
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(isError ? Palette.error.opacity(0.06) : Palette.frame)
        .overlay(alignment: .bottom) { Palette.edge.frame(height: 1) }
    }
}

private struct TranscriptRow: View {
    let segment: TranscriptSegment
    let columns: Bool
    let alternate: Bool
    @Bindable var model: AppModel
    @ViewState<Bool> private var showsEditor = false
    @ViewState<String> private var editText = ""
    @ViewState<Bool> private var hovering = false

    private var isLive: Bool { !segment.isRecognitionFinal }

    var body: some View {
        Group {
            if columns {
                HStack(alignment: .top, spacing: 0) {
                    timecode.frame(width: Metrics.gutter, alignment: .leading).padding(.leading, 20)
                    languageCell(model.dialoguePair.left).frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: Metrics.columnGap)
                    languageCell(model.dialoguePair.right).frame(maxWidth: .infinity, alignment: .leading)
                    actionsMenu.frame(width: Metrics.actions)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { timecode; Spacer(); actionsMenu }
                    languageCell(model.dialoguePair.left)
                    languageCell(model.dialoguePair.right)
                }
                .padding(.leading, 20).padding(.trailing, 8)
            }
        }
        .padding(.vertical, Metrics.rowPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .overlay(alignment: .leading) {
            if isLive { Palette.accent.frame(width: 3) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
        .sheet(isPresented: $showsEditor) { editor }
    }

    private var background: Color {
        if isLive { return Palette.live }
        return alternate ? Palette.transcriptAlternate : Palette.transcript
    }

    /// Start time and spoken length, like a subtitle timecode.
    private var timecode: some View {
        let start = segment.speechSpan?.startedAt ?? segment.createdAt
        let end = segment.speechSpan?.endedAt
        return VStack(alignment: .leading, spacing: 2) {
            Text(TranscriptExporter.timeString(start)).font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(Palette.metadata)
            if isLive {
                Text("說話中").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.accent)
            } else if let end, end >= start {
                Text(Self.duration(end.timeIntervalSince(start)))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.metadata)
            }
        }
        .padding(.top, 2)
        .help(TranscriptExporter.speechTime(segment))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 60 ? String(format: "%.1f 秒", seconds)
            : "\(Int(seconds) / 60) 分 \(Int(seconds) % 60) 秒"
    }

    private func languageCell(_ language: String) -> some View {
        let cell = BilingualCell(segment: segment, language: language)
        let draft = cell.role == .translation && segment.status != .complete && !cell.text.isEmpty
        return VStack(alignment: .leading, spacing: 4) {
            if !columns {
                Text(TranscriptLanguage.name(language)).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.metadata)
            }
            if !cell.text.isEmpty {
                Text(cell.text).font(.system(size: 16)).lineSpacing(4)
                    .foregroundStyle(cell.role == .original ? Palette.accent
                                     : draft ? Palette.secondary : Palette.translationText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(Text("\(TranscriptLanguage.name(language))\(cell.role == .original ? "原文" : draft ? "暫譯" : "譯文")"))
                    .accessibilityValue(Text(cell.text))
            } else if cell.role == .unrecorded {
                Text("—").foregroundStyle(Palette.metadata).accessibilityLabel("未記錄\(TranscriptLanguage.name(language))")
            }
            if cell.isWaitingForTranslation(in: segment) && cell.text.isEmpty {
                Text("翻譯中").font(.system(size: 12)).foregroundStyle(Palette.metadata)
            }
            if cell.role == .translation && segment.status == .failed {
                HStack(spacing: 8) {
                    Text(segment.error ?? "翻譯失敗").font(.system(size: 12)).foregroundStyle(Palette.error)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("重新翻譯") { model.retry(segment) }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .help(draft ? "本機暫譯；整句說完後換成正式譯文" : "")
    }

    private var actionsMenu: some View {
        Menu { menuItems } label: {
            Image(systemName: "ellipsis").frame(width: 24, height: 20)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(Palette.secondary)
        .opacity(hovering ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("編輯、重新翻譯或複製這一句")
        .accessibilityLabel("這一句的操作")
    }

    @ViewBuilder private var menuItems: some View {
        Button("編輯原文並重新翻譯") { editText = segment.source; showsEditor = true }
            .disabled(!segment.isRecognitionFinal)
        Button("重新翻譯") { model.retry(segment) }
            .disabled(!segment.isRecognitionFinal)
        Button("校正譯文") { model.polish(segment) }
            .disabled(segment.status != .complete || segment.translatedCopyText.isEmpty || segment.resolvedSourceLanguage == segment.resolvedTargetLanguage)
        Divider()
        Button("複製原文") { copy(segment.sourceCopyText) }
            .disabled(segment.sourceCopyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("複製譯文") { copy(segment.translatedCopyText) }
            .disabled(segment.translatedCopyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("複製原文與譯文") { copy(segment.combinedCopyText) }
    }

    private func copy(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("編輯原文").font(.system(size: 15, weight: .semibold))
            TextEditor(text: $editText).font(.system(size: 15)).frame(minHeight: 150)
                .padding(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.edge))
            HStack {
                Spacer()
                Button("取消") { showsEditor = false }.keyboardShortcut(.cancelAction)
                Button("儲存並翻譯") { model.revise(segment, source: editText); showsEditor = false }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 580).tint(Palette.accent)
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    var availableSize = CGSize(width: 680, height: 785)
    @Environment(\.dismiss) private var dismiss
    @ViewState<Provider> private var provider: Provider = .openAI
    @ViewState<Bool> private var showsModels = false
    @ViewState<ModelSlot?> private var choosingModel: ModelSlot?
    private var apiKey: Binding<String> {
        Binding(get: { model.keyDrafts.value(for: provider) },
                set: { model.updateKeyDraft($0, provider: provider) })
    }
    private var canBrowseModels: Bool {
        #if UI_ACCEPTANCE
        true
        #else
        !model.isDemo
        #endif
    }
    private var idle: Bool { model.captureState == .idle }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("設定").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { if model.saveKeyDrafts() { dismiss() } } label: {
                    Image(systemName: "xmark").frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless).foregroundStyle(Palette.secondary)
                .help("關閉設定").accessibilityLabel("關閉設定")
            }
            .padding(.horizontal, 20).frame(height: Metrics.barHeight)
            .overlay(alignment: .bottom) { Palette.edge.frame(height: 1) }
            if let error = model.errorMessage {
                Notice(text: error, isError: true) { model.errorMessage = nil }
            } else if let info = model.infoMessage {
                Notice(text: info, isError: false) { model.infoMessage = nil }
            }
            Form {
                Section {
                    serviceRow("語音辨識", selection: $model.settings.asrProvider, choices: Provider.speechProviders,
                               slot: .speech(model.settings.asrProvider))
                    serviceRow("翻譯與詞彙", selection: $model.settings.translationProvider, choices: Provider.allCases,
                               slot: .translation(model.settings.translationProvider))
                } header: {
                    Text("服務與模型")
                } footer: {
                    note("語音送到辨識服務，文字送到翻譯服務。Claude 只做文字翻譯。")
                }

                Section {
                    Picker("服務商", selection: $provider) {
                        ForEach(Provider.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    HStack(spacing: 8) {
                        SecureField("API 金鑰", text: apiKey,
                                    prompt: Text("貼上 \(provider.title) API 金鑰").foregroundStyle(Palette.metadata))
                            .onSubmit { saveAPIKey() }
                        Button("儲存") { saveAPIKey() }
                            .disabled(model.isDemo || model.keyDrafts.value(for: provider).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    HStack(spacing: 8) {
                        Button("測試連線") { testConnection(provider) }
                            .disabled(model.isDemo || model.modelDirectory.state(provider).isLoading)
                        if model.modelDirectory.state(provider).isLoading { ProgressView().controlSize(.small) }
                        Text(keyStatus)
                            .font(.system(size: 12))
                            .foregroundStyle(model.modelDirectory.state(provider).isFailure ? Palette.error : Palette.secondary)
                            .lineLimit(2)
                    }
                } header: {
                    Text("API 金鑰")
                } footer: {
                    note("金鑰存在本機資料夾的 Private 目錄。測試連線只讀取模型清單。")
                }

                Section {
                    Picker("換句停頓", selection: $model.settings.pauseSegmentation) {
                        ForEach(PauseSegmentation.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .disabled(!idle || !model.settings.supportsPauseSegmentation)
                    Toggle("自動整理主題與詞彙", isOn: $model.settings.contextualCorrection)
                        .disabled(model.isDemo)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("專業術語")
                        TextEditor(text: $model.settings.glossary)
                            .font(.system(size: 13)).frame(height: 64)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(Color.black.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                            .disabled(!idle)
                        Text("用逗號或換行分隔，開始辨識時一併交給語音辨識。")
                            .font(.system(size: 11)).foregroundStyle(Palette.metadata)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("翻譯情境")
                        TextField("翻譯情境", text: Binding(get: { model.settings.translationNote ?? "" },
                                                        set: { model.settings.translationNote = $0.isEmpty ? nil : $0 }),
                                  prompt: Text("例如：研究所課程，教授以英文講授研究方法").foregroundStyle(Palette.metadata))
                        Text("說明場合與聽眾，翻譯會依此選擇用語。").font(.system(size: 11)).foregroundStyle(Palette.metadata)
                    }
                } header: {
                    Text("辨識")
                } footer: {
                    note(model.settings.supportsPauseSegmentation
                         ? "停頓超過設定長度就換下一句並送出翻譯；文字 3 秒沒有增加也會換句。主題與詞彙每 3–4 句整理一次，另計少量文字用量。"
                         : "Gemini 由服務端自動斷句。主題與詞彙每 3–4 句整理一次，另計少量文字用量。")
                }

                Section {
                    Picker("引擎", selection: Binding(get: { model.settings.draftEngine ?? .localModel },
                                                    set: { model.settings.draftEngine = $0 })) {
                        ForEach(DraftEngineKind.allCases) { Text($0.title).tag($0) }
                    }
                    if (model.settings.draftEngine ?? .localModel) == .localModel {
                        TextField("伺服器", text: Binding(get: { model.settings.draftModelEndpoint ?? DraftEngineConfig.defaultEndpoint },
                                                       set: { model.settings.draftModelEndpoint = $0.isEmpty ? nil : $0 }))
                        TextField("模型", text: Binding(get: { model.settings.draftModelName ?? DraftEngineConfig.defaultModel },
                                                     set: { model.settings.draftModelName = $0.isEmpty ? nil : $0 }))
                    }
                } header: {
                    Text("本機暫譯")
                } footer: {
                    note("講話時先在本機產生灰色暫譯，句子結束後由上方翻譯服務給正式譯文。本機模型可用 Ollama 或 LM Studio 等相容伺服器，只接受這台 Mac 的位址；預設 translategemma:4b（執行 ollama pull translategemma:4b 下載）。")
                }
                .disabled(!idle)

                Section {
                    Toggle("無痕模式", isOn: $model.settings.isIncognito)
                        .help("開啟時不保存逐字稿，也不寫入詞彙庫")
                    LabeledContent("資料夾") {
                        Button("在 Finder 中顯示") { model.revealData() }
                    }
                } header: {
                    Text("本機資料")
                } footer: {
                    note("歷史紀錄與設定存放在你的使用者資料庫。")
                }

                Section {
                    DisclosureGroup("手動輸入模型名稱", isExpanded: $showsModels) {
                        modelField("OpenAI 辨識", text: $model.settings.openAIASRModel)
                        modelField("Gemini 辨識", text: $model.settings.geminiASRModel)
                        modelField("OpenAI 翻譯", text: $model.settings.openAITranslationModel)
                        modelField("Gemini 翻譯", text: $model.settings.geminiTranslationModel)
                        modelField("Claude 翻譯", text: $model.settings.claudeTranslationModel)
                    }
                    .disabled(!idle)
                }
            }
            .formStyle(.grouped)
            .font(.system(size: 13))
        }
        .frame(width: min(600, max(480, availableSize.width - 40)),
               height: min(760, max(440, availableSize.height - 40)))
        .background(Palette.frame).foregroundStyle(Palette.text).tint(Palette.accent)
        .onAppear { model.prepareKeyDraft(provider) }
        .onChange(of: provider) { _, value in model.prepareKeyDraft(value) }
        .onExitCommand { if model.saveKeyDrafts() { dismiss() } }
        .sheet(item: $choosingModel) { slot in
            CloudModelPicker(model: model, slot: slot, availableSize: availableSize) { testConnection(slot.provider) }
        }
    }

    private var keyStatus: String {
        let state = model.modelDirectory.state(provider)
        if !state.message.isEmpty { return state.message }
        if model.keyDrafts.value(for: provider).isEmpty { return "尚未填入" }
        return model.keyDrafts.isSaved(provider) ? "已儲存" : "尚未儲存"
    }

    /// Provider picker, the chosen model and its price, and a way to change the model.
    private func serviceRow(_ title: String, selection: Binding<Provider>, choices: [Provider], slot: ModelSlot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(title, selection: selection) {
                ForEach(choices) { Text($0.title).tag($0) }
            }
            .disabled(!idle)
            HStack(spacing: 8) {
                Text(model.settings.model(for: slot)).monospacedDigit().foregroundStyle(Palette.secondary)
                    .textSelection(.enabled)
                if let rate = ModelRates.rate(model.settings.model(for: slot), slot: slot) {
                    Text(rate.price).foregroundStyle(Palette.metadata)
                }
                Spacer()
                Button("更換模型…") { openModelPicker(slot) }
                    .buttonStyle(.borderless)
                    .disabled(!canBrowseModels || !idle)
            }
            .font(.system(size: 12))
        }
    }

    private func saveAPIKey() {
        model.saveKey(model.keyDrafts.value(for: provider), provider: provider)
    }

    private func testConnection(_ target: Provider) {
        guard !model.isDemo else { return }
        model.prepareKeyDraft(target)
        model.modelDirectory.fetch(provider: target, key: model.keyDrafts.value(for: target))
    }

    private func openModelPicker(_ slot: ModelSlot) {
        choosingModel = slot
        if model.modelDirectory.models[slot.provider] == nil && !model.modelDirectory.state(slot.provider).isLoading {
            testConnection(slot.provider)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Palette.metadata)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func modelField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text, prompt: Text(title).foregroundStyle(Palette.metadata))
            .font(.system(size: 12))
    }
}

private struct VersionHistoryEntry: Decodable, Identifiable {
    enum Status: String, Decodable {
        case release, installed, verified, candidate, withdrawn

        var label: String {
            switch self {
            case .release: "正式版本"
            case .installed: "曾安裝"
            case .verified: "曾驗收"
            case .candidate: "候選版"
            case .withdrawn: "已撤回"
            }
        }
    }

    let version: String
    let build: String
    let status: Status
    let title: String
    let changes: String
    let verification: String?

    var id: String { version }
}

private struct VersionHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let availableSize: CGSize

    private let entries: [VersionHistoryEntry] = {
        guard let url = Bundle.main.url(forResource: "VersionHistory", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([VersionHistoryEntry].self, from: data) else { return [] }
        return entries
    }()

    var body: some View {
        VStack(spacing: 0) {
            Text("版本記錄")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if entries.isEmpty {
                        Text("無法讀取版本記錄").padding(.vertical, 18)
                    }
                    ForEach(entries) { entry in
                        versionEntry(entry)
                        if entry.id != entries.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
        }
        .foregroundStyle(Palette.text)
        .frame(width: min(610, availableSize.width - 40),
               height: min(650, availableSize.height - 50))
    }

    private func versionEntry(_ entry: VersionHistoryEntry) -> some View {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let current = entry.version == currentVersion
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("\(entry.version)（\(entry.build)）")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                Text(current ? "目前版本" : entry.status.label)
                    .font(.caption)
                    .foregroundStyle(entry.status == .withdrawn ? Palette.error : Palette.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Text(entry.title).font(.body.weight(.semibold))
            Text(entry.changes)
            if let verification = entry.verification {
                Text(verification).foregroundStyle(Palette.secondary)
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, 14)
    }
}

/// Topic, this conversation's words, the mishearings fixed by later context,
/// and the cross-conversation vocabulary sent as recognition hints.
private struct SemanticEnvironmentView: View {
    @Bindable var model: AppModel
    let availableSize: CGSize
    @Environment(\.dismiss) private var dismiss

    private var segments: [TranscriptSegment] { model.currentConversation?.segments ?? [] }
    private var snapshot: SemanticSnapshot? { model.currentSemanticSnapshot }
    private var terms: [SemanticTerm] { snapshot?.groundedTerms(in: segments) ?? [] }
    /// Every fix recorded in this conversation, newest first, once each.
    private var corrections: [SemanticTerm] {
        var seen = Set<String>()
        return (model.currentConversation?.semanticEnvironment?.snapshots ?? []).reversed()
            .flatMap(\.terms).filter { $0.correction?.rationale == VocabularyLearner.appliedRationale }
            .filter { seen.insert(($0.correction?.surface ?? "") + "→" + $0.text).inserted }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("語意環境").font(.system(size: 15, weight: .semibold))
                if model.isAnalyzingSemantics { ProgressView().controlSize(.small) }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.borderless).foregroundStyle(Palette.secondary)
                    .help("關閉").accessibilityLabel("關閉語意環境")
            }
            .padding(.horizontal, 20).frame(height: Metrics.barHeight)
            .overlay(alignment: .bottom) { Palette.edge.frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    topicBlock
                    if !terms.isEmpty {
                        block("這次對話的罕見詞（交給語音辨識，最多 12 個）") {
                            FlowLayout(spacing: 6) {
                                ForEach(terms) { term in
                                    TermChip(text: term.text,
                                             heard: term.correction?.rationale == VocabularyLearner.spellingRationale ? term.correction?.surface : nil)
                                }
                            }
                        }
                    }
                    if !corrections.isEmpty {
                        block("依上下文修正的字") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(corrections) { term in correctionRow(term) }
                            }
                        }
                    }
                    Palette.edge.frame(height: 1)
                    VocabularyStoreList(model: model)
                }
                .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("重新整理") { model.refreshSemanticEnvironment() }
                    .disabled(model.isDemo || model.isAnalyzingSemantics || !model.settings.contextualCorrection
                              || model.currentConversation?.hasContent != true)
                    .help("用目前對話最近的句子重新整理主題與詞彙")
                Spacer()
                Button("完成") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(Palette.frame)
            .overlay(alignment: .top) { Palette.edge.frame(height: 1) }
        }
        .frame(width: min(600, max(480, availableSize.width - 40)),
               height: min(720, max(440, availableSize.height - 40)))
        .background(.white).foregroundStyle(Palette.text).tint(Palette.accent)
    }

    @ViewBuilder private var topicBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("情境").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
            let topic = snapshot?.groundedTopic(in: segments) ?? ""
            Text(topic.isEmpty ? "尚未判斷出情境" : topic)
                .font(.system(size: 17, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(topic.isEmpty ? Palette.metadata : Palette.text)
            Text(statusLine).font(.system(size: 12)).foregroundStyle(model.semanticError == nil ? Palette.metadata : Palette.error)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusLine: String {
        if let error = model.semanticError { return error }
        if !model.settings.contextualCorrection { return "自動整理已關閉，可在設定中開啟。先前的紀錄仍保留。" }
        if !model.semanticActivity.isEmpty { return model.semanticActivity }
        if let snapshot {
            let usage = model.sessionTranslationRequests + model.sessionContextRequests > 0
                ? " · 本次收音：翻譯 \(model.sessionTranslationRequests) 次、情境整理 \(model.sessionContextRequests) 次" : ""
            return "最近更新 \(TranscriptExporter.timeString(snapshot.createdAt)) · \(snapshot.model)\(usage)"
        }
        return "開始辨識後，第 3 句起每 3–4 句改寫一次情境，這句話會交給語音辨識與翻譯。"
    }

    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
            content()
        }
    }

    private func correctionRow(_ term: SemanticTerm) -> some View {
        let segment = segments.first { $0.id == term.evidence.segmentID }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(term.correction?.surface ?? "").strikethrough().foregroundStyle(Palette.metadata)
            Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Palette.metadata)
            Text(term.text).foregroundStyle(Palette.text)
            Spacer()
            if let segment {
                Text(TranscriptExporter.timeString(segment.speechSpan?.startedAt ?? segment.createdAt))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.metadata)
            }
        }
        .font(.system(size: 14))
    }
}

private struct TermChip: View {
    let text: String
    var heard: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 13))
            if let heard { Text("聽成 \(heard)").font(.system(size: 11)).foregroundStyle(Palette.metadata) }
        }
            .padding(.horizontal, 10).frame(height: 26)
            .background(Palette.frame, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.edge))
            .textSelection(.enabled)
    }
}

/// Wraps chips onto as many lines as needed.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 480
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
        }
        return CGSize(width: width, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// Words learned across conversations; they are sent as recognition hints when listening starts.
private struct VocabularyStoreList: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("詞彙庫").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
                Text("\(model.vocabulary.count) 個").font(.system(size: 12)).foregroundStyle(Palette.metadata)
            }
            Text("跨對話累積，供你挑選。只有釘選的詞會在每次開始辨識時交給語音辨識；其他詞只留紀錄，不會影響下一場對話。")
                .font(.system(size: 12)).foregroundStyle(Palette.metadata)
                .fixedSize(horizontal: false, vertical: true)
            if model.vocabulary.isEmpty {
                Text("還沒有詞彙").font(.system(size: 13)).foregroundStyle(Palette.metadata).padding(.top, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.vocabulary.sorted { ($0.pinned ? 1 : 0, $0.count) > ($1.pinned ? 1 : 0, $1.count) }) { entry in
                        VocabularyRow(model: model, entry: entry)
                    }
                }
            }
        }
    }
}

private struct VocabularyRow: View {
    @Bindable var model: AppModel
    let entry: VocabularyEntry
    @ViewState<Bool> private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Palette.accent)
                .opacity(entry.pinned ? 1 : 0).frame(width: 14)
            Text(entry.text).font(.system(size: 13)).textSelection(.enabled)
            Spacer()
            Text("\(entry.count) 次").font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.metadata)
            Group {
                Button { model.togglePinned(entry) } label: { Image(systemName: entry.pinned ? "pin.slash" : "pin") }
                    .help(entry.pinned ? "取消釘選" : "釘選，開始辨識時排在最前面")
                    .accessibilityLabel(entry.pinned ? "取消釘選 \(entry.text)" : "釘選 \(entry.text)")
                Button { model.removeVocabulary(entry) } label: { Image(systemName: "trash") }
                    .help("從詞彙庫刪除").accessibilityLabel("刪除 \(entry.text)")
            }
            .buttonStyle(.borderless).foregroundStyle(Palette.secondary)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 8).frame(height: 32)
        .background(hovering ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
    }
}

private struct CloudModelPicker: View {
    @Bindable var model: AppModel
    let slot: ModelSlot
    let availableSize: CGSize
    let refresh: () -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState<String> private var query = ""
    @ViewState<String> private var selected = ""
    @ViewState<Bool> private var includesOtherModels = false

    private var state: ModelConnectionState { model.modelDirectory.state(slot.provider) }
    private var allModels: [CloudModel] { model.modelDirectory.models[slot.provider] ?? [] }
    private var visibleModels: [CloudModel] {
        ModelRates.relevant(allModels, slot: slot, current: model.settings.model(for: slot), includeOther: includesOtherModels || !query.isEmpty).filter {
            (query.isEmpty || $0.id.localizedCaseInsensitiveContains(query)
                || $0.displayName.localizedCaseInsensitiveContains(query))
        }
    }
    private var canChoose: Bool { allModels.contains { $0.id == selected && $0.supports(slot) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("從雲端取得模型").font(.system(size: 17, weight: .semibold))
                Spacer()
                Text(slot.title).font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }.padding(.horizontal, 20).frame(height: 56).background(Palette.frame)
            VStack(alignment: .leading, spacing: 12) {
                TextField("搜尋模型", text: $query).textFieldStyle(.roundedBorder)
                HStack(spacing: 12) {
                    Text(state.message).font(.system(size: 12))
                        .foregroundStyle(state.isFailure ? Palette.error : Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if state.isLoading { ProgressView().controlSize(.small) }
                    Spacer(minLength: 0)
                    Button("重新取得") { refresh() }.disabled(state.isLoading)
                }
                if !slot.isSpeech {
                    Toggle("其他可用文字模型", isOn: $includesOtherModels)
                        .toggleStyle(.checkbox).font(.system(size: 12))
                }
                Text("只列出雲端清單中符合用途的模型；推論權限仍依帳戶而定")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }.padding(20)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if visibleModels.isEmpty {
                        Text(state.isLoading ? "正在取得模型…" : query.isEmpty ? "沒有符合此用途的模型" : "找不到符合的模型")
                            .font(.system(size: 13)).foregroundStyle(Palette.secondary).padding(.vertical, 20)
                        if !state.isLoading && query.isEmpty {
                            Text("請確認金鑰與模型存取權限，或在進階設定手動輸入模型名稱。")
                                .font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    ForEach(visibleModels) { item in
                        Button { selected = item.id } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: selected == item.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(item.supports(slot) ? Palette.accent : Palette.metadata)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.id).font(.system(size: 13, design: .monospaced))
                                        .fixedSize(horizontal: false, vertical: true)
                                    if item.displayName != item.id {
                                        Text(item.displayName).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                                    }
                                    if let rate = ModelRates.rate(item.id, slot: slot) {
                                        Text("\(rate.label) · \(rate.price)").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        if let detail = rate.detail {
                                            Text(detail).font(.system(size: 11)).foregroundStyle(Palette.metadata)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    } else {
                                        Text("價格未收錄，請查官方費率").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }.multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 12).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!item.supports(slot))
                        Divider()
                    }
                }.padding(.horizontal, 20)
            }
            HStack(alignment: .top) {
                Text("標準付費價格 · USD · \(ModelRates.checkedOn) 查核；免費額度、快取折扣及稅額依帳戶計算。")
                    .font(.system(size: 11)).foregroundStyle(Palette.metadata).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Link("官方費率", destination: ModelRates.reference(slot.provider)).font(.system(size: 12))
            }.padding(.horizontal, 20).padding(.vertical, 10)
            HStack {
                Text("\(visibleModels.count) 個模型").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("使用此模型") {
                    guard canChoose, model.captureState == .idle else { return }
                    model.settings.setModel(selected, for: slot)
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!canChoose || model.captureState != .idle)
            }.padding(20).background(Palette.frame)
        }
        .frame(width: min(600, max(480, availableSize.width - 80)),
               height: min(620, max(350, availableSize.height - 80)))
        .background(.white).foregroundStyle(Palette.text).tint(Palette.accent)
        .onAppear { selected = model.settings.model(for: slot) }
    }
}

private struct ConversationActions {
    var renameTarget: Conversation?
    var deleteTarget: Conversation?
    var renameText = ""

    mutating func rename(_ conversation: Conversation) {
        renameText = conversation.name ?? conversation.title
        renameTarget = conversation
    }
}

private struct ConversationMenuItems: View {
    let model: AppModel
    let conversation: Conversation
    @Binding var actions: ConversationActions

    var body: some View {
        Button("重新命名") { actions.rename(conversation) }
            .disabled(model.isBusy)
        Button("匯出 Markdown") { model.export(conversation, format: .markdown) }
            .disabled(!conversation.hasContent)
        Divider()
        Button("刪除對話", role: .destructive) { actions.deleteTarget = conversation }
            .disabled(model.isBusy)
    }
}

private struct ConversationActionDialogs: ViewModifier {
    let model: AppModel
    @Binding var actions: ConversationActions

    func body(content: Content) -> some View {
        content
            .alert("重新命名對話", isPresented: presenting($actions.renameTarget), presenting: actions.renameTarget) { target in
                TextField("名稱", text: $actions.renameText)
                Button("取消", role: .cancel) {}
                Button("儲存") { model.renameConversation(target.id, name: actions.renameText) }
                    .disabled(model.isBusy)
            } message: { _ in
                Text("留空會使用第一段原文作為名稱")
            }
            .alert("刪除對話？", isPresented: presenting($actions.deleteTarget), presenting: actions.deleteTarget) { target in
                Button("取消", role: .cancel) {}
                Button("刪除對話", role: .destructive) { model.deleteConversation(target.id) }
                    .disabled(model.isBusy)
            } message: { target in
                let title = target.title.count > 80 ? String(target.title.prefix(80)) + "…" : target.title
                Text("「\(title)」和其中的逐字稿將從本機刪除，無法復原")
            }
    }

    private func presenting(_ target: Binding<Conversation?>) -> Binding<Bool> {
        Binding(get: { target.wrappedValue != nil }, set: { if !$0 { target.wrappedValue = nil } })
    }
}

struct HistoryView: View {
    @Bindable var model: AppModel
    var availableSize = CGSize(width: 750, height: 620)
    @Environment(\.dismiss) private var dismiss
    @ViewState<ConversationActions> private var conversationActions = ConversationActions()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("歷史紀錄").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.borderless).help("關閉歷史紀錄").accessibilityLabel("關閉歷史紀錄")
            }.padding(.horizontal, 24).frame(height: 60).background(Palette.frame)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
                TextField("搜尋原文或譯文", text: $model.historySearch,
                          prompt: Text("搜尋原文或譯文").foregroundStyle(Palette.metadata))
                    .textFieldStyle(.plain)
            }
            .font(.system(size: 13)).padding(8)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.edge))
            .padding(.horizontal, 24).padding(.vertical, 16)
            if model.history.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.settings.isIncognito ? "無痕模式已開啟" : model.historySearch.isEmpty ? "尚無歷史紀錄" : "找不到符合的對話")
                        .font(.system(size: 14, weight: .medium))
                    Text(model.settings.isIncognito ? "不儲存或顯示歷史紀錄" : model.historySearch.isEmpty ? "辨識內容會自動儲存" : "可搜尋原文、英文或中文譯文")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    Spacer()
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.history) { conversation in
                            historyRow(conversation)
                            Divider()
                        }
                    }.padding(.horizontal, 24)
                }
            }
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 24).padding(.vertical, 16).background(Palette.frame)
        }
        .frame(width: min(710, max(500, availableSize.width - 40)),
               height: min(570, max(440, availableSize.height - 50)))
        .background(.white).foregroundStyle(Palette.text).tint(Palette.accent)
        .modifier(ConversationActionDialogs(model: model, actions: $conversationActions))
    }

    private func historyRow(_ conversation: Conversation) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Button { model.selectConversation(conversation.id) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(conversation.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    if let first = conversation.segments.first {
                        Text(first.english.isEmpty ? first.source : first.english)
                            .font(.system(size: 13)).foregroundStyle(Palette.secondary).lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Text("\(conversation.createdAt.formatted(.dateTime.year().month().day().hour().minute())) · \(conversation.segments.count) 段")
                        .font(.system(size: 12)).foregroundStyle(Palette.metadata).monospacedDigit()
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.borderless).foregroundStyle(Palette.text).disabled(model.isBusy)
            HStack(spacing: 8) {
                ForEach(ExportFormat.allCases) { format in
                    Button { model.export(conversation, format: format) } label: {
                        Label(format == .markdown ? "MD" : "TXT", systemImage: "arrow.down")
                    }
                    .font(.system(size: 12)).buttonStyle(.bordered).fixedSize()
                    .help("匯出這段對話的 \(format.title) 逐字稿")
                }
                historyActions(conversation)
            }
        }
        .padding(.vertical, 16)
        .contentShape(Rectangle())
        .contextMenu {
            ConversationMenuItems(model: model, conversation: conversation, actions: $conversationActions)
        }
    }

    private func historyActions(_ conversation: Conversation) -> some View {
        Menu {
            ConversationMenuItems(model: model, conversation: conversation, actions: $conversationActions)
        } label: {
            Image(systemName: "ellipsis").frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .disabled(model.isBusy)
        .help("對話操作")
        .accessibilityLabel("對話操作：\(conversation.title)")
    }
}
