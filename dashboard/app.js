/* Dashboard de ApplyPilot.
 *
 * Lee /api/jobs (solo lectura sobre la base SQLite del pipeline) y dibuja el
 * estado del embudo. Los titulos, portales y mensajes de error vienen de sitios
 * scrapeados: son datos no confiables y por eso todo texto entra al DOM con
 * textContent, nunca concatenando innerHTML.
 */

const SVG_NS = 'http://www.w3.org/2000/svg';

const state = {
  jobs: [],
  minScore: 0,
  site: '',
  query: '',
};

/* --- Helpers de DOM ------------------------------------------------------ */

function el(tag, attrs = {}, text) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (key === 'class') node.className = value;
    else node.setAttribute(key, value);
  }
  if (text !== undefined && text !== null) node.textContent = String(text);
  return node;
}

function svg(tag, attrs = {}, text) {
  const node = document.createElementNS(SVG_NS, tag);
  for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, value);
  if (text !== undefined && text !== null) node.textContent = String(text);
  return node;
}

function clear(node) {
  while (node.firstChild) node.removeChild(node.firstChild);
}

const fmtInt = (n) => Number(n || 0).toLocaleString('es');

function fmtDuration(ms) {
  if (ms === null || ms === undefined || ms === '') return '—';
  const seconds = Number(ms) / 1000;
  if (!Number.isFinite(seconds)) return '—';
  if (seconds < 60) return `${seconds.toFixed(1)} s`;
  const mins = Math.floor(seconds / 60);
  return `${mins} min ${Math.round(seconds - mins * 60)} s`;
}

function fmtDate(value) {
  if (!value) return '—';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return String(value);
  return date.toLocaleDateString('es', { day: '2-digit', month: 'short', year: 'numeric' });
}

const cssVar = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();

/* --- Modelo -------------------------------------------------------------- */

const filled = (value) => value !== null && value !== undefined && String(value).trim() !== '';

/* Number(null) y Number('') son 0, y 0 pasa isFinite: sin este guardia los
 * avisos sin puntuar se cuentan como puntaje 0. Devuelve null o un numero. */
function scoreOf(job) {
  if (!filled(job.fit_score)) return null;
  const score = Number(job.fit_score);
  return Number.isFinite(score) ? score : null;
}

/* Los estados los escribe el pipeline y pueden crecer con el tiempo, asi que en
 * vez de asumir un enum cerrado agrupamos lo conocido y dejamos el resto en
 * "otro" con color neutro, visible pero sin fingir que sabemos que significa. */
const OUTCOME_GROUPS = [
  { id: 'ok', label: 'Enviada', tone: 'good', icon: '✓', match: ['applied', 'submitted', 'success', 'verified', 'complete', 'completed'] },
  { id: 'review', label: 'Necesita revisión', tone: 'serious', icon: '!', match: ['needs_review', 'manual', 'captcha', 'partial', 'paused'] },
  { id: 'skipped', label: 'Omitida', tone: 'warning', icon: '–', match: ['skipped', 'blocked', 'ineligible', 'closed'] },
  { id: 'failed', label: 'Fallida', tone: 'critical', icon: '✕', match: ['failed', 'error', 'failure', 'timeout'] },
];

const TONE_VAR = {
  good: '--good',
  warning: '--warning',
  serious: '--serious',
  critical: '--critical',
  neutral: '--neutral',
};

function rawOutcome(job) {
  const status = String(job.apply_status || '').trim().toLowerCase();
  if (status) return status;
  if (filled(job.applied_at)) return 'applied';
  return '';
}

function hasAttempt(job) {
  return Boolean(rawOutcome(job)) || Number(job.apply_attempts || 0) > 0;
}

function outcomeGroup(job) {
  const raw = rawOutcome(job);
  if (!raw) return null;
  const group = OUTCOME_GROUPS.find((candidate) => candidate.match.includes(raw));
  if (group) return group;
  return { id: 'other', label: 'Otro', tone: 'neutral', icon: '•', match: [] };
}

