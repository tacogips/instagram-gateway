// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "instagram-gateway",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "InstagramGatewayCore", targets: ["InstagramGatewayCore"]),
    .executable(name: "instagram-gateway-reader", targets: ["InstagramGatewayReader"]),
    .executable(name: "instagram-gateway-writer", targets: ["InstagramGatewayWriter"])
  ],
  targets: [
    .target(name: "InstagramGatewayCore"),
    .target(
      name: "InstagramGatewayCLI",
      dependencies: ["InstagramGatewayCore"]
    ),
    .executableTarget(
      name: "InstagramGatewayReader",
      dependencies: ["InstagramGatewayCLI"]
    ),
    .executableTarget(
      name: "InstagramGatewayWriter",
      dependencies: ["InstagramGatewayCLI"]
    ),
    .testTarget(
      name: "InstagramGatewayCoreTests",
      dependencies: ["InstagramGatewayCore"],
      resources: [.copy("../Fixtures")]
    ),
    .testTarget(
      name: "InstagramGatewayCLITests",
      dependencies: ["InstagramGatewayCore", "InstagramGatewayCLI"]
    )
  ],
  swiftLanguageModes: [.v6]
)
