import Foundation

/// 看板「路线」页用的分段数据（云端建图时导出，传到后台 /api/segments/<地图>）。
///
/// 每段给出「原始位置」（只做了起点 / 朝向对齐，没做多遍自动对齐、没套手动修改）的样本，
/// 和现在实际用的变换（手动摆过的用手动的，否则用自动对齐的）。看板按 变换(原始位置) 画，
/// 拖动 / 旋转时在现在的变换上再叠一层，存成新的手动修改（同样作用在原始位置上，见 SurveySegments.Edit）。
/// 着色在看板里按同一套规则实时重算（SurveySegments.consistency），这里也算一份写进去。
public struct SurveySegmentExport: Codable {
    public struct Transform: Codable, Equatable {
        public var dx: Double
        public var dy: Double
        public var rotDeg: Double
        public var pivotX: Double
        public var pivotY: Double
    }

    public struct Segment: Codable {
        /// 会话名 @ 开始时间（ms）
        public var id: String
        public var session: String
        public var t0Ms: Int64
        public var t1Ms: Int64
        public var lengthM: Double
        /// 原始位置的样本：[x cm, y cm, |B| µT, Bz µT]（已减掉会话整体偏移），约 25 cm 一个
        public var raw: [[Double]]
        /// 现在实际套的变换（手动摆过的 = 手动的，否则 = 这次建图的自动对齐；nil = 原样）
        public var current: Transform?
        /// 手动摆过的话是那份修改
        public var edit: Transform?
        /// 不管手动摆放时自动对齐会放在哪（看板「复位」用）
        public var auto: Transform?
        public var deleted: Bool
        public var verdict: SurveySegments.Verdict
        /// 中点离这遍最近真值点（起点 / 长按修正）的路程（m）
        public var driftM: Double?
    }

    public struct Session: Codable {
        public var name: String
        /// 质量筛选的结果（整遍不用时 false + 原因）
        public var kept: Bool
        public var reason: String?
    }

    public struct Thresholds: Codable {
        public var cellCm: Double
        public var minRefWeight: Double
        public var minOverlapM: Double
        public var greenUT: Double
        public var yellowUT: Double
    }

    public var version = 1
    public var mapId: String
    public var builtMs: Int64
    public var thresholds: Thresholds
    public var sessions: [Session]
    public var segments: [Segment]
    /// 各色段数
    public var counts: [String: Int]