const STAGES = [
  { id: 'discovered', label: 'Descubiertos', test: () => true },
  { id: 'enriched', label: 'Enriquecidos', test: (j) => Boolean(j.has_full_description) || filled(j.detail_scraped_at) },
  { id: 'scored', label: 'Puntuados', test: (j) => scoreOf(j) !== null },
  { id: 'tailored', label: 'CV adaptado', test: (j) => filled(j.tailored_resume_path) },
  { id: 'cover', label: 'Carta escrita', test: (j) => filled(j.cover_letter_path) },
  { id: 'applied', label: 'Enviadas', test: (j) => outcomeGroup(j)?.id === 'ok' },
];

function visibleJobs() {
  const query = state.query.trim().toLowerCase();
  return state.jobs.filter((job) => {
    if (state.minScore > 0) {
      const score = scoreOf(job);
      if (score === null || score < state.minScore) return false;
    }
    if (state.site && String(job.site || '') !== state.site) return false;
    if (query) {
      const haystack = `${job.title || ''} ${job.site || ''} ${job.location || ''}`.toLowerCase();
      if (!haystack.includes(query)) return false;
    }
    return true;
  });
}

/* --- Tooltip ------------------------------------------------------------- */

const tooltip = document.getElementById('tooltip');

function showTooltip(event, { value, label, color, extra }) {
  clear(tooltip);
  tooltip.appendChild(el('div', { class: 'tt-value' }, value));
  const row = el('div', { class: 'tt-label' });
  if (color) {
    const key = el('span', { class: 'tt-key' });
    key.style.background = color;
    row.appendChild(key);
  }
  row.appendChild(el('span', {}, label));
  tooltip.appendChild(row);
  if (extra) tooltip.appendChild(el('div', { class: 'tt-extra' }, extra));

  tooltip.classList.add('visible');
  positionTooltip(event);
}

function positionTooltip(event) {
  const rect = tooltip.getBoundingClientRect();
  let x = 12;
  let y = 12;
  if (event && typeof event.clientX === 'number' && event.clientX !== 0) {
    x = event.clientX + 14;
    y = event.clientY + 14;
  } else if (event && event.target && event.target.getBoundingClientRect) {
    const target = event.target.getBoundingClientRect();
    x = target.left + target.width / 2;
    y = target.top - rect.height - 8;
  }
  x = Math.min(x, window.innerWidth - rect.width - 8);
  y = Math.min(y, window.innerHeight - rect.height - 8);
  tooltip.style.left = `${Math.max(8, x)}px`;
  tooltip.style.top = `${Math.max(8, y)}px`;
}

function hideTooltip() {
  tooltip.classList.remove('visible');
}

/* Une un area de impacto (mas grande que la marca) con su marca y el tooltip. */
function bindHit(hit, mark, payload) {
  const show = (event) => {
    if (mark) mark.classList.remove('dim');
    showTooltip(event, payload);
  };
  hit.addEventListener('pointerenter', show);
  hit.addEventListener('pointermove', positionTooltip);
  hit.addEventListener('pointerleave', hideTooltip);
  hit.addEventListener('focus', show);
  hit.addEventListener('blur', hideTooltip);
  hit.setAttribute('tabindex', '0');
  hit.setAttribute('role', 'img');
  hit.setAttribute('aria-label', `${payload.label}: ${payload.value}`);
}

/* --- Graficos ------------------------------------------------------------ */

const BAR_MAX = 24; // grosor tope; lo que sobra de la banda queda como aire
const GAP = 2; // separacion en color de superficie entre marcas vecinas

/* Barra con la punta redondeada (4px) y escuadrada en la linea base. */
function hBarPath(x, y, width, height, radius) {
  const r = Math.max(0, Math.min(radius, width, height / 2));
  if (width <= 0) return `M${x} ${y} L${x} ${y + height}`;
  return [
    `M${x} ${y}`,
    `H${x + width - r}`,
    `Q${x + width} ${y} ${x + width} ${y + r}`,
    `V${y + height - r}`,
    `Q${x + width} ${y + height} ${x + width - r} ${y + height}`,
    `H${x}`,
    'Z',
  ].join(' ');
}

function vBarPath(x, y, width, height, radius) {
  const r = Math.max(0, Math.min(radius, height, width / 2));
  if (height <= 0) return `M${x} ${y + height} H${x + width}`;
  return [
    `M${x} ${y + height}`,
    `V${y + r}`,
    `Q${x} ${y} ${x + r} ${y}`,
    `H${x + width - r}`,
    `Q${x + width} ${y} ${x + width} ${y + r}`,
    `V${y + height}`,
    'Z',
  ].join(' ');
}

