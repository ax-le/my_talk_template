/* talk.js — browser side of the "talk" Quarto extension. Modules (each an IIFE):
     (1) KaTeX patch: \hl / \hlo / \tick macros, equation highlights moved into their parts
     (2) annotations and edges: labels and arrows laid out from where their targets really are
     (3) audio (data-audio buttons, play / stop triggers, autoplay), auto-animate matcher,
         letter-box bleed of section slides, keys A (stop sounds) and R (highlight areas)
     (4) slide-number labels of uncounted slides (test slide, additional-N)
     (5) push transition: .talk-pushing while two slides move
     (6) waiting: delay=S, delay=move, delay=end (one module for every delayed appearance)
     (7) references slide pagination
   Audio (module 3), written by talk.lua from audio= play= stop= delay= loop= volume=: any element
   with data-audio="file.mp3" is a play/stop button; data-autoplay, data-autoplay-delay="1",
   data-loop, data-volume="0.5"; triggers <span class="fragment" data-play="id"> / data-stop-audio;
   YAML talk: audio: {autoplay, delay, stop-on-slide-change}. */

// run fn once reveal.js is ready (at once when it already is); evenWithout: also when the page
// has no reveal.js at all
function talkWhenReady(fn, evenWithout) {
  const go = () => {
    if (!window.Reveal) { if (evenWithout) fn(); return; }
    if (Reveal.isReady && Reveal.isReady()) fn(); else Reveal.on('ready', fn);
  };
  if (document.readyState === 'complete') go(); else window.addEventListener('load', go);
}

/* ---- (1) highlights inside equations ---------------------------------------------
   \hl{STEPS}{colour}{part}   rounded box behind a part of an equation
   \hlo{STEPS}{colour}{part}  oval
   STEPS as for hl=…: 2, 2-4, 2-, 0 ; colour: a name of the highlight palette (teal, purple…)
   KaTeX marks the part with \htmlData; the highlight is then added as fragments.         */