    /// - rigid: 每遍的自动对齐修正（云端出图结果 ProductionBuild.rigid；全部没过质量筛选时传空）
    /// - quality: 质量筛选结果
    /// - edits: 后台存的手动修改
    public static func build(mapId: String, fusion: MultiSessionFusion, sessions: [SurveySession],
                             rigid allRigid: [SessionRegistration.Rigid?], autoRigid: [SessionRegistration.Rigid?]? = nil,
                             segmentAuto: [String: [SurveySegments.Edit]] = [:],
                             quality qualityReports: [SessionQualityGate.Report],
                             edits: SurveySegments.EditSet?, walkable: WalkableMap? = nil,
                             split: SurveySegments.SplitConfig = .init(),
                             consistency: SurveySegments.ConsistencyConfig = .init()) -> SurveySegmentExport {
        // 原始位置（不套任何修正，删掉的段也要）
        let raw = fusion.fuse(sessions)
        let quality = Dictionary(qualityReports.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var segs: [Segment] = []
        var pieces: [SurveySegments.Piece] = []
        for (k, s) in sessions.enumerated() {
            let ed = edits?.session(s.name)
            let rigid = k < allRigid.count ? allRigid[k] : nil
            func tr(_ r: SessionRegistration.Rigid?) -> Transform? {
                r.flatMap { $0.isIdentity ? nil : Transform(dx: $0.dx, dy: $0.dy, rotDeg: $0.rotDeg, pivotX: $0.pivotX, pivotY: $0.pivotY) }
            }
            let cur = tr(rigid)
            let auto = autoRigid.map { k < $0.count ? tr($0[k]) : nil } ?? cur
            let samples = raw.samples[k]
            let spans = SurveySegments.split(raw.tracks[k], config: split)
            // 离最近真值点（起点 / 途中长按修正）的路程：沿原始轨迹累积
            let truth = s.anchors.filter { $0.kind == "start" || $0.kind == "reanchor" }.map(\.tMs).sorted()
            let track = raw.tracks[k]
            var cum: [Double] = [0]
            for i in track.indices.dropFirst() { let d = track[i].p.distance(to: track[i - 1].p); cum.append(cum.last! + (d < 300 ? d : 0)) }
            func pathAt(_ t: Int64) -> Double? {
                guard let i = track.lastIndex(where: { $0.tMs <= t }) ?? (track.isEmpty ? nil : 0) else { return nil }
                return cum[i]
            }
            func drift(_ t: Int64) -> Double? {
                guard let a = truth.last(where: { $0 <= t }) ?? truth.first, let pa = pathAt(a), let pt = pathAt(t) else { return nil }
                return max(0, pt - pa) / 100
            }
            for (i, sp) in spans.enumerated() {
                let last = i == spans.count - 1
                let mine = samples.filter { $0.tMs >= sp.t0Ms && ($0.tMs < sp.t1Ms || (last && $0.tMs <= sp.t1Ms)) }
                let th = SurveySegments.thin(mine, position: { $0.p })
                guard th.count >= 2 else { continue }
                let mid = sp.t0Ms + (sp.t1Ms - sp.t0Ms) / 2
                let pin = ed?.pinned(mid)
                let deleted = ed?.deleted(mid) ?? false
                let editT = pin.map { Transform(dx: $0.dx, dy: $0.dy, rotDeg: $0.rotDeg, pivotX: $0.pivotX, pivotY: $0.pivotY) }
                let segAuto = segmentAuto[s.name]?.first { $0.contains(mid) }
                let segAutoT = segAuto.map { Transform(dx: $0.dx, dy: $0.dy, rotDeg: $0.rotDeg, pivotX: $0.pivotX, pivotY: $0.pivotY) }
                func place(_ p: Point2) -> Point2 {
                    if let e = pin { return e.apply(p) }
                    if let e = segAuto { return e.apply(p) }
                    if let r = rigid, !r.isIdentity { return r.apply(p) }
                    return p
                }
                let id = "\(s.name)@\(sp.t0Ms)"
                pieces.append(.init(id: id, session: s.name, samples: th.map { (place($0.p), $0.f.total, $0.f.vertical) }, deleted: deleted,
                                driftM: drift(mid)))
                segs.append(Segment(id: id, session: s.name, t0Ms: sp.t0Ms, t1Ms: sp.t1Ms, lengthM: (sp.lengthCm / 10).rounded() / 10,
                                    raw: th.map { [($0.p.x * 10).rounded() / 10, ($0.p.y * 10).rounded() / 10,
                                                   ($0.f.total * 100).rounded() / 100, ($0.f.vertical * 100).rounded() / 100] },
                                    current: editT ?? segAutoT ?? cur, edit: editT, auto: segAutoT ?? auto, deleted: deleted,
                                    verdict: .init(grade: .gray, overlapM: 0, residualUT: nil, conflicts: [:], suggestDx: nil, suggestDy: nil, suggestResidualUT: nil),
                                    driftM: drift(mid).map { ($0 * 10).rounded() / 10 }))
            }
        }
        let verdicts = SurveySegments.consistency(pieces, config: consistency, walkable: walkable.map { w in { w.isWalkable($0) } })
        var counts: [String: Int] = [:]
        for i in segs.indices {
            segs[i].verdict = verdicts[i]
            if !segs[i].deleted { counts[verdicts[i].grade.rawValue, default: 0] += 1 } else { counts["deleted", default: 0] += 1 }
        }
        let ss = sessions.map { s -> Session in
            let q = quality[s.name]
            return Session(name: s.name, kept: q?.kept ?? true, reason: q?.reason)
        }
        return SurveySegmentExport(mapId: mapId, builtMs: Int64((Date().timeIntervalSince1970 * 1000).rounded()),
                                   thresholds: .init(cellCm: consistency.cellCm, minRefWeight: consistency.minRefWeight,
                                                     minOverlapM: consistency.minOverlapM, greenUT: consistency.greenUT, yellowUT: consistency.yellowUT),
                                   sessions: ss, segments: segs, counts: counts)
    }
}
