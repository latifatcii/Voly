import Foundation
import VolyModels

/// What debug info says about one address inside a binary image.
public struct SymbolicatedProbe: Codable, Equatable, Sendable {
    public let offset: UInt64
    public let symbol: String?
    public let file: String?
    public let line: Int?

    public init(offset: UInt64, symbol: String?, file: String?, line: Int?) {
        self.offset = offset
        self.symbol = symbol
        self.file = file
        self.line = line
    }
}

public struct SymbolicatedImage: Codable, Equatable, Sendable {
    public let path: String
    public let uuid: String?
    /// Zero means the image (and any dSYM / object files LLDB could find for
    /// it) carries no debug info.
    public let compileUnits: Int?
    public let error: String?
    public let probes: [SymbolicatedProbe]

    public init(path: String, uuid: String?, compileUnits: Int?, error: String?, probes: [SymbolicatedProbe]) {
        self.path = path
        self.uuid = uuid
        self.compileUnits = compileUnits
        self.error = error
        self.probes = probes
    }
}

public protocol Symbolicating: Sendable {
    /// Resolve image-relative offsets to symbols and line-table entries.
    func symbolicate(_ requests: [String: [UInt64]]) async throws -> [SymbolicatedImage]
}

/// Line-table lookups through LLDB's scripting API (`SBTarget`, `SBModule`,
/// `SBSymbolContext`, `SBLineEntry`, `SBCompileUnit`).
///
/// Runs a throw-away `lldb --batch` that only *creates targets from files on
/// disk*. It never attaches to a process, so an Xcode debug session on the
/// same app is not touched or even noticed. Using Xcode's own `lldb` means
/// dSYMs, debug-map object files and Swift symbols are found the same way
/// the debugger finds them, and there is no private framework to link.
public struct LLDBSymbolicator: Symbolicating {
    public enum SymbolicationError: Error, Equatable, LocalizedError {
        case lldbFailed(code: Int32, output: String)
        case malformedOutput

        public var errorDescription: String? {
            switch self {
            case .lldbFailed(let code, let output):
                return "lldb exited with \(code): \(output)"
            case .malformedOutput:
                return "Could not read lldb's symbol lookup output."
            }
        }
    }

    static let beginMarker = "<<<VOLY_SOURCE_JSON"
    static let endMarker = "VOLY_SOURCE_JSON>>>"
    private static let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")

    private let shell: ShellExecutor

    public init(shell: ShellExecutor = SystemShellExecutor()) {
        self.shell = shell
    }

    public func symbolicate(_ requests: [String: [UInt64]]) async throws -> [SymbolicatedImage] {
        guard !requests.isEmpty else { return [] }
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("voly-lldb-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        // The module name doubles as the script file name.
        let script = workDir.appendingPathComponent("voly_source_lookup.py")
        try Self.script.write(to: script, atomically: true, encoding: .utf8)
        let request = workDir.appendingPathComponent("request.json")
        let images = requests.sorted { $0.key < $1.key }.map { ["path": $0.key, "offsets": $0.value] as [String: Any] }
        try JSONSerialization.data(withJSONObject: ["images": images]).write(to: request)

        let result = try await shell.run(
            executable: Self.xcrun,
            arguments: [
                "lldb", "--batch", "--no-lldbinit",
                "-o", "command script import \"\(script.path)\"",
                "-o", "voly_source_lookup \"\(request.path)\"",
            ],
            environment: nil
        )
        let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
        guard result.exitCode == 0 else {
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            throw SymbolicationError.lldbFailed(
                code: result.exitCode,
                output: String((stderr.isEmpty ? stdout : stderr).suffix(400))
            )
        }
        return try Self.parse(output: stdout)
    }

    static func parse(output: String) throws -> [SymbolicatedImage] {
        guard let begin = output.range(of: beginMarker),
              let end = output.range(of: endMarker, range: begin.upperBound..<output.endIndex)
        else { throw SymbolicationError.malformedOutput }
        struct Envelope: Decodable { let images: [SymbolicatedImage] }
        let json = output[begin.upperBound..<end.lowerBound]
        do {
            return try JSONDecoder().decode(Envelope.self, from: Data(json.utf8)).images
        } catch {
            throw SymbolicationError.malformedOutput
        }
    }

    /// Static lookups only: create a target per image, resolve each offset to
    /// its symbol and that symbol's first line-table row.
    static let script = #"""
    import json
    import lldb

    def _line(address):
        entry = address.GetLineEntry()
        if not entry.IsValid():
            return None, 0
        spec = entry.GetFileSpec()
        path = spec.fullpath if spec.IsValid() else None
        return path, entry.GetLine()

    def _lookup(target, module, base, offset):
        hit = {"offset": offset, "symbol": None, "file": None, "line": None}
        address = module.ResolveFileAddress(base + offset)
        if not address.IsValid():
            return hit
        context = address.GetSymbolContext(lldb.eSymbolContextEverything)
        symbol = context.GetSymbol()
        if not symbol.IsValid():
            return hit
        name = symbol.GetName()
        mangled = symbol.GetMangledName() or ""
        path, line = _line(symbol.GetStartAddress())
        # A Swift "@objc" thunk is compiler-generated and has no source line;
        # the method it forwards to is the same mangled name without "To".
        if mangled.endswith("To") and not line:
            matches = target.FindSymbols(mangled[:-2])
            for index in range(matches.GetSize()):
                real = matches.GetContextAtIndex(index).GetSymbol()
                real_path, real_line = _line(real.GetStartAddress())
                if real_line:
                    name, path, line = real.GetName(), real_path, real_line
                    break
        if not line:
            path = None
        hit.update({"symbol": name, "file": path, "line": line or None})
        return hit

    def voly_source_lookup(debugger, command, result, internal_dict):
        with open(command.strip().strip('"')) as handle:
            request = json.load(handle)
        scratch = lldb.SBDebugger.Create()
        scratch.SetAsync(False)
        images = []
        for image in request["images"]:
            entry = {"path": image["path"], "uuid": None, "compileUnits": None, "error": None, "probes": []}
            error = lldb.SBError()
            target = scratch.CreateTarget(image["path"], None, None, False, error)
            if not target or not target.IsValid() or target.GetNumModules() == 0:
                entry["error"] = error.GetCString() or "could not open image"
                images.append(entry)
                continue
            module = target.GetModuleAtIndex(0)
            entry["uuid"] = module.GetUUIDString()
            entry["compileUnits"] = module.GetNumCompileUnits()
            base = module.GetObjectFileHeaderAddress().GetFileAddress()
            for offset in image["offsets"]:
                entry["probes"].append(_lookup(target, module, base, offset))
            scratch.DeleteTarget(target)
            images.append(entry)
        lldb.SBDebugger.Destroy(scratch)
        print("<<<VOLY_SOURCE_JSON")
        print(json.dumps({"images": images}))
        print("VOLY_SOURCE_JSON>>>")

    def __lldb_init_module(debugger, internal_dict):
        debugger.HandleCommand("command script add -f voly_source_lookup.voly_source_lookup voly_source_lookup")
    """#
}
