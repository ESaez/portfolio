#!/usr/bin/env python3
"""Dashboard local para ApplyPilot.

Sirve una vista del pipeline leyendo la base SQLite que ApplyPilot mantiene en
APP_DIR. La conexion se abre en modo solo-lectura para que el dashboard no pueda
tocar los datos del pipeline aunque falle.

Uso:
    python3 server.py                 abre el navegador en 127.0.0.1:8787
    python3 server.py --port 9000     otro puerto
    python3 server.py --db ruta.db    otra base
    python3 server.py --no-browser    no abrir el navegador
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import webbrowser
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# Mismo criterio de resolucion que applypilot/config.py, para que el dashboard
# apunte siempre a la base que el pipeline esta usando de verdad.
APP_DIR = Path(os.environ.get("APPLYPILOT_DIR", Path.home() / ".applypilot"))
DEFAULT_DB_PATH = APP_DIR / "applypilot.db"

STATIC_DIR = Path(__file__).resolve().parent

# La carpeta tiene mas cosas que la interfaz (scripts, guia). El servidor
# entrega solo estos archivos en vez del directorio completo.
STATIC_FILES = {"/": "index.html", "/index.html": "index.html", "/app.js": "app.js", "/styles.css": "styles.css"}

# Columnas que el dashboard necesita. La tabla `jobs` de ApplyPilot crece por
# migracion (ensure_columns), asi que una base vieja puede no tenerlas todas:
# pedimos solo la interseccion con lo que existe de verdad.
SCALAR_COLUMNS = [
    "url",
    "title",
    "salary",
    "location",
    "site",
    "strategy",
    "discovered_at",
    "application_url",
    "detail_scraped_at",
    "detail_error",
    "fit_score",
    "scored_at",
    "tailored_resume_path",
    "tailored_at",
    "cover_letter_path",
    "cover_letter_at",
    "applied_at",
    "apply_status",
    "apply_error",
    "apply_attempts",
    "last_attempted_at",
    "apply_duration_ms",
    "verification_confidence",
]

# Columnas de texto largo: no viajan al navegador enteras. De las descripciones
# solo interesa si existen (marca la etapa de enriquecimiento) y del reasoning
# alcanza con un extracto.
PRESENCE_COLUMNS = ["full_description", "description"]
TRUNCATED_COLUMNS = {"score_reasoning": 240}

REASONING_LIMIT = 240


class DatabaseUnavailable(Exception):
    """La base no existe o no tiene la tabla que esperamos."""


def existing_columns(conn: sqlite3.Connection) -> set[str]:
    try:
        rows = conn.execute("PRAGMA table_info(jobs)").fetchall()
    except sqlite3.DatabaseError as exc:  # archivo corrupto o no es sqlite
        raise DatabaseUnavailable(f"No se pudo leer la tabla jobs: {exc}") from exc
    if not rows:
        raise DatabaseUnavailable(
            "La base existe pero no tiene la tabla 'jobs'. "
            "Corre 'applypilot run' al menos una vez."
        )
    return {row[1] for row in rows}


def build_select(columns: set[str]) -> str:
    parts: list[str] = []
    for name in SCALAR_COLUMNS:
        if name in columns:
            parts.append(f'"{name}"')
    for name in PRESENCE_COLUMNS:
        if name in columns:
            parts.append(f'("{name}" IS NOT NULL AND "{name}" != \'\') AS has_{name}')
    for name, limit in TRUNCATED_COLUMNS.items():
        if name in columns:
            parts.append(f'substr("{name}", 1, {limit}) AS "{name}"')
    if not parts:
        raise DatabaseUnavailable("La tabla 'jobs' no tiene ninguna columna conocida.")
    return "SELECT " + ", ".join(parts) + " FROM jobs"


def read_jobs(db_path: Path) -> dict:
    if not db_path.is_file():
        raise DatabaseUnavailable(
            f"No existe la base en {db_path}. "
            "Corre 'applypilot run' primero, o pasa --db con la ruta correcta."
        )
    # mode=ro: el dashboard es un lector. Si algo sale mal, no puede escribir.
    uri = f"file:{db_path.as_posix()}?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    try:
        conn.row_factory = sqlite3.Row
        columns = existing_columns(conn)
        rows = conn.execute(build_select(columns)).fetchall()
    finally:
        conn.close()
    return {
        "db_path": str(db_path),
        "columns": sorted(columns),
        "jobs": [dict(row) for row in rows],
    }


class DashboardHandler(SimpleHTTPRequestHandler):
    """Sirve los estaticos de esta carpeta y una API de solo lectura."""

    db_path: Path = DEFAULT_DB_PATH

    def do_GET(self) -> None:  # noqa: N802  (nombre impuesto por la clase base)
        route = self.path.split("?", 1)[0]
        if route == "/api/jobs":
            self.send_json_api()
            return
        if route not in STATIC_FILES:
            self.send_error(404, "No encontrado")
            return
        self.path = "/" + STATIC_FILES[route]
        super().do_GET()

    def send_json_api(self) -> None:
        try:
            payload = read_jobs(self.db_path)
            status = 200
        except DatabaseUnavailable as exc:
            payload = {"error": str(exc)}
            status = 503
        except sqlite3.Error as exc:
            payload = {"error": f"Error de SQLite: {exc}"}
            status = 500
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args) -> None:  # noqa: A002
        # El log por request no aporta nada en una herramienta local.
        pass


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Dashboard local de ApplyPilot")
    parser.add_argument("--port", type=int, default=8787, help="puerto (default 8787)")
    parser.add_argument(
        "--host",
        default="127.0.0.1",
        help="interfaz donde escuchar (default 127.0.0.1, solo tu maquina)",
    )
    parser.add_argument(
        "--db",
        type=Path,
        default=DEFAULT_DB_PATH,
        help=f"ruta de la base (default {DEFAULT_DB_PATH})",
    )
    parser.add_argument(
        "--no-browser", action="store_true", help="no abrir el navegador al arrancar"
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    if not args.db.is_file():
        print(f"Aviso: aun no existe {args.db}.", file=sys.stderr)
        print("El dashboard va a arrancar igual y te lo dira en pantalla.", file=sys.stderr)

    if args.host not in ("127.0.0.1", "localhost", "::1"):
        # La base trae datos personales (nombre, telefono, direccion, historial
        # de postulaciones), asi que exponerla a la red merece una advertencia.
        print(
            f"Aviso: escuchando en {args.host}, no solo en tu maquina. "
            "La base de ApplyPilot contiene datos personales.",
            file=sys.stderr,
        )

    handler = partial(DashboardHandler, directory=str(STATIC_DIR))
    DashboardHandler.db_path = args.db

    try:
        server = ThreadingHTTPServer((args.host, args.port), handler)
    except OSError as exc:
        print(f"No se pudo abrir {args.host}:{args.port}: {exc}", file=sys.stderr)
        return 1

    url = f"http://{args.host}:{args.port}/"
    print(f"Dashboard de ApplyPilot en {url}")
    print(f"Leyendo (solo lectura) {args.db}")
    print("Ctrl+C para detener.")

    if not args.no_browser:
        webbrowser.open(url)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nDetenido.")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
