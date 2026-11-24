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

/** Approves the pending device with grants of every listed workspace: exosuitctl when it has the subcommand, else connect-real.py. */
function approve(deviceId, workspaceIds, code) {
  if (process.env.E2E_APPROVE_WITH === "exosuitctl") {
    const command = `source "${machineEnv}" && cd "${appDir}" && scripts/exosuitctl approve --code "${code}" ${deviceId} ${workspaceIds.join(" ")}`;
    return JSON.parse(execFileSync("bash", ["-c", command], {encoding: "utf8"}).trim().split("\n").pop());
  }
  const reply = machine("approve", "--home", '"$EXOSUIT_EXOHOST_HOME"', "--device", deviceId);
  for (const id of workspaceIds) machine("grant", "--home", '"$EXOSUIT_EXOHOST_HOME"', "--device", deviceId, "--workspace", id);
  return reply;
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
    await browser.defaultBrowserContext().overridePermissions(`http://127.0.0.1:${SITE_PORT}`, ["clipboard-read", "clipboard-write", "clipboard-sanitized-write"]);
    page.on("console", message => { const text = message.text(); if (!text.includes("exosuit-state:") && !text.includes("GL Driver")) log("page:", text.slice(0, 300)); });
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
    try {
      await page.waitForFunction(() => window.exosuit && window.exosuit.state === "running" && window.exosuit.frames > 5, {timeout: 120000});
    } catch (error) {
      log("startup state:", JSON.stringify(await page.evaluate(() => window.exosuit && {state: window.exosuit.state, frames: window.exosuit.frames, error: window.exosuit.error, unavailable: window.exosuit.unavailable})));
      await shot("fail-startup");
      throw error;
    }
    log("editor running"); await shot("01-started");
    await waitState("snapshot", s => s && s.remoteAccess);

    const targets = async () => (await state()).shell.testTargets;
    const centre = box => ({x: box.x + box.width / 2, y: box.y + box.height / 2});
    /** Clicks the element a snapshot target names (logical pixels = CSS pixels here). */
    const click = async (name, seconds = 30) => {
      const deadline = Date.now() + seconds * 1000;
      while (Date.now() < deadline) {
        const box = (await targets())[name];
        if (box) { const {x, y} = centre(box); await page.mouse.click(x, y); log("click", name, Math.round(x), Math.round(y)); return; }
        await sleep(300);
      }
      await shot("fail-click-" + name);
      throw new Error(`no visible element for ${name}`);
    };
    const remote = async () => (await state()).remoteAccess;

    // 1. The invitation, from the test machine's exohost.
    const invitation = machine("invite").invitation;
    log("invitation for device", invitation.deviceId);

    // 2. Remote Access panel: paste the URL (with the machine key fragment), Pair.
    await click("remoteAccessActivity");
    await sleep(500);
    await click("pairingUrl");
    // Typed keys lose characters (the page handles one per frame), so the URL goes through the clipboard and the Paste button.
    await page.evaluate(text => navigator.clipboard.writeText(text), invitation.invitationUrl);
    const field = (await targets()).pairingUrl;
    await page.mouse.click(field.x + field.width + 8 + 32, field.y + field.height / 2);
    await sleep(500);
    await shot("02-url-typed");
    await click("pairingConnect");

    // 3. The page shows a code; the machine lists the same code for this device. Compare, confirm on the page, approve on the machine.
    const withCode = await waitState("authentication code on the page", s => s.remoteAccess && s.remoteAccess.code, 60);
    const code = withCode.remoteAccess.code;
    let pending = null;
    for (let attempt = 0; attempt < 60 && !pending; attempt++) {
      pending = (machine("devices").pending || []).find(item => item.deviceId === invitation.deviceId);
      if (!pending) await sleep(500);
    }
    if (!pending) throw new Error("the machine never listed the device as pending");
    if (pending.authenticationCode !== code) throw new Error(`codes differ: page ${code}, machine ${pending.authenticationCode}`);
    log("codes match:", code);
    await shot("03-code");
    await click("pairingConfirm");
    const workspaces = process.env.E2E_WORKSPACE_IDS || execFileSync("bash", ["-c", `source "${machineEnv}" && cd "${appDir}" && python3 scripts/exohost.py machine --json`], {encoding: "utf8"});
    const ids = process.env.E2E_WORKSPACE_IDS ? process.env.E2E_WORKSPACE_IDS.split(",") : [...workspaces.matchAll(/workspace-[0-9a-f]{32}/g)].map(match => match[0]);
    const approval = approve(invitation.deviceId, ids, code);
    log("approval:", JSON.stringify(approval));
    if (!approval.ok) throw new Error("the machine refused the approval");
    await waitState("machine online with a workspace", s => s.remoteAccess && s.remoteAccess.machines.some(m => m.online && m.workspaces.length > 0), 90);
    await shot("04-paired");

    // 4. Open the workspace, then a terminal.
    if (await page.evaluate(() => window.exosuit.openFirstWorkspace()) !== 0) throw new Error("no workspace to open");
    await waitState("workspace connected", s => s.remoteAccess && s.remoteAccess.open && s.remoteAccess.open.connected, 90);
    await shot("05-workspace");
    await click("workbenchActivity");
    await click("newTerminal", 60);
    await waitState("a terminal tab", s => s.shell.terminalIds && s.shell.terminalIds.length > 0, 90);
    await sleep(2000);
    await click("terminalPane", 60);
    await page.keyboard.type("echo web-ok $((6*7))", {delay: 20});
    await page.keyboard.press("Enter");
    await waitState("web-ok 42 in the terminal", s => JSON.stringify(s.shell).includes("web-ok 42"), 60);
    await shot("06-terminal");
    log("PASS: paired, opened the workspace, and read `web-ok 42` back from the terminal");
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
