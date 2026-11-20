#!/usr/bin/env node
// Browser end to end against the local relay and a test exohost: pair the page, approve and grant through exohost's control socket,
// open the workspace, open a terminal, run `echo web-ok $((6*7))` and read `web-ok 42` back. Headless Chrome over CDP only.
//
//   node web/tools/e2e-local-pair.mjs [--site DIR] [--out DIR] [--steps pair,open,terminal]
//
// Needs: the built site (web/build.sh), relay + machine from relay/HANDOFF.md, puppeteer-core (EXOSUIT_PUPPETEER_DIR, default
// ../scratch-b next to the checkout's parent, or any resolvable `puppeteer-core`). The machine is controlled through
// android/scripts/connect-real.py with the machine's environment (MACHINE_ENV, default state/b-web/machine-env.sh).
import {spawn, execFileSync} from "node:child_process";
import {createRequire} from "node:module";
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const appDir = path.resolve(here, "../..");
const nightDir = process.env.EXOSUIT_NIGHT_DIR || path.resolve(appDir, "..");
const args = Object.fromEntries(process.argv.slice(2).reduce((pairs, value, index, all) => value.startsWith("--") ? [...pairs, [value.slice(2), all[index + 1]]] : pairs, []));
const siteDir = args.site || path.join(appDir, "build/web/site");
const outDir = args.out || path.join(nightDir, "state/b-web/e2e");
const machineEnv = process.env.MACHINE_ENV || path.join(nightDir, "state/b-web/machine-env.sh");
const SITE_PORT = 18080, CDP_PORT = 19222;
const browserPath = process.env.EXOSUIT_WEB_BROWSER || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const require = createRequire(path.join(process.env.EXOSUIT_PUPPETEER_DIR || path.join(nightDir, "scratch-b"), "x.js"));
const puppeteer = require("puppeteer-core");
fs.mkdirSync(outDir, {recursive: true});

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const log = (...parts) => console.log(new Date().toISOString().slice(11, 23), ...parts);

/** connect-real.py against the test machine; returns its JSON. */
function machine(...parts) {
  const command = `source "${machineEnv}" && cd "${appDir}" && python3 android/scripts/connect-real.py ${parts.join(" ")}`;
  return JSON.parse(execFileSync("bash", ["-c", command], {encoding: "utf8"}).trim().split("\n").pop());
}

const types = {".html": "text/html", ".js": "text/javascript", ".wasm": "application/wasm", ".ttf": "font/ttf", ".txt": "text/plain"};
function serve() {
  const server = http.createServer((request, response) => {
    const file = path.join(siteDir, decodeURIComponent(request.url.split("?")[0]).replace(/^\/$/, "/index.html"));
    if (!file.startsWith(siteDir) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) { response.writeHead(404).end(); return; }
    response.writeHead(200, {"content-type": types[path.extname(file)] || "application/octet-stream", "cache-control": "no-store"});
    fs.createReadStream(file).pipe(response);
  });
  return new Promise(resolve => server.listen(SITE_PORT, "127.0.0.1", () => resolve(server)));
}

async function main() {
  const server = await serve();
  const profile = fs.mkdtempSync(path.join(outDir, "profile-"));
  const chrome = spawn(browserPath, ["--headless=new", "--no-first-run", "--enable-unsafe-swiftshader", "--use-angle=swiftshader",
    "--disable-background-timer-throttling", "--disable-renderer-backgrounding", "--window-size=1400,900", `--user-data-dir=${profile}`,
    `--remote-debugging-port=${CDP_PORT}`, "--remote-allow-origins=*", "about:blank"], {stdio: "ignore", detached: true});
  let browser, failed = null;
  try {
    for (let attempt = 0; attempt < 60 && !browser; attempt++) {
      try { browser = await puppeteer.connect({browserURL: `http://127.0.0.1:${CDP_PORT}`, defaultViewport: {width: 1400, height: 900}}); } catch { await sleep(500); }
    }
    if (!browser) throw new Error("Chrome did not open its DevTools port");
    const page = await browser.newPage();
    page.on("console", message => log("page:", message.text().slice(0, 300)));
    page.on("pageerror", error => log("pageerror:", error.message));
    const shot = name => page.screenshot({path: path.join(outDir, name + ".png")});
    const state = async () => page.evaluate(() => { window.exosuit.snapshot(); return window.exosuit.document; });
    const waitState = async (label, predicate, seconds = 60) => {
      const deadline = Date.now() + seconds * 1000;
      let last = null;
      while (Date.now() < deadline) {
        last = await state();
        if (predicate(last)) { log("ok:", label); return last; }
        await sleep(500);
      }
      await shot("fail-" + label.replace(/\W+/g, "-"));
      throw new Error(`timed out waiting for ${label}; last remoteAccess: ${JSON.stringify(last && last.remoteAccess)}`);
    };

    await page.goto(`http://127.0.0.1:${SITE_PORT}/index.html`);
    await page.waitForFunction(() => window.exosuit && window.exosuit.state === "running" && window.exosuit.frames > 5, {timeout: 120000});
    log("editor running"); await shot("01-started");
    await waitState("snapshot", s => s && s.remoteAccess);

    // The rest of the flow is canvas UI: filled in against the real build (pairing field, Pair, approve, workspace, terminal).
    throw new Error("flow beyond startup is not implemented yet");
  } catch (error) {
    failed = error; console.error("FAILED:", error.message);
  } finally {
    if (browser) await browser.disconnect();
    try { process.kill(-chrome.pid); } catch {}
    server.close();
  }
  process.exit(failed ? 1 : 0);
}
main();