(function () {
  const MACROS = {
    '\\hl': '\\htmlData{hl=#1,hlc=#2}{#3}',
    '\\hlo': '\\htmlData{hl=#1,hlc=#2,hlshape=oval}{#3}',
    // \tick{colour}: a thick vertical tick (a boundary on a time line), palette name or CSS colour
    '\\tick': '\\htmlStyle{color:var(--hl-#1,#1)}{\\rule[-0.1em]{0.28em}{0.85em}}',
  };
  // the fragments were made by talk.lua right after the equation (.hl-math-slot), in order
  function regions(mathEl) {
    const slots = [];
    for (let n = mathEl.nextElementSibling; n && n.classList.contains('hl-math-slot'); n = n.nextElementSibling) slots.push(n);
    mathEl.querySelectorAll('[data-hl]:not(.hl-region)').forEach((el, i) => {
      const slot = slots[i]; if (!slot) return;
      const c = (el.getAttribute('data-hlc') || '').trim();
      el.classList.add('hl-host', 'hl-under');
      if (el.getAttribute('data-hlshape') === 'oval') el.classList.add('hl-oval');
      // a colour name → var(--hl-NAME, NAME), as talk.lua color_value (theme names included)
      if (c) el.style.setProperty('--hl-c', /^#|\(/.test(c) ? c : `var(--hl-${c}, ${c})`);
      if (slot.getAttribute('data-name')) el.setAttribute('data-anchor', slot.getAttribute('data-name'));
      slot.classList.add('placed');
      el.appendChild(slot);
    });
  }
  function patch(k) {
    if (!k || k.__talk) return k;
    const render = k.render;
    k.render = function (tex, el, opts) {
      opts = Object.assign({}, opts || {});
      opts.macros = Object.assign({}, opts.macros || {}, MACROS);
      const trust = opts.trust;
      opts.trust = ctx => ctx.command === '\\htmlData' || ctx.command === '\\htmlStyle' || (typeof trust === 'function' ? trust(ctx) : !!trust);
      const r = render.call(this, tex, el, opts);
      if (el && el.nextElementSibling) regions(el);
      if (window.TalkAnnot) window.TalkAnnot.later();
      return r;
    };
    k.__talk = true;
    return k;
  }
  if (window.katex) patch(window.katex);
  else {
    let k;
    Object.defineProperty(window, 'katex', { configurable: true, get: () => k, set: v => { k = patch(v); } });
  }
})();

/* ---- (2) annotations (and edges, .annot from=): ::: {.annot to="name …" pos=below} label :::  -------------------------
   The label is placed next to the named parts (\hl[name]{…}, \hlo[name]{…}, \eqmark{name}{…},
   or any element id) and an arrow is drawn to each of them, from where they really are.     */
(function () {
  const NS = 'http://www.w3.org/2000/svg';
  function target(sec, n) {
    const el = sec.querySelector(`[data-anchor="${n}"], [data-hlmark="${n}"]`) || sec.querySelector('#' + CSS.escape(n));
    if (!el) return null;
    const f = el.querySelector(':scope > .hl-region > .hl-fill');   // the visible highlight (halo, oval)
    return f || el;
  }
  function box(el, sr, k) {
    const r = el.getBoundingClientRect();
    return { l: (r.left - sr.left) * k, t: (r.top - sr.top) * k, r: (r.right - sr.left) * k, b: (r.bottom - sr.top) * k };
  }
  const cx = b => (b.l + b.r) / 2, cy = b => (b.t + b.b) / 2;
  // point where the segment from the centre of b towards (x, y) leaves the box b (+ gap)
  function exitPoint(b, x, y, gap) {
    const ox = cx(b), oy = cy(b), dx = x - ox, dy = y - oy;
    const hw = (b.r - b.l) / 2 + gap, hh = (b.b - b.t) / 2 + gap;
    const s = 1 / Math.max(Math.abs(dx) / hw || 0, Math.abs(dy) / hh || 0, 1e-9);
    return [ox + dx * s, oy + dy * s];
  }
  // an arrow polygon from (x1, y1) to the tip (x2, y2): shaft w px, head `head` long and 2·hw wide
  function arrow(x1, y1, x2, y2, w, head, hw) {
    const len = Math.hypot(x2 - x1, y2 - y1); if (len < 4) return null;
    const ux = (x2 - x1) / len, uy = (y2 - y1) / len;
    const bx = x2 - ux * head, by = y2 - uy * head, px = -uy, py = ux;
    const pts = [[x1 + px * w / 2, y1 + py * w / 2], [bx + px * w / 2, by + py * w / 2], [bx + px * hw, by + py * hw], [x2, y2],
                 [bx - px * hw, by - py * hw], [bx - px * w / 2, by - py * w / 2], [x1 - px * w / 2, y1 - py * w / 2]];
    const p = document.createElementNS(NS, 'polygon');
    p.setAttribute('points', pts.map(q => q[0].toFixed(1) + ',' + q[1].toFixed(1)).join(' '));
    return p;
  }
  function svgFor(sec, kind) {
    const svg = document.createElementNS(NS, 'svg');
    svg.setAttribute('class', 'annot-arrows ' + kind);
    svg.setAttribute('width', sec.offsetWidth); svg.setAttribute('height', sec.offsetHeight);
    return svg;
  }
  // arrow shape: arrow=fat|thin (presets: shaft width, head length, head half-width), width= / head=
  // (px) override them; without arrow= an edge is 4 px wide with a head 3.5 × as long
  const PRESETS = { fat: [9, 16, 11], thin: [2.5, 9, 5] };
  function shape(a, dflt) {
    const p = PRESETS[a.getAttribute('data-arrow') || dflt];
    const W = parseFloat(a.getAttribute('data-width') || ''), Hd = parseFloat(a.getAttribute('data-head') || '');
    if (p && !W && !Hd) return p;
    const w = W || (p ? p[0] : 4), head = Hd || w * 3.5;
    return [w, head, head * 0.6];
  }
  // [label]{.annot from=a to=b}: an arrow from the edge of #a to the edge of #b, label beside its middle
  function layoutEdge(sec, a, sr, k) {
    const A = target(sec, a.getAttribute('data-from') || ''), B = target(sec, a.getAttribute('data-to') || '');
    const lab = a.querySelector('.annot-edge-label');
    let svg = a.querySelector(':scope > svg.annot-arrows');
    if (svg) svg.remove();
    if (!A || !B || !lab) return;
    const bA = box(A, sr, k), bB = box(B, sr, k), gap = parseFloat(a.getAttribute('data-gap') || '2');
    const [x2, y2] = exitPoint(bB, cx(bA), cy(bA), gap);
    const [x1, y1] = exitPoint(bA, x2, y2, gap);
    svg = svgFor(sec, 'edge-arrow');
    const p = arrow(x1, y1, x2, y2, ...shape(a, null));
    if (p) svg.appendChild(p);
    a.insertBefore(svg, a.firstChild);
    // the label: at the middle of the arrow, `shift` px to its left (seen from a to b), `along` px further
    const len = Math.hypot(x2 - x1, y2 - y1) || 1, ux = (x2 - x1) / len, uy = (y2 - y1) / len;
    const shift = parseFloat(a.getAttribute('data-shift') || '18'), along = parseFloat(a.getAttribute('data-along') || '0');
    const mx = (x1 + x2) / 2 + ux * along, my = (y1 + y2) / 2 + uy * along;
    lab.style.left = (mx + uy * shift) + 'px'; lab.style.top = (my - ux * shift) + 'px';
  }
  function layoutOne(sec, a, sr, k) {
    if (a.hasAttribute('data-from')) return layoutEdge(sec, a, sr, k);
    const names = (a.getAttribute('data-to') || '').split(/[\s,]+/).filter(Boolean);
    const ts = names.map(n => target(sec, n)).filter(Boolean).map(e => box(e, sr, k));
    const lab = a.querySelector('.annot-box');
    if (!lab) return;
    const lw = lab.offsetWidth, lh = lab.offsetHeight;
    const pos = a.getAttribute('data-pos') || 'below';
    const dist = parseFloat(a.getAttribute('data-dist') || '40'), shift = parseFloat(a.getAttribute('data-shift') || '0');
    let x, y;
    if (ts.length) {
      const U = ts.reduce((u, b) => ({ l: Math.min(u.l, b.l), t: Math.min(u.t, b.t), r: Math.max(u.r, b.r), b: Math.max(u.b, b.b) }));
      if (pos === 'above') { x = cx(U) - lw / 2 + shift; y = U.t - dist - lh; }
      else if (pos === 'left') { x = U.l - dist - lw; y = cy(U) - lh / 2 + shift; }
      else if (pos === 'right') { x = U.r + dist; y = cy(U) - lh / 2 + shift; }
      else { x = cx(U) - lw / 2 + shift; y = U.b + dist; }
    }
    if (a.hasAttribute('data-x')) x = parseFloat(a.getAttribute('data-x'));
    if (a.hasAttribute('data-y')) y = parseFloat(a.getAttribute('data-y'));
    if (x === undefined) return;
    lab.style.left = x + 'px'; lab.style.top = y + 'px';
    let svg = a.querySelector(':scope > svg.annot-arrows');
    if (svg) svg.remove();
    const kind = a.getAttribute('data-arrow') || 'fat';
    if (kind === 'none' || kind === 'false' || !ts.length) return;
    svg = svgFor(sec, kind);
    // the arrow starts at the label box itself (not at the text under it); dir=from: it starts
    // at the target and points to the label
    const main = lab.querySelector('.annot-label') || lab;
    const L = { l: x + main.offsetLeft, t: y + main.offsetTop, r: x + main.offsetLeft + main.offsetWidth, b: y + main.offsetTop + main.offsetHeight };
    const gap = parseFloat(a.getAttribute('data-gap') || '3'), rev = a.getAttribute('data-dir') === 'from';
    // anchor=right|left|top|bottom: the arrow meets the target at the middle of that side (like
    // TikZ's east/west…); default: where the line from its centre leaves it
    const anchor = a.getAttribute('data-anchor');
    const side = (b, g) => anchor === 'right' ? [b.r + g, cy(b)] : anchor === 'left' ? [b.l - g, cy(b)]
      : anchor === 'top' ? [cx(b), b.t - g] : anchor === 'bottom' ? [cx(b), b.b + g] : null;
    ts.forEach(T => {
      let [x2, y2] = side(T, rev ? 1 : gap) || exitPoint(T, cx(L), cy(L), rev ? 1 : gap);
      let [x1, y1] = exitPoint(L, x2, y2, rev ? gap : 1);
      if (rev) [x1, y1, x2, y2] = [x2, y2, x1, y1];
      const p = arrow(x1, y1, x2, y2, ...shape(a, 'fat'));
      if (p) svg.appendChild(p);
    });
    a.insertBefore(svg, a.firstChild);
  }
  function layout(sec) {
    if (!sec) return;
    const as = sec.querySelectorAll('.annot');
    if (!as.length) return;
    const sr = sec.getBoundingClientRect();
    if (!sr.width) return;
    const k = sec.offsetWidth / sr.width;
    as.forEach(a => {
      // colour: the one of the first highlighted target, unless given
      if (!a.style.getPropertyValue('--annot-c')) {
        const n = (a.getAttribute('data-to') || '').split(/[\s,]+/)[0];
        const t = n && target(sec, n);
        // t is the highlight itself when the target has one: its colour is the right one
        const c = t && t.classList.contains('hl-fill') && getComputedStyle(t).getPropertyValue('--hl-c').trim();
        if (c) a.style.setProperty('--annot-c', c);
      }
      layoutOne(sec, a, sr, k);
    });
  }
  function current() { return window.Reveal && Reveal.getCurrentSlide && Reveal.getCurrentSlide(); }
  function all() {
    if (window.Reveal && Reveal.isPrintingPDF && Reveal.isPrintingPDF()) document.querySelectorAll('.reveal .slides section').forEach(layout);
    else layout(current());
  }
  let t = null;
  window.TalkAnnot = { layout, later: () => { clearTimeout(t); t = setTimeout(all, 30); } };
  talkWhenReady(() => {
    all();
    Reveal.on('slidechanged', e => layout(e.currentSlide));
    Reveal.on('resize', () => window.TalkAnnot.later());
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(() => window.TalkAnnot.later());
  });
})();

// ---- (3) audio, auto-animate matcher, letter-box bleed, keys ------------------------
(function () {
  const cfg = Object.assign({ autoplay: false, delay: 0, stopOnSlideChange: true },
    (window.TalkConfig && window.TalkConfig.audio) || {});
  const players = new Map();

  function audioFor(el) {
    let a = players.get(el);
    if (!a) {
      a = new Audio(el.getAttribute('data-audio'));
      a.preload = 'auto';
      const loop = el.getAttribute('data-loop');
      if (loop !== null && loop !== 'false') a.loop = true;
      if (el.hasAttribute('data-volume')) a.volume = Math.max(0, Math.min(1, parseFloat(el.getAttribute('data-volume'))));
      a.addEventListener('ended', () => { el.classList.remove('playing'); idleLater(); });
      a.addEventListener('pause', idleLater);
      players.set(el, a);
    }
    return a;
  }
  function stopAll(except) {
    players.forEach((a, el) => {
      if (el === except) return;
      clearTimeout(el._talkTimer);
      a.pause(); el.classList.remove('playing');
    });
  }
  // for the waiting module (6): is a sound playing? and the event "talk:audio-idle" once none plays
  // any more (end, stop, blocked by the browser)
  const playing = () => Array.from(players.values()).some(a => !a.paused);
  window.TalkAudio = { playing };
  function idleLater() {
    setTimeout(() => { if (!playing()) document.dispatchEvent(new Event('talk:audio-idle')); }, 0);
  }
  function play(el) {
    const a = audioFor(el);
    stopAll(el);
    a.currentTime = 0;
    el.classList.remove('blocked');
    el.classList.add('playing');
    const p = a.play();
    if (p && p.catch) p.catch(err => {          // browser autoplay policy: needs one click/key first
      el.classList.remove('playing');           // (an AbortError = stopped before it started: not blocked)
      if (!err || err.name !== 'AbortError') el.classList.add('blocked');
      idleLater();
    });
  }
  function toggle(el) {
    const a = audioFor(el);
    if (a.paused) play(el); else { a.pause(); el.classList.remove('playing'); }
  }
  function wantsAutoplay(el) {
    const v = el.getAttribute('data-autoplay');
    if (v === null) return !!cfg.autoplay;
    return v !== 'false';
  }
  function isShown(el) {
    const s = el.closest('section');
    if (!s || !s.classList.contains('present')) return false;
    let f = el.closest('.fragment');
    while (f) {
      if (!f.classList.contains('visible')) return false;
      f = f.parentElement && f.parentElement.closest('.fragment');
    }
    return true;
  }
  function schedule(el) {
    const d = parseFloat(el.getAttribute('data-autoplay-delay') || cfg.delay || 0) * 1000;
    clearTimeout(el._talkTimer);
    el._talkTimer = setTimeout(() => { if (isShown(el)) play(el); }, d);
  }
  function autoplayIn(root) {
    if (!root) return;
    root.querySelectorAll('[data-audio]').forEach(el => {
      if (wantsAutoplay(el) && isShown(el)) schedule(el);
    });
  }

  function init() {
    if (init.done) return; init.done = true;
    // click = play / stop (capture phase so reveal.js does not see the click)
    document.addEventListener('click', ev => {
      const el = ev.target.closest && ev.target.closest('[data-audio]');
      if (!el) return;
      ev.preventDefault(); ev.stopPropagation();
      toggle(el);
    }, true);
    if (!window.Reveal) return;
    Reveal.on('slidechanged', ev => {
      if (cfg.stopOnSlideChange) stopAll();
      autoplayIn(ev.currentSlide);
    });
    Reveal.on('fragmentshown', ev => {
      (ev.fragments || [ev.fragment]).forEach(f => {
        if (f.hasAttribute('data-stop-audio')) stopAll();
        const ids = f.getAttribute('data-play');
        // (a trigger made by play=N; its sound waits data-autoplay-delay seconds, if given)
        if (ids) ids.split(/[\s,]+/).forEach(id => {
          const el = document.getElementById(id); if (!el) return;
          const d = parseFloat(el.getAttribute('data-autoplay-delay') || 0) * 1000;
          if (d > 0) { clearTimeout(el._talkTimer); el._talkTimer = setTimeout(() => play(el), d); } else play(el);
        });
        const els = f.matches('[data-audio]') ? [f] : Array.from(f.querySelectorAll('[data-audio]'));
        els.filter(wantsAutoplay).forEach(schedule);
      });
    });
    Reveal.on('fragmenthidden', ev => {
      (ev.fragments || [ev.fragment]).forEach(f => {
        const els = f.matches('[data-audio]') ? [f] : Array.from(f.querySelectorAll('[data-audio]'));
        els.forEach(el => { clearTimeout(el._talkTimer); const a = players.get(el); if (a) { a.pause(); el.classList.remove('playing'); } });
      });
    });
    if (!Reveal.getConfig().autoAnimateMatcher) Reveal.configure({ autoAnimateMatcher: talkMatcher });
    updateBleed();
    Reveal.on('resize', updateBleed);
    window.addEventListener('resize', () => setTimeout(updateBleed, 50));
    Reveal.addKeyBinding({ keyCode: 65, key: 'A', description: 'Stop all sounds' }, () => stopAll());
    Reveal.addKeyBinding({ keyCode: 82, key: 'R', description: 'Show highlight areas (hl=…)' },
      () => document.documentElement.classList.toggle('talk-hl-debug'));
    autoplayIn(Reveal.getCurrentSlide());
  }

  // ---- auto-animate matcher: same pairing as reveal.js, but words of section titles
  //      (class "w") animate their font-size instead of being scaled (no double zoom) ----
  // Positions are measured relative to the slide itself (reveal measures offsetLeft, i.e.
  // relative to the nearest positioned parent, which differs between the two slides).
  function measure(el) {
    const s = el.closest('section');
    const r = el.getBoundingClientRect(), o = s ? s.getBoundingClientRect() : { left: 0, top: 0 };
    return { x: r.left - o.left, y: r.top - o.top, width: r.width, height: r.height };
  }
  function zoomInside(el) {
    let z = 1, n = el.parentElement;
    while (n && n.tagName !== 'SECTION') {
      const v = parseFloat(getComputedStyle(n).zoom);
      if (v && v !== 1) z *= v;
      n = n.parentElement;
    }
    return z;
  }
  function findMatches(pairs, fromSlide, toSlide, selector, keyFn, optFn) {
    const from = {}, seen = {};
    fromSlide.querySelectorAll(selector).forEach(el => {
      const k = keyFn(el); if (typeof k === 'string' && k.length) (from[k] = from[k] || []).push(el);
    });
    toSlide.querySelectorAll(selector).forEach(to => {
      const k = keyFn(to); (seen[k] = seen[k] || []).push(to);
      const list = from[k]; if (!list) return;
      const i = seen[k].length - 1, j = list.length - 1;
      let el = null;
      if (list[i]) { el = list[i]; list[i] = null; } else if (list[j]) { el = list[j]; list[j] = null; }
      if (el) {
        // reveal applies the offset inside the target element: if that element sits in a
        // zoomed box (summary titles use CSS zoom), express the offset in its own units
        const z = zoomInside(to);
        const m = z === 1 ? measure : (e => { const r = measure(e); return { x: r.x / z, y: r.y / z, width: r.width, height: r.height }; });
        pairs.push({ from: el, to: to, options: Object.assign({ measure: m }, optFn ? optFn(el) : {}) });
      }
    });
  }
  function talkMatcher(fromSlide, toSlide) {
    const pairs = [], text = 'h1, h2, h3, h4, h5, h6, p, li';
    // an image with hl=… is wrapped in a span: it still pairs with the plain image of the other slide
    // a data-id pairs whatever the tags (a grid cell <div> with the slice <span> of a stack)
    findMatches(pairs, fromSlide, toSlide, '[data-id]', el => 'ID:::' + el.getAttribute('data-id'), el => {
      // colour block of section slides: animate its real size → borders stay crisp
      if (el.matches(text)) return { scale: false };
      return {};
    });
    // (a <p> holding only positioned objects has no text: it must not pair with another empty <p>)
    findMatches(pairs, fromSlide, toSlide, text, el => el.innerText.trim() ? el.nodeName + ':::' + el.innerText : null, () => ({ scale: false }));
    findMatches(pairs, fromSlide, toSlide, 'img:not(.hl-img), video, iframe', el => el.nodeName + ':::' + (el.getAttribute('src') || el.getAttribute('data-src')));
    findMatches(pairs, fromSlide, toSlide, 'pre', el => el.nodeName + ':::' + el.innerText, () => ({ scale: false, styles: ['width', 'height'] }));
    return pairs;
  }

  // ---- section slides: make the colour block reach the real screen edges -------
  function updateBleed() {
    if (!window.Reveal || !Reveal.getScale) return;
    const s = Reveal.getScale() || 1;
    const vp = (Reveal.getViewportElement && Reveal.getViewportElement()) || document.documentElement;
    const r = vp.getBoundingClientRect();
    const cfgW = (Reveal.getConfig().width || 1280), cfgH = (Reveal.getConfig().height || 720);
    const bx = Math.max(0, (r.width / s - cfgW) / 2), by = Math.max(0, (r.height / s - cfgH) / 2);
    document.documentElement.style.setProperty('--sec-bleed-x', bx.toFixed(1) + 'px');
    document.documentElement.style.setProperty('--sec-bleed-y', by.toFixed(1) + 'px');
  }

  talkWhenReady(init, true);
})();

// ============================================================================
// (4) slide numbers: reveal's own counter ("c/t"), except for the slides left out of
//     the count by the filter: .test-slide → "test slide", .additional (set on the slide, or on
//     every slide after a ::: {.appendix} ::: marker) → "additional-1", …
//     (labels from YAML talk: slide-number: {test, additional}; {n} = rank of the slide)
// ============================================================================
(function () {
  function labels() {
    const c = (window.TalkConfig && window.TalkConfig.slideNumber) || {};
    return { test: c.test || 'test slide', additional: c.additional || 'additional-{n}' };
  }
  function number(slide) {
    const R = window.Reveal, L = labels();
    // the summary of a section pair shows the header's label (counted, test or additional)
    const prev = slide && slide.previousElementSibling;
    if (slide && slide.classList.contains('talk-sec-summary') && slide.dataset.visibility === 'uncounted'
        && prev && prev.classList.contains('talk-sec-header')) return number(prev);
    if (slide && slide.classList.contains('test-slide')) return [L.test];
    if (slide && slide.classList.contains('additional')) {
      const all = Array.from(document.querySelectorAll('.reveal .slides section.additional'));
      return [L.additional.replace('{n}', String(all.indexOf(slide) + 1))];
    }
    const a = slide && slide.dataset.visibility === 'uncounted' ? 0 : 1;
    return [R.getSlidePastCount(slide) + a, '/', R.getTotalSlides()];
  }
  function init() {
    const cfg = Reveal.getConfig();
    if (!cfg.slideNumber) return;            // slide numbers switched off: keep it that way
    Reveal.configure({ slideNumber: number });
  }
  talkWhenReady(init);
})();

// ============================================================================
// (5) push transition ({push=up} on a heading, see talk.scss PUSH TRANSITION): while the two
//     slides move, they carry .talk-pushing (hides a section panel's off-screen border bars)
// ============================================================================
(function () {
  function init() {
    Reveal.on('slidechanged', e => {
      const a = e.previousSlide, b = e.currentSlide;
      if (!a || !b || a.dataset.transition !== 'talk-push' || b.dataset.transition !== 'talk-push') return;
      const d = parseFloat(getComputedStyle(b).transitionDuration) * 1000 || 800;
      [a, b].forEach(s => { s.classList.add('talk-pushing'); clearTimeout(s._talkPush);
                            s._talkPush = setTimeout(() => s.classList.remove('talk-pushing'), d + 50); });
    });
  }
  talkWhenReady(init);
})();

// ============================================================================
// (6) waiting: every appearance that does not happen exactly at its click.
//     delay=S     (PowerPoint "after previous" + delay): S seconds after its click (CSS transition-delay,
//                 --talk-delay); only on the way in: reset once shown, so a .fade-in-then-out leaves
//                 at its click (restored when hidden again)
//     delay=move  when the motion path (.fragment.move) of the same click has ended
//     delay=end   when the sound playing at its click ends or is stopped (module 3 starts the sounds
//                 of a click first: its fragmentshown listener is registered before this one)
//     A waiting fragment is .visible.talk-waiting (hidden by talk.scss) until its reason is over.
// ============================================================================
(function () {
  const waits = new Map();                  // fragment → reason ('move' | 'end')
  function hold(f, why) { waits.set(f, why); f.classList.add('talk-waiting'); }
  function release(pred) {
    waits.forEach((why, f) => { if (pred(f, why)) { waits.delete(f); f.classList.remove('talk-waiting'); } });
  }
  function init() {
    document.querySelectorAll('.reveal .slides [data-delay]').forEach(el => {
      const s = parseFloat(el.dataset.delay);
      if (s > 0) el.style.setProperty('--talk-delay', s + 's');
    });
    Reveal.on('fragmentshown', ev => {
      const fs = ev.fragments || [ev.fragment];
      fs.forEach(f => {
        const s = parseFloat(f.dataset.delay);
        if (s > 0) { clearTimeout(f._talkDelay); f._talkDelay = setTimeout(() => f.style.setProperty('--talk-delay', '0s'), s * 1000 + 250); }
        if (f.dataset.delay === 'end' && window.TalkAudio && TalkAudio.playing()) hold(f, 'end');
      });
      const waiting = fs.filter(f => f.dataset.delay === 'move');
      const mv = fs.filter(f => f.classList.contains('move'));
      if (!waiting.length || !mv.length) return;
      waiting.forEach(f => hold(f, 'move'));
      const done = () => release((f, why) => why === 'move' && waiting.includes(f));
      let n = 0;
      mv.forEach(m => m.addEventListener('transitionend', () => { if (++n >= mv.length) done(); }, { once: true }));
      const d = Math.max(...mv.map(m => parseFloat(getComputedStyle(m).transitionDuration) * 1000 || 1000));
      setTimeout(done, d + 100);          // in case no transition fires (printing, reduced motion)
    });
    Reveal.on('fragmenthidden', ev => {
      const fs = ev.fragments || [ev.fragment];
      release(f => fs.includes(f));
      fs.forEach(f => {
        const s = parseFloat(f.dataset.delay);
        if (s > 0) { clearTimeout(f._talkDelay); f.style.setProperty('--talk-delay', s + 's'); }
      });
    });
    Reveal.on('slidechanged', () => release(() => true));
    document.addEventListener('talk:audio-idle', () => release((f, why) => why === 'end'));
  }
  talkWhenReady(init);
})();

// ============================================================================
// (7) references pagination: the entries of a .references-slide that do not fit its box (two
//     columns, fixed height: they would spill into a third column off the slide) move to copies
//     of the slide, inserted right after it; the headings read "References (1/3)", "(2/3)"…
//     Measured in the browser, so it holds whatever the entries' lengths and the font.
// ============================================================================
(function () {
  function overflowing(box) {
    const r = box.getBoundingClientRect();
    return Array.from(box.children).filter(e => e.getBoundingClientRect().left >= r.right - 1);
  }
  function paginate() {
    const slides = Array.from(document.querySelectorAll('.reveal .slides section.references-slide'))
      .filter(s => !s.dataset.talkPaginated);
    let changed = false;
    slides.forEach(first => {
      const pages = [first];
      let sec = first;
      for (let guard = 0; guard < 50; guard++) {
        const box = sec.querySelector('.talk-references');
        if (!box) break;
        const shown = sec.style.display;
        sec.style.display = 'block';                       // reveal hides far slides: lay it out to measure
        const over = overflowing(box);
        sec.style.display = shown;
        if (!over.length) break;
        const copy = sec.cloneNode(false);
        copy.id = first.id ? first.id + '-' + (pages.length + 1) : '';
        const h = sec.querySelector('h2, h1, h3');
        if (h) copy.appendChild(h.cloneNode(true));
        const nb = box.cloneNode(false);
        nb.id = (box.id || 'talk-refs') + '-' + (pages.length + 1);
        over.forEach(e => nb.appendChild(e));
        copy.appendChild(nb);
        sec.after(copy);
        pages.push(copy); sec = copy; changed = true;
      }
      if (pages.length > 1) pages.forEach((p, i) => {
        const h = p.querySelector('h2, h1, h3');
        if (h) h.insertAdjacentHTML('beforeend', ` <span class="refs-page">(${i + 1}/${pages.length})</span>`);
      });
      pages.forEach(p => p.dataset.talkPaginated = '1');
    });
    if (changed && window.Reveal && Reveal.sync) Reveal.sync();
  }
  talkWhenReady(() => { paginate(); if (document.fonts && document.fonts.ready) document.fonts.ready.then(paginate); });
})();
