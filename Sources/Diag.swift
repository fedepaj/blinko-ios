import Foundation

/// Appends diagnostic lines to Documents/rslog_diag.txt (readable from the Mac with devicectl).
enum Diag {
    private static let url: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return d.appendingPathComponent("rslog_diag.txt")
    }()
    private static let queue = DispatchQueue(label: "rslog.diag")
    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

    static func log(_ s: String) {
        print(s)
        let line = "\(fmt.string(from: Date())) \(s)\n"
        queue.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
