import InstagramGatewayCLI

await InstagramGatewayCLI.run(binary: .writer, arguments: Array(CommandLine.arguments.dropFirst()))
