"""Find a Glyphs 4 download in Glyphs' update feed, and check its signature.

Part of the Glyphs 4 fallback in export.sh: remove both once glyphs-cli can
install Glyphs 4.

Usage:
  glyphs4_feed.py find VERSION < FEED
      Print the download URL for VERSION, `4` (the newest stable build) or a
      pinned build such as `4.1.1-4108`, then the feed's signature for that
      download on a second line, empty when the feed no longer lists it.
  glyphs4_feed.py verify FILE SIGNATURE
      Exit non-zero unless FILE matches the signature, made with Glyphs' key.

The feed is the one Glyphs 4 updates itself from (SUFeedURL in its Info.plist).
Each download carries a Sparkle EdDSA (Ed25519) signature, checked here against
the public key Glyphs 4 itself trusts (SUPublicEDKey in its Info.plist).
"""

import base64
import sys
import xml.etree.ElementTree as ET

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

DOWNLOADS = "https://updates.glyphsapp.com/"
PUBLIC_KEY = "/knL40iCECw6J8jhImfZSgN7J+0UlKLtxx1RrFqWRbQ="
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def find(version, feed):
    downloads = {}
    stable = []
    for item in ET.fromstring(feed).iter("item"):
        enclosure = item.find("enclosure")
        url = enclosure.get("url")
        downloads[url] = enclosure.get(SPARKLE + "edSignature") or ""
        if item.find(SPARKLE + "channel") is None:
            stable.append((int(item.findtext(SPARKLE + "version")), url))
    if version == "4":
        if not stable:
            sys.exit("The feed lists no stable Glyphs 4.")
        url = max(stable)[1]
    else:
        url = f"{DOWNLOADS}Glyphs{version}.zip"
    print(url)
    print(downloads.get(url, ""))


def verify(path, signature):
    key = Ed25519PublicKey.from_public_bytes(base64.b64decode(PUBLIC_KEY))
    with open(path, "rb") as download:
        data = download.read()
    try:
        key.verify(base64.b64decode(signature), data)
    except InvalidSignature:
        sys.exit("The download does not match the signature in Glyphs' update feed.")


if __name__ == "__main__":
    if sys.argv[1:2] == ["find"] and len(sys.argv) == 3:
        find(sys.argv[2], sys.stdin.read())
    elif sys.argv[1:2] == ["verify"] and len(sys.argv) == 4:
        verify(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)
