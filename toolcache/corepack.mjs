#!/usr/bin/env node
// Seeds the official Corepack cache (COREPACK_HOME) with manifest.json corepack.packages.
// Usage: corepack.mjs [--verify]  (--verify runs offline from the cache and never installs or fetches)
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const log = (m) => console.log(`[corepack] ${m}`)
const die = (m) => { throw new Error(m) }

const here = path.dirname(fileURLToPath(import.meta.url))
const manifest = JSON.parse(fs.readFileSync(process.env.TOOLCACHE_MANIFEST || path.join(here, 'manifest.json'), 'utf8'))
const corepackHome = process.env.COREPACK_HOME || '/opt/corepack'

// name@x.y.z with an optional +sha512.<hex> integrity suffix.
const SPEC = /^(yarn|pnpm)@(\d+\.\d+\.\d+)(\+sha\d+\.[0-9a-f]+)?$/

const args = process.argv.slice(2)
const verify = args.includes('--verify')
for (const a of args) if (a !== '--verify') die(`unknown argument: ${a}\nusage: corepack.mjs [--verify]`)

const packages = manifest.corepack?.packages
if (!Array.isArray(packages) || !packages.length) die('manifest has no corepack.packages')
for (const p of packages) if (!SPEC.test(p)) die(`bad corepack package spec: ${p}`)
// Install creates the cache dir (the Dockerfile chowns it afterwards). Verify requires it to exist.
if (!verify) fs.mkdirSync(corepackHome, { recursive: true })
else if (!fs.statSync(corepackHome, { throwIfNoEntry: false })?.isDirectory()) die(`COREPACK_HOME ${corepackHome} does not exist`)

function corepack(argv, opts) {
  const res = spawnSync('corepack', argv, {
    stdio: ['ignore', 'pipe', 'inherit'],
    encoding: 'utf8',
    ...opts,
    env: { ...process.env, COREPACK_HOME: corepackHome, COREPACK_ENABLE_DOWNLOAD_PROMPT: '0', COREPACK_ENABLE_AUTO_PIN: '0', ...opts?.env },
  })
  if (res.error) die(`corepack ${argv.join(' ')}: ${res.error.message}`)
  if (res.status !== 0) die(`corepack ${argv.join(' ')} exited with ${res.status}`)
  return res.stdout
}

function install(spec) {
  log(`installing ${spec.replace(/\+.*/, '')} into ${corepackHome}`)
  // --cache-only fills the cache without changing the global default version.
  corepack(['install', '--global', '--cache-only', spec], { stdio: 'inherit' })
}

function check(spec) {
  const [, , version] = spec.match(SPEC)
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'corepack-verify-'))
  try {
    fs.writeFileSync(path.join(tmp, 'package.json'), JSON.stringify({ packageManager: spec }))
    const tool = spec.split('@')[0]
    const out = corepack([tool, '--version'], { cwd: tmp, env: { COREPACK_ENABLE_NETWORK: '0' } }).trim()
    if (out !== version) die(`${spec.replace(/\+.*/, '')}: expected ${version}, got ${out}`)
    log(`verified ${tool}@${version} offline`)
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true })
  }
}

if (!verify) for (const p of packages) install(p)
for (const p of packages) check(p)
