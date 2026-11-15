// 打包扩展到 dist/：脚本用 esbuild 打成单文件，其余原样拷贝。
// version_name 写成打包结果的指纹（写入之前算，manifest 本身也在内）：App 比对它，知道浏览器里跑的是不是最新一版
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
  hash.update(path).update(readFileSync(path))  // manifest 也算：只改权限也是新的一版
})
walk('dist')
const manifest = JSON.parse(readFileSync('dist/manifest.json', 'utf8'))
manifest.version_name = hash.digest('hex').slice(0, 12)
writeFileSync('dist/manifest.json', JSON.stringify(manifest, null, 2))
console.log(`扩展已打包到 dist/，版本 ${manifest.version_name}`)
