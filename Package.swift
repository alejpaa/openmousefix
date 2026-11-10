// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenMouseFix",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "OpenMouseFix",
            path: "Sources/OpenMouseFix",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
