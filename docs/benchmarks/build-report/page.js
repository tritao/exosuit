(function () {
  const DATA = JSON.parse(document.getElementById("build-data").textContent);
  const NS = "http://www.w3.org/2000/svg";
  const tip = document.createElement("div");
  tip.className = "tip";
  document.body.appendChild(tip);

  function el(name, attrs, parent) {
    const node = document.createElementNS(NS, name);
    for (const k in attrs) node.setAttribute(k, attrs[k]);
    if (parent) parent.appendChild(node);
    return node;
  }
  function hover(node, html) {
    node.addEventListener("mousemove", (e) => {
      tip.innerHTML = html;
      tip.style.display = "block";
      const x = Math.min(e.clientX + 12, window.innerWidth - tip.offsetWidth - 8);
      tip.style.left = x + "px";
      tip.style.top = (e.clientY + 14) + "px";
    });
    node.addEventListener("mouseleave", () => { tip.style.display = "none"; });
  }
  function niceStep(span, target) {
    const raw = span / target;
    const mag = Math.pow(10, Math.floor(Math.log10(raw)));
    for (const m of [1, 2, 5, 10]) if (m * mag >= raw) return m * mag;
    return 10 * mag;
  }
  function fmt(s) {
    if (s >= 120) return Math.floor(s / 60) + ":" + String(Math.round(s % 60)).padStart(2, "0");
    return (Math.round(s * 10) / 10) + " s";
  }
  function xAxis(svg, x, y0, width, wall, label) {
    const g = el("g", { class: "axis" }, svg);
    el("line", { x1: x(0), x2: x(wall), y1: y0, y2: y0 }, g);
    const step = niceStep(wall, Math.max(4, Math.floor(width / 90)));
    for (let t = 0; t <= wall + 1e-6; t += step) {
      el("line", { x1: x(t), x2: x(t), y1: y0, y2: y0 + 4 }, g);
      const tx = el("text", { x: x(t), y: y0 + 16, "text-anchor": "middle" }, g);
      tx.textContent = (Math.round(t * 100) / 100) + " s";
    }
    if (label) {
      const l = el("text", { x: x(wall), y: y0 + 30, "text-anchor": "end" }, g);
      l.textContent = label;
    }
    return step;
  }
  function vGrid(svg, x, top, bottom, wall, step) {
    const g = el("g", { class: "grid" }, svg);
    for (let t = step; t <= wall + 1e-6; t += step) el("line", { x1: x(t), x2: x(t), y1: top, y2: bottom }, g);
  }
  function widthOf(host) { return Math.max(340, host.clientWidth || 800); }

  const KIND_COLOR = {
    configure: "var(--s-cmake)", build: "var(--s-compile)", haxe: "var(--s-haxe)", project: "var(--s-bg)",
    setup: "var(--s-msbuild)", python: "var(--s-python)", link: "var(--s-link)", other: "var(--s-other)"
  };

  function gantt(host) {
    const run = DATA.runs[host.dataset.run];
    const rows = run.gantt;
    const W = Math.max(widthOf(host), +(host.dataset.minWidth || 0));
    const labelW = Math.min(280, W * 0.38), right = 16, rowH = 18, top = 8;
    const lanes = [];
    for (const r of rows) if (!lanes.includes(r.lane)) lanes.push(r.lane);
    const H = top + lanes.length * rowH + 44;
    const svg = el("svg", { width: W, height: H, viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": host.dataset.label || "Gantt chart" }, host);
    const wall = +(host.dataset.wall || run.wall);
    const x = (t) => labelW + (t / wall) * (W - labelW - right);
    const step = niceStep(wall, Math.max(4, Math.floor((W - labelW) / 90)));
    vGrid(svg, x, top, top + lanes.length * rowH, wall, step);
    lanes.forEach((lane, i) => {
      const y = top + i * rowH;
      const t = el("text", { x: labelW - 8, y: y + rowH * 0.7, "text-anchor": "end" }, svg);
      t.textContent = lane;
    });
    for (const r of rows) {
      const i = lanes.indexOf(r.lane);
      const y = top + i * rowH + 3;
      const w = Math.max(1.5, x(r.e) - x(r.s));
      const rect = el("rect", { x: x(r.s), y: y, width: w, height: rowH - 6, fill: KIND_COLOR[r.kind] || KIND_COLOR.other, rx: 1.5 }, svg);
      hover(rect, `<b>${r.label}</b><br>${fmt(r.s)} → ${fmt(r.e)} (${(r.e - r.s).toFixed(1)} s)${r.note ? "<br>" + r.note : ""}`);
    }
    xAxis(svg, x, top + lanes.length * rowH + 4, W - labelW, wall, "seconds since build start");
  }

  function cpuChart(host) {
    const run = DATA.runs[host.dataset.run];
    const W = widthOf(host), H = 236, left = 40, right = 16, top = 26, bottom = 40;
    const svg = el("svg", { width: W, height: H, viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": "CPU cores busy over time" }, host);
    const wall = +(host.dataset.wall || run.wall), cores = DATA.machine.logical || 32;
    const x = (t) => left + (t / wall) * (W - left - right);
    const y = (c) => top + (1 - c / cores) * (H - top - bottom);
    const g = el("g", { class: "grid" }, svg);
    for (let c = 0; c <= cores; c += 8) {
      el("line", { x1: left, x2: W - right, y1: y(c), y2: y(c) }, g);
      const t = el("text", { x: left - 6, y: y(c) + 4, "text-anchor": "end" }, svg);
      t.textContent = c;
    }
    const lab = el("text", { x: 4, y: 12, "text-anchor": "start" }, svg);
    lab.textContent = "cores";
    function area(points, fill, opacity) {
      if (!points.length) return;
      let d = `M${x(points[0][0])},${y(0)}`;
      for (const [t, v] of points) d += `L${x(t)},${y(Math.min(cores, v))}`;
      d += `L${x(points[points.length - 1][0])},${y(0)}Z`;
      el("path", { d, fill, "fill-opacity": opacity }, svg);
    }
    area(run.cpuTotal, "var(--s-bg)", 1);
    area(run.cpuBuild, "var(--s-compile)", 0.9);
    xAxis(svg, x, y(0), W - left, wall, "seconds since build start");
    const overlay = el("rect", { x: left, y: top, width: W - left - right, height: H - top - bottom, fill: "transparent" }, svg);
    overlay.addEventListener("mousemove", (e) => {
      const box = svg.getBoundingClientRect();
      const t = ((e.clientX - box.left) - left) / (W - left - right) * wall;
      const near = (arr) => { let best = null; for (const p of arr) if (!best || Math.abs(p[0] - t) < Math.abs(best[0] - t)) best = p; return best; };
      const a = near(run.cpuTotal), b = near(run.cpuBuild);
      tip.innerHTML = `t = ${fmt(t)}<br>machine busy: ${a ? a[1].toFixed(1) : "?"} cores<br>this build: ${b ? b[1].toFixed(1) : "?"} cores`;
      tip.style.display = "block";
      tip.style.left = Math.min(e.clientX + 12, window.innerWidth - 220) + "px";
      tip.style.top = (e.clientY + 14) + "px";
    });
    overlay.addEventListener("mouseleave", () => { tip.style.display = "none"; });
  }

  function heatmap(host) {
    const run = DATA.runs[host.dataset.run];
    const heat = run.heat;
    const W = widthOf(host), left = 40, right = 16, top = 6, cell = 6;
    const n = heat.rows.length, H = top + n * cell + 40;
    const svg = el("svg", { width: W, height: H, viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": "Per-core utilisation heatmap" }, host);
    const wall = +(host.dataset.wall || run.wall);
    const x = (t) => left + (t / wall) * (W - left - right);
    const colors = ["var(--heat-0)", "var(--heat-1)", "var(--heat-2)", "var(--heat-3)", "var(--heat-4)"];
    heat.rows.forEach((row, core) => {
      row.forEach((v, i) => {
        const level = v < 10 ? 0 : v < 35 ? 1 : v < 65 ? 2 : v < 90 ? 3 : 4;
        const t0 = heat.t0 + i * heat.bin;
        el("rect", { x: x(Math.max(0, t0)), y: top + core * cell, width: Math.max(0.6, x(t0 + heat.bin) - x(t0)) + 0.3, height: cell - 0.5, fill: colors[level] }, svg);
      });
      if (core % 8 === 0) {
        const t = el("text", { x: left - 6, y: top + core * cell + cell, "text-anchor": "end" }, svg);
        t.textContent = "cpu " + core;
      }
    });
    xAxis(svg, x, top + n * cell + 2, W - left, wall, "");
  }

  function concurrency(host) {
    const run = DATA.runs[host.dataset.run];
    const conc = run.conc;
    const W = widthOf(host), H = 236, left = 40, right = 16, top = 26, bottom = 40;
    const svg = el("svg", { width: W, height: H, viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": "Concurrent build processes" }, host);
    const wall = +(host.dataset.wall || run.wall);
    const keys = conc.keys;
    let max = 1;
    conc.t.forEach((_, i) => { let s = 0; for (const k of keys) s += conc.series[k][i]; max = Math.max(max, s); });
    max = Math.max(Math.ceil(max / 2) * 2, +(host.dataset.max || 0));
    const x = (t) => left + (t / wall) * (W - left - right);
    const y = (c) => top + (1 - c / max) * (H - top - bottom);
    const g = el("g", { class: "grid" }, svg);
    const ystep = max <= 8 ? 1 : max <= 16 ? 2 : 4;
    for (let c = 0; c <= max; c += ystep) {
      el("line", { x1: left, x2: W - right, y1: y(c), y2: y(c) }, g);
      const t = el("text", { x: left - 6, y: y(c) + 4, "text-anchor": "end" }, svg);
      t.textContent = c;
    }
    const base = conc.t.map(() => 0);
    for (const k of keys) {
      const vals = conc.series[k];
      let d = "";
      conc.t.forEach((t, i) => { d += (i ? "L" : "M") + x(t) + "," + y(base[i] + vals[i]); });
      for (let i = conc.t.length - 1; i >= 0; i--) d += "L" + x(conc.t[i]) + "," + y(base[i]);
      d += "Z";
      el("path", { d, fill: conc.colors[k], stroke: "none" }, svg);
      vals.forEach((v, i) => { base[i] += v; });
    }
    xAxis(svg, x, y(0), W - left, wall, "seconds since build start");
    const lab = el("text", { x: 4, y: 12 }, svg);
    lab.textContent = "procs";
  }


  // Before/after bars: DATA.bars[name] = {unit, rows: [{label, before, after}]}; a missing value draws no bar.
  function bars(host) {
    const spec = DATA.bars[host.dataset.bars];
    const W = widthOf(host), labelW = Math.min(230, W * 0.36), right = 120, rowH = 46, top = 6;
    const H = top + spec.rows.length * rowH + 28;
    const svg = el("svg", { width: W, height: H, viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": host.dataset.label || "Before and after" }, host);
    let max = 0;
    for (const r of spec.rows) max = Math.max(max, r.before || 0, r.after || 0);
    max = max || 1;
    const x = (v) => labelW + (v / max) * (W - labelW - right);
    const step = niceStep(max, Math.max(3, Math.floor((W - labelW) / 110)));
    vGrid(svg, x, top, top + spec.rows.length * rowH, max, step);
    spec.rows.forEach((r, i) => {
      const y = top + i * rowH;
      const t = el("text", { x: labelW - 8, y: y + rowH / 2 + 4, "text-anchor": "end" }, svg);
      t.textContent = r.label;
      [["before", "var(--s-before)", 4], ["after", "var(--s-compile)", 22]].forEach(([k, fill, dy]) => {
        const v = r[k];
        if (v === null || v === undefined) return;
        const rect = el("rect", { x: labelW, y: y + dy, width: Math.max(1.5, x(v) - labelW), height: 16, fill, rx: 1.5 }, svg);
        hover(rect, `<b>${r.label}</b><br>${k}: ${v}${spec.unit}`);
        const lab = el("text", { x: x(v) + 5, y: y + dy + 12 }, svg);
        lab.textContent = (Math.round(v * 10) / 10) + spec.unit + (k === "before" ? " before" : "");
      });
    });
    const g = el("g", { class: "axis" }, svg);
    const y0 = top + spec.rows.length * rowH;
    el("line", { x1: labelW, x2: x(max), y1: y0, y2: y0 }, g);
    for (let v = 0; v <= max + 1e-6; v += step) {
      const tx = el("text", { x: x(v), y: y0 + 16, "text-anchor": "middle" }, g);
      tx.textContent = (Math.round(v * 100) / 100) + spec.unit;
    }
  }

  function render() {
    tip.style.display = "none";
    document.querySelectorAll("[data-chart]").forEach((host) => {
      host.innerHTML = "";
      ({ gantt, cpu: cpuChart, heat: heatmap, conc: concurrency, bars })[host.dataset.chart](host);
    });
  }
  render();
  let timer = null;
  window.addEventListener("resize", () => { clearTimeout(timer); timer = setTimeout(render, 150); });

  if (window.mermaid) {
    const css = getComputedStyle(document.documentElement);
    const v = (n) => css.getPropertyValue(n).trim();
    window.mermaid.initialize({
      startOnLoad: false, theme: "base", securityLevel: "strict",
      themeVariables: {
        background: v("--surface"), primaryColor: v("--accent-soft"), primaryTextColor: v("--ink"),
        primaryBorderColor: v("--accent"), lineColor: v("--muted"), secondaryColor: v("--warn-soft"),
        tertiaryColor: v("--code-bg"), fontFamily: "IBM Plex Sans, Segoe UI, sans-serif", fontSize: "13px",
        clusterBkg: v("--bg"), clusterBorder: v("--rule-strong"), edgeLabelBackground: v("--surface")
      }
    });
    window.mermaid.run({ querySelector: "pre.mermaid" });
  }
})();
