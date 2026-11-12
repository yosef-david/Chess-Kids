import { access, readFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const root = process.cwd();
const required = [
  'dist/index.html',
  'dist/config.js',
  'dist/engine/stockfish-19-lite-single.js',
  'dist/engine/stockfish-19-lite-single.wasm',
  'dist/engine/COPYING.txt'
];

for (const relativePath of required) {
  await access(resolve(root, relativePath));
}

const html = await readFile(resolve(root, 'dist/index.html'), 'utf8');
if (!html.includes('Chess Kids')) {
  throw new Error('Built HTML does not contain the Chess Kids app title.');
}

const config = await readFile(resolve(root, 'dist/config.js'), 'utf8');
if (!config.includes('CHESS_KIDS_CONFIG')) {
  throw new Error('Supabase browser configuration was not copied into dist.');
}

console.log('Build smoke check passed: app, public config, Stockfish JS/WASM and license are present.');
