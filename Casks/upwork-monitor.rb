cask "upwork-monitor" do
  version "1.1"
  sha256 "64cdb9b892c6fd5ab7947de75aaf6661a6bc57765a4211937aeb401bb930dd81"

  url "https://github.com/Kgym-Hina/homebrew-upwork-monitor/releases/download/v#{version}/UpworkMonitor-#{version}.zip"
  name "Upwork Monitor"
  desc "Read Upwork job feeds and draft AI replies"
  homepage "https://github.com/Kgym-Hina/homebrew-upwork-monitor"

  depends_on macos: :sonoma

  app "UpworkMonitor.app"

  caveats do
    <<~EOS
      This app is ad-hoc signed and is not notarized with an Apple Developer ID.
      If macOS blocks the first launch, Control-click Upwork Monitor in Finder and
      choose Open, or allow it under System Settings → Privacy & Security.
    EOS
  end
end
