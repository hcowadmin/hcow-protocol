// Compiles every file in flat/ standalone, exactly as Remix would, and
// compares the resulting creation bytecode against the artifact Hardhat
// produced from the original imported sources. A flattened file that drifts
// from the tested source is worse than no flattened file at all.
const fs = require("fs");
const path = require("path");
// Must be the same compiler hardhat.config.cjs pins, or every bytecode
// comparison below is meaningless.
const solc = require("solc-0834");

const ROOT = path.join(__dirname, "..");
const FLAT = path.join(ROOT, "flat");
const ART = path.join(ROOT, "artifacts", "contracts");

const artifactFor = (name) => {
  const hits = [];
  (function walk(d) {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name === `${name}.json`) hits.push(p);
    }
  })(ART);
  return hits[0] ? JSON.parse(fs.readFileSync(hits[0], "utf8")) : null;
};

let pass = 0, fail = 0;

for (const file of fs.readdirSync(FLAT).filter((f) => f.endsWith(".sol"))) {
  const source = fs.readFileSync(path.join(FLAT, file), "utf8");
  const input = {
    language: "Solidity",
    sources: { [file]: { content: source } },
    settings: {
      optimizer: { enabled: true, runs: 200 },
      evmVersion: "paris",
      outputSelection: { "*": { "*": ["evm.bytecode.object"] } },
    },
  };
  const out = JSON.parse(solc.compile(JSON.stringify(input)));
  const errors = (out.errors || []).filter((e) => e.severity === "error");
  if (errors.length) {
    console.log(`FAIL  ${file}\n      ${errors[0].formattedMessage.split("\n")[0]}`);
    fail++;
    continue;
  }
  for (const [name, c] of Object.entries(out.contracts[file])) {
    const art = artifactFor(name);
    if (!art) continue;                       // interfaces and libraries
    if (!art.bytecode || art.bytecode === "0x") continue;
    // Trim the trailing metadata hash: it encodes the source path, which
    // differs by construction between flattened and imported builds.
    const strip = (b) => b.replace(/^0x/, "").slice(0, -106);
    const same = strip(c.evm.bytecode.object) === strip(art.bytecode);
    console.log(`${same ? "ok  " : "FAIL"}  ${file} :: ${name}`);
    same ? pass++ : fail++;
  }
}

console.log(`\n${pass} match, ${fail} differ`);
process.exitCode = fail ? 1 : 0;
