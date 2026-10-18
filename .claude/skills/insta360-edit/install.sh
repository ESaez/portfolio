#!/usr/bin/env bash
# Installs the insta360-edit skill and its base, ffmpeg-skill, into ~/.claude/skills.
#
#   ./install.sh                 macOS: checks Homebrew + ffmpeg, installs everything, runs a self-test
#   ./install.sh --link          symlink this folder instead of copying it (for development)
#   ./install.sh --no-vision     skip the Apple Vision tracker's Python environment
#   ./install.sh --no-brew       don't touch Homebrew (ffmpeg must already be on PATH; used on Linux/CI)
#   ./install.sh --force         re-download ffmpeg-skill even if the pinned version is installed
#   ./install.sh --skip-selftest
#
# Idempotent, never needs sudo, never deletes anything it did not install.
set -euo pipefail

FFMPEG_SKILL_VERSION="2.10.4"
FFMPEG_SKILL_SRI="sha512-1SLGwNOFwNtrpewhmn84bGDIesbvxNteMfzBln/MqTXeGhWRJPxpgMhxlTDgmLdBlm3akUr6UglgdwI7mf5+DQ=="
FFMPEG_SKILL_URL="https://registry.npmjs.org/ffmpeg-skill/-/ffmpeg-skill-${FFMPEG_SKILL_VERSION}.tgz"

SKILLS="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
HERE="$(cd "$(dirname "$0")" && pwd -P)"
DEST="$SKILLS/insta360-edit"
MARKER=".insta360-edit-managed"

LINK=0; WITH_VISION=1; USE_BREW=1; FORCE=0; SELFTEST=1
for arg in "$@"; do
	case "$arg" in
		--link) LINK=1 ;;
		--no-vision) WITH_VISION=0 ;;
		--no-brew) USE_BREW=0 ;;
		--force) FORCE=1 ;;
		--skip-selftest) SELFTEST=0 ;;
		-h|--help) sed -n '2,12p' "$0"; exit 0 ;;
		*) echo "unknown option: $arg" >&2; exit 2 ;;
	esac
done

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ] && [ "${INSTA360_ALLOW_ROOT:-0}" != 1 ]; then
	fail "run this as your normal user, not root (set INSTA360_ALLOW_ROOT=1 in a throwaway container)"
fi
OS="$(uname -s)"
[ "$OS" = "Darwin" ] || WITH_VISION=0

# --- ffmpeg ------------------------------------------------------------------------------
if [ "$USE_BREW" = 1 ] && [ "$OS" = "Darwin" ]; then
	BREW="$(command -v brew || true)"
	[ -z "$BREW" ] && [ -x /opt/homebrew/bin/brew ] && BREW=/opt/homebrew/bin/brew
	[ -z "$BREW" ] && fail "Homebrew is not installed. Get it from https://brew.sh and run this again."
	if ! command -v ffmpeg >/dev/null 2>&1 && ! [ -x /opt/homebrew/bin/ffmpeg ]; then
		say "Installing ffmpeg with Homebrew (this takes a few minutes)"
		"$BREW" install ffmpeg
	fi
	case ":$PATH:" in *":/opt/homebrew/bin:"*) ;; *) export PATH="/opt/homebrew/bin:$PATH" ;; esac
fi
command -v ffmpeg >/dev/null 2>&1 || fail "ffmpeg is not on PATH (macOS: brew install ffmpeg; Linux: apt install ffmpeg)"
command -v ffprobe >/dev/null 2>&1 || fail "ffprobe is not on PATH"

say "Checking ffmpeg $(ffmpeg -version 2>/dev/null | head -1 | awk '{print $3}')"
FILTERS="$(ffmpeg -hide_banner -filters 2>/dev/null | awk '{print $2}')"
for f in v360 sendcmd xfade acrossfade drawtext drawgrid hstack tile loudnorm sidechaincompress ebur128; do
	printf '%s\n' "$FILTERS" | grep -qx "$f" || fail "this ffmpeg build lacks the '$f' filter; install Homebrew's ffmpeg"
done
ffmpeg -hide_banner -encoders 2>/dev/null | awk '{print $2}' | grep -qx libx264 || fail "this ffmpeg build lacks libx264"

# --- python --------------------------------------------------------------------------------
PY="$(command -v python3 || true)"
[ -z "$PY" ] && fail "python3 is not installed (macOS: brew install python)"
if [ "$OS" = "Darwin" ] && [ "$PY" = "/usr/bin/python3" ] && ! xcode-select -p >/dev/null 2>&1; then
	fail "/usr/bin/python3 needs the Xcode Command Line Tools: run 'xcode-select --install'"
