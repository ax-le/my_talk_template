/* talk.js — audio for reveal.js decks (part of the "talk" Quarto extension)

   Any element with  data-audio="file.mp3"  becomes a play/stop button.
   Options (HTML attributes, or shortcode arguments of {{< audio >}}):
     data-autoplay            play automatically when the element becomes visible:
                              when its slide opens, or when its fragment appears.
                              data-autoplay="false" disables it even if the global default is on.
     data-autoplay-delay="1"  wait (seconds) before auto-playing
     data-loop                loop the sound
     data-volume="0.5"        0 … 1
   After the sound:  {.fragment delay=end}  appears when the sound playing at its click ends
                     (or is stopped); at once if no sound plays.
   Trigger fragments:
     <span class="fragment" data-play="intro"></span>   plays the audio element with id="intro"
     <span class="fragment" data-stop-audio></span>     stops every sound
   Global defaults (YAML):  talk: audio: { autoplay: false, delay: 0, stop-on-slide-change: true }
   Keyboard: "A" stops all sounds.
*/
/* ---- highlights inside equations ------------------------------------------------
   \hl{STEPS}{colour}{part}   rounded box behind a part of an equation
   \hlo{STEPS}{colour}{part}  oval
   STEPS as for hl=…: 2, 2-4, 2-, 0 ; colour: a name of the highlight palette (teal, purple…)
   KaTeX marks the part with \htmlData; the highlight is then added as fragments.         */
