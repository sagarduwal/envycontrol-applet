#!/bin/sh
set -eu
dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
if kpackagetool6 --type Plasma/Applet --install "$dir"; then
    exit 0
fi
kpackagetool6 --type Plasma/Applet --upgrade "$dir"
