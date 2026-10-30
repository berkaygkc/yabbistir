"use strict";
// JIT benchmark payload for the extension host.
// A pure CPU workload: a numeric loop, string building and JSON round trips, fixed in size so
// timings compare across runs. It is copied as index.js into a throwaway extension (the same
// manifest shape as a built-in with one action `bench`) and run through the helper's NDJSON
// protocol; it never ships in the app.
function bench() {
  const start = Date.now();
  let acc = 0;
  for (let i = 1; i < 60000000; i++) {
    acc = (acc + (i * 31) % 7 + Math.sqrt(i & 1023)) % 1000003;
  }
  const afterNumeric = Date.now();
  let digest = 0;
  for (let round = 0; round < 400; round++) {
    const rows = [];
    for (let i = 0; i < 200; i++) rows.push({ id: i, name: "item-" + i + "-" + round, tags: ["a", "b", String(i % 9)], score: i / 7 });
    const text = JSON.stringify(rows);
    const back = JSON.parse(text);
    for (const row of back) digest = (digest + row.name.length + row.tags.length + row.score) % 1000003;
  }
  const end = Date.now();
  return { text: JSON.stringify({ numericMs: afterNumeric - start, jsonMs: end - afterNumeric, totalMs: end - start, check: Math.round(acc + digest) }) };
}
module.exports = { actions: { bench: { run: bench } } };
