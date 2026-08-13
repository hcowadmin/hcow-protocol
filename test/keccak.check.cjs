const { keccakUtf8, keccakHex } = require('/home/claude/ledger/lib/keccak');
const { keccak256, toUtf8Bytes } = require('ethers');
let bad = 0, n = 0;
const check = (label, mine, theirs) => { n++; if (mine !== theirs) { bad++; console.log('MISMATCH', label, mine, theirs); } };

check('empty', keccakUtf8(''), keccak256(toUtf8Bytes('')));
check('abc', keccakUtf8('abc'), keccak256(toUtf8Bytes('abc')));
check('HCOWv1|', keccakUtf8('HCOWv1|'), keccak256(toUtf8Bytes('HCOWv1|')));
// lengths across the 136 byte rate boundary and beyond
for (const len of [1,63,64,135,136,137,271,272,273,1000,5000]) {
  const s = 'x'.repeat(len);
  check('len'+len, keccakUtf8(s), keccak256(toUtf8Bytes(s)));
}
// unicode
for (const s of ['한글 테스트','🐮🚀','tint\tr-1\n','Ω≈ç√∫']) check('u:'+s, keccakUtf8(s), keccak256(toUtf8Bytes(s)));
// random hex inputs
for (let i = 0; i < 300; i++) {
  const len = 1 + Math.floor(Math.random()*200);
  const b = Buffer.from(Array.from({length:len},()=>Math.floor(Math.random()*256)));
  check('rand'+i, keccakHex('0x'+b.toString('hex')), keccak256(b));
}
console.log(bad === 0 ? `keccak256 OK: ${n}/${n} match ethers` : `FAILED: ${bad}/${n}`);
process.exit(bad?1:0);
