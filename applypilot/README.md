# ApplyPilot

Esta carpeta no forma parte del portfolio en React. Vive en una rama aparte
(`claude/applypilot-setup`) y junta dos cosas: cómo instalar
[ApplyPilot](https://github.com/Pickle-Pixel/ApplyPilot) en tu máquina, y un
dashboard local para ver cómo le está yendo. No modifica ni depende de nada del
resto del repo.

ApplyPilot es un pipeline autónomo de postulación a empleos. Lo relevante es que
**la última etapa usa Claude Code como motor**: es Claude Code quien abre Chrome,
navega el formulario, llena los campos, sube el CV y la carta, responde las
preguntas de screening y envía. No hay que integrarlo con nada; basta con tener
ambos instalados.

## Qué hay acá

| Archivo | Para qué |
| --- | --- |
| `setup.sh` | Verifica requisitos e instala ApplyPilot |
| `server.py` | Levanta el dashboard local |
| `index.html`, `app.js`, `styles.css` | La interfaz del dashboard |
| `make_demo_db.py` | Base de demo, para ver el dashboard sin datos propios |

## Las 6 etapas

| # | Etapa | Qué hace |
| - | ------------ | ------------------------------------------------- |
| 1 | Discover | Scraping de portales de empleo |
| 2 | Enrich | Extrae la descripción completa de cada aviso |
| 3 | Score | Puntúa el calce contigo de 1 a 10 con un LLM |
| 4 | Tailor | Adapta tu CV a cada aviso |
| 5 | Cover Letter | Escribe la carta de presentación |
| 6 | Auto-Apply | **Claude Code** llena el formulario y envía |

Las etapas 3, 4 y 5 usan el LLM que configures (Gemini por defecto). La etapa 6
es la que usa Claude Code.

---

# Parte 1 — Instalación

## Requisitos

- **Python 3.11+** — es lo que declara el paquete, no negociable.
- **Node.js 18+**, porque `npx` levanta el servidor Playwright MCP.
- **Chrome o Chromium**.
- **Claude Code CLI** — `npm install -g @anthropic-ai/claude-code`, y luego
  `claude` una vez para iniciar sesión.
- **Una API key de Gemini**, gratis en [aistudio.google.com](https://aistudio.google.com).
  También se admite OpenAI o un modelo local (Ollama / llama.cpp).
- Opcional: una API key de **CapSolver** si quieres que resuelva CAPTCHAs solo.

## Instalar

### Opción A: el script de esta carpeta

```bash
./applypilot/setup.sh --check-only   # solo verifica requisitos
./applypilot/setup.sh                # verifica, instala y corre doctor
```

Por defecto instala en un venv en `~/.applypilot/venv` para no chocar con el
error `externally-managed-environment` (PEP 668) que dan las distros modernas y
Homebrew. Con `--system` instala en el Python que tengas activo.

### Opción B: a mano

```bash
pip install applypilot
pip install --no-deps python-jobspy && pip install pydantic tls-client requests markdownify regex
```

La segunda línea no es opcional ni un workaround improvisado: `python-jobspy`
fija una versión exacta de numpy en su metadata que hace fallar al resolvedor de
pip, pero funciona bien en runtime con cualquier numpy moderno. El `--no-deps`
salta el resolvedor y el segundo comando instala las dependencias que realmente
necesita.

## Configurar

```bash
applypilot init     # asistente: CV, perfil, preferencias, API keys
applypilot doctor   # confirma que detecta Claude Code y Chrome
```

`init` crea tres archivos en `~/.applypilot/`:

- **`profile.json`** — tus datos estructurados: contacto, autorización para
  trabajar, disponibilidad, expectativa de renta, años de experiencia, skills,
  y los datos que no debe inventar al adaptar el CV (empresas, proyectos,
  universidad, métricas reales). También incluye una sección EEO opcional, donde
  «prefiero no responder» es una respuesta válida en todos los campos.
- **`searches.yaml`** — tus búsquedas: títulos objetivo agrupados por prioridad,
  ubicaciones (aquí pones `Remote`), portales a consultar (Indeed, LinkedIn,
  Glassdoor, ZipRecruiter, Google Jobs), cuántos resultados por sitio, qué tan
  recientes, y qué títulos excluir. Puedes definir varias búsquedas con
  parámetros distintos. El paquete trae un `searches.example.yaml` de referencia;
  el script te imprime su ruta exacta al terminar.
- **`.env`** — `GEMINI_API_KEY`, `LLM_MODEL` (Gemini 2.0 Flash es el recomendado
  y el más barato; también acepta `gpt-4o-mini` o un modelo local), y opcionales
  `CAPSOLVER_API_KEY` y configuración de proxy para el scraping.

El paquete además trae su propio registro de empleadores Workday
(`config/employers.yaml`) y de sitios de carrera directos y dominios bloqueados
(`config/sites.yaml`).

## Usar

```bash
applypilot run              # etapas 1-5: descubre, puntúa, adapta CV, cartas
applypilot apply --dry-run  # llena formularios SIN enviar  ← empieza aquí
applypilot apply            # envío autónomo
applypilot status           # estadísticas del pipeline
applypilot dashboard        # ver resultados
```

Flags que vale la pena conocer:

- `run` acepta etapas sueltas, `--workers N` para paralelizar, `--stream`,
  `--min-score N` para filtrar por puntaje, su propio `--dry-run` (previsualiza
  el pipeline sin ejecutarlo) y `--validation lenient|strict`.
- `apply` acepta `--workers N`, `--dry-run` (llena sin enviar), `--continuous`,
  `--headless`, y `--url URL` para una postulación puntual. Para corregir el
  estado a mano están `--mark-applied` / `--mark-failed` con una URL, y
  `--reset-failed` para reintentar las fallidas.

Ojo con la diferencia: `run --dry-run` y `apply --dry-run` **no** son lo mismo.
El primero previsualiza el pipeline; el segundo es el que llena formularios
reales sin apretar «enviar», y es el que deberías usar los primeros días para
revisar qué está escribiendo en tu nombre.

El servidor Playwright MCP se configura automáticamente en tiempo de ejecución,
por worker. No requiere configuración manual de MCP.

---

# Parte 2 — El dashboard

## Por qué existe

ApplyPilot trae su propio `applypilot dashboard`: un HTML estático centrado en
**descubrimiento y puntajes** (distribución de scores, tarjetas por aviso,
filtros por puntaje). Es bueno para decidir a qué postular.

Lo que ese dashboard no muestra es el **resultado de las postulaciones**. La
tabla `jobs` guarda `apply_status`, `apply_error`, `apply_attempts`,
`apply_duration_ms` y `verification_confidence`, y esas columnas son las que
dicen si la automatización está funcionando o llenando formularios a ciegas.
Este dashboard es esa mitad.

## Correrlo

```bash
python3 applypilot/server.py
```

Abre `http://127.0.0.1:8787/` en tu navegador. Sin argumentos usa la misma base
que ApplyPilot: `$APPLYPILOT_DIR/applypilot.db`, y si esa variable no está,
`~/.applypilot/applypilot.db` — el mismo criterio que `applypilot/config.py` del
paquete, así que siempre apunta a la base que el pipeline está usando de verdad.

Opciones:

```bash
python3 applypilot/server.py --port 9000       # otro puerto
python3 applypilot/server.py --db ruta/a.db    # otra base
python3 applypilot/server.py --no-browser      # no abrir el navegador
```

No necesita dependencias de npm ni paquetes extra: corre con el mismo Python que
ya instalaste para ApplyPilot.

### Sin datos todavía

Para ver cómo se ve antes de correr el pipeline:

```bash
python3 applypilot/make_demo_db.py /tmp/demo.db
python3 applypilot/server.py --db /tmp/demo.db
```

`make_demo_db.py` genera 140 avisos ficticios con el esquema real y un embudo
que se angosta de forma realista. Sirve también para probar cambios sin tocar
tus datos.

## Qué muestra

- **Postulaciones enviadas** como cifra principal, con la tasa de éxito sobre el
  total de intentos.
- **Embudo del pipeline**: cuántos avisos llegaron a cada una de las 6 etapas.
  Es la vista que delata dónde se está cayendo el proceso.
- **Resultado de las postulaciones**: enviadas, fallidas, omitidas y las que
  necesitan revisión.
- **Distribución de puntajes** y **avisos por portal**.
- **Últimos intentos**: una fila por corrida de la etapa 6, con estado, número de
  intentos, duración, confianza de verificación y el error cuando lo hubo. Es la
  tabla para responder «¿por qué no se envió esta?».

Los filtros de arriba (puntaje, portal, búsqueda) alcanzan a todo lo de abajo,
así que las cifras siempre concuerdan entre sí.

## Decisiones que vale la pena conocer

**Solo lectura.** La conexión a SQLite se abre con `mode=ro`. El dashboard no
puede escribir en la base del pipeline aunque algo falle.

**Solo tu máquina.** Escucha en `127.0.0.1`. La base contiene datos personales
—nombre, teléfono, dirección, historial de postulaciones—, así que exponerla a
la red no es el default; si pasas otro `--host`, el servidor te lo advierte.

**Los textos largos no viajan al navegador.** De las descripciones solo se manda
si existen o no (es lo que marca la etapa de enriquecimiento) y del razonamiento
del puntaje, un extracto. La respuesta queda en ~120 KB para 140 avisos.

**Tolera bases viejas.** La tabla `jobs` de ApplyPilot crece por migración, así
que el servidor consulta `PRAGMA table_info` y pide solo las columnas que
existen de verdad, en vez de asumir el esquema más nuevo.

**No asume los estados posibles.** `apply_status` lo escribe el pipeline y puede
crecer. Los valores conocidos se agrupan en enviada / fallida / omitida /
necesita revisión, y cualquier valor nuevo aparece como «Otro» en gris: visible,
sin fingir que sabemos qué significa. La columna «Estados en la base» de la tabla
te muestra los valores crudos.

**Los gráficos tienen tabla equivalente.** Cada uno trae un botón «Ver tabla»,
y ningún valor depende de pasar el mouse por encima. Los colores de estado van
siempre con ícono y texto, nunca solos. Funciona en tema claro y oscuro.

---

## Antes de soltarlo en automático

**`profile.json` contiene datos sensibles.** El esquema incluye un campo
`password` para las cuentas de los portales de empleo, además de tu dirección y
teléfono. Vive en `~/.applypilot/`, fuera de este repo, y ahí debe quedarse:
nunca lo copies a una carpeta versionada ni lo pegues en un issue.

**Usa `apply --dry-run` varios días.** Estás delegando a un agente que escribe
respuestas a nombre tuyo en formularios de empresas reales. Revisa qué contesta
en las preguntas de screening antes de dejarlo enviar.

**Es AGPL-3.0.** Si alguna vez lo modificas y lo ofreces como servicio, esa
licencia te obliga a publicar tus cambios.

## Dos cosas que no están en la documentación

Son lecturas mías, no promesas del proyecto:

1. **La etapa 6 consume tu plan de Claude Code.** El README no menciona costos ni
   cuotas, pero si Claude Code corre una sesión de navegador por postulación, ese
   uso sale de tu plan. Mídelo con dos o tres postulaciones en `--dry-run` antes
   de correrlo en volumen.
2. **Hay varios proyectos llamados ApplyPilot** en GitHub (`ibarrajo`, `eliornl`,
   `iknalos`). El que instala `pip install applypilot` es el de `Pickle-Pixel`,
   que es el que describe esta guía. Si encuentras documentación que no calza,
   probablemente estés leyendo otro.

## Verificado contra

Escrito el 2026-08-29 contra la versión 0.3.0 del paquete:

- [applypilot en PyPI](https://pypi.org/project/applypilot/)
- [Pickle-Pixel/ApplyPilot](https://github.com/Pickle-Pixel/ApplyPilot)

Los números del dashboard se contrastaron contra consultas SQL directas sobre la
base de demo (embudo, distribución de puntajes, promedios por portal y el filtro
de 7+): coinciden exactamente. Se revisó además en Chromium en tema claro y
oscuro, sin errores de consola ni desbordes.