/* Barras horizontales: una serie por defecto, o color por fila cuando el color
 * significa estado. Etiqueta de valor fuera de la punta, nunca recortada. */
function renderHBars(container, rows, options = {}) {
  clear(container);
  if (!rows.length) {
    container.appendChild(el('p', { class: 'empty' }, options.emptyText || 'Sin datos todavía.'));
    return;
  }

  const width = Math.max(container.clientWidth || 480, 320);
  const rowHeight = 34;
  const labelWidth = Math.min(options.labelWidth || 132, Math.round(width * 0.38));
  const valueWidth = 56;
  const height = rows.length * rowHeight + 8;
  const plotWidth = Math.max(40, width - labelWidth - valueWidth - 8);
  const max = Math.max(...rows.map((row) => row.value), 1);
  const defaultColor = cssVar('--series-1');

  const root = svg('svg', {
    viewBox: `0 0 ${width} ${height}`,
    width,
    height,
    role: 'group',
    'aria-label': options.ariaLabel || 'Gráfico de barras',
  });

  rows.forEach((row, index) => {
    const bandTop = index * rowHeight;
    const barHeight = Math.min(BAR_MAX, rowHeight - 10);
    const y = bandTop + (rowHeight - barHeight) / 2;
    const barWidth = (row.value / max) * plotWidth;
    const color = row.color || defaultColor;

    const label = svg('text', {
      x: labelWidth - 10,
      y: bandTop + rowHeight / 2,
      'text-anchor': 'end',
      'dominant-baseline': 'middle',
      class: 'cat-label',
    });
    label.textContent = row.label;
    root.appendChild(label);

    const mark = svg('path', {
      d: hBarPath(labelWidth, y, Math.max(barWidth, row.value > 0 ? 2 : 0), barHeight, 4),
      fill: color,
      class: 'mark',
    });
    root.appendChild(mark);

    const value = svg('text', {
      x: labelWidth + Math.max(barWidth, 0) + 8,
      y: bandTop + rowHeight / 2,
      'dominant-baseline': 'middle',
      class: 'value-label',
    });
    value.textContent = fmtInt(row.value);
    root.appendChild(value);

    // El area de impacto cubre toda la banda: mas grande que la marca.
    const hit = svg('rect', {
      x: labelWidth - GAP,
      y: bandTop,
      width: plotWidth + valueWidth,
      height: rowHeight,
      class: 'hit',
    });
    bindHit(hit, mark, {
      value: fmtInt(row.value),
      label: row.label,
      color,
      extra: row.extra,
    });
    root.appendChild(hit);
  });

  container.appendChild(root);
}

/* Escala con tope y paso "redondos" (1, 2, 2.5, 5 x 10^n) para que los ticks
 * del eje se lean como numeros y no como fracciones del maximo. */
function niceScale(rawMax, targetTicks = 4) {
  if (!(rawMax > 0)) return { max: 1, step: 1 };
  const rough = rawMax / targetTicks;
  const magnitude = 10 ** Math.floor(Math.log10(rough));
  const normalized = rough / magnitude;
  const nice = normalized <= 1 ? 1 : normalized <= 2 ? 2 : normalized <= 5 ? 5 : 10;
  const step = nice * magnitude;
  return { max: Math.ceil(rawMax / step) * step, step };
}

/* Columnas para la distribucion de puntajes. Una sola serie, sin leyenda: el
 * titulo ya dice que se grafica. Se rotula solo el maximo. */
