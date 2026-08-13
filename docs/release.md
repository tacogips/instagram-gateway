# Release

Release packaging is documented but not automated in this implementation.

Expected Homebrew-style artifacts:

- `instagram-gateway-reader-darwin-arm64.tar.gz`
- `instagram-gateway-reader-darwin-x64.tar.gz`
- `instagram-gateway-writer-darwin-arm64.tar.gz`
- `instagram-gateway-writer-darwin-x64.tar.gz`

Minimum release checklist:

```bash
swift build -c release
swift test
swift run instagram-gateway-reader --help
swift run instagram-gateway-writer --help
```

Formula checks when scripts are added:

```bash
ruby -c Formula/instagram-gateway-reader.rb
ruby -c Formula/instagram-gateway-writer.rb
brew audit --strict --formula tacogips/tap/instagram-gateway-reader
brew audit --strict --formula tacogips/tap/instagram-gateway-writer
```
