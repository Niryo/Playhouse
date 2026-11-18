import Darwin
import Foundation

@main
enum PlayhouseCLI {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments == ["help"] || arguments == ["--help"] || arguments == ["-h"] {
            print(helpText)
            return
        }

        // Claude Code's read-only side chat hook: answered here, without the daemon, for each tool call.
        if arguments == SideChatReadOnlyPolicy.hookSubcommand {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            let cliPaths = [CommandLine.arguments[0]] + (Bundle.main.executableURL.map { [$0.path] } ?? [])
            if let output = SideChatReadOnlyPolicy.hookOutput(for: input, cliPaths: cliPaths) {
                FileHandle.standardOutput.write(output)
            }
            return
        }

        do {
            if let local = try runLocally(arguments) {
                printResponse(local)
                if !local.ok { exit(exitStatus(for: local.error?.code)) }
                return
            }
        } catch {
            let invalid = BridgeRequest(command: "invalid")
            printResponse(.failure(invalid, code: "invalid_argument", message: error.localizedDescription))
            exit(2)
        }

        let request: BridgeRequest
        do {
            request = try parse(arguments)
        } catch {
            let invalid = BridgeRequest(command: "invalid")
            printResponse(.failure(invalid, code: "invalid_argument", message: error.localizedDescription))
            exit(2)
        }

        let configuredRequest = request.configuredForCaller()

        do {
            let response = try BridgeClient().send(configuredRequest) { event in
                printJSON(event)
            }
            printResponse(response)
            guard response.ok else { exit(exitStatus(for: response.error?.code)) }
            // A plugin that renders with errors still answers with the full report, but fails the process.
            if configuredRequest.command == "plugin.render",
               case .array(let errors)? = response.result?.object?["errors"], !errors.isEmpty {
                exit(1)
            }
        } catch {
            let unavailable = BridgeResponse.failure(
                configuredRequest,
                code: "service_unavailable",
                message: error.localizedDescription
            )
            printResponse(unavailable)
            exit(69)
        }
    }



}