function renderColumns(container, rows, options = {}) {
  clear(container);
  const total = rows.reduce((sum, row) => sum + row.value, 0);
  if (!total) {
    container.appendChild(el('p', { class: 'empty' }, options.emptyText || 'Sin datos todavía.'));
    return;
  }

  const width = Math.max(container.clientWidth || 480, 320);
  const plotHeight = 160;
  const axisBand = 26; // el contenedor incluye la banda del eje, no la recorta
  const height = plotHeight + axisBand;
  const leftPad = 34;
  const plotWidth = width - leftPad - 8;
  const scale = niceScale(Math.max(...rows.map((row) => row.value), 1));
  const max = scale.max;
  const color = cssVar('--series-1');
  const band = plotWidth / rows.length;
  const barWidth = Math.min(BAR_MAX, band - GAP * 2 - 4);
  const peak = rows.reduce((best, row) => (row.value > best.value ? row : best), rows[0]);

  const root = svg('svg', {
    viewBox: `0 0 ${width} ${height}`,
    width,
    height,
    role: 'group',
    'aria-label': options.ariaLabel || 'Distribución',
  });

  // Grilla: hairline solida, retraida, con ticks redondos.
  const ticks = Math.round(max / scale.step);
  for (let i = 0; i <= ticks; i += 1) {
    const value = scale.step * i;
    const y = plotHeight - (value / max) * plotHeight;
    root.appendChild(
      svg('line', { x1: leftPad, x2: width - 8, y1: y, y2: y, class: i === 0 ? 'baseline' : 'gridline' })
    );
    const tick = svg('text', {
      x: leftPad - 8,
      y,
      'text-anchor': 'end',
      'dominant-baseline': 'middle',
      class: 'axis-text',
    });
    tick.textContent = fmtInt(value);
    root.appendChild(tick);
  }

  rows.forEach((row, index) => {
    const bandLeft = leftPad + index * band;
    const x = bandLeft + (band - barWidth) / 2;
    const barHeight = (row.value / max) * plotHeight;
    const y = plotHeight - barHeight;

    const mark = svg('path', {
      d: vBarPath(x, y, barWidth, barHeight, 4),
      fill: color,
      class: 'mark',
    });
    root.appendChild(mark);

    const tickLabel = svg('text', {
      x: bandLeft + band / 2,
      y: plotHeight + 16,
      'text-anchor': 'middle',
      class: 'axis-text',
    });
    tickLabel.textContent = row.label;
    root.appendChild(tickLabel);

    if (row === peak && row.value > 0) {
      const cap = svg('text', {
        x: bandLeft + band / 2,
        y: y - 6,
        'text-anchor': 'middle',
        class: 'value-label',
      });
      cap.textContent = fmtInt(row.value);
      root.appendChild(cap);
    }

    const hit = svg('rect', {
      x: bandLeft,
      y: 0,
      width: band,
      height: plotHeight,
      class: 'hit',
    });
    bindHit(hit, mark, {
      value: fmtInt(row.value),
      label: row.tooltipLabel || row.label,
      color,
      extra: row.extra,
    });
    root.appendChild(hit);
  });

  container.appendChild(root);
}

/* --- Tablas equivalentes ------------------------------------------------- */

function renderTable(container, columns, rows) {
  clear(container);
  const table = el('table');
  const thead = el('thead');
  const headRow = el('tr');
  columns.forEach((column) => {
    headRow.appendChild(el('th', column.numeric ? { class: 'num' } : {}, column.label));
  });
  thead.appendChild(headRow);
  table.appendChild(thead);

  const tbody = el('tbody');
  rows.forEach((row) => {
    const tr = el('tr');
    columns.forEach((column) => {
      const value = row[column.key];
      const classes = [column.numeric ? 'num' : '', column.wrap ? 'wrap' : ''].filter(Boolean).join(' ');
      if (column.render) {
        const td = el('td', classes ? { class: classes } : {});
        column.render(td, row);
        tr.appendChild(td);
      } else {
        tr.appendChild(el('td', classes ? { class: classes } : {}, value === null || value === undefined || value === '' ? '—' : value));
      }
    });
    tbody.appendChild(tr);
  });
  table.appendChild(tbody);
  container.appendChild(table);
}

/* --- Render principal ---------------------------------------------------- */

function render() {
  const jobs = visibleJobs();

  document.getElementById('shown-count').textContent =
    jobs.length === state.jobs.length
      ? `${fmtInt(jobs.length)} avisos`
      : `${fmtInt(jobs.length)} de ${fmtInt(state.jobs.length)} avisos`;

  renderHero(jobs);
  renderTiles(jobs);
  renderFunnel(jobs);
  renderOutcomes(jobs);
  renderScores(jobs);
  renderSites(jobs);
  renderAttempts(jobs);
}

