#if canImport(UIKit)
import UIKit
import ObjectiveC.runtime
import Darwin
import MachO
#if !VOLY_UNIFIED_BUILD
import VolyModels
#endif

/// Finds the app-defined classes behind a selection and describes each one
/// in terms the host can look up in debug info: the binary image that
/// defines it and where its methods sit inside that image.
///
/// The agent never guesses file names or lines. It reports addresses; the
/// host asks the image's debug info what source they came from.
@MainActor
enum SourceCandidateResolver {
    private static let maxProbes = 24

    static func candidates(for object: AnyObject) -> [SourceCandidate] {
        var result: [SourceCandidate] = []
        var seen = Set<String>()
        func add(_ cls: AnyClass?, role: SourceCandidate.Role) {
            guard let cls, let candidate = candidate(for: cls, role: role),
                  seen.insert(candidate.runtimeName).inserted
            else { return }
            result.append(candidate)
        }

        let dynamicClass: AnyClass = type(of: object)
        let own: AnyClass? = firstAppDefinedClass(from: dynamicClass, stoppingAt: stopClass(for: object))
        add(own, role: own == dynamicClass ? .viewClass : .superclass)

        if let view = object as? UIView {
            // The controller that owns the view, then controllers containing
            // it — a plain UILabel usually leads to "the screen it's on".
            var controller = view.volyOwningVC
            while let current = controller {
                add(firstAppDefinedClass(from: type(of: current), stoppingAt: UIViewController.self),
                    role: .viewController)
                controller = current.parent
            }
            var ancestor = view.superview
            while let current = ancestor {
                add(firstAppDefinedClass(from: type(of: current), stoppingAt: UIView.self), role: .ancestorView)
                ancestor = current.superview
            }
        }
        return result
    }

    private static func stopClass(for object: AnyObject) -> AnyClass {
        if object is UIView { return UIView.self }
        if object is UIViewController { return UIViewController.self }
        return NSObject.self
    }

    private static func firstAppDefinedClass(from start: AnyClass, stoppingAt stop: AnyClass) -> AnyClass? {
        var cls: AnyClass? = start
        while let current = cls, current != stop {
            if isAppDefined(current) { return current }
            cls = class_getSuperclass(current)
        }
        return nil
    }

    /// App-defined == its image lives inside the app bundle (the executable,
    /// its debug dylib, embedded frameworks). System frameworks and the
    /// Voly agent itself are outside it.
    private static func isAppDefined(_ cls: AnyClass) -> Bool {
        guard let image = imagePath(of: cls) else { return false }
        return image.hasPrefix(appRoot)
    }

    private static let appRoot: String = {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return path.hasSuffix("/") ? path : path + "/"
    }()

    private static func imagePath(of cls: AnyClass) -> String? {
        guard let name = class_getImageName(cls) else { return nil }
        return URL(fileURLWithPath: String(cString: name)).resolvingSymlinksInPath().path
    }

    private static func candidate(for cls: AnyClass, role: SourceCandidate.Role) -> SourceCandidate? {
        guard let rawImage = class_getImageName(cls) else { return nil }
        let imageName = String(cString: rawImage)
        let reflected = String(reflecting: cls)
        let parts = reflected.split(separator: ".")
        let module = parts.dropLast().joined(separator: ".")
        return SourceCandidate(
            role: role,
            className: parts.last.map(String.init) ?? reflected,
            moduleName: module.isEmpty ? nil : module,
            runtimeName: NSStringFromClass(cls),
            imagePath: imageName,
            imageUUID: MachOImages.uuid(forImageNamed: imageName),
            probes: probes(for: cls, imageName: imageName)
        )
    }

    /// Offsets of the class's own method implementations inside its image.
    /// Lifecycle and initializer entry points come first: they exist on
    /// nearly every view/controller and are what a developer wants to land on.
    private static func probes(for cls: AnyClass, imageName: String) -> [SourceCandidate.Probe] {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(cls, &count) else { return [] }
        defer { free(methods) }

        var found: [SourceCandidate.Probe] = []
        for index in 0..<Int(count) {
            let method = methods[index]
            let implementation = unsafeBitCast(method_getImplementation(method), to: UnsafeRawPointer.self)
            var info = Dl_info()
            guard dladdr(implementation, &info) != 0,
                  let base = info.dli_fbase, let file = info.dli_fname,
                  String(cString: file) == imageName
            else { continue }   // inherited, swizzled or trampoline IMP
            let offset = UInt(bitPattern: implementation) - UInt(bitPattern: base)
            found.append(.init(selector: NSStringFromSelector(method_getName(method)), imageOffset: UInt64(offset)))
        }
        return Array(found.sorted { priority($0.selector) < priority($1.selector) }.prefix(maxProbes))
    }

    private static func priority(_ selector: String) -> Int {
        if selector.hasPrefix("init") { return 0 }
        if selector == "viewDidLoad" || selector == "loadView" || selector == "awakeFromNib" { return 1 }
        if selector == "layoutSubviews" || selector.hasPrefix("drawRect") || selector.hasPrefix("viewWill") { return 2 }
        if selector.hasPrefix(".") { return 4 }   // .cxx_destruct and friends
        return 3
    }
}

/// Minimal Mach-O lookups against the images loaded in this process.
enum MachOImages {
    static func uuid(forImageNamed name: String) -> String? {
        for index in 0..<_dyld_image_count() {
            guard let rawName = _dyld_get_image_name(index), String(cString: rawName) == name,
                  let header = _dyld_get_image_header(index)
            else { continue }
            return uuid(of: header)
        }
        return nil
    }

    private static func uuid(of header: UnsafePointer<mach_header>) -> String? {
        guard header.pointee.magic == MH_MAGIC_64 else { return nil }
        var cursor = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let command = cursor.assumingMemoryBound(to: load_command.self).pointee
            if command.cmd == UInt32(LC_UUID) {
                let uuid = cursor.assumingMemoryBound(to: uuid_command.self).pointee.uuid
                return UUID(uuid: uuid).uuidString
            }
            cursor = cursor.advanced(by: Int(command.cmdsize))
        }
        return nil
    }
}
#endif
