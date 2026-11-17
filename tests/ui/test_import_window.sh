#!/bin/sh
# Opens the real "Protect all your existing keys" window with fake .env files and checks, as laid out on screen,
# that the list of projects and keys has height, every key has a row, and there's an import button.
# Runs next to an installed keydillo without touching it (no port, no control socket, no user files).
APP="${1:-$(dirname "$0")/../../App/build/Build/Products/Release/keydillo.app}"
KEYDILLO_DEV=1 "$APP/Contents/MacOS/keydillo" -kdSelfTest import
