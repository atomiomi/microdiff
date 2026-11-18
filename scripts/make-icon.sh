#!/bin/bash
# Rebuilds Resources/AppIcon.icns from the two 1024 px pictures exported from Figma:
#   Resources/AppIcon/AppIcon-1024.png        the icon as designed
#   Resources/AppIcon/AppIcon-small-1024.png  same tile with a bigger mark, used for the 16 and 32 px sizes
#   scripts/make-icon.sh
set -euo pipefail
cd "$(dirname "$0")/.."

BIG="Resources/AppIcon/AppIcon-1024.png"
SMALL="Resources/AppIcon/AppIcon-small-1024.png"
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"

# name, pixel size, source
while read -r name size source; do
  sips -z "$size" "$size" "$source" --out "$SET/$name" >/dev/null
done <<EOF
icon_16x16.png 16 $SMALL
icon_16x16@2x.png 32 $SMALL
icon_32x32.png 32 $SMALL
icon_32x32@2x.png 64 $BIG
icon_128x128.png 128 $BIG
icon_128x128@2x.png 256 $BIG
icon_256x256.png 256 $BIG
icon_256x256@2x.png 512 $BIG
icon_512x512.png 512 $BIG
icon_512x512@2x.png 1024 $BIG
EOF

iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "Resources/AppIcon.icns"
