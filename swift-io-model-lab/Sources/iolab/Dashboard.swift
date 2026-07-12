/// The dashboard page. Self-contained HTML/CSS/JS; connects to `/events` via
/// EventSource and draws one panel per server mode, stacked on a shared time
/// axis. Each connection is a row, time runs left to right, colored by phase.
/// With the `lab` command all three models appear at once, so you can compare
/// blocking (staircase) vs threaded (aligned column) vs nonblocking directly.
func dashboardHTML(serverInfo: String) -> String {
  return """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>IO Model Lab</title>
    <style>
      :root { color-scheme: dark; }
      * { box-sizing: border-box; }
      body {
        margin: 0; background: #0b1020; color: #e5e9f0;
        font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      }
      header { padding: 14px 18px; border-bottom: 1px solid #1e2740; }
      h1 { margin: 0 0 4px; font-size: 16px; }
      .sub { color: #94a3b8; font-size: 12px; }
      .legend { display: flex; gap: 14px; flex-wrap: wrap; padding: 10px 18px; font-size: 12px; }
      .legend span { display: inline-flex; align-items: center; gap: 6px; }
      .sw { width: 12px; height: 12px; border-radius: 3px; display: inline-block; }
      #wrap { padding: 8px 18px 24px; overflow-x: auto; }
      #log {
        margin: 4px 18px 20px; padding: 8px 10px; background: #0f1630;
        border: 1px solid #1e2740; border-radius: 6px; font-family: ui-monospace, monospace;
        font-size: 12px; color: #9fb3d1; max-height: 96px; overflow-y: auto; white-space: pre-wrap;
      }
      text { fill: #cbd5e1; font-family: ui-monospace, monospace; font-size: 11px; }
      .grid { stroke: #1e2740; }
      .mode { fill: #e2e8f0; font-weight: 600; font-size: 12px; }
      .div { stroke: #223052; }
    </style>
    </head>
    <body>
    <header>
      <h1>IO Model Lab — live connection timeline</h1>
      <div class="sub">\(serverInfo)</div>
    </header>
    <div class="legend">
      <span><i class="sw" style="background:#64748b"></i>accepted / waiting</span>
      <span><i class="sw" style="background:#3b82f6"></i>reading</span>
      <span><i class="sw" style="background:#f59e0b"></i>working</span>
      <span><i class="sw" style="background:#22c55e"></i>writing</span>
      <span><i class="sw" style="background:#334155"></i>closed</span>
      <span class="sub" id="stat"></span>
    </div>
    <div id="log"></div>
    <div id="wrap"><svg id="tl" width="100%" height="80"></svg></div>
    <script>
      // mode -> Map(connID -> { events: [] })
      const modes = new Map();
      const modeOrder = ["blocking", "threaded", "nonblocking"];
      const logs = [];
      let maxT = 0.5;

      const color = (phase) => {
        if (phase === "accepted") return "#64748b";
        if (phase === "read-start" || phase === "read") return "#3b82f6";
        if (phase === "work") return "#f59e0b";
        if (phase === "write") return "#22c55e";
        if (phase === "closed") return "#334155";
        return "#64748b";
      };

      const es = new EventSource("/events");
      es.onmessage = (e) => {
        const ev = JSON.parse(e.data);
        if (ev.phase === "log" || ev.mode === "system") {
          logs.push(ev.detail || ev.phase);
          if (logs.length > 60) logs.shift();
          const el = document.getElementById("log");
          el.textContent = logs.join("\\n");
          el.scrollTop = el.scrollHeight;
          return;
        }
        let m = modes.get(ev.mode);
        if (!m) { m = new Map(); modes.set(ev.mode, m); }
        let c = m.get(ev.connID);
        if (!c) { c = { events: [] }; m.set(ev.connID, c); }
        c.events.push(ev);
        if (ev.t > maxT) maxT = ev.t;
        schedule();
      };

      let pending = false;
      const schedule = () => {
        if (pending) return;
        pending = true;
        requestAnimationFrame(() => { pending = false; render(); });
      };

      const presentModes = () => {
        const present = modeOrder.filter((m) => modes.has(m));
        for (const k of modes.keys()) {
          if (k !== "system" && !present.includes(k)) present.push(k);
        }
        return present;
      };

      const render = () => {
        const svg = document.getElementById("tl");
        const width = Math.max(svg.clientWidth, 360);
        const labelW = 60, rowH = 16, panelHead = 22, panelGap = 12, top = 20;
        const plotW = width - labelW - 12;
        const scale = plotW / (maxT * 1.05);
        const present = presentModes();

        let height = top;
        for (const mode of present) height += panelHead + modes.get(mode).size * rowH + panelGap;
        height += 8;
        svg.setAttribute("height", height);

        const parts = [];
        const step = niceStep(maxT * 1.05);
        for (let g = 0; g <= maxT * 1.05; g += step) {
          const x = labelW + g * scale;
          parts.push(`<line class="grid" x1="${x}" y1="14" x2="${x}" y2="${height}"></line>`);
          parts.push(`<text x="${x + 2}" y="11">${g.toFixed(1)}s</text>`);
        }

        let y = top;
        for (const mode of present) {
          const conns = modes.get(mode);
          parts.push(`<text x="4" y="${y + 15}" class="mode">${mode} (${conns.size})</text>`);
          parts.push(`<line class="div" x1="0" y1="${y + panelHead - 5}" x2="${width}" y2="${y + panelHead - 5}"></line>`);
          y += panelHead;
          const ids = [...conns.keys()].sort((a, b) => a - b);
          for (const id of ids) {
            const evs = conns.get(id).events;
            for (let k = 0; k < evs.length; k++) {
              const e0 = evs[k];
              const e1 = evs[k + 1];
              const x0 = labelW + e0.t * scale;
              const x1 = e1 ? labelW + e1.t * scale : x0 + 3;
              const w = Math.max(2, x1 - x0);
              const title = `${mode} #${id} ${e0.phase}${e0.detail ? " — " + e0.detail : ""} @${e0.t.toFixed(3)}s`;
              parts.push(
                `<rect x="${x0}" y="${y + 2}" width="${w}" height="${rowH - 4}" rx="2" ` +
                `fill="${color(e0.phase)}"><title>${escapeXml(title)}</title></rect>`);
            }
            y += rowH;
          }
          y += panelGap;
        }

        svg.innerHTML = parts.join("");
        document.getElementById("stat").textContent =
          present.join(" · ") + " · t=" + maxT.toFixed(1) + "s";
      };

      const niceStep = (span) => {
        const raw = span / 8;
        const pow = Math.pow(10, Math.floor(Math.log10(raw || 0.1)));
        const n = raw / pow;
        const f = n < 1.5 ? 1 : n < 3.5 ? 2 : n < 7.5 ? 5 : 10;
        return Math.max(0.05, f * pow);
      };

      const escapeXml = (s) =>
        s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

      window.addEventListener("resize", schedule);
    </script>
    </body>
    </html>
    """
}
