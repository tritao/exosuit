// Node console child, as Claude Code is: raw mode, reports the bytes of each chunk read from stdin as hex.
process.stdin.setRawMode(true);
process.stdin.on("data", (data) => {
  console.log("DATA " + Buffer.from(data).toString("hex"));
  if (data.includes(0x71)) process.exit(0);
});
console.log("READY");