function renderHero(jobs) {
  const sent = jobs.filter((job) => outcomeGroup(job)?.id === 'ok').length;
  const attempts = jobs.filter(hasAttempt).length;
  document.getElementById('hero-value').textContent = fmtInt(sent);
  const foot = document.getElementById('hero-foot');
  if (!attempts) {
    foot.textContent = 'Todavía no hay intentos registrados.';
    return;
  }
  const rate = Math.round((sent / attempts) * 100);
  const word = attempts === 1 ? 'intento' : 'intentos';
  foot.textContent = `${fmtInt(attempts)} ${word} · ${rate}% enviadas con éxito`;
}

function renderTiles(jobs) {
  const scored = jobs.filter((job) => scoreOf(job) !== null);
  const strong = scored.filter((job) => scoreOf(job) >= 7);
  const failed = jobs.filter((job) => outcomeGroup(job)?.id === 'failed').length;
  const avg = scored.length
    ? (scored.reduce((sum, job) => sum + scoreOf(job), 0) / scored.length).toFixed(1)
    : '—';

  const tiles = [
    { label: 'Avisos', value: fmtInt(jobs.length) },
    { label: 'Puntuados', value: fmtInt(scored.length), foot: `promedio ${avg}` },
    { label: 'Calce alto (7+)', value: fmtInt(strong.length) },
    { label: 'Fallidas', value: fmtInt(failed) },
  ];

  const container = document.getElementById('tiles');
  clear(container);
  tiles.forEach((tile) => {
    const node = el('div');
    node.appendChild(el('div', { class: 'tile-label' }, tile.label));
    node.appendChild(el('div', { class: 'tile-value' }, tile.value));
    if (tile.foot) node.appendChild(el('div', { class: 'tile-foot' }, tile.foot));
    container.appendChild(node);
  });
}

function funnelRows(jobs) {
  return STAGES.map((stage) => {
    const count = jobs.filter(stage.test).length;
    const share = jobs.length ? Math.round((count / jobs.length) * 100) : 0;
    return { key: stage.id, label: stage.label, value: count, share, extra: `${share}% de los avisos` };
  });
}

function renderFunnel(jobs) {
  const rows = funnelRows(jobs);
  renderHBars(document.getElementById('funnel-chart'), rows, {
    ariaLabel: 'Avisos por etapa del pipeline',
    emptyText: 'Sin avisos. Corre "applypilot run" para poblar la base.',
  });
  renderTable(
    document.getElementById('funnel-table'),
    [
      { key: 'label', label: 'Etapa' },
      { key: 'value', label: 'Avisos', numeric: true },
      { key: 'share', label: '% del total', numeric: true },
    ],
    rows
  );
}

function outcomeRows(jobs) {
  const counts = new Map();
  jobs.forEach((job) => {
    const group = outcomeGroup(job);
    if (!group) return;
    const current = counts.get(group.id) || { group, value: 0, statuses: new Set() };
    current.value += 1;
    current.statuses.add(rawOutcome(job));
    counts.set(group.id, current);
  });
  return [...counts.values()]
    .sort((a, b) => b.value - a.value)
    .map((entry) => ({
      key: entry.group.id,
      label: `${entry.group.icon} ${entry.group.label}`,
      plainLabel: entry.group.label,
      value: entry.value,
      color: cssVar(TONE_VAR[entry.group.tone]),
      tone: entry.group.tone,
      icon: entry.group.icon,
      statuses: [...entry.statuses].filter(Boolean).join(', '),
      extra: [...entry.statuses].filter(Boolean).join(', '),
    }));
}

function renderOutcomes(jobs) {
  const rows = outcomeRows(jobs);
  renderHBars(document.getElementById('outcome-chart'), rows, {
    ariaLabel: 'Resultado de las postulaciones',
    emptyText: 'Ninguna postulación intentada todavía.',
    labelWidth: 160,
  });

  // El color de estado nunca va solo: cada entrada lleva icono y texto.
  const legend = document.getElementById('outcome-legend');
  clear(legend);
  rows.forEach((row) => {
    const item = el('div', { class: 'legend-item' });
    const swatch = el('span', { class: 'legend-swatch' });
    swatch.style.background = row.color;
    item.appendChild(swatch);
    item.appendChild(el('span', {}, `${row.icon} ${row.plainLabel}`));
    legend.appendChild(item);
  });

  renderTable(
    document.getElementById('outcome-table'),
    [
      { key: 'plainLabel', label: 'Resultado' },
      { key: 'value', label: 'Postulaciones', numeric: true },
      { key: 'statuses', label: 'Estados en la base', wrap: true },
    ],
    rows
  );
}

