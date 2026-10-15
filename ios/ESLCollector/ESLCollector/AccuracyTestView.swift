import Foundation
import SwiftUI

/// 精度测试：当前地图的「采集 → 云端融合 → 走测试会话 → 看成绩」清单，加最近几次云端报告的成绩和趋势。
/// 成绩来自云端融合（hpass-build）对测试会话（purpose = test）的评估，报告在后台 /api/reports/build_<地图>_<时间>.json。

// MARK: - 云端报告

/// 一个测试会话的成绩（同一会话跑了几次不同随机种子，取平均）
struct AccuracyRow: Identifiable {
    var id: String { session }
    var session: String
    var runs: Int
    var medianCm: Double?
    var p90Cm: Double?
    var within1m: Double?
    var firstFixM: Double?
    var jumps: Double?
    var wrongFixShare: Double?
    var inMapMedianCm: Double?
    var inMapShare: Double?
}

struct AccuracyReport: Identifiable {
    var id: String
    var date: Date
    var version: Int64?
    var rows: [AccuracyRow]
    var testSessions: [String]
    var buildSessions: Int
    /// 这一版的总成绩：各测试会话中位误差的中位数
    var medianCm: Double? {
        let v = rows.compactMap(\.medianCm).sorted()
        return v.isEmpty ? nil : v[v.count / 2]
    }
}

@MainActor
final class AccuracyReports: ObservableObject {
    @Published private(set) var reports: [AccuracyReport] = []
    @Published private(set) var loading = false
    @Published private(set) var message: String?

    private struct Empty: Decodable {}
    private struct ListItem: Decodable { var key: String }
    private struct RawTest: Decodable {
        var session: String
        var medianCm: Double?, p90Cm: Double?, within1m: Double?, firstFixM: Double?, wrongFixShare: Double?
        var inMapMedianCm: Double?, inMapShare: Double?
        var jumps: Int?
    }
    private struct RawReport: Decodable {
        var version: Int64?
        var tests: [RawTest]?
        var testSessions: [String]?
        var sessions: [Empty]?
    }

    /// 取这张地图最近几次云端报告（新的在前）
    func load(mapId: String, limit: Int = 5) async {
        guard Telemetry.shared.enabled else { message = "先在「门店数据 → 云端后台」填地址和口令并打开连接。"; return }
        loading = true
        defer { loading = false }
        do {
            let data = try await Telemetry.shared.getData("api/reports")
            let items = try JSONDecoder().decode([ListItem].self, from: data)
            // 文件名 build_<地图>_<yyyyMMdd_HHmmss>.json；后面必须正好是时间戳，免得把名字开头相同的别的地图算进来
            let prefix = "reports/build_\(mapId)_"
            let mine = items.compactMap { it -> (String, Date)? in
                guard it.key.hasPrefix(prefix) else { return nil }
                let rest = String(it.key.dropFirst(prefix.count))
                guard rest.hasSuffix(".json"), let d = Self.stampDate(String(rest.dropLast(5))) else { return nil }
                return (String(it.key.dropFirst("reports/".count)), d)
            }.sorted { $0.1 > $1.1 }.prefix(limit)
            var out: [AccuracyReport] = []
            for (name, date) in mine {
                let d = try await Telemetry.shared.getData("api/reports/\(name)")
                guard let raw = try? JSONDecoder().decode(RawReport.self, from: d) else { continue }
                out.append(AccuracyReport(id: name, date: date, version: raw.version, rows: Self.aggregate(raw.tests ?? []),
                                          testSessions: raw.testSessions ?? [], buildSessions: raw.sessions?.count ?? 0))
            }
            reports = out
            message = out.isEmpty ? "云端还没有这张地图的融合报告。" : nil
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            message = "取云端报告失败：\(error)"
        }
    }

    private static func stampDate(_ s: String) -> Date? {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyyMMdd_HHmmss"
        return df.date(from: s)
    }

    private static func aggregate(_ tests: [RawTest]) -> [AccuracyRow] {
        func mean(_ v: [Double?]) -> Double? {
            let a = v.compactMap { $0 }
            return a.isEmpty ? nil : a.reduce(0, +) / Double(a.count)
        }
        var order: [String] = []
        var groups: [String: [RawTest]] = [:]
        for t in tests {
            if groups[t.session] == nil { order.append(t.session) }
            groups[t.session, default: []].append(t)
        }
        return order.map { name in
            let g = groups[name] ?? []
            return AccuracyRow(session: name, runs: g.count, medianCm: mean(g.map(\.medianCm)), p90Cm: mean(g.map(\.p90Cm)),
                               within1m: mean(g.map(\.within1m)), firstFixM: mean(g.map(\.firstFixM)),
                               jumps: mean(g.map { $0.jumps.map(Double.init) }), wrongFixShare: mean(g.map(\.wrongFixShare)),
                               inMapMedianCm: mean(g.map(\.inMapMedianCm)), inMapShare: mean(g.map(\.inMapShare)))
        }
    }
}

