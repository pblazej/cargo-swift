#!/usr/bin/env swift
import Foundation

func error(_ msg: String) { FileHandle.standardError.write(msg.data(using: .utf8)!) }
func dirExists(atPath path: String) -> Bool {
    var isDirectory : ObjCBool = true
    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
    return exists && isDirectory.boolValue
}
func fileExists(atPath path: String) -> Bool {
    var isDirectory : ObjCBool = true
    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
    return exists && !isDirectory.boolValue
}

let projectName = "swift-project-dynamic"
let libName = "swift_project_dynamic"
let packageName = "SwiftProjectDynamic"

// Create project
print("Creating project...")
let cargoSwiftInit = Process()
cargoSwiftInit.executableURL = URL(fileURLWithPath: "/usr/bin/env")
cargoSwiftInit.arguments = ["cargo", "swift", "init", projectName, "-y", "--silent"]
try! cargoSwiftInit.run()
cargoSwiftInit.waitUntilExit()

guard cargoSwiftInit.terminationStatus == 0 else {
    error("cargo swift init failed with status \(cargoSwiftInit.terminationStatus)")
    exit(1)
}

// Patch Cargo.toml to use cdylib
print("Patching Cargo.toml for cdylib...")
let cargoTomlPath = "\(projectName)/Cargo.toml"
var cargoToml = try! String(contentsOfFile: cargoTomlPath, encoding: .utf8)
cargoToml = cargoToml.replacingOccurrences(
    of: "crate-type = [\"staticlib\", \"lib\"]",
    with: "crate-type = [\"cdylib\", \"lib\"]"
)
try! cargoToml.write(toFile: cargoTomlPath, atomically: true, encoding: .utf8)

// Add uniffi.toml with custom ffi_module_name
print("Adding uniffi.toml with custom ffi_module_name...")
let ffiModuleName = "CustomDynFFI"
let uniffiToml = """
[bindings.swift]
ffi_module_name = "\(ffiModuleName)"
"""
FileManager.default.createFile(
    atPath: "\(projectName)/uniffi.toml",
    contents: uniffiToml.data(using: .utf8),
    attributes: nil
)

// Package as dynamic library
print("Running cargo swift package --lib-type dynamic...")
let cargoSwiftPackage = Process()
let xcFrameworkName = ffiModuleName
cargoSwiftPackage.executableURL = URL(fileURLWithPath: "/usr/bin/env")
cargoSwiftPackage.currentDirectoryPath += "/" + projectName
cargoSwiftPackage.arguments = ["cargo", "swift", "package", "-y", "--silent", "-p", "macos", "ios", "--lib-type", "dynamic"]
try! cargoSwiftPackage.run()
cargoSwiftPackage.waitUntilExit()

guard cargoSwiftPackage.terminationStatus == 0 else {
    error("cargo swift package --lib-type dynamic failed with status \(cargoSwiftPackage.terminationStatus)")
    exit(1)
}

// Verify basic package structure
guard dirExists(atPath: "\(projectName)/\(packageName)") else {
    error("No package directory (\"\(packageName)/\") found in project directory")
    exit(1)
}
guard fileExists(atPath: "\(projectName)/\(packageName)/Package.swift") else {
    error("No Package.swift file found in package directory")
    exit(1)
}
guard dirExists(atPath: "\(projectName)/\(packageName)/\(xcFrameworkName).xcframework") else {
    error("No .xcframework directory found in package directory (expected \(xcFrameworkName).xcframework)")
    exit(1)
}
guard dirExists(atPath: "\(projectName)/\(packageName)/Sources") else {
    error("No \"Sources/\" directory found in package directory")
    exit(1)
}
guard fileExists(atPath: "\(projectName)/\(packageName)/Sources/\(packageName)/\(libName).swift") else {
    error("No \(libName).swift file found in module")
    exit(1)
}

// Verify that xcframework contains .framework bundles (not bare dylibs)
let xcframeworkPath = "\(projectName)/\(packageName)/\(xcFrameworkName).xcframework"
let subframeworks = try! FileManager.default.contentsOfDirectory(atPath: xcframeworkPath)
    .filter { !$0.hasPrefix(".") && $0 != "Info.plist" }

guard !subframeworks.isEmpty else {
    error("XCFramework has no platform slices")
    exit(1)
}

for subframework in subframeworks {
    let slicePath = "\(xcframeworkPath)/\(subframework)"

    // Each slice should contain a .framework bundle
    let frameworkPath = "\(slicePath)/\(xcFrameworkName).framework"
    guard dirExists(atPath: frameworkPath) else {
        error("Expected .framework bundle at \(frameworkPath) — got bare dylib instead?")
        exit(1)
    }

    // Framework should contain the binary (renamed, no lib prefix or .dylib extension)
    guard fileExists(atPath: "\(frameworkPath)/\(xcFrameworkName)") else {
        error("No binary found at \(frameworkPath)/\(xcFrameworkName)")
        exit(1)
    }

    // Framework should contain Info.plist
    guard fileExists(atPath: "\(frameworkPath)/Info.plist") else {
        error("No Info.plist found in \(frameworkPath)")
        exit(1)
    }

    // Framework should contain Headers/
    guard dirExists(atPath: "\(frameworkPath)/Headers") else {
        error("No Headers/ directory found in \(frameworkPath)")
        exit(1)
    }

    // Headers should contain the header file
    guard fileExists(atPath: "\(frameworkPath)/Headers/\(xcFrameworkName).h") else {
        error("No \(xcFrameworkName).h found in \(frameworkPath)/Headers/")
        exit(1)
    }

    // Framework should contain Modules/module.modulemap
    guard dirExists(atPath: "\(frameworkPath)/Modules") else {
        error("No Modules/ directory found in \(frameworkPath)")
        exit(1)
    }
    guard fileExists(atPath: "\(frameworkPath)/Modules/module.modulemap") else {
        error("No module.modulemap found in \(frameworkPath)/Modules/")
        exit(1)
    }

    print("  \(subframework): .framework bundle structure verified")
}

// Verify install_name_tool set the correct rpath
print("Checking install name on framework binaries...")
for subframework in subframeworks {
    let binaryPath = "\(xcframeworkPath)/\(subframework)/\(xcFrameworkName).framework/\(xcFrameworkName)"
    let otool = Process()
    let pipe = Pipe()
    otool.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    otool.arguments = ["otool", "-D", binaryPath]
    otool.standardOutput = pipe
    try! otool.run()
    otool.waitUntilExit()

    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let expectedId = "@rpath/\(xcFrameworkName).framework/\(xcFrameworkName)"
    guard output.contains(expectedId) else {
        error("Binary install name should contain \(expectedId), got:\n\(output)")
        exit(1)
    }
    print("  \(subframework): install name OK")
}

// Build the Swift package to verify it links correctly
print("Building Swift package...")
let swift = Process()
swift.executableURL = URL(fileURLWithPath: "/usr/bin/env")
swift.currentDirectoryPath += "/\(projectName)/\(packageName)"
swift.arguments = ["swift", "build"]
try! swift.run()
swift.waitUntilExit()

guard swift.terminationStatus == 0 else {
    error("Swift build failed")
    exit(1)
}

print("Tests for cargo swift package --lib-type dynamic passed!")
