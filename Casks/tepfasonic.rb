# Homebrew cask template. The release workflow substitutes the version and
# checksum and pushes it to the tap repository (default Edwardrem/homebrew-tepfasonic).
cask "tepfasonic" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/Edwardrem/Tepfasonic-Client/releases/download/v#{version}/Tepfasonic-#{version}.dmg"
  name "Tepfasonic"
  desc "Free, open-source SSH client and terminal for macOS with a built-in Claude agent"
  homepage "https://edwardrem.github.io/Tepfasonic-Client/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sequoia"

  app "Tepfasonic.app"

  zap trash: [
    "~/Library/Application Support/Tepfasonic",
    "~/Library/Preferences/com.tepfasonic.client.plist",
  ]
end