// MARK: - 页面

struct AccuracyTestView: View {
    @ObservedObject var survey: SurveyEngine
    @ObservedObject var mapService: SurveyMapService
    /// 点「开始测试会话」：外面把页面切到采集并开始（见 MagneticView）
    var onStart: () -> Void

    @ObservedObject private var lib = MapLibrary.shared
    @ObservedObject private var store = MagMapStore.shared
    @ObservedObject private var tel = Telemetry.shared
    @StateObject private var model = AccuracyReports()
    @Environment(\.dismiss) private var dismiss

    private var mapId: String { lib.activeId ?? "" }
    private var fused: Bool { lib.active?.isCloudFused == true }
    private var latest: AccuracyReport? { model.reports.first }
    /// 本机的测试会话里，最新一份报告还没评估到的
    private var pendingTests: [SurveyMapService.Item] {
        guard let l = latest else { return mapService.testItems }
        let done = Set(l.testSessions)
        return mapService.testItems.filter { !done.contains($0.id) }
    }

    var body: some View {
        Form {
            checklistSection
            startSection
            resultSection
            trendSection
            Section {
                Text("成绩是和「这段测试自己的 ARKit 轨迹 + 起点」比出来的，不是尺子量的真值：起点点得不准、走很久后 ARKit 漂移，都会让成绩偏差几十厘米。同一张图、同一段测试会话在不同版本之间比较才有意义，别和别的系统的数字直接比。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("精度测试")
        .onAppear {
            mapService.refresh()
            Task { await model.load(mapId: mapId) }
        }
    }

    // MARK: 清单

    @ViewBuilder private var checklistSection: some View {
        Section {
            if let e = lib.active {
                check(e.isRoom, "房间已扫描", e.isRoom ? e.name : "当前是「\(e.name)」（门店地图），也可以测，只是下面按房间来写")
            } else {
                check(false, "房间已扫描", "还没有地图：先到「房间扫描」页扫一遍")
            }
            let n = mapService.items.count
            check(n >= 3, "已采集 \(n) 段", n >= 3 ? "够了" : "建议至少 3 段，从不同方向把地面走满")
            check(fused, "云端融合版本",
                  fused ? "\(CloudMapsSection.date(lib.active?.cloudVersion ?? 0))，\(lib.active?.cloudInfo?.sessions ?? 0) 个会话"
                        : "还没有：上传会话后在 GitHub 触发云端融合，再到「云端地图」下载")
            let t = mapService.testItems.count
            check(t > 0, "测试会话 \(t) 段",
                  t == 0 ? "还没有：下面开始走一段" : (pendingTests.isEmpty ? "都已评估" : "\(pendingTests.count) 段还没出成绩：上传后重新云端融合"))
            Text(nextStep).font(.callout.bold())
        } header: { Text("清单（\(lib.active?.name ?? "无地图")）") }
    }

    private var nextStep: String {
        if lib.active == nil { return "下一步：先扫描房间。" }
        if mapService.items.count < 3 { return "下一步：到「采集」步骤多采几段建图会话。" }
        if !fused { return "下一步：上传会话，触发云端融合（见 docs/office-test.md），再下载融合后的地图。" }
        if mapService.testItems.isEmpty { return "下一步：走一段测试会话。" }
        if !pendingTests.isEmpty { return "下一步：上传测试会话，再触发一次云端融合，成绩就出来了。" }
        return "已有成绩：改完算法后重新融合，看下面的趋势有没有变好。"
    }

    private func check(_ ok: Bool, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 开始测试

    @ViewBuilder private var startSection: some View {
        Section {
            Text("""
                1. 先用一条和建图时不同的路线，别重复建图走过的路。
                2. 走 2～5 分钟，正常步速，手机竖着、摄像头朝前下方。
                3. 从一个能准确指出的点出发（例如地上贴的胶带、某个桌角），在地图上长按这个点定起点，再设朝向、直走 1.5 m。
                4. 中途不要长按修正（修正会让参考轨迹不独立）。走完点「结束采集」，会话会自动上传。
                """)
                .font(.footnote)
            if survey.isRunning {
                Text("正在采集，先结束当前这一段。").foregroundStyle(.orange).font(.footnote)
            }
            if !store.usesStoreMap {
                Text("当前地图没有可走区域，先扫描房间或导入地图。").foregroundStyle(.orange).font(.footnote)
            }
            if store.field == nil {
                Text("本机还没有磁场图，走的时候不会实时显示成绩，但会话照样录下来，云端融合后出成绩。")
                    .foregroundStyle(.secondary).font(.footnote)
            }
            LoggedButton(name: "精度测试·开始", detail: "测试会话") {
                onStart()
                dismiss()
            } label: {
                Text("开始测试会话").frame(maxWidth: .infinity).fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .disabled(survey.isRunning || !store.usesStoreMap)
            if tel.enabled {
                Button { Task { await mapService.uploadAll() } } label: { Label("上传本机还没上传的会话", systemImage: "icloud.and.arrow.up") }
                if let u = mapService.uploadStatus { Text(u).font(.caption).foregroundStyle(.secondary) }
            }
            if let s = survey.evalSummary {
                VStack(alignment: .leading, spacing: 2) {
                    Text("本机刚测的一段（实时，采集轨迹当参考）").font(.footnote.bold())
                    Text(s).font(.footnote.monospacedDigit())
                }
            }
        } header: { Text("走测试会话") }
    }

    // MARK: 成绩

    @ViewBuilder private var resultSection: some View {
        Section {
            if model.loading && model.reports.isEmpty { ProgressView() }
            if let m = model.message { Text(m).font(.footnote).foregroundStyle(.secondary) }
            if let r = latest {
                Text("云端报告 \(Self.dateText(r.date))，建图 \(r.buildSessions) 个会话").font(.footnote).foregroundStyle(.secondary)
                if r.rows.isEmpty {
                    Text("这一版没有测试成绩：测试会话还没传到后台，或融合时没带上。传完重新触发云端融合。")
                        .font(.footnote).foregroundStyle(.orange)
                }
                ForEach(r.rows) { row in rowView(row) }
            }
            Button { Task { await model.load(mapId: mapId) } } label: { Label("刷新云端成绩", systemImage: "arrow.clockwise") }
                .disabled(model.loading)
        } header: { Text("最新成绩") } footer: {
            Text("中位 = 一半的时刻误差比它小；P90 = 九成的时刻比它小；≤1 m = 误差在 1 米内的占比；首次定位 = 开始走多远才第一次定到；跳 = 位置突然跳走的次数；错定 = 自信地定在 5 m 外的占比。同一段会话云端用不同随机种子跑了几次，取平均。")
        }
    }

    private func rowView(_ r: AccuracyRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(String(r.session.suffix(15)) + (r.runs > 1 ? "（\(r.runs) 次平均）" : "")).font(.footnote.bold())
            HStack {
                metric("中位", cm(r.medianCm), color: color(r.medianCm))
                metric("P90", cm(r.p90Cm), color: nil)
                metric("≤1 m", pct(r.within1m), color: nil)
            }
            HStack {
                metric("首次定位", r.firstFixM.map { String(format: "%.1f m", $0) } ?? "没定到", color: nil)
                metric("跳", r.jumps.map { String(format: "%.1f", $0) } ?? "—", color: nil)
                metric("错定", pct(r.wrongFixShare), color: nil)
            }
            if r.inMapMedianCm != nil {
                Text("只看建图覆盖到的地方（占 \(pct(r.inMapShare))）：中位 \(cm(r.inMapMedianCm))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func metric(_ title: String, _ value: String, color: Color?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().bold()).foregroundStyle(color ?? .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 趋势

    @ViewBuilder private var trendSection: some View {
        let list = model.reports.filter { $0.medianCm != nil }
        if list.count >= 1 {
            let maxV = max(list.compactMap(\.medianCm).max() ?? 1, 1)
            Section {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, r in
                    let v = r.medianCm ?? 0
                    let prev = i + 1 < list.count ? list[i + 1].medianCm : nil
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(Self.dateText(r.date)).font(.footnote)
                            Spacer()
                            Text(cm(v)).font(.footnote.monospacedDigit().bold())
                            if let p = prev {
                                let d = v - p
                                Text(abs(d) < 5 ? "持平" : "\(d < 0 ? "↓ 好了" : "↑ 差了") \(Int(abs(d).rounded())) cm")
                                    .font(.caption).foregroundStyle(abs(d) < 5 ? Color.secondary : (d < 0 ? Color.green : Color.red))
                            }
                        }
                        GeometryReader { g in
                            RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.6))
                                .frame(width: max(g.size.width * v / maxV, 2), height: 6)
                        }
                        .frame(height: 6)
                        Text("\(r.rows.count) 段测试 · 建图 \(r.buildSessions) 个会话").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: { Text("趋势（每次云端融合的中位误差，越短越好）") } footer: {
                Text("每次融合会带上当时所有测试会话；想看算法有没有变好，两次之间别增减测试会话，否则比的不是同一批数据。")
            }
        }
    }

    // MARK: 格式

    private func cm(_ v: Double?) -> String { v.map { String(format: "%.0f cm", $0) } ?? "—" }
    private func pct(_ v: Double?) -> String { v.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }
    private func color(_ v: Double?) -> Color? {
        guard let v else { return nil }
        return v <= 150 ? .green : (v <= 300 ? .orange : .red)
    }
    private static func dateText(_ d: Date) -> String {
        let df = DateFormatter(); df.dateFormat = "MM-dd HH:mm"
        return df.string(from: d)
    }
}
