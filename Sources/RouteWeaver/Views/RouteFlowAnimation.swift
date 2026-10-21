import SwiftUI

/// Local illustration state. This is never connected to measured traffic.
enum RouteDemoBranch: String, CaseIterable {
    case direct, exit
    var color: Color { self == .direct ? WeaveStyle.accent : WeaveStyle.blue }
}

enum RouteDemoLayout {
    case overview, preview

    func points(in size: CGSize, branch: RouteDemoBranch) -> (CGPoint, CGPoint, CGPoint, CGPoint, CGPoint) {
        let centerY = size.height * 0.48
        let endY = size.height * (branch == .direct ? 0.26 : 0.74)
        let start: CGPoint
        let split: CGPoint
        let end: CGPoint
        switch self {
        case .overview:
            start = CGPoint(x: size.width * 0.19 + 38, y: centerY)
            split = CGPoint(x: size.width * 0.43, y: centerY)
            end = CGPoint(x: size.width * 0.535, y: endY)
        case .preview:
            start = CGPoint(x: 53, y: centerY)
            split = CGPoint(x: size.width * 0.34, y: centerY)
            end = CGPoint(x: size.width * 0.58, y: endY)
        }
        let bend = max(12, (end.x - split.x) * 0.5)
        return (start, split, CGPoint(x: split.x + bend, y: centerY), CGPoint(x: end.x - bend, y: endY), end)
    }

    func path(in size: CGSize, branch: RouteDemoBranch) -> Path {
        let (start, split, control1, control2, end) = points(in: size, branch: branch)
        var path = Path()
        path.move(to: start)
        path.addLine(to: split)
        path.addCurve(to: end, control1: control1, control2: control2)
        return path
    }

    func point(at progress: Double, in size: CGSize, branch: RouteDemoBranch) -> CGPoint {
        let (start, split, control1, control2, end) = points(in: size, branch: branch)
        // Divide the journey between its straight stem and cubic branch.
        if progress < 0.48 {
            let t = progress / 0.48
            return CGPoint(x: start.x + (split.x - start.x) * t, y: start.y)
        }
        let t = (progress - 0.48) / 0.52
        let u = 1 - t
        return CGPoint(x: u * u * u * split.x + 3 * u * u * t * control1.x + 3 * u * t * t * control2.x + t * t * t * end.x,
                       y: u * u * u * split.y + 3 * u * u * t * control1.y + 3 * u * t * t * control2.y + t * t * t * end.y)
    }
}

/// Only this small canvas receives frame updates; tables and the store stay idle.
struct RouteFlowAnimation: View {
    var layout: RouteDemoLayout
    var focus: RouteDemoBranch?
    var playing: Bool
    var directAvailable = true
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var running: Bool {
        playing && !reduceMotion && scenePhase == .active && controlActiveState == .key
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !running)) { timeline in
            Canvas { context, size in
                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.6) / 3.6
                for branch in RouteDemoBranch.allCases {
                    if branch == .direct && !directAvailable { continue }
                    let selected = focus == nil || focus == branch
                    let color = branch.color
                    let opacity = selected ? 1.0 : 0.18
                    let path = layout.path(in: size, branch: branch)
                    context.stroke(path, with: .color(color.opacity(0.07 * opacity)), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    context.stroke(path, with: .color(color.opacity(0.6 * opacity)), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, dash: branch == .exit ? [4, 5] : []))
                    guard selected else { continue }
                    let end = layout.points(in: size, branch: branch).4
                    if reduceMotion {
                        context.fill(Path(ellipseIn: CGRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6)), with: .color(color))
                        continue
                    }
                    for offset in [0.0, 0.5] {
                        let progress = (phase + offset).truncatingRemainder(dividingBy: 1)
                        let point = layout.point(at: progress, in: size, branch: branch)
                        // A short trail makes direction clear without drawing attention from the controls.
                        for tail in 1...4 {
                            let prior = max(0, progress - Double(tail) * 0.018)
                            let p = layout.point(at: prior, in: size, branch: branch)
                            context.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)), with: .color(color.opacity(0.28 / Double(tail))))
                        }
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)), with: .color(color.opacity(0.15)))
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 2.4, y: point.y - 2.4, width: 4.8, height: 4.8)), with: .color(color))
                        if progress > 0.86 {
                            let response = (progress - 0.86) / 0.14
                            let radius = 3 + response * 9
                            context.stroke(Path(ellipseIn: CGRect(x: end.x - radius, y: end.y - radius, width: radius * 2, height: radius * 2)), with: .color(color.opacity((1 - response) * 0.7)), lineWidth: 1)
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct RouteDemoPlaybackButton: View {
    @Binding var playing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { playing.toggle() } label: {
            Image(systemName: reduceMotion ? "circle.dotted" : (playing ? "pause.fill" : "play.fill"))
                .font(.system(size: 10, weight: .semibold)).frame(width: 15, height: 13)
        }
        .buttonStyle(WeaveActionStyle())
        .disabled(reduceMotion)
        .accessibilityLabel(reduceMotion ? "已按系统设置减少动态效果" : (playing ? "暂停流向演示" : "播放流向演示"))
        .help(reduceMotion ? "已按系统设置减少动态效果" : (playing ? "暂停流向演示" : "播放流向演示"))
    }
}
