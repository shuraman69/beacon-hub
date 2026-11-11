import Foundation

/// Запуск внешних утилит (security, glab) без блокировки main thread.
enum Shell {
    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: String
        var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    }

    /// Каталоги, где обычно лежат CLI. У GUI-приложений PATH урезанный, поэтому добавляем их явно.
    static let searchPaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "/run/current-system/sw/bin", "/usr/bin", "/bin"]
    }()

    static func which(_ tool: String) -> String? {
        searchPaths
            .map { "\($0)/\(tool)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 20) async throws -> Result {
        try await withCheckedThrowingContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (searchPaths + [env["PATH"] ?? ""]).joined(separator: ":")
            process.environment = env
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().async {
                let o = out.fileHandleForReading.readDataToEndOfFile()
                let e = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                cont.resume(returning: Result(status: process.terminationStatus,
                                              stdout: o,
                                              stderr: String(decoding: e, as: UTF8.self)))
            }
        }
    }
}

enum Log {
    static func info(_ message: @autoclosure () -> String) {
        FileHandle.standardError.write(Data("[BeaconHub] \(message())\n".utf8))
    }
}
