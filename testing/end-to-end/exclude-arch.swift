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

// ---------------------------------------------------------------------------
// Test 1: --exclude-arch collapses a universal slice to single-arch
//
// macOS is Universal [x86_64-apple-darwin, aarch64-apple-darwin].
// Excluding x86_64-apple-darwin should collapse it to single-arch arm64.
// ---------------------------------------------------------------------------

let projectName = "excl-arch-project"
let packageName = "ExclArchProject"

print("Creating project...")
let initProc = Process()
initProc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
initProc.arguments = ["cargo", "swift", "init", projectName, "-y", "--silent"]
try! initProc.run()
initProc.waitUntilExit()
guard initProc.terminationStatus == 0 else {
    error("cargo swift init failed")
    exit(1)
}

print("Test 1: --exclude-arch collapses universal to single-arch...")
let pkg1 = Process()
pkg1.executableURL = URL(fileURLWithPath: "/usr/bin/env")
pkg1.currentDirectoryPath += "/" + projectName
pkg1.arguments = [
    "cargo", "swift", "package", "-y", "--silent",
    "-p", "macos",
    "--exclude-arch", "x86_64-apple-darwin",
]
try! pkg1.run()
pkg1.waitUntilExit()

guard pkg1.terminationStatus == 0 else {
    error("cargo swift package with --exclude-arch failed with status \(pkg1.terminationStatus)")
    exit(1)
}

// The xcframework should have a macos slice but only for arm64
let xcfPath1 = "\(projectName)/\(packageName)"
guard dirExists(atPath: xcfPath1) else {
    error("No package directory found")
    exit(1)
}

// Find the xcframework
let xcfDir1 = try! FileManager.default.contentsOfDirectory(atPath: xcfPath1)
    .first { $0.hasSuffix(".xcframework") }
guard let xcfDir1 = xcfDir1 else {
    error("No .xcframework found in package")
    exit(1)
}

let xcfFullPath1 = "\(xcfPath1)/\(xcfDir1)"
let slices1 = try! FileManager.default.contentsOfDirectory(atPath: xcfFullPath1)
    .filter { !$0.hasPrefix(".") && $0 != "Info.plist" }

// Should have exactly one slice (macOS arm64 only)
guard slices1.count == 1 else {
    error("Expected 1 slice after excluding x86_64-apple-darwin, got \(slices1.count): \(slices1)")
    exit(1)
}

// The slice name should indicate arm64 only (not universal arm64_x86_64)
let slice1 = slices1[0]
guard !slice1.contains("x86_64") else {
    error("Slice should not contain x86_64 after exclusion, got: \(slice1)")
    exit(1)
}

print("  Collapsed to single-arch slice: \(slice1)")

// Verify swift build works
let swift1 = Process()
swift1.executableURL = URL(fileURLWithPath: "/usr/bin/env")
swift1.currentDirectoryPath += "/\(projectName)/\(packageName)"
swift1.arguments = ["swift", "build"]
try! swift1.run()
swift1.waitUntilExit()
guard swift1.terminationStatus == 0 else {
    error("Swift build failed after collapse")
    exit(1)
}

print("Test 1 passed: universal slice collapsed to single-arch")

// ---------------------------------------------------------------------------
// Test 2: --exclude-arch drops a slice entirely
//
// Build for macos + ios. iOS produces two targets:
//   - ios-arm64 (Single)
//   - ios-simulator (Universal [x86_64-apple-ios, aarch64-apple-ios-sim])
//
// Excluding both simulator archs should drop the simulator slice entirely,
// leaving only macos + ios-arm64.
// ---------------------------------------------------------------------------

print("\nTest 2: --exclude-arch drops a slice when all archs excluded...")

// Clean previous output
let rmProc = Process()
rmProc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
rmProc.arguments = ["rm", "-rf", "\(projectName)/\(packageName)"]
try! rmProc.run()
rmProc.waitUntilExit()

let pkg2 = Process()
pkg2.executableURL = URL(fileURLWithPath: "/usr/bin/env")
pkg2.currentDirectoryPath += "/" + projectName
pkg2.arguments = [
    "cargo", "swift", "package", "-y", "--silent",
    "-p", "macos", "ios",
    "--exclude-arch", "x86_64-apple-ios",
    "--exclude-arch", "aarch64-apple-ios-sim",
]
try! pkg2.run()
pkg2.waitUntilExit()

guard pkg2.terminationStatus == 0 else {
    error("cargo swift package with --exclude-arch (drop slice) failed with status \(pkg2.terminationStatus)")
    exit(1)
}

let xcfDir2 = try! FileManager.default.contentsOfDirectory(atPath: xcfPath1)
    .first { $0.hasSuffix(".xcframework") }
guard let xcfDir2 = xcfDir2 else {
    error("No .xcframework found in package (test 2)")
    exit(1)
}

let xcfFullPath2 = "\(xcfPath1)/\(xcfDir2)"
let slices2 = try! FileManager.default.contentsOfDirectory(atPath: xcfFullPath2)
    .filter { !$0.hasPrefix(".") && $0 != "Info.plist" }

// Should have macOS + iOS device slices, but NO simulator slice
let hasSimulator = slices2.contains { $0.contains("simulator") }
guard !hasSimulator else {
    error("Simulator slice should have been dropped, but found: \(slices2)")
    exit(1)
}

// Should still have at least 2 slices (macOS + iOS device)
guard slices2.count >= 2 else {
    error("Expected at least 2 slices (macos + ios), got \(slices2.count): \(slices2)")
    exit(1)
}

print("  Remaining slices (no simulator): \(slices2)")

// Verify swift build works
let swift2 = Process()
swift2.executableURL = URL(fileURLWithPath: "/usr/bin/env")
swift2.currentDirectoryPath += "/\(projectName)/\(packageName)"
swift2.arguments = ["swift", "build"]
try! swift2.run()
swift2.waitUntilExit()
guard swift2.terminationStatus == 0 else {
    error("Swift build failed after dropping simulator slice")
    exit(1)
}

print("Test 2 passed: simulator slice dropped entirely")
print("\nAll --exclude-arch tests passed!")
