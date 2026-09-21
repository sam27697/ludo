#!/usr/bin/env node
/*
UX probe: measure what a web page actually renders, not what the code claims.

Usage (run from the repository root; needs the playwright package and a browser):
  node .uxprogram/kit/tools/ux_probe.mjs --url URL [--url URL2 ...] --out DIR
    [--viewports 320x640,390x844,768x1024,1440x900] [--color-scheme light|dark|both]
    [--reduced-motion] [--forced-colors] [--locale ar-AE] [--browser chromium|firefox|webkit]
    [--storage-state auth.json] [--wait-ms 800] [--wait-for SELECTOR]
    [--expect TEXT ...]          text that must appear in the served HTML (build id, bundle hash)
    [--axe] [--inventory] [--dump-styles SELECTOR]
    [--min-pointer 24] [--min-touch 44] [--touch-max-width 820] [--overlap 0.15]
    [--exclude SELECTOR] [--console-errors warn|fail] [--fail-on fail|warn] [--allow-service-workers]

Checks per URL x viewport x color scheme:
  navigation        page loads (FAIL)
  stale-build       every --expect text is present in the served HTML (FAIL)
  h-overflow        page scrolls sideways (FAIL; WCAG 1.4.10 reflow)
  obscured          a control stays covered by a fixed or sticky element at every scroll
                    alignment tried: start, center and end (FAIL above --overlap)
  target-size       control smaller than --min-pointer (with the WCAG 2.5.8 spacing
                    exception) or, on touch viewports, smaller than --min-touch (FAIL)
  no-name           control without an accessible name (FAIL); placeholder only (WARN)
  clipped-text      text cut off by overflow without an ellipsis (WARN)
  console           console errors (WARN, or FAIL with --console-errors fail)
  axe               axe-core WCAG 2.x A/AA: critical or serious FAIL, others WARN (--axe)
Writes DIR/probe.json, DIR/probe.md and full-page screenshots.
Prints PROBE: PASS or PROBE: FAIL. Exit 0 pass, 1 fail, 2 setup error.
*/
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';

const VERSION = 'ux_probe 2';

function parseArgs(argv) {
  const o = {
    url: [], expect: [], viewports: '320x640,390x844,768x1024,1440x900', colorScheme: 'light',
    reducedMotion: false, forcedColors: false, locale: null, browser: 'chromium', storageState: null,
    waitMs: 800, waitFor: null, axe: false, inventory: false, dumpStyles: null, minPointer: 24,
    minTouch: 44, touchMaxWidth: 820, overlap: 0.15, exclude: null, consoleErrors: 'warn',
    failOn: 'fail', allowServiceWorkers: false, out: null,
  };
  const flags = { '--reduced-motion': 'reducedMotion', '--forced-colors': 'forcedColors', '--axe': 'axe',
    '--inventory': 'inventory', '--allow-service-workers': 'allowServiceWorkers' };
  const values = { '--viewports': 'viewports', '--color-scheme': 'colorScheme', '--locale': 'locale',
    '--browser': 'browser', '--storage-state': 'storageState', '--wait-ms': 'waitMs', '--wait-for': 'waitFor',
    '--dump-styles': 'dumpStyles', '--min-pointer': 'minPointer', '--min-touch': 'minTouch',
    '--touch-max-width': 'touchMaxWidth', '--overlap': 'overlap', '--exclude': 'exclude',
    '--console-errors': 'consoleErrors', '--fail-on': 'failOn', '--out': 'out' };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--url') o.url.push(argv[++i]);
    else if (a === '--expect') o.expect.push(argv[++i]);
    else if (flags[a]) o[flags[a]] = true;
    else if (values[a]) o[values[a]] = argv[++i];
    else if (a === '-h' || a === '--help') { o.help = true; }
    else throw new Error('unknown argument: ' + a);
  }
  for (const k of ['waitMs', 'minPointer', 'minTouch', 'touchMaxWidth', 'overlap']) o[k] = Number(o[k]);
  return o;
}

async function loadModule(name) {
  try { return await import(name); } catch (e) { /* try other locations */ }
  for (const base of [process.cwd(), (() => { try { return execSync('npm root -g', { encoding: 'utf8' }).trim(); } catch { return null; } })()]) {
    if (!base) continue;
    try { return createRequire(path.join(base, 'noop.js'))(name); } catch (e) { /* next */ }
  }
  return null;
}

