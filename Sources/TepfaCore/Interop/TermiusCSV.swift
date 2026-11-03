import Foundation

/// Hosts from a Termius CSV export (and similar spreadsheets). Columns are
/// found by header name, so the exact column order does not matter.
public enum TermiusCSV {
    public enum Error: LocalizedError {
        case noHostnameColumn([String])

        public var errorDescription: String? {
            switch self {
            case .noHostnameColumn(let headers):
                "No hostname column found. Headers: \(headers.joined(separator: ", "))"
            }
        }
    }

    private static let nameHeaders = ["label", "name", "title", "alias", "host label"]
    private static let hostnameHeaders = ["hostname/ip", "hostname", "host", "address", "ip", "ip address", "hostname or ip"]
    private static let portHeaders = ["port"]
    private static let userHeaders = ["username", "user", "login"]
    private static let groupHeaders = ["groups", "group", "folder", "parent group"]
    private static let tagHeaders = ["tags", "tag"]
    private static let protocolHeaders = ["protocol", "type"]

    public static func document(from text: String, tag: String = "termius") throws -> TepfaDocument {
        let rows = CSV.parse(text)
        guard let header = rows.first else { return TepfaDocument() }
        let headers = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func column(_ candidates: [String]) -> Int? {
            for candidate in candidates { if let index = headers.firstIndex(of: candidate) { return index } }
            return nil
        }
        guard let hostnameColumn = column(hostnameHeaders) else { throw Error.noHostnameColumn(header) }
        let nameColumn = column(nameHeaders)
        let portColumn = column(portHeaders)
        let userColumn = column(userHeaders)
        let groupColumn = column(groupHeaders)
        let tagColumn = column(tagHeaders)
        let protocolColumn = column(protocolHeaders)

        var document = TepfaDocument()
        var groups: [String: UUID] = [:]
        for row in rows.dropFirst() {
            func value(_ index: Int?) -> String? {
                guard let index, index < row.count else { return nil }
                let trimmed = row[index].trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            guard let hostname = value(hostnameColumn) else { continue }
            if let proto = value(protocolColumn)?.lowercased(), !proto.isEmpty, proto != "ssh" { continue }
            let name = value(nameColumn) ?? hostname
            var groupID: UUID?
            if let groupPath = value(groupColumn) {
                // Termius writes nested groups as "Parent/Child"; keep the leaf.
                let leaf = groupPath.split(whereSeparator: { $0 == "/" || $0 == ">" }).last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? groupPath
                if let existing = groups[leaf] {
                    groupID = existing
                } else {
                    let id = UUID.stable("\(tag)-group:\(leaf)")
                    groups[leaf] = id
                    document.groups.append(.init(id: id, name: leaf, sortOrder: document.groups.count))
                    groupID = id
                }
            }
            var tags = [tag]
            if let tagText = value(tagColumn) {
                tags += tagText.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "|" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            document.hosts.append(.init(
                id: UUID.stable("\(tag):\(name)@\(hostname)"),
                name: name,
                hostname: hostname,
                port: value(portColumn).flatMap { Int($0) } ?? 22,
                username: value(userColumn) ?? NSUserName(),
                tags: tags,
                sortOrder: document.hosts.count,
                groupID: groupID))
        }
        return document
    }
}
