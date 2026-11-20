// GLITCH TIDE — BRAINROT HEIST: THE MEMEVERSE — make.fun roblox-brainrot-01 entry program (Node 22,
// standard library only). Based on the official kit starter's main.ts (kit bundle_sha256
// 0ca08c49f7bc9d313dea81a29e37b3c56acaca0bdc2e198e4021c14eee80cdf5); same copy rules, same dossier caps.
//
// The game is this directory's Rojo project, built into game.rbxl with
//   rojo build default.project.json --output game.rbxl        (Rojo 7.7.1)
// This program hands it in: it copies game.rbxl, src/, screenshots/ and PLAY.json from beside this file to
// /output and writes /output/dossier.json with buildDossier from the kit's unchanged vendor/makefun-roblox.ts.
//
// Every name under /output must start with a letter, digit or _ and hold only letters, digits, . _ and -,
// so src/ and screenshots/ are copied without any name that starts with a dot (e.g. src/map/.gitkeep).
//
// Before copying, it checks that every required input exists and fails with a clear message if not.
//
// Outside the grader's container, MAKEFUN_OUTPUT_DIR stands in for /output:
//   mkdir -p out && MAKEFUN_OUTPUT_DIR=out node main.ts

import { copyFileSync, cpSync, existsSync, mkdirSync, statSync, writeFileSync } from 'node:fs';
import { basename, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildDossier } from './vendor/makefun-roblox.ts';

const here = fileURLToPath(new URL('.', import.meta.url));
const out = process.env.MAKEFUN_OUTPUT_DIR ?? '/output';

/** Preflight: name every missing required input at once, then stop with a non-zero exit. */
const required: Array<[string, 'file' | 'dir']> = [
  ['game.rbxl', 'file'],
  ['PLAY.json', 'file'],
  ['src', 'dir'],
  ['vendor/makefun-roblox.ts', 'file'],
];
const missing = required
  .filter(([p, kind]) => {
    const full = join(here, p);
    if (!existsSync(full)) return true;
    const st = statSync(full);
    return kind === 'file' ? !st.isFile() : !st.isDirectory();
  })
  .map(([p, kind]) => `${p} (${kind})`);
if (missing.length > 0) {
  console.error(`main.ts: missing required input(s) beside main.ts: ${missing.join(', ')}`);
  console.error('game.rbxl: rojo build default.project.json --output game.rbxl; PLAY.json: the published Public place (see HANDOFF_TO_GROK_BUILD.md).');
  process.exit(1);
}
if (!existsSync(out)) {
  console.error(`main.ts: output directory ${out} does not exist (set MAKEFUN_OUTPUT_DIR or create it).`);
  process.exit(1);
}

/** cpSync's filter: leave out every file and directory whose name starts with a dot (.gitkeep, .DS_Store, .git). */
const notDotted = (path: string): boolean => !basename(path).startsWith('.');

copyFileSync(join(here, 'game.rbxl'), join(out, 'game.rbxl'));
copyFileSync(join(here, 'PLAY.json'), join(out, 'PLAY.json'));
cpSync(join(here, 'src'), join(out, 'src'), { recursive: true, filter: notDotted });
mkdirSync(join(out, 'screenshots'), { recursive: true });
if (existsSync(join(here, 'screenshots'))) cpSync(join(here, 'screenshots'), join(out, 'screenshots'), { recursive: true, filter: notDotted });

// The scorer's own caps (reference/gate.json), exactly as in the kit starter: only text_max_bytes shapes the bytes;
// the others refuse an entry the scorer would refuse.
writeFileSync(
  join(out, 'dossier.json'),
  buildDossier(out, { text_max_bytes: 65536, screenshots: { max: 4, max_bytes: 262144 }, max_instances: 500000, scripts_max_source_bytes: 8388608, scripts_max_path_chars: 1048576 }),
);
