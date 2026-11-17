// Builds the extension into dist/: scripts are bundled into single files with esbuild, everything else is copied as is.
// version_name is set to a fingerprint of the build output (computed before writing, manifest included): the App compares it to know whether the browser is running the latest version
import { build } from 'esbuild'
import { createHash } from 'node:crypto'
import { cpSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'

rmSync('dist', { recursive: true, force: true })
await build({ entryPoints: ['src/background.ts', 'src/read.ts', 'src/reader-page.ts'], bundle: true, format: 'iife', target: 'chrome120', outdir: 'dist' })
cpSync('static', 'dist', { recursive: true })

const hash = createHash('sha256')
const walk = dir => readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name < b.name ? -1 : 1).forEach(entry => {
  const path = `${dir}/${entry.name}`
  if (entry.isDirectory()) return walk(path)
  hash.update(path).update(readFileSync(path))  // the manifest counts too: a change to permissions alone is also a new version
})
walk('dist')
const manifest = JSON.parse(readFileSync('dist/manifest.json', 'utf8'))
manifest.version_name = hash.digest('hex').slice(0, 12)
writeFileSync('dist/manifest.json', JSON.stringify(manifest, null, 2))
console.log(`Extension bundled to dist/, version ${manifest.version_name}`)
