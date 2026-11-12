import { mkdir, copyFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const root = process.cwd();
const publicDir = resolve(root, 'public');
const engineSource = resolve(root, 'node_modules/stockfish/bin');
const engineDestination = resolve(publicDir, 'engine');

await mkdir(engineDestination, { recursive: true });
await copyFile(resolve(root, 'config.js'), resolve(publicDir, 'config.js'));

for (const file of ['stockfish-19-lite-single.js', 'stockfish-19-lite-single.wasm']) {
  await copyFile(resolve(engineSource, file), resolve(engineDestination, file));
}
console.log('Chess Kids public config and Stockfish assets prepared.');
