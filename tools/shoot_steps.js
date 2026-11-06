// Headless screenshots of a rendered reveal.js deck, for checking template.qmd / index.qmd.
//   node tools/shoot_steps.js URL OUTDIR [last|all]      (needs Playwright + Chromium)
//   serve the project first, e.g.  python3 -m http.server 8765  →  URL = http://localhost:8765/template.html
//   last: one PNG per slide at its last click step;  all: every click step (s012_f3.png = slide 12, step 3)
//   env: FROM / TO (0-based slide range), WAIT (ms per step in "all" mode, default 1500)
//   OUTDIR/info.json lists slide, step and the slide-number label shown.
const { chromium } = require('playwright');
(async () => {
  const [url, out, mode='last'] = process.argv.slice(2);
  const fs = require('fs'); fs.mkdirSync(out, {recursive:true});
  const b = await chromium.launch(); const p = await b.newPage({viewport:{width:1280,height:720}});
  await p.goto(url); await p.waitForFunction(() => window.Reveal && Reveal.isReady());
  await p.waitForTimeout(800);
  const n = await p.evaluate(() => document.querySelectorAll('.reveal .slides section:not(.stack)').length);
  const info = [];
  const from=+(process.env.FROM||0), to=+(process.env.TO||n); for (let i = from; i < Math.min(n,to); i++) {
    await p.evaluate(i => { const s = document.querySelectorAll('.reveal .slides section:not(.stack)')[i]; const ix = Reveal.getIndices(s); Reveal.slide(ix.h, ix.v, -1); }, i);
    await p.waitForTimeout(150);
    const nf = await p.evaluate(() => { const s = Reveal.getCurrentSlide(); return [...new Set([...s.querySelectorAll('.fragment')].map(f=>f.dataset.fragmentIndex))].length; });
    const steps = mode === 'all' ? [...Array(nf+1).keys()].map(k=>k-1) : [nf-1];
    for (const f of steps) {
      await p.evaluate(f => { const ix = Reveal.getIndices(); Reveal.slide(ix.h, ix.v, f); }, f);
      await p.waitForTimeout(mode==='all'?+(process.env.WAIT||1500):1400);
      const num = await p.evaluate(() => (document.querySelector('.slide-number')||{}).textContent);
      const name = `${out}/s${String(i+1).padStart(3,'0')}_f${f+1}.png`;
      await p.screenshot({path: name});
      info.push({i:i+1, f:f+1, num});
    }
  }
  fs.writeFileSync(out+'/info.json', JSON.stringify(info));
  await b.close();
})();