fi
PYVER="$("$PY" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
"$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' || fail "python3 $PYVER is too old (need 3.9+)"

# --- ffmpeg-skill (pinned, checksum-verified; no Node needed) -------------------------------
mkdir -p "$SKILLS"
BASE="$SKILLS/ffmpeg-skill"
BASE_MARK="$BASE/.insta360-edit-installed"
if [ "$FORCE" = 1 ] || [ "$(cat "$BASE_MARK" 2>/dev/null || true)" != "$FFMPEG_SKILL_SRI" ]; then
	if [ -d "$BASE" ] && [ ! -f "$BASE_MARK" ]; then
		fail "$BASE exists but was not installed by this script; move it away or delete it, then run again"
	fi
	say "Downloading ffmpeg-skill $FFMPEG_SKILL_VERSION"
	TMP="$(mktemp -d "${TMPDIR:-/tmp}/ffmpeg-skill.XXXXXX")"
	trap 'rm -rf "$TMP"' EXIT
	curl -fsSL --retry 3 --connect-timeout 20 -o "$TMP/pkg.tgz" "$FFMPEG_SKILL_URL"
	GOT="$("$PY" -c 'import sys, hashlib, base64; print("sha512-" + base64.b64encode(hashlib.sha512(open(sys.argv[1], "rb").read()).digest()).decode())' "$TMP/pkg.tgz")"
	[ "$GOT" = "$FFMPEG_SKILL_SRI" ] || fail "ffmpeg-skill download does not match the pinned checksum ($GOT)"
	tar -xzf "$TMP/pkg.tgz" -C "$TMP"
	[ -f "$TMP/package/SKILL.md" ] && [ -d "$TMP/package/scripts" ] || fail "unexpected ffmpeg-skill package layout"
	rm -rf "$BASE"
	mv "$TMP/package" "$BASE"
	printf '%s' "$FFMPEG_SKILL_SRI" > "$BASE_MARK"
else
	say "ffmpeg-skill $FFMPEG_SKILL_VERSION already installed"
fi

# --- this skill ----------------------------------------------------------------------------
if [ "$HERE" = "$DEST" ]; then
	say "insta360-edit is already in place at $DEST"
else
	if [ -e "$DEST" ] && [ ! -L "$DEST" ] && [ ! -f "$DEST/$MARKER" ]; then
		fail "$DEST exists and was not installed by this script; move it away, then run again"
	fi
	rm -rf "$DEST"
	if [ "$LINK" = 1 ]; then
		say "Linking $DEST -> $HERE"
		ln -s "$HERE" "$DEST"
	else
		say "Copying the skill to $DEST"
		mkdir -p "$DEST"
		cp -R "$HERE"/. "$DEST"/
		rm -rf "$DEST/.venv" "$DEST/__pycache__" "$DEST/scripts/__pycache__" "$DEST/tests/__pycache__" "$DEST/tests/.fixtures"
	fi
	touch "$DEST/$MARKER"
fi

# --- Apple Vision tracker environment (macOS only) -----------------------------------------
if [ "$WITH_VISION" = 1 ]; then
	VENV="$DEST/.venv"
	if "$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'; then
		if [ ! -x "$VENV/bin/python" ]; then
			say "Creating the tracker's Python environment (PyObjC + Apple Vision)"
			"$PY" -m venv "$VENV"
		fi
		"$VENV/bin/python" -m pip install --quiet --upgrade pip >/dev/null
		"$VENV/bin/python" -m pip install --quiet "pyobjc-framework-Vision>=10" "pyobjc-framework-Quartz>=10"
		"$VENV/bin/python" -c 'import Vision, Quartz' && say "Apple Vision is available for subject tracking"
	else
		echo "note: python3 $PYVER is too old for PyObjC (needs 3.10+). Subject tracking will be off;" >&2
		echo "      run 'brew install python' and this installer again to enable it." >&2
	fi
fi

# --- doctor + self-test --------------------------------------------------------------------
say "ffmpeg-skill doctor"
"$PY" "$BASE/scripts/_contract.py" doctor || echo "note: doctor reported missing optional capabilities (see above)" >&2

if [ "$SELFTEST" = 1 ]; then
	say "Self-test on synthetic footage"
	"$PY" "$DEST/scripts/selftest.py" || fail "self-test failed"
fi

say "Done. Open Terminal in the folder with your videos and photos, run 'claude', and ask for an edit."
