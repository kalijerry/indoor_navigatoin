import HPASSKit
import SwiftUI

/// 「导航」Tab：全屏地图 + 状态胶囊 + 按状态切换的底部卡片。
///
/// 只用现有的定位引擎（`AppEngines.shared.magnetic`），不改算法。原始数值都在「设置 → 开发者 → 高级控制台」里。
@MainActor
struct NavigateView: View {
    @Binding var tab: AppTab

    @ObservedObject private var engine = AppEngines.shared.magnetic
    @ObservedObject private var store = MagMapStore.shared
    @ObservedObject private var storeData = StoreDataStore.shared
    @ObservedObject private var lib = MapLibrary.shared

    @State private var follow = true
    @State private var floorIndex = 0
    @State private var showSearch = false
    @State private var showPermissions = false
    @State private var resetToken = 0

    /// 底部卡片的几种状态
    enum Phase: Equatable { case noMap, idle, needFix, searching, needHeading, tracking, navigating, lost }

    // MARK: 演示数据（-uiDemo）

    private var demo: Bool { DemoMode.isOn }

    private var phase: Phase {
        if demo {
            switch DemoMode.state {
            case "idle": return .idle
            case "searching": return .searching
            case "tracking": return .tracking
            case "nomap": return .noMap
            default: return .navigating
            }
        }
        if !AppEngines.shared.hasVenueMap && store.field == nil { return .noMap }
        guard engine.phase == .live else { return .idle }
        switch engine.locState {
        case .searching: return .searching
        case .lost: return .lost
        default: break
        }
        guard engine.position != nil else { return engine.searching ? .searching : .needFix }
        if !engine.isTracking || engine.headingEditing { return .needHeading }
        return engine.navLabel != nil ? .navigating : .tracking
    }

    private var mapForCanvas: StoreMap? { demo ? DemoMode.map : AppEngines.shared.canvasMap }
    private var shownPosition: Point2? {
        if demo { return [.tracking, .navigating].contains(phase) ? DemoMode.position : nil }
        return engine.phase == .live ? engine.position : nil
    }
    private var shownHeading: Double { demo ? DemoMode.headingRad : engine.headingRad }
    private var shownUncertainty: Double { demo ? 120 : (engine.isTracking && !engine.searching ? engine.uncertaintyCm : 0) }
    private var shownRoute: Route? {
        if demo { return phase == .navigating ? DemoMode.route : nil }
        return engine.navRoute
    }