function renderScores(jobs) {
  const buckets = Array.from({ length: 10 }, (_, index) => ({
    key: index + 1,
    label: String(index + 1),
    tooltipLabel: `Puntaje ${index + 1}`,
    value: 0,
  }));
  jobs.forEach((job) => {
    const score = scoreOf(job);
    if (score === null) return;
    const index = Math.min(10, Math.max(1, Math.round(score))) - 1;
    buckets[index].value += 1;
  });

  renderColumns(document.getElementById('score-chart'), buckets, {
    ariaLabel: 'Distribución de puntajes de calce',
    emptyText: 'Ningún aviso puntuado todavía.',
  });
  renderTable(
    document.getElementById('score-table'),
    [
      { key: 'label', label: 'Puntaje', numeric: true },
      { key: 'value', label: 'Avisos', numeric: true },
    ],
    buckets
  );
}

function siteRows(jobs) {
  const counts = new Map();
  jobs.forEach((job) => {
    const site = String(job.site || '').trim() || 'desconocido';
    const current = counts.get(site) || { label: site, value: 0, scoreSum: 0, scored: 0, strong: 0 };
    current.value += 1;
    const score = scoreOf(job);
    if (score !== null) {
      current.scoreSum += score;
      current.scored += 1;
      if (score >= 7) current.strong += 1;
    }
    counts.set(site, current);
  });
  return [...counts.values()]
    .sort((a, b) => b.value - a.value)
    .map((entry) => ({
      ...entry,
      avg: entry.scored ? (entry.scoreSum / entry.scored).toFixed(1) : '—',
      extra: entry.scored ? `promedio ${(entry.scoreSum / entry.scored).toFixed(1)} · ${entry.strong} con 7+` : 'sin puntuar',
    }));
}

function renderSites(jobs) {
  const rows = siteRows(jobs);
  // Cantidad y promedio son escalas distintas: la barra grafica solo la
  // cantidad y el promedio vive en la tabla. Nunca un segundo eje.
  renderHBars(document.getElementById('site-chart'), rows, {
    ariaLabel: 'Avisos por portal',
    emptyText: 'Sin avisos todavía.',
  });
  renderTable(
    document.getElementById('site-table'),
    [
      { key: 'label', label: 'Portal' },
      { key: 'value', label: 'Avisos', numeric: true },
      { key: 'avg', label: 'Puntaje promedio', numeric: true },
      { key: 'strong', label: 'Con 7+', numeric: true },
    ],
    rows
  );
}

function renderAttempts(jobs) {
  const rows = jobs
    .filter(hasAttempt)
    .sort((a, b) => String(b.last_attempted_at || b.applied_at || '').localeCompare(String(a.last_attempted_at || a.applied_at || '')))
    .slice(0, 100)
    .map((job) => {
      const group = outcomeGroup(job);
      return {
        title: job.title || '(sin título)',
        site: job.site || '—',
        score: scoreOf(job) === null ? '—' : scoreOf(job),
        group,
        attempts: job.apply_attempts || 0,
        duration: fmtDuration(job.apply_duration_ms),
        confidence: job.verification_confidence || '—',
        when: fmtDate(job.last_attempted_at || job.applied_at),
        error: job.apply_error || '',
        url: job.application_url || job.url || '',
      };
    });

  const container = document.getElementById('attempts-table');
  if (!rows.length) {
    clear(container);
    container.appendChild(
      el('p', { class: 'empty' }, 'Ninguna postulación intentada todavía. Empieza con "applypilot apply --dry-run".')
    );
    return;
  }

  renderTable(
    container,
    [
      {
        key: 'title',
        label: 'Aviso',
        wrap: true,
        render: (td, row) => {
          if (row.url) {
            const link = el('a', { href: row.url, target: '_blank', rel: 'noopener noreferrer' }, row.title);
            td.appendChild(link);
          } else {
            td.textContent = row.title;
          }
        },
      },
      { key: 'site', label: 'Portal' },
      { key: 'score', label: 'Puntaje', numeric: true },
      {
        key: 'group',
        label: 'Resultado',
        render: (td, row) => {
          const wrap = el('span', { class: 'status-cell' });
          const dot = el('span', { class: 'status-dot' });
          dot.style.background = cssVar(TONE_VAR[row.group?.tone || 'neutral']);
          wrap.appendChild(dot);
          wrap.appendChild(el('span', {}, `${row.group?.icon || '•'} ${row.group?.label || '—'}`));
          td.appendChild(wrap);
        },
      },
      { key: 'attempts', label: 'Intentos', numeric: true },
      { key: 'duration', label: 'Duración', numeric: true },
      { key: 'confidence', label: 'Verificación' },
      { key: 'when', label: 'Último intento' },
      { key: 'error', label: 'Error', wrap: true },
    ],
    rows
  );
}

