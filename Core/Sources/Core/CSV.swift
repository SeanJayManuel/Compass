import Foundation

/// A small CSV reader for bank and Monarch exports: quoted fields, doubled
/// quotes, newlines inside quotes, CRLF and a leading byte order mark.
struct CSV {
    struct Row {
        /// The 1-based line the row starts on, for error messages.
        var line: Int
        var fields: [String]
    }

    var header: [String]
    var rows: [Row]

    init(_ text: String) {
        var rows: [Row] = []
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        var line = 1
        var rowStart = 1
        var characters = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil
        var atStart = true

        func endRow() {
            fields.append(field)
            field = ""
            if !fields.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                rows.append(Row(line: rowStart, fields: fields))
            }
            fields = []
        }

        while let scalar = pending ?? characters.next() {
            pending = nil
            if atStart { atStart = false; if scalar == "\u{FEFF}" { continue } }
            if inQuotes {
                if scalar == "\"" {
                    let next = characters.next()
                    if next == "\"" { field.unicodeScalars.append("\"") } else { inQuotes = false; pending = next }
                } else {
                    if scalar == "\n" { line += 1 }
                    if scalar != "\r" { field.unicodeScalars.append(scalar) }
                }
                continue
            }
            switch scalar {
            // Only a quote that opens a field starts quoting; elsewhere it's text.
            case "\"" where field.isEmpty: inQuotes = true
            case ",": fields.append(field); field = ""
            case "\r": break
            case "\n":
                endRow()
                line += 1
                rowStart = line
            default: field.unicodeScalars.append(scalar)
            }
        }
        if !field.isEmpty || !fields.isEmpty { endRow() }

        header = rows.first?.fields.map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        self.rows = Array(rows.dropFirst())
    }

    /// The index of the column called `name`: an exact match (ignoring case)
    /// wins, otherwise the first header that contains it.
    func column(_ name: String) -> Int? {
        let lowered = header.map { $0.lowercased() }
        return lowered.firstIndex(of: name) ?? lowered.firstIndex { $0.contains(name) }
    }
}

enum CSVValue {
    /// "2026-10-01" (anything after a T or space is ignored), "10/1/2026" or "10/1/26".
    static func day(_ text: String) -> Day? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let datePart = trimmed.split(whereSeparator: { $0 == "T" || $0 == " " }).first.map(String.init) ?? ""
        let parts: [Int]
        let year: Int, month: Int, day: Int
        if datePart.contains("-") {
            parts = datePart.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            (year, month, day) = (parts[0], parts[1], parts[2])
        } else if datePart.contains("/") {
            parts = datePart.split(separator: "/").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            (month, day) = (parts[0], parts[1])
            year = parts[2] < 100 ? parts[2] + 2000 : parts[2]
        } else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard DateComponents(year: year, month: month, day: day).isValidDate(in: calendar) else { return nil }
        return Day(year: year, month: month, day: day)
    }

    /// "$1,234.56", "-12" or "(250.50)" for a negative. Nil for a blank cell;
    /// throws nothing, so callers decide what an unreadable amount means.
    static func amount(_ text: String) -> AmountResult {
        var cleaned = text.filter { !"$, ".contains($0) }.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return .blank }
        var negative = false
        if cleaned.hasPrefix("("), cleaned.hasSuffix(")") {
            negative = true
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        guard cleaned.wholeMatch(of: /-?\d+(\.\d+)?/) != nil,
            let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
        else { return .unreadable }
        return .value(negative ? -value : value)
    }

    enum AmountResult: Equatable {
        case value(Decimal)
        case blank
        case unreadable
    }
}
