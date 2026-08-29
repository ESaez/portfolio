#!/usr/bin/env bash
#
# Instalador y verificador de requisitos para ApplyPilot.
#
#   ./setup.sh               instala en un venv dedicado (~/.applypilot/venv)
#   ./setup.sh --check-only  solo verifica requisitos, no instala nada
#   ./setup.sh --system      instala en el Python actual en vez de un venv
#
set -euo pipefail

CHECK_ONLY=0
USE_VENV=1
VENV_DIR="${APPLYPILOT_VENV:-$HOME/.applypilot/venv}"
MISSING=0

usage() {
	cat <<'EOF'
Uso: ./setup.sh [opciones]

  --check-only   Solo verifica requisitos (Python, Node, Chrome, Claude Code).
  --system       Instala en el Python actual en vez de crear un venv.
  -h, --help     Muestra esta ayuda.

Variables de entorno:
  APPLYPILOT_VENV   Ruta del venv a crear/usar (default: ~/.applypilot/venv)
EOF
}

for arg in "$@"; do
	case "$arg" in
	--check-only) CHECK_ONLY=1 ;;
	--system) USE_VENV=0 ;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "Opción desconocida: $arg" >&2
		usage >&2
		exit 2
		;;
	esac
done

if [ -t 1 ]; then
	GREEN=$'\033[32m' RED=$'\033[31m' YELLOW=$'\033[33m' BOLD=$'\033[1m' RESET=$'\033[0m'
else
	GREEN='' RED='' YELLOW='' BOLD='' RESET=''
fi

ok() { printf '  %sOK%s   %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '  %sAVISO%s %s\n' "$YELLOW" "$RESET" "$1"; }
fail() {
	printf '  %sFALTA%s %s\n' "$RED" "$RESET" "$1"
	MISSING=$((MISSING + 1))
}
section() { printf '\n%s%s%s\n' "$BOLD" "$1" "$RESET"; }

# --- Python 3.11+ -----------------------------------------------------------
# ApplyPilot declara requires-python >= 3.11, así que buscamos el primer
# intérprete que lo cumpla en vez de asumir que `python3` sirve.
PY=""
for candidate in python3.14 python3.13 python3.12 python3.11 python3 python; do
	if command -v "$candidate" >/dev/null 2>&1 &&
		"$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
		PY="$candidate"
		break
	fi
done

section "Requisitos"

if [ -n "$PY" ]; then
	ok "Python $("$PY" -c 'import platform; print(platform.python_version())') ($(command -v "$PY"))"
else
	fail "Python 3.11+ no encontrado. Instálalo desde https://www.python.org/downloads/"
fi

# --- Node.js 18+ (npx levanta el servidor Playwright MCP) -------------------
if command -v node >/dev/null 2>&1; then
	NODE_MAJOR="$(node -v | sed 's/^v//' | cut -d. -f1)"
	if [ "$NODE_MAJOR" -ge 18 ] 2>/dev/null; then
		ok "Node.js $(node -v)"
	else
		fail "Node.js $(node -v) es muy antiguo; ApplyPilot necesita 18+."
	fi
else
	fail "Node.js no encontrado. Instálalo desde https://nodejs.org/"
fi

if command -v npx >/dev/null 2>&1; then
	ok "npx disponible (necesario para el servidor Playwright MCP)"
else
	fail "npx no encontrado; normalmente viene con Node.js."
fi

# --- Chrome / Chromium ------------------------------------------------------
CHROME=""
for candidate in \
	google-chrome google-chrome-stable chromium chromium-browser \
	"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
	"/Applications/Chromium.app/Contents/MacOS/Chromium"; do
	if command -v "$candidate" >/dev/null 2>&1 || [ -x "$candidate" ]; then
		CHROME="$candidate"
		break
	fi
done

if [ -n "$CHROME" ]; then
	ok "Chrome/Chromium encontrado ($CHROME)"
else
	fail "Chrome/Chromium no encontrado. Instálalo desde https://www.google.com/chrome/"
fi

# --- Claude Code CLI (es el motor de la etapa 6) ----------------------------
if command -v claude >/dev/null 2>&1; then
	ok "Claude Code CLI ($(command -v claude))"
else
	fail "Claude Code CLI no encontrado. Instala con: npm install -g @anthropic-ai/claude-code"
fi

if [ "$MISSING" -gt 0 ]; then
	printf '\n%sFaltan %d requisito(s).%s Resuélvelos y vuelve a correr este script.\n' \
		"$RED" "$MISSING" "$RESET"
	exit 1
fi

printf '\n%sTodos los requisitos están presentes.%s\n' "$GREEN" "$RESET"

if [ "$CHECK_ONLY" -eq 1 ]; then
	exit 0
fi

# --- Instalación ------------------------------------------------------------
section "Instalando ApplyPilot"

if [ "$USE_VENV" -eq 1 ]; then
	# Un venv evita el error "externally-managed-environment" (PEP 668) que dan
	# las distros modernas y macOS/Homebrew al instalar con pip en el sistema.
	if [ ! -x "$VENV_DIR/bin/python" ]; then
		echo "  Creando venv en $VENV_DIR"
		"$PY" -m venv "$VENV_DIR"
	else
		echo "  Reutilizando venv en $VENV_DIR"
	fi
	PY="$VENV_DIR/bin/python"
fi

"$PY" -m pip install --upgrade pip >/dev/null
"$PY" -m pip install applypilot

# python-jobspy fija una versión exacta de numpy en su metadata que choca con
# el resolvedor de pip, pero funciona bien en runtime con cualquier numpy
# moderno. Por eso se instala sin dependencias y luego se agregan las reales.
"$PY" -m pip install --no-deps python-jobspy
"$PY" -m pip install pydantic tls-client requests markdownify regex

APPLYPILOT_BIN="$(dirname "$PY")/applypilot"
[ -x "$APPLYPILOT_BIN" ] || APPLYPILOT_BIN="applypilot"

section "Verificando la instalación"
"$APPLYPILOT_BIN" doctor || warn "'applypilot doctor' reportó problemas; revisa el detalle arriba."

# La plantilla de búsquedas viaja dentro del paquete; mostramos su ruta real en
# vez de adivinarla, para poder copiarla como punto de partida.
EXAMPLE="$("$PY" - <<'PYEOF' 2>/dev/null || true
import pathlib
import applypilot

path = pathlib.Path(applypilot.__file__).parent / "config" / "searches.example.yaml"
print(path if path.is_file() else "")
PYEOF
)"

section "Siguientes pasos"
if [ "$USE_VENV" -eq 1 ]; then
	cat <<EOF
  El comando quedó en el venv. Actívalo antes de usarlo:

      source "$VENV_DIR/bin/activate"

  O invócalo por ruta completa: $APPLYPILOT_BIN
EOF
fi
cat <<'EOF'

  1. applypilot init              carga tu CV y crea la configuración
  2. applypilot run               descubre, puntúa, adapta CV y cartas
  3. applypilot apply --dry-run   llena formularios SIN enviar (empieza aquí)
  4. applypilot apply             envío autónomo
EOF
if [ -n "$EXAMPLE" ]; then
	printf '\n  Plantilla de búsquedas de ejemplo:\n      %s\n' "$EXAMPLE"
fi
printf '\n  Guía completa: applypilot/README.md\n'
