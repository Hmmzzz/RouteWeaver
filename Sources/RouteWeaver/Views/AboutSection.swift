import SwiftUI

/// Public attribution only; never derives an author from the local account.
struct AboutSection: View {
    let version: String
    let author: String
    let authorURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("关于", systemImage: "info.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(WeaveStyle.accent)

            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(WeaveStyle.accent)
                    .frame(width: 44, height: 44)
                    .background(WeaveStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("RouteWeaver").font(.system(size: 17, weight: .semibold))
                    Text("版本 \(version) · 原生 macOS IPv4 分流")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 24) {
                Text("作者").foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                if let authorURL {
                    Link(author, destination: authorURL).tint(WeaveStyle.accent)
                } else {
                    Text(author).textSelection(.enabled)
                }
            }
            .font(.system(size: 13))

            HStack(alignment: .firstTextBaseline, spacing: 24) {
                Text("许可").foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                Text("MIT · 第三方数据保留各自许可")
            }
            .font(.system(size: 13))

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("致谢").font(.system(size: 13, weight: .semibold))
                credit("分流实现参考", links: "[leolovenet / tailscale-routes](https://github.com/leolovenet/tailscale-routes)")
                credit("数据来源", links: "[APNIC](https://ftp.apnic.net/stats/apnic/) · [domain-list-community](https://github.com/v2fly/domain-list-community) · [Public Suffix List](https://publicsuffix.org/list/)")
                credit("界面与交互参考", links: "[Stats](https://github.com/exelban/stats) · [Ice](https://github.com/jordanbaird/Ice) · [CodeEdit](https://github.com/CodeEditApp/CodeEdit) · [Xcodes](https://github.com/XcodesOrg/XcodesApp) · [Pearcleaner](https://github.com/alienator88/Pearcleaner)")
                credit("技术与数据研究", links: "[Apple XNU](https://github.com/apple-oss-distributions/xnu) · [configd](https://github.com/apple-oss-distributions/configd) · [china-operator-ip](https://github.com/gaoyifan/china-operator-ip)")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WeaveStyle.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(WeaveStyle.stroke))
    }

    private func credit(_ title: String, links: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(.init(links))
                .font(.system(size: 12))
                .tint(WeaveStyle.accent)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