    var body: some View {
        ZStack {
            if phase == .noMap {
                noMapState
            } else {
                mapLayer.ignoresSafeArea(edges: .top)
                overlays
            }
        }
        .background(DS.Palette.mapFloor.ignoresSafeArea())
        .sheet(isPresented: $showSearch) {
            DestinationSearchSheet(engine: engine) { follow = true }
        }
        .sheet(isPresented: $showPermissions) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Spacing.l) {
                        Text("定位只在你的手机上进行，不需要额外硬件。为了找到你的位置，App 会用到：")
                            .font(.callout).foregroundStyle(DS.Palette.textSecondary)
                        PermissionExplainer(items: PermissionExplainer.positioning)
                    }
                    .padding(DS.Spacing.l)
                }
                .navigationTitle("为什么需要这些权限")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("好") { showPermissions = false } } }
            }
            .presentationDetents([.medium, .large])
        }
        .onAppear { AppEngines.shared.prepareIfNeeded() }
        .onChange(of: engine.locState) { s in
            switch s {
            case .tracking: Haptics.success()
            case .lost: Haptics.warning()
            default: break
            }
        }
        .onChange(of: engine.navArrived) { arrived in if arrived { Haptics.success() } }
        .onChange(of: engine.position) { _ in reportTelemetry() }
    }

    // MARK: 地图

    private var mapLayer: some View {
        MapCanvas(map: mapForCanvas,
                  fingerprints: [],
                  trail: demo ? (shownPosition == nil ? [] : DemoMode.trail) : (engine.phase == .live ? engine.trail : []),
                  position: shownPosition,
                  headingRad: shownHeading,
                  uncertaintyCm: shownUncertainty,
                  route: shownRoute,
                  showFingerprints: false,
                  highlightShelf: nil,
                  // 后验航向不可信（多峰 / 散布大）时不画精确的朝向箭头（NAV-003）
                  showHeading: demo ? true : ((engine.isTracking && !engine.headingUncertain) || engine.headingEditing),
                  positionStale: !demo && engine.locState == .lost,
                  headingEditing: !demo && engine.headingEditing,
                  onLongPress: longPress,
                  onDoubleTap: engine.phase == .live && engine.position != nil ? { engine.toggleHeadingEdit() } : nil,
                  onHeadingPoint: engine.phase == .live ? { engine.pointHeading(toward: $0) } : nil,
                  productStyle: true,
                  follow: follow && shownPosition != nil,
                  followAnchor: CGPoint(x: 0.5, y: 0.42),
                  onUserInteract: { follow = false },
                  smooth: true,
                  showsResetButton: false,
                  accessibilitySummary: a11ySummary,
                  resetToken: resetToken)
    }

    /// 长按：我在这里（手动定位 / 修正）
    private var longPress: ((Point2) -> Void)? {
        guard !demo, engine.phase == .live, !engine.headingEditing else { return nil }
        return { p in
            engine.setAnchor(p)
            Haptics.heavy()
        }
    }

    private var a11ySummary: String {
        switch phase {
        case .tracking, .navigating:
            let m = shownUncertainty / 100
            return "已定位，精度约 \(Fmt.f(max(m, 0.5), 1)) 米，" + Self.directionText(shownHeading)
        case .searching: return "正在寻找你的位置"
        case .lost: return "定位信号弱，位置已暂停更新"
        default: return "未定位"
        }
    }

    /// 地图系朝向（0 = 地图下方，dx = sinθ）→ 朝地图哪边
    static func directionText(_ h: Double) -> String {
        let dx = sin(h), dy = cos(h)
        if abs(dx) > abs(dy) { return dx > 0 ? "面朝地图右侧" : "面朝地图左侧" }
        return dy > 0 ? "面朝地图下方" : "面朝地图上方"
    }

    // MARK: 浮层

    private var overlays: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, DS.Spacing.l)
                .padding(.top, DS.Spacing.s)
            if let err = engine.lastError, !demo {
                ErrorBanner(message: err, onDismiss: { engine.clearError() })
                    .padding(.horizontal, DS.Spacing.l)
                    .padding(.top, DS.Spacing.s)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            HStack {
                Spacer()
                sideControls
            }
            .padding(.horizontal, DS.Spacing.l)
            .padding(.top, DS.Spacing.m)
            Spacer()
            bottomCard
                .padding(.horizontal, DS.Spacing.m)
                .padding(.bottom, DS.Spacing.s)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: phase)
    }

    private var topBar: some View {
        HStack(spacing: DS.Spacing.s) {
            HStack(spacing: 6) {
                Image(systemName: "building.2")
                    .foregroundStyle(DS.Palette.accent)
                    .accessibilityHidden(true)
                if demo {
                    Text("示例场地").font(.footnote.weight(.semibold))
                } else {
                    MapPickerMenu(disabled: engine.phase != .idle)
                }
            }
            .padding(.horizontal, DS.Spacing.m)
            .frame(minHeight: 40)
            .dsFloating(cornerRadius: 20)
            Spacer(minLength: DS.Spacing.s)
            statusPill
                .padding(4)
                .dsFloating(cornerRadius: 20)
        }
    }

    @ViewBuilder private var statusPill: some View {
        switch phase {
        case .noMap, .idle:
            StatusPill(text: "未定位", systemImage: "location.slash", tone: .neutral)
        case .needFix:
            StatusPill(text: "等你定位", systemImage: "hand.tap", tone: .info)
        case .searching:
            StatusPill(text: "正在定位", tone: .info, busy: true)
        case .needHeading:
            StatusPill(text: "确认朝向", systemImage: "location.north.line", tone: .info)
        case .tracking, .navigating:
            StatusPill(text: "已定位 ±\(Fmt.f(max(shownUncertainty / 100, 0.5), 1)) m", systemImage: "location.fill", tone: .success)
        case .lost:
            StatusPill(text: "信号弱", systemImage: "exclamationmark.triangle.fill", tone: .warning)
        }
    }

    private var floors: [String] {
        let name = (demo ? DemoMode.map.floorName : storeData.map?.floorName) ?? "1F"
        return [name.count > 4 ? String(name.prefix(4)) : name]
    }

    private var sideControls: some View {
        VStack(spacing: DS.Spacing.m) {
            FloorSwitcher(floors: floors, selection: $floorIndex)
            VStack(spacing: DS.Spacing.s) {
                DSIconButton(systemImage: follow ? "location.fill" : "location",
                             label: follow ? "正在跟随我的位置" : "跟随我的位置",
                             active: follow && shownPosition != nil) {
                    follow = true
                }
                .disabled(shownPosition == nil)
                .opacity(shownPosition == nil ? 0.5 : 1)
                DSIconButton(systemImage: "map", label: "显示全图") {
                    follow = false
                    resetToken += 1
                }
            }
        }
    }

    // MARK: 底部卡片

    private var bottomCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            Capsule().fill(DS.Palette.separator).frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            cardContent
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.top, DS.Spacing.s)
        .padding(.bottom, DS.Spacing.l)
        .dsFloating(cornerRadius: DS.Radius.sheet)
    }

    @ViewBuilder private var cardContent: some View {
        switch phase {
        case .noMap:
            EmptyView()
        case .idle:
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                Text("开始室内定位").font(DS.Typography.title)
                Text("只用手机的运动传感器和地磁信号找到你的位置，不需要额外硬件，也不用摄像头。手机拿在手里看屏最准；放口袋、包里或打电话时也会继续定位，但这些携带方式还在实测验证中，可能找回得慢、偏得多。")
                    .font(.callout).foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                startPositioning()
            } label: {
                Label("开始定位", systemImage: "location.fill")
            }
            .buttonStyle(.dsPrimary)
            Button("为什么需要这些权限？") { showPermissions = true }
                .font(.footnote.weight(.medium))
                .frame(maxWidth: .infinity)
        case .needFix:
            Text("你在哪里？").font(DS.Typography.title)
            Text(canAutoLocate ? "可以让 App 自动找你，也可以在地图上长按你所在的位置。"
                               : "在地图上长按你所在的位置（这张地图还没有可用于自动定位的数据）。")
                .font(.callout).foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if canAutoLocate {
                Button {
                    Haptics.tap()
                    engine.startColdSearch()
                } label: { Label("自动找我的位置", systemImage: "location.magnifyingglass") }
                .buttonStyle(.dsPrimary)
            }
            stopButton
        case .searching:
            HStack(spacing: DS.Spacing.m) {
                ProgressView().controlSize(.large)
                VStack(alignment: .leading, spacing: 2) {
                    Text("正在找你的位置").font(DS.Typography.title)
                    if let s = engine.searchStarted {
                        TimelineView(.periodic(from: s, by: 1)) { ctx in
                            Text("已用 \(Int(ctx.date.timeIntervalSince(s))) 秒")
                                .font(.footnote).monospacedDigit().foregroundStyle(DS.Palette.textSecondary)
                        }
                    }
                }
            }
            .accessibilityElement(children: .combine)
            tipRow("figure.walk", "沿走廊正常往前走 10～20 米，不要原地转圈")
            tipRow("hand.tap", "知道自己在哪：长按地图上的位置")
            stopButton
        case .needHeading:
            Text(engine.headingEditing ? "在地图上点一下你面朝的方向" : "确认你面朝的方向").font(DS.Typography.title)
            Text("橙色箭头指向你正前方后点「确定」。也可以双击地图开始 / 结束。")
                .font(.callout).foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(engine.headingEditing ? "确定" : "设置朝向") {
                Haptics.tap()
                engine.toggleHeadingEdit()
            }
            .buttonStyle(.dsPrimary)
            stopButton
        case .tracking:
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("你在这里").font(DS.Typography.title)
                    Text("位置偏了：长按地图上的正确位置即可修正")
                        .font(.footnote).foregroundStyle(DS.Palette.textSecondary)
                }
                Spacer()
                Button(role: .destructive) { stopPositioning() } label: {
                    Image(systemName: "stop.fill")
                        .frame(width: 40, height: 40)
                        .background(DS.Palette.danger.opacity(0.12), in: Circle())
                        .foregroundStyle(DS.Palette.danger)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("停止定位")
            }
            Button {
                showSearch = true
            } label: {
                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: "magnifyingglass")
                    Text("搜索目的地").foregroundStyle(DS.Palette.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, DS.Spacing.m)
                .frame(minHeight: 46)
                .background(DS.Palette.surfaceRaised.opacity(0.8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("搜索目的地")
        case .navigating:
            turnCard
        case .lost:
            HStack(spacing: DS.Spacing.m) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2).foregroundStyle(DS.Palette.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("定位信号弱").font(DS.Typography.title)
                    Text("灰点是最后可信的位置。走回已建图的区域会自动恢复。")
                        .font(.footnote).foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            tipRow("hand.tap", "也可以长按地图，手动告诉 App 你在哪")
            stopButton
        }
    }

    private var stopButton: some View {
        Button("停止定位", role: .destructive) { stopPositioning() }
            .buttonStyle(.dsSecondaryTint(DS.Palette.danger))
    }

    private func tipRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.s) {
            Image(systemName: icon).foregroundStyle(DS.Palette.accent).frame(width: 22).accessibilityHidden(true)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var turnCard: some View {
        if demo {
            TurnCard(maneuver: .left, primary: "8 m 后左转", secondary: "前往 位置 A-12",
                     remaining: "27 m", onEnd: {})
        } else {
            TurnCard(maneuver: maneuver, primary: turnPrimary, secondary: engine.navLabel.map { "前往 \($0)" },
                     remaining: engine.navHint.map { NavInstruction.meters($0.remainingDistance) },
                     onEnd: { engine.stopNavigation(); Haptics.tap() })
        }
    }

    private var maneuver: TurnCard.Maneuver {
        if engine.navArrived { return .arrived }
        guard let h = engine.navHint else { return .planning }
        if h.isOffRoute { return .offRoute }
        // 定位不够准时不出转向箭头（NAV-004）
        guard h.quality.allowsTurnInstructions, let t = NavInstruction.nextTurn(h), t.distanceCm <= 1500 else { return .straight }
        switch t.direction {
        case .left: return .left
        case .right: return .right
        case .uturn: return .uturn
        case .straight: return .straight
        }
    }

    private var turnPrimary: String {
        if engine.navArrived { return "已到达" }
        guard let h = engine.navHint else { return engine.position == nil ? "等待定位…" : "正在规划路线…" }
        if h.isOffRoute { return "偏离路线，正在重新规划" }
        if h.quality.pausesNavigation { return "正在确认位置…" }
        if h.quality == .coarse { return "位置还不太准，先朝目标方向走" }
        // 是否到达只看 engine.navArrived（ArrivalPolicy 连续确认过）；剩余里程短只说快到了
        if h.remainingDistance <= NavInstruction.arriveCm { return "快到了" }
        if h.quality.allowsTurnInstructions, let t = NavInstruction.nextTurn(h), t.distanceCm <= 1500 {
            let d = NavInstruction.meters(t.distanceCm)
            switch t.direction {
            case .left: return "\(d) 后左转"
            case .right: return "\(d) 后右转"
            case .uturn: return "\(d) 后掉头"
            case .straight: return "继续直行"
            }
        }
        return "沿路线直行"
    }

    // MARK: 空状态

    private var noMapState: some View {
        VStack {
            Spacer()
            EmptyStateView(systemImage: "map",
                           title: "还没有可用的地图",
                           message: "先在地图库里下载场地地图，或者自己走一遍生成地图，然后就能在室内定位和导航了。",
                           actionTitle: "打开地图库",
                           action: { tab = .library },
                           secondaryTitle: "去建图",
                           secondaryAction: { tab = .mapping })
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 动作

    private var canAutoLocate: Bool {
        (store.field != nil || engine.visualAvailable) && store.usesStoreMap
    }

    private func startPositioning() {
        guard !demo else { return }
        Haptics.tap()
        follow = true
        engine.startLive()
        // 有地图数据就直接开始自动找位置，用户只需要往前走
        if engine.phase == .live && canAutoLocate { engine.startColdSearch() }
    }

    private func stopPositioning() {
        Haptics.tap()
        engine.stopNavigation()
        engine.stopLive()
    }

    private func reportTelemetry() {
        guard !demo, tab == .navigate else { return }
        let loc: String = {
            switch engine.locState {
            case .tracking: return "tracking"
            case .searching: return "searching"
            case .lost: return "lost"
            default: return "idle"
            }
        }()
        Telemetry.shared.state(mode: "live", position: engine.position, uncertaintyCm: engine.uncertaintyCm,
                               headingRad: engine.headingRad, loc: loc, ble: engine.bleTagsHeard,
                               extra: ["visualFixes": engine.visualFixes, "changedSpots": engine.changedSpots.count,
                                       "outside": engine.bleOutside])
    }
}

// MARK: - 搜索目的地

/// 目的地：地图里的区域 / 物体，加上手动标的点。
struct DestinationSearchSheet: View {
    @ObservedObject var engine: MagneticEngine
    var onPick: () -> Void

    @ObservedObject private var storeData = StoreDataStore.shared
    @ObservedObject private var store = MagMapStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private struct Place: Identifiable {
        enum Kind { case area, point }
        let id: String
        let title: String
        let subtitle: String
        let kind: Kind
        let code: String?
        let position: Point2
    }

    private var places: [Place] {
        var out: [Place] = []
        if let m = storeData.map {
            for s in m.shelves where s.kind == .standard || s.code.hasPrefix("Room-") {
                let title: String
                if s.code.hasPrefix("Room-") {
                    let parts = s.code.split(separator: "-")
                    title = parts.count >= 2 ? RoomCategory.label(String(parts[1])) : s.code
                } else {
                    title = "位置 \(s.code)"
                }
                out.append(Place(id: "s-" + s.code, title: title, subtitle: "地图上的区域", kind: .area,
                                 code: s.code, position: Point2(s.x, s.y)))
            }
        }
        for p in store.points {
            out.append(Place(id: "p-" + p.id, title: "标记点 \(p.id)", subtitle: "手动标记的位置", kind: .point,
                             code: nil, position: p.position))
        }
        return out
    }

    private var filtered: [Place] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = places
        guard !q.isEmpty else { return Array(all.prefix(60)) }
        return Array(all.filter { $0.title.localizedCaseInsensitiveContains(q) || ($0.code?.localizedCaseInsensitiveContains(q) ?? false) }.prefix(60))
    }

    var body: some View {
        NavigationStack {
            Group {
                if places.isEmpty {
                    EmptyStateView(systemImage: "mappin.slash", title: "这张地图还没有目的地",
                                   message: "地图里没有标注区域。可以在「设置 → 开发者 → 高级控制台」里长按地图添加标记点。")
                } else if filtered.isEmpty {
                    EmptyStateView(systemImage: "magnifyingglass", title: "没有找到「\(query)」",
                                   message: "换个关键词试试。")
                } else {
                    List(filtered) { p in
                        Button {
                            pick(p)
                        } label: {
                            HStack(spacing: DS.Spacing.m) {
                                Image(systemName: p.kind == .area ? "square.dashed.inset.filled" : "mappin.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(p.kind == .area ? DS.Palette.accent : DS.Palette.danger)
                                    .frame(width: 30)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.title).foregroundStyle(DS.Palette.textPrimary)
                                    Text(distanceText(p) ?? p.subtitle).font(.caption).foregroundStyle(DS.Palette.textSecondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                                    .font(.title2).foregroundStyle(DS.Palette.accent)
                                    .accessibilityHidden(true)
                            }
                        }
                        .accessibilityHint("开始导航")
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索区域或标记点")
            .navigationTitle("去哪里")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func distanceText(_ p: Place) -> String? {
        guard let here = engine.position else { return nil }
        return "直线约 " + NavInstruction.meters(here.distance(to: p.position))
    }

    private func pick(_ p: Place) {
        Haptics.success()
        if let code = p.code, p.kind == .area, !code.hasPrefix("Room-") {
            engine.navigateToShelf(code: code)
        } else {
            engine.navigate(to: p.position, label: p.title)
        }
        AppLog.tap("导航·目的地", p.title)
        onPick()
        dismiss()
    }
}
