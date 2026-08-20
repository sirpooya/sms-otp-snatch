// swift-tools-version:6.0
import PackageDescription

// Deliberately dependency-free. See CLAUDE.md security rules: this process holds
// Full Disk Access, so it links nothing it does not need and nothing networked.
let package = Package(
    name: "OTPSnatcher",
    platforms: [.macOS("14.0")],
    products: [
        .executable(name: "OTPSnatcher", targets: ["OTPSnatcher"]),
        .library(name: "OTPCore", targets: ["OTPCore"]),
    ],
    targets: [
        // Pure logic. No I/O, no permissions, no Foundation-beyond-basics.
        .target(
            name: "OTPCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // NSUnarchiver is unavailable from Swift, so the legacy typedstream
        // decode happens behind this one-function ObjC shim. See Phase 2a notes
        // in plan.md: chat.db stores attributedBody as `streamtyped`, verified
        // on macOS 26.5.
        .target(
            name: "OTPTypedStream"
        ),
        // SQLite access + body decoding.
        .target(
            name: "OTPMessages",
            dependencies: ["OTPCore", "OTPTypedStream"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "OTPSnatcher",
            dependencies: ["OTPCore", "OTPMessages"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OTPCoreTests",
            dependencies: ["OTPCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OTPMessagesTests",
            dependencies: ["OTPMessages", "OTPTypedStream"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
