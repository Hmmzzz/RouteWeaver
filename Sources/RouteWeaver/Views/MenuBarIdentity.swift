import AppKit
import SwiftUI

/// The two colors identify paths; they do not claim that traffic is active.
enum MenuBarIdentity {
    static func image(direct: String?, tailscale: String?, dark: Bool) -> NSImage {
        // AppKit centers the full image in the status item. Keep the drawing
        // coordinates shared by both modes, but leave enough canvas above the
        // upper text row (which reaches 21.5 pt). The 22 pt canvas also lowers
        // the visible rows by 1 pt compared with the old 20 pt image.
        let image = NSImage(size: NSSize(width: direct == nil ? 14 : 58, height: 22), flipped: false) { _ in
            (dark ? NSColor(red: 0.43, green: 0.67, blue: 1.0, alpha: 1) : NSColor(red: 0.10, green: 0.36, blue: 0.76, alpha: 1)).setFill()
            NSBezierPath(ovalIn: NSRect(x: 3, y: 12, width: 5, height: 5)).fill()
            (dark ? NSColor(red: 0.65, green: 0.51, blue: 0.98, alpha: 1) : NSColor(red: 0.45, green: 0.32, blue: 0.77, alpha: 1)).setFill()
            NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 5, height: 5)).fill()
            if let direct, let tailscale {
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .right
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                    .foregroundColor: dark ? NSColor.white : NSColor.black,
                    .paragraphStyle: paragraph
                ]
                (direct as NSString).draw(in: NSRect(x: 12, y: 9.5, width: 43, height: 12), withAttributes: attributes)
                (tailscale as NSString).draw(in: NSRect(x: 12, y: 0, width: 43, height: 12), withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

struct MenuBarTrafficLabel: View {
    var traffic: TrafficMonitor
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        // A single image preserves the two rows when AppKit converts the label
        // into a status item; the accessibility value remains real text.
        Image(nsImage: MenuBarIdentity.image(
            direct: traffic.showsMenuBarRates ? TrafficRateFormat.compact(traffic.direct) : nil,
            tailscale: traffic.showsMenuBarRates ? TrafficRateFormat.compact(traffic.tailscale) : nil,
            dark: colorScheme == .dark
        )).renderingMode(.original)
        .help("上：国内直连；下：Tailscale。速率为每秒收发字节合计，展开可看下载和上传。")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("RouteWeaver，蓝色：国内直连；紫色：Tailscale")
        .accessibilityValue(traffic.showsMenuBarRates ? "直连 " + TrafficRateFormat.full(traffic.direct) + "，Tailscale " + TrafficRateFormat.full(traffic.tailscale) : "菜单栏速率已隐藏，展开可查看实时速率")
    }
}

enum TrafficRateFormat {
    static func compact(_ reading: TrafficRateReading) -> String {
        guard let down = reading.downloadBytesPerSecond, let up = reading.uploadBytesPerSecond,
              down.isFinite, up.isFinite, down >= 0, up >= 0 else { return "—" }
        return bytes(down + up, compact: true)
    }
    static func full(_ reading: TrafficRateReading) -> String {
        guard let down = reading.downloadBytesPerSecond, let up = reading.uploadBytesPerSecond,
              down.isFinite, up.isFinite, down >= 0, up >= 0 else { return "—" }
        return "↓ " + bytes(down, compact: false) + "  ↑ " + bytes(up, compact: false)
    }
    static func measurement(_ value: Double?) -> (value: String, unit: String) {
        guard let value, value.isFinite, value >= 0 else { return ("—", "") }
        let units = ["B/s", "KiB/s", "MiB/s", "GiB/s", "TiB/s"]
        var amount = value
        var index = 0
        while amount >= 1024 && index < units.count - 1 { amount /= 1024; index += 1 }
        return (String(format: index == 0 || amount >= 10 ? "%.0f" : "%.1f", amount), units[index])
    }
    private static func bytes(_ value: Double, compact: Bool) -> String {
        let units = compact ? ["B", "K", "M", "G", "T"] : ["B/s", "KiB/s", "MiB/s", "GiB/s", "TiB/s"]
        var amount = value
        var index = 0
        while amount >= 1024 && index < units.count - 1 { amount /= 1024; index += 1 }
        let number = String(format: index == 0 || amount >= 10 ? "%.0f" : "%.1f", amount)
        return number + (compact ? "" : " ") + units[index]
    }
}
