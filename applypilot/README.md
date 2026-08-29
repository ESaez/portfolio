# ApplyPilot — guía de instalación y uso

Esta carpeta no forma parte del portfolio en React. Vive en una rama aparte
(`claude/applypilot-setup`) y contiene solo notas y un script para instalar
[ApplyPilot](https://github.com/Pickle-Pixel/ApplyPilot) en tu propia máquina.
No modifica ni depende de nada del resto del repo.

ApplyPilot es un pipeline autónomo de postulación a empleos. Lo relevante para
nosotros es que **la última etapa usa Claude Code como motor**: es Claude Code
quien abre Chrome, navega el formulario, llena los campos, sube el CV y la carta,
responde las preguntas de screening y envía. No hay que integrarlo con nada;
basta con tener ambos instalados.

## Las 6 etapas

| # | Etapa        | Qué hace                                          |
| - | ------------ | ------------------------------------------------- |
| 1 | Discover     | Scraping de portales de empleo                    |
| 2 | Enrich       | Extrae la descripción completa de cada aviso      |
| 3 | Score        | Puntúa el calce contigo de 1 a 10 con un LLM      |
| 4 | Tailor       | Adapta tu CV a cada aviso                         |
| 5 | Cover Letter | Escribe la carta de presentación                  |
| 6 | Auto-Apply   | **Claude Code** llena el formulario y envía       |

Las etapas 3, 4 y 5 usan el LLM que configures (Gemini por defecto). La etapa 6
es la que usa Claude Code.

## Requisitos

- **Python 3.11+** — es lo que declara el paquete, no negociable.
- **Node.js 18+**, porque `npx` levanta el servidor Playwright MCP.
- **Chrome o Chromium**.
- **Claude Code CLI** — `npm install -g @anthropic-ai/claude-code`, y luego
  `claude` una vez para iniciar sesión.
- **Una API key de Gemini**, gratis en [aistudio.google.com](https://aistudio.google.com).
  También se admite OpenAI o un modelo local (Ollama / llama.cpp).
- Opcional: una API key de **CapSolver** si quieres que resuelva CAPTCHAs solo.

## Instalación

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

## Configuración

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

## Uso

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
