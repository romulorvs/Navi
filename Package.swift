// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Navi",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "Navi",
            path: ".",
            exclude: ["Info.plist", "build.sh", "install.sh", "README.md"],
            sources: ["main.swift"],
            resources: [
                .copy("icon.png")
            ]
        )
    ]
)
