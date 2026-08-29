# Dashboard de ApplyPilot

Un dashboard local que lee la base de ApplyPilot y muestra en qué quedó cada
etapa del pipeline, con foco en lo que hizo la etapa 6 (la que maneja Claude
Code): qué se envió, qué falló, cuántos reintentos costó y con qué confianza
quedó verificado.

No es parte del portfolio en React. Es una herramienta suelta, sin dependencias
de npm, que corre con el Python que ya necesitas para ApplyPilot.

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
python3 dashboard/server.py
```

Abre `http://127.0.0.1:8787/` en tu navegador. Sin argumentos usa la misma base
que ApplyPilot: `$APPLYPILOT_DIR/applypilot.db`, y si esa variable no está,
`~/.applypilot/applypilot.db` — el mismo criterio que `applypilot/config.py`, así
que siempre apunta a la base que el pipeline está usando de verdad.

Opciones:

```bash
python3 dashboard/server.py --port 9000       # otro puerto
python3 dashboard/server.py --db ruta/a.db    # otra base
python3 dashboard/server.py --no-browser      # no abrir el navegador
```

### Sin datos todavía

Para ver cómo se ve antes de correr el pipeline:

```bash
python3 dashboard/make_demo_db.py /tmp/demo.db
python3 dashboard/server.py --db /tmp/demo.db
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

## Verificación

Los números del dashboard se contrastaron contra consultas SQL directas sobre la
base de demo (embudo, distribución de puntajes, promedios por portal y el filtro
de 7+): coinciden exactamente. Se revisó además en Chromium en tema claro y
oscuro, sin errores de consola ni desbordes.
