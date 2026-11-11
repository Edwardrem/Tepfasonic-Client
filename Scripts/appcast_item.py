#!/usr/bin/env python3
"""Adds one release to a Sparkle appcast without signing it.

Used by the release workflow when no Sparkle private key is configured: the
app's download-only mode reads the feed and sends people to the DMG. Items
already in the feed are kept; an item with the same build number is replaced.

Environment: FEED (path), VERSION (marketing), BUILD (CFBundleVersion),
CHANNEL (stable|beta), DMG (path), GITHUB_REPOSITORY, GITHUB_REF_NAME.
"""
import email.utils
import os
import re
from xml.sax.saxutils import escape

feed = os.environ["FEED"]
version = os.environ["VERSION"]
build = os.environ["BUILD"]
channel = os.environ.get("CHANNEL", "stable")
dmg = os.environ["DMG"]
repo = os.environ["GITHUB_REPOSITORY"]
tag = os.environ["GITHUB_REF_NAME"]

download = f"https://github.com/{repo}/releases/download/{tag}/{os.path.basename(dmg)}"
release_page = f"https://github.com/{repo}/releases/tag/{tag}"

existing = open(feed, encoding="utf-8").read() if os.path.exists(feed) else ""
items = re.findall(r"<item>.*?</item>", existing, re.S)
items = ["    " + i for i in items if f"<sparkle:version>{build}</sparkle:version>" not in i]

channel_element = f"\n      <sparkle:channel>{escape(channel)}</sparkle:channel>" if channel != "stable" else ""
item = f"""    <item>
      <title>Tepfasonic {escape(version)}</title>
      <link>{escape(release_page)}</link>
      <sparkle:version>{escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>{channel_element}
      <sparkle:releaseNotesLink>{escape(release_page)}</sparkle:releaseNotesLink>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <enclosure url="{escape(download)}" length="{os.path.getsize(dmg)}" type="application/octet-stream" sparkle:version="{escape(build)}" sparkle:shortVersionString="{escape(version)}"/>
    </item>"""

body = "\n".join([item] + items)
os.makedirs(os.path.dirname(feed) or ".", exist_ok=True)
with open(feed, "w", encoding="utf-8") as out:
    out.write(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Tepfasonic</title>
    <link>https://edwardrem.github.io/Tepfasonic-Client/</link>
    <description>Tepfasonic releases</description>
    <language>en</language>
{body}
  </channel>
</rss>
""")
print(f"appcast: {feed} now has {len(items) + 1} item(s); newest {version} (build {build})")
