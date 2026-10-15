cask "upwork-monitor" do
  version "1.0"
  sha256 "94f7ed5f98f05af4c006be047dfcf7e291775062c99caf5c2b750d2d677728cc"

  url "https://github.com/Kgym-Hina/homebrew-upwork-monitor/releases/download/v#{version}/UpworkMonitor-#{version}.zip"
  name "Upwork Monitor"
  desc "Read Upwork job feeds and draft AI replies"
  homepage "https://github.com/Kgym-Hina/homebrew-upwork-monitor"

  depends_on macos: ">= :sonoma"

  app "UpworkMonitor.app"

  caveats do
    <<~EOS
      This app is ad-hoc signed and is not notarized with an Apple Developer ID.
      If macOS blocks the first launch, Control-click Upwork Monitor in Finder and
      choose Open, or allow it under System Settings → Privacy & Security.
    EOS
  end
end
