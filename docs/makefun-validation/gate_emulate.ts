// Local emulation of the gate rows the CLI check does not run (no local grade exists). Uses the kit's vendor library.
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';
import { readPlace, matchSources } from './makefun-roblox.ts';
const dir = process.argv[2];
const buf = readFileSync(join(dir, 'game.rbxl'));
console.log('place_file: size', buf.length, 'magic', buf.subarray(0, 8).toString('latin1'));
const place = readPlace(buf, { max_instances: 500000, scripts_max_source_bytes: 8388608, scripts_max_path_chars: 1048576 } as any);
const nonEmpty = place.scripts.filter((s: any) => s.source.length > 0).length;
console.log('place_scripts: scripts', place.scripts.length, 'non-empty', nonEmpty, 'instances', (place as any).instances ?? '(see classes)');
const files: string[] = [];
const walk = (d: string) => { for (const n of readdirSync(d)) { const p = join(d, n); statSync(p).isDirectory() ? walk(p) : files.push(p); } };
walk(join(dir, 'src'));
let total = 0; for (const f of files) total += statSync(f).size;
const scr = files.filter((f) => /\.(luau|lua)$/.test(f) && !f.split('/').pop()!.startsWith('.'));
const m = matchSources(place, scr.map((f) => ({ path: relative(join(dir, 'src'), f), bytes: new Uint8Array(readFileSync(f)) })));
console.log('source_matches_place: src files', files.length, 'bytes', total, 'script files', scr.length, 'matched', m.matched.length, 'unmatched', JSON.stringify(m.unmatched), 'coverage', m.coverage.toFixed(4), 'scripts matched', m.scriptMatched.filter(Boolean).length + '/' + place.scripts.length);
