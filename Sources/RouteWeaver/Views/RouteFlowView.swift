import SwiftUI

/// A schematic of the selected plan, never a traffic meter.
struct RouteFlowView: View {
    let store: AppStore
    @State private var focus: RouteDemoBranch?
    @State private var playing = true
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("一台设备 · 两条路径")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                Spacer()
                Text("流向演示 · 非实时流量").font(.system(size: 11)).foregroundStyle(.white.opacity(0.42))
                RouteDemoPlaybackButton(playing: $playing)
            }.padding(.horizontal, 22).padding(.top, 18)
            GeometryReader { geometry in
                let w = geometry.size.width
                let h = geometry.size.height
                ZStack {
                    Canvas { context, size in
                        for x in stride(from: 12.0, to: size.width, by: 22) {
                            for y in stride(from: 8.0, to: size.height, by: 22) {
                                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.white.opacity(0.08)))
                            }
                        }
                    }.mask(LinearGradient(colors: [.clear, .white, .clear], startPoint: .leading, endPoint: .trailing))
                    RouteFlowAnimation(layout: .overview, focus: focus, playing: playing)
                    source.position(x: w * 0.19, y: h * 0.48)
                    destination(title: store.countryEnabled ? "中国大陆地址" : "匹配直连规则的地址", subtitle: "经本地网关直达", tag: "DIRECT", icon: "arrow.up.right", branch: .direct)
                        .frame(width: w * 0.41).position(x: w * 0.74, y: h * 0.26)
                    destination(title: "其余地址", subtitle: store.network.exitNodeName ?? "Tailscale 出口节点", tag: "EXIT NODE", icon: "network", branch: .exit)
                        .frame(width: w * 0.41).position(x: w * 0.74, y: h * 0.74)
                }
            }.frame(height: 200)
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(WeaveStyle.accent.opacity(0.65))
                Text("出口例外优先").foregroundStyle(.white.opacity(0.47))
                Spacer()
                Text(store.serviceDNSActive ? "国内域名解析已分流" : "域名解析沿用原设置").foregroundStyle(.white.opacity(0.45))
            }.font(.system(size: 11)).padding(.horizontal, 22).padding(.bottom, 16)
        }
        .background {
            ZStack {
                Color(red: 0.045, green: 0.065, blue: 0.105)
                RadialGradient(colors: [WeaveStyle.accent.opacity(0.10), .clear], center: UnitPoint(x: 0.2, y: 0.47), startRadius: 10, endRadius: 220)
                RadialGradient(colors: [WeaveStyle.blue.opacity(0.09), .clear], center: .bottomTrailing, startRadius: 10, endRadius: 300)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.07)))
        .accessibilityElement(children: .contain)
    }

    private var source: some View {
        ZStack {
            // The rings share one center and one geometry with the path origin.
            // Static shading gives the hub depth without another animated layer.
            Circle()
                .fill(WeaveStyle.accent.opacity(0.025))
                .overlay(Circle().strokeBorder(WeaveStyle.accent.opacity(0.13), lineWidth: 1))
                .frame(width: 100, height: 100)
            Circle()
                .fill(LinearGradient(
                    colors: [Color(red: 0.105, green: 0.17, blue: 0.27), Color(red: 0.055, green: 0.09, blue: 0.15)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .overlay(Circle().strokeBorder(LinearGradient(
                    colors: [WeaveStyle.accent.opacity(0.42), .white.opacity(0.06)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ), lineWidth: 1))
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
                .frame(width: 80, height: 80)
            Image(systemName: "laptopcomputer")
                .font(.system(size: 31, weight: .light))
                .foregroundStyle(WeaveStyle.accent)
        }
        .frame(width: 104, height: 104)
        .overlay(alignment: .bottom) {
            VStack(spacing: 4) {
                Text("这台 Mac").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                Text("LOCAL DEVICE").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.1).foregroundStyle(.white.opacity(0.38))
            }
            .fixedSize()
            .offset(y: 36)
        }
        .accessibilityElement(children: .combine)
    }

    private func destination(title: String, subtitle: String, tag: String, icon: String, branch: RouteDemoBranch) -> some View {
        let color = branch.color
        let selected = focus == nil || focus == branch
        return Button { focus = focus == branch ? nil : branch } label: {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 20, weight: .regular))
                .foregroundStyle(color).frame(width: 38, height: 40)
                .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(.white.opacity(0.92))
                HStack(spacing: 6) {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(tag).font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(0.3).foregroundStyle(color.opacity(0.8)).fixedSize()
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(13)
        .background(LinearGradient(colors: [color.opacity(0.08), .white.opacity(0.02)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(color.opacity(focus == branch ? 0.5 : 0.13)))
        .opacity(selected ? 1 : 0.48)
        .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(WeaveQuietStyle(cornerRadius: 18))
        .accessibilityLabel("聚焦" + (branch == .direct ? "直连" : "出口") + "流向：" + title + "，" + subtitle)
        .accessibilityValue(focus == branch ? "已聚焦，再次点按显示全部" : "未聚焦")
        .help(focus == branch ? "再次点击显示两条路径" : "点击聚焦这条路径")
    }
}
