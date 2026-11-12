import { mkdir, copyFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const root = process.cwd();
const source = resolve(root, 'node_modules/stockfish/bin');
const destination = resolve(root, 'public/engine');

await mkdir(destination, { recursive: true });
for (const file of ['stockfish-19-lite-single.js', 'stockfish-19-lite-single.wasm']) {
  await copyFile(resolve(source, file), resolve(destination, file));
}
console.log('Stockfish browser engine copied to public/engine.');