/* --- Controles ----------------------------------------------------------- */

const SCORE_PRESETS = [
  { label: 'Todos', value: 0 },
  { label: '5+', value: 5 },
  { label: '7+', value: 7 },
  { label: '8+', value: 8 },
];

function buildFilters() {
  const scoreFilter = document.getElementById('score-filter');
  clear(scoreFilter);
  SCORE_PRESETS.forEach((preset) => {
    const button = el('button', { type: 'button', 'aria-pressed': String(state.minScore === preset.value) }, preset.label);
    button.addEventListener('click', () => {
      state.minScore = preset.value;
      [...scoreFilter.children].forEach((child) => child.setAttribute('aria-pressed', String(child === button)));
      render();
    });
    scoreFilter.appendChild(button);
  });

  const siteFilter = document.getElementById('site-filter');
  const sites = [...new Set(state.jobs.map((job) => String(job.site || '').trim()).filter(Boolean))].sort();
  sites.forEach((site) => siteFilter.appendChild(el('option', { value: site }, site)));
  siteFilter.addEventListener('change', () => {
    state.site = siteFilter.value;
    render();
  });

  const search = document.getElementById('search-filter');
  let timer;
  search.addEventListener('input', () => {
    clearTimeout(timer);
    timer = setTimeout(() => {
      state.query = search.value;
      render();
    }, 150);
  });

  document.querySelectorAll('.table-toggle').forEach((button) => {
    button.addEventListener('click', () => {
      const target = document.getElementById(button.dataset.table);
      const willShow = target.hidden;
      target.hidden = !willShow;
      button.setAttribute('aria-expanded', String(willShow));
      button.textContent = willShow ? 'Ocultar tabla' : 'Ver tabla';
    });
  });
}

function showBanner(message, hint) {
  const banner = document.getElementById('banner');
  clear(banner);
  banner.appendChild(el('strong', {}, 'No se pudo leer la base de ApplyPilot'));
  banner.appendChild(el('p', {}, message));
  if (hint) {
    const p = el('p', {}, 'Prueba con: ');
    p.appendChild(el('code', {}, hint));
    banner.appendChild(p);
  }
  banner.hidden = false;
  document.getElementById('subtitle').textContent = 'Sin datos';
}

async function load() {
  let payload;
  try {
    const response = await fetch('/api/jobs');
    payload = await response.json();
    if (!response.ok) {
      showBanner(payload.error || `El servidor respondió ${response.status}.`, 'applypilot run');
      return;
    }
  } catch (error) {
    showBanner(`No se pudo contactar al servidor local: ${error.message}`, 'python3 server.py');
    return;
  }

  state.jobs = payload.jobs || [];
  document.getElementById('subtitle').textContent = `${fmtInt(state.jobs.length)} avisos en ${payload.db_path}`;
  document.getElementById('filters').hidden = false;
  document.getElementById('content').hidden = false;
  buildFilters();
  render();
}

let resizeTimer;
window.addEventListener('resize', () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(render, 150);
});

// Los tokens cambian con el tema: hay que volver a pintar las marcas.
window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
  if (state.jobs.length) render();
});

load();
