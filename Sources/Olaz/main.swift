import AppKit

// `Olaz --engine-probe [login|main] [seconds]` runs the runtime harness;
// otherwise the SwiftUI app starts.
if let index = CommandLine.arguments.firstIndex(of: "--mcp-proxy"), CommandLine.arguments.indices.contains(index + 1) {
    let status = MainActor.assumeIsolated { MCPProxy.run(configurationPath: CommandLine.arguments[index + 1]) }
    exit(status)
} else if CommandLine.arguments.contains("--engine-probe") {
    MainActor.assumeIsolated {
        EngineProbe.run(arguments: Array(CommandLine.arguments.dropFirst()))
    }
} else {
    // Before anything opens cookies, WebKit storage or preferences: they are keyed by bundle id.
    MainActor.assumeIsolated { LegacyMigration.runIfNeeded() }
    OlazApp.main()
}
