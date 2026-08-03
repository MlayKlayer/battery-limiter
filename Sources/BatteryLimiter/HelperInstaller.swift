import BatteryLimiterShared
import Foundation

enum HelperInstallError: LocalizedError {
    case appleScriptUnavailable
    case appleScriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .appleScriptUnavailable:
            return "Could not create the install script."
        case .appleScriptFailed(let message):
            return message
        }
    }
}

/// Installs/removes the privileged LaunchDaemon that actually writes the SMC
/// keys. Runs as a one-time admin-authenticated shell script (no paid
/// Developer ID, so SMAppService.daemon()/SMJobBless are not usable here).
enum HelperInstaller {
    static let label = "com.batterylimiter.helper"
    static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    static let helperDestPath = "/Library/PrivilegedHelperTools/\(label)"

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    static func install() throws {
        let helperSrc = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/battery-limiter-helper")
            .path
        let plistTemp = try writeTempFile(plistContents, suffix: "plist")

        let script = """
        set -e
        mkdir -p \(quote(ConfigStore.directory.path))
        chown \(getuid()) \(quote(ConfigStore.directory.path))
        chmod 775 \(quote(ConfigStore.directory.path))
        mkdir -p /Library/PrivilegedHelperTools
        cp \(quote(helperSrc)) \(quote(helperDestPath))
        chown root:wheel \(quote(helperDestPath))
        chmod 755 \(quote(helperDestPath))
        cp \(quote(plistTemp)) \(quote(plistPath))
        chown root:wheel \(quote(plistPath))
        chmod 644 \(quote(plistPath))
        launchctl bootout system/\(label) 2>/dev/null || true
        launchctl bootstrap system \(quote(plistPath))
        """
        try runPrivileged(script, cleanup: [plistTemp])
    }

    static func uninstall() throws {
        let script = """
        launchctl kill TERM system/\(label) 2>/dev/null || true
        sleep 1
        launchctl bootout system/\(label) 2>/dev/null || true
        rm -f \(quote(plistPath))
        rm -f \(quote(helperDestPath))
        """
        try runPrivileged(script, cleanup: [])
    }

    private static var plistContents: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key><array><string>\(helperDestPath)</string></array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>StandardOutPath</key><string>/var/log/\(label).log</string>
            <key>StandardErrorPath</key><string>/var/log/\(label).log</string>
        </dict>
        </plist>
        """
    }

    private static func writeTempFile(_ contents: String, suffix: String) throws -> String {
        let path = "/tmp/\(label).\(UUID().uuidString).\(suffix)"
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func runPrivileged(_ shellScript: String, cleanup: [String]) throws {
        let scriptPath = try writeTempFile(shellScript, suffix: "sh")
        defer {
            try? FileManager.default.removeItem(atPath: scriptPath)
            cleanup.forEach { try? FileManager.default.removeItem(atPath: $0) }
        }

        let command = "/bin/sh \(quote(scriptPath))"
        let source = "do shell script \(appleScriptQuote(command)) with administrator privileges"
        guard let appleScript = NSAppleScript(source: source) else {
            throw HelperInstallError.appleScriptUnavailable
        }

        var errorDict: NSDictionary?
        appleScript.executeAndReturnError(&errorDict)
        if let errorDict {
            let message = errorDict[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            throw HelperInstallError.appleScriptFailed(message)
        }
    }

    private static func appleScriptQuote(_ s: String) -> String {
        "\"" + s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
