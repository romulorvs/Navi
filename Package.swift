// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Navi",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Navi",
            dependencies: [],
            path: ".",
            exclude: ["build.sh", "install.sh", "README.md", "Info.plist", "LICENSE", "PrivacyInfo.xcprivacy"],
            sources: ["main.swift"],
            resources: [
                .copy("icon.png")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
