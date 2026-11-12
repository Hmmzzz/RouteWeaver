import Foundation
import RouteCore

/// Import, editing and export share one budget measured in the actual backup
/// format. Checking only the incoming text misses UUIDs, JSON escaping and
/// formatting added during export.
enum RulesArchive {
    static let maximumBytes = 16 * 1024 * 1024
    static let maximumRuleCount = 20_000

    static func encode(_ rules: [RouteRule]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(rules)
    }

    static func validateInput(_ text: String) throws {
        guard text.utf8.count <= maximumBytes else {
            throw AppFailure("请选择不超过 16 MiB 的 UTF-8 规则文件。支持文本或 JSON。")
        }
    }

    static func validate(_ rules: [RouteRule], replacing existing: [RouteRule]) throws {
        guard rules.count <= maximumRuleCount else { throw AppFailure("自定义规则最多 20,000 条。") }
        let size = try encode(rules).count
        guard size > maximumBytes else { return }
        // Old profiles had no note-size limit. Keep them intact and permit
        // migration by reducing content, without accepting further growth.
        if size <= (try encode(existing).count) { return }
        throw AppFailure("规则备份超过 16 MiB，未保存此更改。请减少备注或规则，确保导出的备份可以重新导入。")
    }

    static func readText(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Bound the read itself, including files that grow after selection.
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65_536, maximumBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else {
                throw AppFailure("请选择不超过 16 MiB 的 UTF-8 规则文件。支持文本或 JSON。")
            }
        }
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8) else {
            throw AppFailure("请选择不超过 16 MiB 的 UTF-8 规则文件。支持文本或 JSON。")
        }
        return text
    }

    static func migrationWarning(for text: String) -> String? {
        guard text.utf8.count > maximumBytes else { return nil }
        return "此备份保留全部旧规则，但超过 16 MiB，不能直接重新导入。请保留此完整副本，并在减少规则或备注后另存一份可导入的备份。"
    }
}
