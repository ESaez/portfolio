#!/usr/bin/env python3
"""Genera una base de demo con el esquema real de ApplyPilot.

Sirve para mirar el dashboard antes de tener datos propios, y para probar
cambios sin tocar la base de verdad.

    python3 make_demo_db.py /tmp/demo.db
    python3 server.py --db /tmp/demo.db
"""

from __future__ import annotations

import random
import sqlite3
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

# Mismo esquema que src/applypilot/database.py.
SCHEMA = """
CREATE TABLE IF NOT EXISTS jobs (
    url TEXT PRIMARY KEY,
    title TEXT,
    salary TEXT,
    description TEXT,
    location TEXT,
    site TEXT,
    strategy TEXT,
    discovered_at TEXT,
    full_description TEXT,
    application_url TEXT,
    detail_scraped_at TEXT,
    detail_error TEXT,
    fit_score INTEGER,
    score_reasoning TEXT,
    scored_at TEXT,
    tailored_resume_path TEXT,
    tailored_at TEXT,
    tailor_attempts INTEGER DEFAULT 0,
    cover_letter_path TEXT,
    cover_letter_at TEXT,
    cover_attempts INTEGER DEFAULT 0,
    applied_at TEXT,
    apply_status TEXT,
    apply_error TEXT,
    apply_attempts INTEGER DEFAULT 0,
    agent_id TEXT,
    last_attempted_at TEXT,
    apply_duration_ms INTEGER,
    apply_task_id TEXT,
    verification_confidence TEXT
)
"""

SITES = ["indeed", "linkedin", "glassdoor", "zip_recruiter", "google"]
TITLES = [
    "Backend Engineer", "Full Stack Developer", "Python Developer",
    "Software Engineer", "Data Engineer", "React Developer",
    "Platform Engineer", "API Engineer", "DevOps Engineer",
    "Senior Backend Developer", "Cloud Engineer", "Site Reliability Engineer",
]
COMPANIES = ["Northwind", "Acme Cloud", "Beacon Labs", "Vertex", "Larkspur", "Tidepool"]
ERRORS = [
    "Timeout esperando el selector del formulario",
    "El portal pidió un CAPTCHA no resuelto",
    "El campo 'years of experience' no aceptó el valor",
    "",
]


def build(db_path: Path, count: int = 140, seed: int = 7) -> None:
    random.seed(seed)
    db_path.parent.mkdir(parents=True, exist_ok=True)
    if db_path.exists():
        db_path.unlink()

    conn = sqlite3.connect(db_path)
    conn.execute(SCHEMA)
    now = datetime.now(timezone.utc)

    rows = []
    for index in range(count):
        discovered = now - timedelta(days=random.randint(0, 25), hours=random.randint(0, 23))
        site = random.choice(SITES)
        title = random.choice(TITLES)
        company = random.choice(COMPANIES)
        url = f"https://example.com/{site}/job/{index}"

        # El embudo se angosta: no todo lo descubierto llega a enriquecerse, ni
        # todo lo enriquecido se puntua, etc.
        enriched = random.random() < 0.86
        scored = enriched and random.random() < 0.92
        score = random.choices(
            [3, 4, 5, 6, 7, 8, 9, 10], weights=[4, 8, 14, 20, 22, 16, 9, 3]
        )[0] if scored else None

        tailored = bool(scored and score >= 7 and random.random() < 0.88)
        covered = tailored and random.random() < 0.93
        attempted = covered and random.random() < 0.72

        status = None
        applied_at = None
        error = None
        attempts = 0
        duration = None
        confidence = None
        last_attempt = None

        if attempted:
            status = random.choices(
                ["applied", "failed", "skipped", "needs_review"],
                weights=[62, 18, 12, 8],
            )[0]
            attempts = 1 if status == "applied" else random.randint(1, 3)
            last_attempt = (discovered + timedelta(days=random.randint(1, 3))).isoformat()
            duration = random.randint(38_000, 320_000)
            if status == "applied":
                applied_at = last_attempt
                confidence = random.choice(["high", "high", "medium"])
            elif status == "failed":
                error = random.choice(ERRORS)
                confidence = "low"

        rows.append((
            url,
            f"{title} — {company}",
            random.choice(["", "$90,000 - $120,000", "$70k-$95k", ""]),
            "Resumen corto del aviso.",
            random.choice(["Remote", "Remote (US)", "San Francisco, CA", "Remote (LatAm)"]),
            site,
            "tier1" if score and score >= 7 else "tier2",
            discovered.isoformat(),
            "Descripción completa del aviso." if enriched else None,
            f"{url}/apply",
            (discovered + timedelta(hours=2)).isoformat() if enriched else None,
            None if enriched else "404 al abrir el detalle",
            score,
            "Calza con la experiencia en Python y APIs." if scored else None,
            (discovered + timedelta(hours=3)).isoformat() if scored else None,
            f"~/.applypilot/tailored_resumes/{index}.pdf" if tailored else None,
            (discovered + timedelta(hours=4)).isoformat() if tailored else None,
            1 if tailored else 0,
            f"~/.applypilot/cover_letters/{index}.txt" if covered else None,
            (discovered + timedelta(hours=5)).isoformat() if covered else None,
            1 if covered else 0,
            applied_at,
            status,
            error,
            attempts,
            f"agent-{index % 4}" if attempted else None,
            last_attempt,
            duration,
            f"task-{index}" if attempted else None,
            confidence,
        ))

    conn.executemany(
        f"INSERT INTO jobs VALUES ({','.join('?' * 30)})",
        rows,
    )
    conn.commit()
    conn.close()
    print(f"Base de demo con {count} avisos en {db_path}")


if __name__ == "__main__":
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("demo.db")
    build(target)