(function () {
  const MACROS = {
    '\\hl': '\\htmlData{hl=#1,hlc=#2}{#3}',
    '\\hlo': '\\htmlData{hl=#1,hlc=#2,hlshape=oval}{#3}',
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
      opts.trust = ctx => ctx.command === '\\htmlData' || (typeof trust === 'function' ? trust(ctx) : !!trust);
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

/* ---- annotations: ::: {.annot to="name …" pos=below} label :::  -------------------------
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
  function layoutOne(sec, a, sr, k) {
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
    svg = document.createElementNS(NS, 'svg');
    svg.setAttribute('class', 'annot-arrows ' + kind);
    svg.setAttribute('width', sec.offsetWidth); svg.setAttribute('height', sec.offsetHeight);
    // the arrow starts at the label box itself (not at the text under it)
    const main = lab.querySelector('.annot-label') || lab;
    const L = { l: x + main.offsetLeft, t: y + main.offsetTop, r: x + main.offsetLeft + main.offsetWidth, b: y + main.offsetTop + main.offsetHeight };
    const gap = parseFloat(a.getAttribute('data-gap') || '3');
    ts.forEach(T => {
      const [x2, y2] = exitPoint(T, cx(L), cy(L), gap);
      const [x1, y1] = exitPoint(L, x2, y2, 1);
      const len = Math.hypot(x2 - x1, y2 - y1); if (len < 4) return;
      const ux = (x2 - x1) / len, uy = (y2 - y1) / len;
      const w = kind === 'thin' ? 2.5 : 9, head = kind === 'thin' ? 9 : 16, hw = kind === 'thin' ? 5 : 11;
      const bx = x2 - ux * head, by = y2 - uy * head, px = -uy, py = ux;
      const pts = [[x1 + px * w / 2, y1 + py * w / 2], [bx + px * w / 2, by + py * w / 2], [bx + px * hw, by + py * hw], [x2, y2],
                   [bx - px * hw, by - py * hw], [bx - px * w / 2, by - py * w / 2], [x1 - px * w / 2, y1 - py * w / 2]];
      const p = document.createElementNS(NS, 'polygon');
      p.setAttribute('points', pts.map(q => q[0].toFixed(1) + ',' + q[1].toFixed(1)).join(' '));
      svg.appendChild(p);
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
  function boot() {
    if (!window.Reveal) return;
    const go = () => {
      all();
      Reveal.on('slidechanged', e => layout(e.currentSlide));
      Reveal.on('resize', () => window.TalkAnnot.later());
      if (document.fonts && document.fonts.ready) document.fonts.ready.then(() => window.TalkAnnot.later());
    };
    if (Reveal.isReady && Reveal.isReady()) go(); else Reveal.on('ready', go);
  }
  if (document.readyState === 'complete') boot(); else window.addEventListener('load', boot);
})();

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
      a.addEventListener('ended', () => { el.classList.remove('playing'); releaseLater(); });
      a.addEventListener('pause', releaseLater);
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
  // {.fragment delay=end}: shown at its click but kept invisible (.talk-waiting) while a sound
  // plays; released when no sound plays any more (end, stop, blocked by the browser)
  const playing = () => Array.from(players.values()).some(a => !a.paused);
  function releaseLater() {
    setTimeout(() => {
      if (!playing()) document.querySelectorAll('.reveal .talk-waiting').forEach(f => f.classList.remove('talk-waiting'));
    }, 0);
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
      releaseLater();
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
      document.querySelectorAll('.reveal .talk-waiting').forEach(f => f.classList.remove('talk-waiting'));
      if (cfg.stopOnSlideChange) stopAll();
      autoplayIn(ev.currentSlide);
    });
    Reveal.on('fragmentshown', ev => {
      (ev.fragments || [ev.fragment]).forEach(f => {
        if (f.hasAttribute('data-stop-audio')) stopAll();
        const ids = f.getAttribute('data-play');
        if (ids) ids.split(/[\s,]+/).forEach(id => { const el = document.getElementById(id); if (el) play(el); });
        const els = f.matches('[data-audio]') ? [f] : Array.from(f.querySelectorAll('[data-audio]'));
        els.filter(wantsAutoplay).forEach(schedule);
      });
      // after the plays above: wait for the end of the sound, if one plays
      (ev.fragments || [ev.fragment]).forEach(f => {
        if (f.getAttribute('data-delay') === 'end' && playing()) f.classList.add('talk-waiting');
      });
    });
    Reveal.on('fragmenthidden', ev => {
      (ev.fragments || [ev.fragment]).forEach(f => {
        f.classList.remove('talk-waiting');
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
    const kind = el => el.classList.contains('hl-img-host') ? 'IMG' : el.nodeName;
    findMatches(pairs, fromSlide, toSlide, '[data-id]', el => kind(el) + ':::' + el.getAttribute('data-id'), el => {
      // colour block of section slides: animate its real size → borders stay crisp
      if (el.matches(text)) return { scale: false };
      return {};
    });
    findMatches(pairs, fromSlide, toSlide, text, el => el.nodeName + ':::' + el.innerText, () => ({ scale: false }));
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

  function boot() {
    if (!window.Reveal) return init();
    if (Reveal.isReady && Reveal.isReady()) init();
    else Reveal.on('ready', init);
  }
  if (document.readyState === 'complete') boot();
  else window.addEventListener('load', boot);
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
  function boot() {
    if (!window.Reveal) return;
    if (Reveal.isReady && Reveal.isReady()) init(); else Reveal.on('ready', init);
  }
  if (document.readyState === 'complete') boot(); else window.addEventListener('load', boot);
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
  function boot() {
    if (!window.Reveal) return;
    if (Reveal.isReady && Reveal.isReady()) init(); else Reveal.on('ready', init);
  }
  if (document.readyState === 'complete') boot(); else window.addEventListener('load', boot);
})();

// ============================================================================
// (6) delayed appearance: {.fragment delay=3.9} (PowerPoint "after previous" + delay) appears
//     that many seconds after its click; it hides at once when going back (talk.scss).
//     delay=end (after the sound) is handled by the audio module (3).
// ============================================================================
(function () {
  function init() {
    document.querySelectorAll('.reveal .slides [data-delay]').forEach(el => {
      const s = parseFloat(el.dataset.delay);
      if (s > 0) el.style.setProperty('--talk-delay', s + 's');
    });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
})();