function resolveAxeSource() {
  for (const base of [process.cwd(), (() => { try { return execSync('npm root -g', { encoding: 'utf8' }).trim(); } catch { return null; } })()]) {
    if (!base) continue;
    try { return fs.readFileSync(createRequire(path.join(base, 'noop.js')).resolve('axe-core/axe.min.js'), 'utf8'); } catch (e) { /* next */ }
  }
  return null;
}

// Runs inside the page.
async function auditInPage(opts) {
  const INTERACTIVE = 'a[href],button,input:not([type=hidden]),select,textarea,summary,[role=button],[role=link],[role=checkbox],[role=switch],[role=tab],[role=menuitem],[role=radio],[role=option],[tabindex]:not([tabindex="-1"]),[contenteditable=""],[contenteditable=true]';
  const frames = () => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
  const excluded = opts.exclude ? Array.from(document.querySelectorAll(opts.exclude)) : [];
  const isExcluded = el => excluded.some(x => x === el || x.contains(el));
  const cssPath = el => {
    if (!el || el.nodeType !== 1) return '';
    const parts = [];
    for (let n = el; n && n.nodeType === 1 && parts.length < 4; n = n.parentElement) {
      if (n.id) { parts.unshift(n.tagName.toLowerCase() + '#' + n.id); break; }
      let p = n.tagName.toLowerCase();
      const cls = Array.from(n.classList).slice(0, 2);
      if (cls.length) p += '.' + cls.join('.');
      const sib = n.parentElement ? Array.from(n.parentElement.children).filter(c => c.tagName === n.tagName) : [];
      if (sib.length > 1) p += `:nth-of-type(${sib.indexOf(n) + 1})`;
      parts.unshift(p);
    }
    return parts.join(' > ');
  };
  const isVisible = el => {
    const s = getComputedStyle(el);
    if (s.display === 'none' || s.visibility === 'hidden' || parseFloat(s.opacity) === 0) return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  };
  const inter = (a, b) => {
    const l = Math.max(a.left, b.left), t = Math.max(a.top, b.top);
    const r = Math.min(a.right, b.right), btm = Math.min(a.bottom, b.bottom);
    return r > l && btm > t ? { left: l, top: t, right: r, bottom: btm } : null;
  };
  const area = r => (r ? Math.max(0, r.right - r.left) * Math.max(0, r.bottom - r.top) : 0);
  const vw = window.innerWidth, vh = window.innerHeight;
  const viewportRect = { left: 0, top: 0, right: vw, bottom: vh };
  const controls = () => Array.from(document.querySelectorAll(INTERACTIVE))
    .filter(el => !isExcluded(el) && isVisible(el) && !el.closest('[inert],[aria-hidden="true"]'));
  const fixedBoxes = () => {
    const out = [];
    for (const el of document.querySelectorAll('body *')) {
      const pos = getComputedStyle(el).position;
      if ((pos === 'fixed' || pos === 'sticky') && !isExcluded(el) && isVisible(el)) {
        const r = el.getBoundingClientRect();
        if (area(inter(r, viewportRect)) < 0.6 * vw * vh) out.push({ el, r });
        else out.push({ el, r, overlay: true });
      }
    }
    return out;
  };
  const coverage = (el, boxes) => {
    const r = el.getBoundingClientRect();
    let clip = inter(r, viewportRect);
    for (let p = el.parentElement; p && clip; p = p.parentElement) {
      const s = getComputedStyle(p);
      if (/(auto|scroll|hidden|clip)/.test(s.overflowY + s.overflowX)) clip = inter(clip, p.getBoundingClientRect());
    }
    if (!clip) return null;
    let worst = { frac: 0, by: null };
    for (const b of boxes) {
      if (b.overlay || b.el === el || b.el.contains(el) || el.contains(b.el)) continue;
      const frac = area(inter(clip, b.el.getBoundingClientRect())) / Math.max(1, area(r));
      if (frac > worst.frac) worst = { frac, by: b.el };
    }
    return worst;
  };
  const result = { checks: {} };
  const add = (id, status, item) => {
    const c = result.checks[id] || (result.checks[id] = { status: 'PASS', items: [] });
    const rank = { PASS: 0, WARN: 1, FAIL: 2 };
    if (rank[status] > rank[c.status]) c.status = status;
    if (item && c.items.length < 25) c.items.push(item);
  };
  for (const id of ['stale-build', 'h-overflow', 'obscured', 'target-size', 'no-name', 'clipped-text']) add(id, 'PASS');

  // stale build
  const html = document.documentElement.outerHTML;
  for (const t of opts.expect) if (!html.includes(t)) add('stale-build', 'FAIL', { missing: t });

  // horizontal overflow
  const layoutW = Math.min(document.documentElement.clientWidth, opts.viewportWidth);
  const sw = document.scrollingElement.scrollWidth;
  if (sw > layoutW + 1 || window.innerWidth > opts.viewportWidth + 1) {
    const wide = Array.from(document.querySelectorAll('body *')).filter(el => {
      const r = el.getBoundingClientRect();
      if (r.right <= layoutW + 1 || !isVisible(el)) return false;
      for (let p = el.parentElement; p; p = p.parentElement) {
        if (/(auto|scroll|hidden|clip)/.test(getComputedStyle(p).overflowX) && p !== document.body && p !== document.documentElement) return false;
      }
      return true;
    }).slice(0, 5).map(el => ({ el: cssPath(el), right: Math.round(el.getBoundingClientRect().right) }));
    add('h-overflow', 'FAIL', { scrollWidth: sw, viewport: opts.viewportWidth, visualWidth: window.innerWidth, widest: wide });
  }

  // obscured controls
  if ((await fixedBoxes()).some(b => b.overlay)) add('obscured', 'WARN', { note: 'a fixed element covers over 60% of the viewport (overlay or backdrop); it was ignored' });
  const scrollers = [document.scrollingElement].concat(Array.from(document.querySelectorAll('body *')).filter(el => {
    const s = getComputedStyle(el);
    return /(auto|scroll|overlay)/.test(s.overflowY) && el.scrollHeight > el.clientHeight + 1 && isVisible(el);
  }));
  const candidates = new Set();
  for (const sc of scrollers) {
    const max = sc.scrollHeight - sc.clientHeight;
    for (const pos of [0, Math.round(max / 2), max]) {
      sc.scrollTo({ top: pos, behavior: 'instant' });
      await frames();
      const boxes = fixedBoxes();
      for (const el of controls()) {
        if (sc !== document.scrollingElement && !sc.contains(el)) continue;
        const cov = coverage(el, boxes);
        if (cov && cov.frac > opts.overlap) candidates.add(el);
      }
    }
    sc.scrollTo({ top: 0, behavior: 'instant' });
  }
  for (const el of candidates) {
    let best = { frac: 2, by: null, align: null };
    for (const align of ['center', 'start', 'end']) {
      el.scrollIntoView({ block: align, inline: 'nearest', behavior: 'instant' });
      await frames();
      const cov = coverage(el, fixedBoxes());
      const frac = cov ? cov.frac : 1;
      if (frac < best.frac) best = { frac, by: cov && cov.by, align };
      if (frac <= opts.overlap) break;
    }
    if (best.frac > opts.overlap) {
      add('obscured', 'FAIL', { el: cssPath(el), coveredBy: cssPath(best.by), overlap: Math.round(best.frac * 100) + '%', threshold: Math.round(opts.overlap * 100) + '%' });
    }
  }
  for (const sc of scrollers) sc.scrollTo({ top: 0, behavior: 'instant' });
  await frames();

  // target size (WCAG 2.5.8 with spacing exception on pointer viewports)
  const all = controls().filter(el => !(el.disabled || el.getAttribute('aria-disabled') === 'true'));
  const rects = new Map(all.map(el => [el, el.getBoundingClientRect()]));
  const min = opts.touch ? opts.minTouch : opts.minPointer;
  const isInlineLink = el => {
    if (el.tagName !== 'A' || getComputedStyle(el).display !== 'inline' || !el.parentElement) return false;
    return el.parentElement.textContent.trim().length > (el.textContent || '').trim().length + 3;
  };
  const small = all.filter(el => { const r = rects.get(el); return (r.width < min || r.height < min) && !isInlineLink(el); });
  const center = r => ({ x: r.left + r.width / 2, y: r.top + r.height / 2 });
  const distToRect = (p, r) => Math.hypot(Math.max(r.left - p.x, 0, p.x - r.right), Math.max(r.top - p.y, 0, p.y - r.bottom));
  for (const el of small) {
    const r = rects.get(el);
    const size = Math.round(r.width) + 'x' + Math.round(r.height);
    const nativeToggle = el.tagName === 'INPUT' && /^(checkbox|radio)$/.test(el.type);
    if (opts.touch) { add('target-size', 'FAIL', { el: cssPath(el), size, min: min + 'x' + min, platform: 'touch' }); continue; }
    const c = center(r);
    const conflict = all.find(o => {
      if (o === el || o.contains(el) || el.contains(o)) return false;
      const orr = rects.get(o);
      return small.includes(o) ? Math.hypot(c.x - center(orr).x, c.y - center(orr).y) < min : distToRect(c, orr) < min / 2;
    });
    if (conflict) add('target-size', nativeToggle ? 'WARN' : 'FAIL', { el: cssPath(el), size, min: min + 'x' + min, tooCloseTo: cssPath(conflict) });
  }

  // accessible names
  const nameOf = el => {
    const al = el.getAttribute('aria-label');
    if (al && al.trim()) return al.trim();
    const lb = el.getAttribute('aria-labelledby');
    if (lb) { const t = lb.split(/\s+/).map(id => (document.getElementById(id) || {}).textContent || '').join(' ').trim(); if (t) return t; }
    if (el.labels && el.labels.length) { const t = Array.from(el.labels).map(l => l.textContent).join(' ').trim(); if (t) return t; }
    if (el.tagName === 'INPUT' && /^(submit|button|reset)$/.test(el.type) && el.value) return el.value;
    if (el.tagName === 'INPUT' && el.type === 'image' && el.alt) return el.alt;
    const txt = (el.innerText || el.textContent || '').trim();
    if (txt && !/^(INPUT|SELECT|TEXTAREA)$/.test(el.tagName)) return txt;
    const img = Array.from(el.querySelectorAll('img[alt],[role=img][aria-label],svg[aria-label]')).map(i => i.getAttribute('alt') || i.getAttribute('aria-label')).join(' ').trim();
    if (img) return img;
    const svgTitle = el.querySelector('svg title');
    if (svgTitle && svgTitle.textContent.trim()) return svgTitle.textContent.trim();
    const title = el.getAttribute('title');
    if (title && title.trim()) return title.trim();
    return '';
  };
  for (const el of all) {
    if (nameOf(el)) continue;
    const ph = el.getAttribute('placeholder');
    if (ph && ph.trim()) add('no-name', 'WARN', { el: cssPath(el), note: 'placeholder is not a label: ' + ph.trim().slice(0, 40) });
    else add('no-name', 'FAIL', { el: cssPath(el), tag: el.tagName.toLowerCase() });
  }

  // clipped text
  for (const el of document.querySelectorAll('body *')) {
    if (/^(INPUT|TEXTAREA|SELECT|SCRIPT|STYLE|svg)$/i.test(el.tagName) || !isVisible(el)) continue;
    const hasText = Array.from(el.childNodes).some(n => n.nodeType === 3 && n.textContent.trim());
    if (!hasText) continue;
    const s = getComputedStyle(el);
    const xClip = /(hidden|clip)/.test(s.overflowX) && el.scrollWidth > el.clientWidth + 1 && s.textOverflow !== 'ellipsis';
    const yClip = /(hidden|clip)/.test(s.overflowY) && el.scrollHeight > el.clientHeight + 1 && !(s.webkitLineClamp && s.webkitLineClamp !== 'none');
    if (xClip || yClip) add('clipped-text', 'WARN', { el: cssPath(el), text: el.textContent.trim().slice(0, 40), axis: xClip ? 'x' : 'y' });
  }

  // style inventory
  if (opts.inventory) {
    const bags = { colors: new Map(), backgrounds: new Map(), fontSizes: new Map(), fontFamilies: new Map(), fontWeights: new Map(), radii: new Map(), shadows: new Map(), spacing: new Map() };
    const bump = (m, v) => m.set(v, (m.get(v) || 0) + 1);
    let n = 0;
    for (const el of document.querySelectorAll('body *')) {
      if (n++ > 6000) break;
      if (!isVisible(el)) continue;
      const s = getComputedStyle(el);
      if (Array.from(el.childNodes).some(c => c.nodeType === 3 && c.textContent.trim())) {
        bump(bags.colors, s.color); bump(bags.fontSizes, s.fontSize); bump(bags.fontWeights, s.fontWeight);
        bump(bags.fontFamilies, s.fontFamily.split(',')[0].trim().replace(/["']/g, ''));
      }
      if (s.backgroundColor !== 'rgba(0, 0, 0, 0)' && s.backgroundColor !== 'transparent') bump(bags.backgrounds, s.backgroundColor);
      if (s.borderRadius !== '0px') bump(bags.radii, s.borderRadius);
      if (s.boxShadow !== 'none') bump(bags.shadows, s.boxShadow);
      for (const p of ['marginTop', 'marginRight', 'marginBottom', 'marginLeft', 'paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft', 'rowGap', 'columnGap']) {
        const v = s[p];
        if (v && v !== '0px' && v !== 'normal' && v !== 'auto') bump(bags.spacing, v);
      }
    }
    result.inventory = {};
    for (const [k, m] of Object.entries(bags)) {
      result.inventory[k] = { distinct: m.size, top: Array.from(m.entries()).sort((a, b) => b[1] - a[1]).slice(0, 12) };
    }
  }

  if (opts.dumpStyles) {
    const props = ['display', 'position', 'color', 'background-color', 'font-family', 'font-size', 'font-weight', 'line-height', 'letter-spacing', 'padding', 'margin', 'border', 'border-radius', 'box-shadow', 'opacity', 'transform', 'transition', 'animation-name', 'z-index'];
    result.styles = Array.from(document.querySelectorAll(opts.dumpStyles)).slice(0, 60).map(el => {
      const s = getComputedStyle(el); const r = el.getBoundingClientRect();
      return { el: cssPath(el), rect: [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)], style: Object.fromEntries(props.map(p => [p, s.getPropertyValue(p)])) };
    });
  }
  return result;
}

async function main() {
  let opts;
  try { opts = parseArgs(process.argv.slice(2)); } catch (e) { console.log('PROBE: FAIL ' + e.message); return 2; }
  if (opts.help || !opts.url.length || !opts.out) {
    console.log('usage: node ux_probe.mjs --url URL --out DIR [options]  (see the header of this file)');
    return 2;
  }
  const pw = await loadModule('playwright');
  if (!pw) {
    console.log('PROBE: FAIL playwright not found. Install it in the project: npm i -D playwright && npx playwright install chromium');
    return 2;
  }
  const axeSource = opts.axe ? resolveAxeSource() : null;
  if (opts.axe && !axeSource) {
    console.log('PROBE: FAIL --axe given but axe-core not found. Install it: npm i -D axe-core');
    return 2;
  }
  const viewports = opts.viewports.split(',').map(v => {
    const [w, h] = v.trim().toLowerCase().split('x').map(Number);
    if (!w || !h) throw new Error('bad viewport ' + v);
    return { width: w, height: h };
  });
  const schemes = opts.colorScheme === 'both' ? ['light', 'dark'] : [opts.colorScheme];
  fs.mkdirSync(opts.out, { recursive: true });
  let browser;
  try {
    browser = await pw[opts.browser].launch();
  } catch (e) {
    console.log('PROBE: FAIL cannot launch ' + opts.browser + ': ' + String(e.message).split('\n')[0] + ' (run: npx playwright install ' + opts.browser + ')');
    return 2;
  }
  const report = { tool: VERSION, started: new Date().toISOString(), options: opts, pages: [] };
  let fails = 0, warns = 0;
  for (const url of opts.url) {
    for (const vp of viewports) {
      for (const scheme of schemes) {
        const touch = vp.width <= opts.touchMaxWidth;
        const ctxOpts = { viewport: vp, deviceScaleFactor: 1, hasTouch: touch, colorScheme: scheme,
          reducedMotion: opts.reducedMotion ? 'reduce' : 'no-preference', forcedColors: opts.forcedColors ? 'active' : 'none',
          serviceWorkers: opts.allowServiceWorkers ? 'allow' : 'block' };
        if (opts.browser !== 'firefox') ctxOpts.isMobile = touch;
        if (opts.locale) ctxOpts.locale = opts.locale;
        if (opts.storageState) ctxOpts.storageState = opts.storageState;
        const context = await browser.newContext(ctxOpts);
        const page = await context.newPage();
        const consoleErrors = [];
        page.on('console', m => { if (m.type() === 'error') consoleErrors.push(m.text().slice(0, 200)); });
        page.on('pageerror', e => consoleErrors.push(String(e.message).slice(0, 200)));
        const slug = url.replace(/^https?:\/\//, '').replace(/[^A-Za-z0-9]+/g, '-').slice(0, 50);
        const entry = { url, viewport: `${vp.width}x${vp.height}`, scheme, touch, checks: {} };
        try {
          await page.goto(url, { waitUntil: 'load', timeout: 60000 });
          await page.waitForLoadState('networkidle', { timeout: 5000 }).catch(() => {});
          if (opts.waitFor) await page.waitForSelector(opts.waitFor, { timeout: 15000 });
          await page.waitForTimeout(opts.waitMs);
          await page.evaluate(() => Promise.race([
            Promise.all(document.getAnimations().filter(a => a.effect && a.effect.getComputedTiming().iterations !== Infinity).map(a => a.finished.catch(() => {}))),
            new Promise(r => setTimeout(r, 3000))]));
          const res = await page.evaluate(auditInPage, { exclude: opts.exclude, overlap: opts.overlap, minPointer: opts.minPointer, minTouch: opts.minTouch, touch, viewportWidth: vp.width, expect: opts.expect, inventory: opts.inventory, dumpStyles: opts.dumpStyles });
          entry.checks = res.checks;
          if (res.inventory) entry.inventory = res.inventory;
          if (res.styles) entry.styles = res.styles;
          entry.checks.console = { status: consoleErrors.length ? (opts.consoleErrors === 'fail' ? 'FAIL' : 'WARN') : 'PASS', items: consoleErrors.slice(0, 10) };
          if (axeSource) {
            await page.addScriptTag({ content: axeSource });
            const axe = await page.evaluate(async () => {
              const r = await window.axe.run(document, { runOnly: { type: 'tag', values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa', 'wcag22aa'] }, resultTypes: ['violations'] });
              return r.violations.map(v => ({ id: v.id, impact: v.impact, help: v.help, nodes: v.nodes.length, targets: v.nodes.slice(0, 3).map(n => n.target.join(' ')) }));
            });
            const bad = axe.filter(v => v.impact === 'critical' || v.impact === 'serious');
            entry.checks.axe = { status: bad.length ? 'FAIL' : (axe.length ? 'WARN' : 'PASS'), items: axe };
          }
          const shot = path.join(opts.out, `${slug}-${vp.width}x${vp.height}-${scheme}.png`);
          await page.screenshot({ path: shot, fullPage: true });
          entry.screenshot = shot.replace(/\\/g, '/');
        } catch (e) {
          entry.checks.navigation = { status: 'FAIL', items: [String(e.message).split('\n')[0]] };
        }
        await context.close();
        const failed = Object.entries(entry.checks).filter(([, c]) => c.status === 'FAIL').map(([k]) => k);
        const warned = Object.entries(entry.checks).filter(([, c]) => c.status === 'WARN').map(([k]) => k);
        fails += failed.length; warns += warned.length;
        console.log(`${failed.length ? 'FAIL' : warned.length ? 'WARN' : 'PASS'} ${url} ${entry.viewport} ${scheme}` +
          (failed.length ? ` fail=[${failed.join(',')}]` : '') + (warned.length ? ` warn=[${warned.join(',')}]` : ''));
        for (const id of failed) for (const it of entry.checks[id].items.slice(0, 5)) console.log('   ' + id + ': ' + JSON.stringify(it));
        report.pages.push(entry);
      }
    }
  }
  await browser.close();
  report.finished = new Date().toISOString();
  report.summary = { fails, warns };
  fs.writeFileSync(path.join(opts.out, 'probe.json'), JSON.stringify(report, null, 2));
  const md = ['| URL | Viewport | Scheme | ' + ['navigation', 'stale-build', 'h-overflow', 'obscured', 'target-size', 'no-name', 'clipped-text', 'console', 'axe'].join(' | ') + ' |',
    '|' + '---|'.repeat(12)];
  for (const p of report.pages) {
    md.push(`| ${p.url} | ${p.viewport} | ${p.scheme} | ` + ['navigation', 'stale-build', 'h-overflow', 'obscured', 'target-size', 'no-name', 'clipped-text', 'console', 'axe']
      .map(k => (p.checks[k] ? p.checks[k].status : (k === 'navigation' ? 'PASS' : '-'))).join(' | ') + ' |');
  }
  fs.writeFileSync(path.join(opts.out, 'probe.md'), md.join('\n') + '\n');
  const failing = fails > 0 || (opts.failOn === 'warn' && warns > 0);
  console.log(`PROBE: ${failing ? 'FAIL' : 'PASS'} (fails=${fails} warns=${warns}) report=${path.join(opts.out, 'probe.json').replace(/\\/g, '/')}`);
  return failing ? 1 : 0;
}

main().then(code => process.exit(code)).catch(e => { console.log('PROBE: FAIL ' + (e && e.stack || e)); process.exit(2); });
