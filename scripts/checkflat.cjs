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

// The contracts this check MUST have compared by the time it exits.
//
// Without this list the script is a no-op that reports success: if artifacts/
// is missing or stale (it is gitignored), or a contract is renamed, every
// candidate hits one of the two `continue`s below, the script prints
// "0 match, 0 differ" and exits 0. A gate that verifies nothing while
// reporting green is the defect class this whole estate has been bitten by.
const REQUIRED = [
  "HCOWLedger", "HCOWProfitShare", "HCOWStaking", "HCOWFaucet",
  "MockHCOW", "MockUSDT",
];

let pass = 0, fail = 0;
const compared = new Set();

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
    // Trim the trailing metadata blob. It encodes the source path, which
    // differs by construction between flattened and imported builds.
    //
    // The length is read from the last two bytes, which is where solc writes
    // the CBOR length, rather than assumed. The previous version subtracted a
    // hardcoded 106 hex characters: correct for this compiler's default
    // ipfs+solc trailer and silently wrong under any metadata setting change,
    // and on any bytecode shorter than 106 characters `slice(0, -106)`
    // returned the empty string, so two DIFFERENT short bytecodes compared
    // equal and the check passed on both.
    const strip = (b) => {
      const h = b.replace(/^0x/, "");
      if (h.length < 8) return null;
      const cborLen = parseInt(h.slice(-4), 16);      // bytes
      const trailer = (cborLen + 2) * 2;              // hex chars, incl. the length word
      if (!Number.isFinite(cborLen) || trailer <= 0 || trailer >= h.length) return null;
      return h.slice(0, -trailer);
    };
    const a = strip(c.evm.bytecode.object), b = strip(art.bytecode);
    if (a === null || b === null) {
      console.log(`FAIL  ${file} :: ${name}  bytecode too short to carry a metadata trailer`);
      fail++;
      compared.add(name);
      continue;
    }
    const same = a === b;
    console.log(`${same ? "ok  " : "FAIL"}  ${file} :: ${name}`);
    same ? pass++ : fail++;
    compared.add(name);
  }
}

const missing = REQUIRED.filter((n) => !compared.has(n));
for (const n of missing) {
  console.log(`FAIL  ${n} was never compared: no flattened source, or no artifact for it`);
  fail++;
}

console.log(`\n${pass} match, ${fail} differ`);
process.exitCode = fail ? 1 : 0;
