// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Advenue",
  // macOS is listed so `swift test` runs the core on a developer's machine and
  // on CI without a simulator. AdvenueCore imports only Foundation, so it also
  // builds on Linux — which is what keeps vector CI on cheap runners.
  platforms: [.iOS(.v15), .macOS(.v13)],
  products: [
    .library(name: "AdvenueCore", targets: ["AdvenueCore"]),
    .library(name: "Advenue", targets: ["Advenue"]),
    .library(name: "AdvenueFirebase", targets: ["AdvenueFirebase"]),
  ],
  dependencies: [
    // TEST ONLY. Production signing uses CryptoKit in AdvenuePlatform (plan
    // 2b); this exists so the Linux test path can verify the signing vectors
    // without anyone hand-rolling HMAC.
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
  ],
  targets: [
    .target(name: "AdvenueCore"),
    .testTarget(
      name: "AdvenueCoreTests",
      dependencies: [
        "AdvenueCore",
        .product(name: "Crypto", package: "swift-crypto"),
      ],
      resources: [.copy("vectors")]
    ),
    .target(name: "AdvenuePlatform", dependencies: ["AdvenueCore"]),
    .target(name: "Advenue", dependencies: ["AdvenueCore", "AdvenuePlatform"]),
    .target(name: "AdvenueFirebase", dependencies: ["Advenue"]),
    .testTarget(
      name: "AdvenuePlatformTests",
      dependencies: ["AdvenuePlatform", "Advenue"],
      resources: [.copy("vectors")]
    ),
  ]
)
