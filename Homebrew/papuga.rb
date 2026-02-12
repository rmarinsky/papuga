cask "papuga" do
  version :latest
  sha256 :no_check

  url "https://github.com/rmarinsky/papuga/releases/latest/download/Papuga-latest.dmg"
  name "Papuga"
  desc "Keyboard layout switcher for macOS — converts already-typed text between layouts"
  homepage "https://github.com/rmarinsky/papuga"

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "papuga.app"

  postflight do
    ohai "Papuga requires Accessibility and Input Monitoring permissions."
    ohai "Go to System Settings -> Privacy & Security to grant them."
  end

  zap trash: [
    "~/Library/Preferences/ua.com.rmarinsky.papuga.plist",
    "~/Library/Application Support/Papuga",
  ]
end
