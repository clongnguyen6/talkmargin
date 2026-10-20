// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MeetingPrompter",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "MeetingPrompter", targets: ["MeetingPrompter"]),
    ],
    targets: [
        .target(name: "PrompterCore"),
        .executableTarget(name: "MeetingPrompter", dependencies: ["PrompterCore"]),
        .testTarget(name: "PrompterCoreTests", dependencies: ["PrompterCore"], resources: [.copy("Fixtures")]),
    ]
)
