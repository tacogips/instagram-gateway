import InstagramGatewayCLI

await InstagramGatewayCLI.run(binary: .reader, arguments: Array(CommandLine.arguments.dropFirst()))
