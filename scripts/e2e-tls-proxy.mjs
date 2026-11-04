// Development only: terminates TLS for the local relay (scripts/e2e-local.ps1).
//
//   node e2e-tls-proxy.mjs --listen PORT --target PORT --cert server.pem --key server.key
//
// Listens on 127.0.0.1:PORT with the locally generated server certificate and pipes every decrypted connection to the
// plain-HTTP `wrangler dev` relay on 127.0.0.1:TARGET. It does not look at HTTP, so WebSocket upgrades just work.
import { readFileSync } from "node:fs";
import net from "node:net";
import tls from "node:tls";

const args = process.argv.slice(2);
const option = (name) => {
  const index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) throw new Error(`${name} is required`);
  return args[index + 1];
};
const listen = Number(option("--listen"));
const target = Number(option("--target"));
const server = tls.createServer({ cert: readFileSync(option("--cert")), key: readFileSync(option("--key")), minVersion: "TLSv1.2" }, (secure) => {
  const plain = net.connect({ host: "127.0.0.1", port: target });
  const end = () => { secure.destroy(); plain.destroy(); };
  secure.on("error", end);
  plain.on("error", end);
  secure.on("close", end);
  plain.on("close", end);
  secure.pipe(plain);
  plain.pipe(secure);
});
server.on("tlsClientError", (error) => console.log(JSON.stringify({ event: "tls-client-error", message: error.message })));
server.listen(listen, "127.0.0.1", () => console.log(JSON.stringify({ event: "listening", port: listen, target })));
