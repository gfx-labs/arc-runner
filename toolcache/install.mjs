#!/usr/bin/env node
// Preinstalls manifest.json tool versions into the runner tool cache by running the pinned setup-* actions.
// Usage: install.mjs [--tool node|go|ruby]... [--verify]  (--verify reuses cached sources and never downloads)
import { execFileSync, spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const log = (m) => console.log(`[toolcache] ${m}`)
const die = (m) => { throw new Error(m) }

const here = path.dirname(fileURLToPath(import.meta.url))
const manifest = JSON.parse(fs.readFileSync(process.env.TOOLCACHE_MANIFEST || path.join(here, 'manifest.json'), 'utf8'))
const actionsRoot = process.env.SETUP_ACTIONS_DIR || '/opt/setup-actions'
const toolCache = process.env.RUNNER_TOOL_CACHE || '/opt/hostedtoolcache'
const home = process.env.HOME || os.userInfo().homedir

const EXACT = /^\d+\.\d+\.\d+$/
const SHA = /^[0-9a-f]{40}$/
const PASS_ENV = ['PATH', 'USER', 'LOGNAME', 'LANG', 'LC_ALL', 'LC_CTYPE', 'TZ', 'TERM',
  'SSL_CERT_FILE', 'SSL_CERT_DIR', 'NODE_EXTRA_CA_CERTS',
  'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'http_proxy', 'https_proxy', 'no_proxy']
const BLOCKED_ENV = /^(LD_|NODE_OPTIONS$|BASH_ENV$|ENV$|GITHUB_|RUNNER_|ACTIONS_|INPUT_)/

// Checks run against the installed binary; `ver` is the exact requested version.
const BINARIES = {
  node: { args: ['--version'], ok: (out, ver) => out.trim() === `v${ver}` },
  go: { args: ['version'], ok: (out, ver) => out.startsWith(`go version go${ver} `) },
  ruby: { args: ['-e', 'print RUBY_VERSION'], ok: (out, ver) => out.trim() === ver },
}

function parseArgs(argv) {
  const opts = { tools: [], verify: false }
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--verify') opts.verify = true
    else if (argv[i] === '--tool') opts.tools.push(argv[++i] ?? die('--tool needs a value'))
    else if (argv[i].startsWith('--tool=')) opts.tools.push(argv[i].slice(7))
    else die(`unknown argument: ${argv[i]}\nusage: install.mjs [--tool node|go|ruby]... [--verify]`)
  }
  const known = Object.keys(manifest.tools)
  for (const t of opts.tools) if (!known.includes(t)) die(`unknown tool ${t} (known: ${known.join(', ')})`)
  if (!opts.tools.length) opts.tools = known
  return opts
}

function validateManifest(tool) {
  if (!Object.hasOwn(BINARIES, tool)) die(`unsupported tool ${tool} (supported: ${Object.keys(BINARIES).join(', ')})`)
  const action = manifest.actions?.[tool] ?? die(`manifest has no action for ${tool}`)
  if (!/^[\w.-]+\/[\w.-]+$/.test(action.repository ?? '')) die(`${tool}: bad repository`)
  if (!SHA.test(action.revision ?? '')) die(`${tool}: revision must be a 40-hex SHA`)
  if (!/^node\d+$/.test(action.runtime ?? '')) die(`${tool}: bad runtime`)
  if (!action.entrypoint || path.isAbsolute(action.entrypoint) || action.entrypoint.split('/').includes('..')) {
    die(`${tool}: bad entrypoint`)
  }
  const versions = manifest.tools[tool]
  if (!Array.isArray(versions) || !versions.length) die(`${tool}: no versions in manifest`)
  for (const v of versions) if (!EXACT.test(v)) die(`${tool}: version ${v} is not an exact semver`)
  return action
}

const within = (root, p) => p === root || p.startsWith(root + path.sep)

// Rejects absolute/.. paths and non file/dir/link entries before extraction.
function checkArchive(tarball) {
  const names = execFileSync('tar', ['-tzf', tarball], { encoding: 'utf8', maxBuffer: 1 << 28 }).split('\n').filter(Boolean)
  for (const n of names) if (path.isAbsolute(n) || n.split('/').includes('..')) die(`unsafe path in archive: ${n}`)
  const verbose = execFileSync('tar', ['-tvzf', tarball], { encoding: 'utf8', maxBuffer: 1 << 28 }).split('\n').filter(Boolean)
  for (const l of verbose) if (!'-dlh'.includes(l[0])) die(`unsupported entry type in archive: ${l}`)
}

// Rejects symlinks that point outside the extracted tree.
function checkSymlinks(root) {
  for (const e of fs.readdirSync(root, { withFileTypes: true, recursive: true })) {
    if (!e.isSymbolicLink()) continue
    const p = path.join(e.parentPath, e.name)
    const target = path.resolve(path.dirname(p), fs.readlinkSync(p))
    if (!within(root, target)) die(`symlink escapes action source: ${p}`)
  }
}

function fetchAction(tool, action) {
  const dest = path.join(actionsRoot, tool, action.revision)
  const marker = path.join(dest, '.source-complete')
  if (fs.existsSync(marker)) return dest
  fs.mkdirSync(path.join(actionsRoot, tool), { recursive: true })
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'setup-action-'))
  const staging = path.join(actionsRoot, tool, `.${action.revision}.${process.pid}`)
  try {
    const tarball = path.join(tmp, 'src.tar.gz')
    const url = `https://codeload.github.com/${action.repository}/tar.gz/${action.revision}`
    log(`downloading ${url}`)
    execFileSync('curl', ['-fsSL', '--proto', '=https', '--tlsv1.2', '--retry', '3', '--retry-connrefused', '-o', tarball, url], { stdio: 'inherit' })
    checkArchive(tarball)
    fs.rmSync(staging, { recursive: true, force: true })
    fs.mkdirSync(staging)
    execFileSync('tar', ['-xzf', tarball, '-C', staging, '--strip-components=1', '--no-same-owner', '--no-same-permissions'])
    checkSymlinks(staging)
    // Readable by the runner user, writable only by the installing user.
    execFileSync('chmod', ['-R', 'u+rwX,go+rX,go-w', staging])
    fs.writeFileSync(path.join(staging, '.source-complete'), `${action.repository}@${action.revision}\n`)
    fs.rmSync(dest, { recursive: true, force: true })
    fs.renameSync(staging, dest)
  } finally {
    fs.rmSync(staging, { recursive: true, force: true })
    fs.rmSync(tmp, { recursive: true, force: true })
  }
  return dest
}

// Reads runs.using and runs.main from action.yml (flat keys at the first indent of `runs:`).
function readRuns(dir) {
  const file = ['action.yml', 'action.yaml'].map((f) => path.join(dir, f)).find((f) => fs.existsSync(f))
    ?? die(`no action.yml in ${dir}`)
  const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/)
  const start = lines.findIndex((l) => /^runs:\s*(#.*)?$/.test(l))
  if (start < 0) die(`${file}: no runs block`)
  const runs = {}
  let indent
  for (const l of lines.slice(start + 1)) {
    if (!l.trim() || l.trim().startsWith('#')) continue
    const m = l.match(/^(\s+)([\w-]+):\s*(.*?)\s*$/)
    if (!m) { if (/^\S/.test(l)) break; continue }
    indent ??= m[1]
    if (m[1] !== indent) continue
    runs[m[2]] = m[3].replace(/\s+#.*$/, '').replace(/^(['"])(.*)\1$/, '$2')
  }
  return runs
}

function bootstrapNode(runtime) {
  const external = `/home/runner/externals/${runtime}/bin/node`
  if (fs.existsSync(external)) return external
  if (`node${process.versions.node.split('.')[0]}` === runtime) return process.execPath
  return die(`no ${runtime} binary: ${external} missing and current node is ${process.version}`)
}

function parseGithubPath(file) {
  return fs.readFileSync(file, 'utf8').split('\n').map((l) => l.trim()).filter(Boolean)
}

// GITHUB_ENV: `NAME=value` lines or `NAME<<DELIM` blocks. Parsed only, never executed.
function parseGithubEnv(file) {
  const out = {}
  const lines = fs.readFileSync(file, 'utf8').split('\n')
  for (let i = 0; i < lines.length; i++) {
    const heredoc = lines[i].match(/^([^=<]+)<<(.+)$/)
    if (heredoc) {
      const body = []
      for (i++; i < lines.length && lines[i] !== heredoc[2]; i++) body.push(lines[i])
      out[heredoc[1]] = body.join('\n')
    } else if (lines[i].includes('=')) {
      const k = lines[i].indexOf('=')
      out[lines[i].slice(0, k)] = lines[i].slice(k + 1)
    }
  }
  return out
}

function baseEnv(verify) {
  const env = { HOME: home, GOTOOLCHAIN: 'local' }
  for (const k of PASS_ENV) if (process.env[k] !== undefined) env[k] = process.env[k]
  env.PATH ??= '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
  if (verify) {
    // Any download attempt through proxy-aware clients fails immediately.
    for (const k of ['HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy']) env[k] = 'http://127.0.0.1:1'
    env.NO_PROXY = env.no_proxy = ''
  }
  return env
}

function runAction(tool, action, sourceDir, version, verify) {
  const runs = readRuns(sourceDir)
  if (runs.using !== action.runtime) die(`${tool}: action.yml runs.using=${runs.using}, manifest expects ${action.runtime}`)
  if (runs.main !== action.entrypoint) die(`${tool}: action.yml runs.main=${runs.main}, manifest expects ${action.entrypoint}`)
  const entry = fs.realpathSync(path.join(sourceDir, runs.main))
  if (!within(fs.realpathSync(sourceDir), entry)) die(`${tool}: entrypoint escapes action source`)

  fs.mkdirSync(toolCache, { recursive: true })
  const runnerTemp = fs.mkdtempSync(path.join(os.tmpdir(), `runner-temp-${tool}-`))
  try {
    const workspace = path.join(runnerTemp, 'work')
    fs.mkdirSync(workspace)
    const files = {}
    for (const n of ['PATH', 'ENV', 'OUTPUT', 'STATE', 'STEP_SUMMARY']) {
      files[n] = path.join(runnerTemp, `github_${n.toLowerCase()}`)
      fs.writeFileSync(files[n], '')
    }
    const env = {
      ...baseEnv(verify),
      CI: 'true',
      GITHUB_ACTIONS: 'true',
      GITHUB_WORKSPACE: workspace,
      GITHUB_ACTION_PATH: sourceDir,
      GITHUB_ACTION_REPOSITORY: action.repository,
      GITHUB_SERVER_URL: 'https://github.com',
      GITHUB_API_URL: 'https://api.github.com',
      GITHUB_PATH: files.PATH,
      GITHUB_ENV: files.ENV,
      GITHUB_OUTPUT: files.OUTPUT,
      GITHUB_STATE: files.STATE,
      GITHUB_STEP_SUMMARY: files.STEP_SUMMARY,
      RUNNER_OS: 'Linux',
      RUNNER_ARCH: process.arch === 'arm64' ? 'ARM64' : 'X64',
      RUNNER_TEMP: runnerTemp,
      RUNNER_TOOL_CACHE: toolCache,
      AGENT_TOOLSDIRECTORY: toolCache,
    }
    const request = verify ? manifest.verifyRequests?.[tool]?.[version] ?? version : version
    const inputs = { ...action.inputs, [`${tool}-version`]: request, token: '' }
    for (const [k, v] of Object.entries(inputs)) env[`INPUT_${k.replace(/ /g, '_').toUpperCase()}`] = String(v)

    log(`${verify ? 'verifying' : 'installing'} ${tool} ${version} (request ${request}) via ${action.repository}@${action.revision.slice(0, 12)}`)
    const r = spawnSync(bootstrapNode(action.runtime), [entry], {
      cwd: workspace, env, stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 1 << 28,
    })
    // Defang workflow commands so the outer CI runner does not execute them from the build log.
    const defang = (buf) => buf.toString().replace(/##\[/g, '#_[').replace(/^(\s*)::/gm, '$1:_')
    process.stdout.write(defang(r.stdout ?? ''))
    process.stderr.write(defang(r.stderr ?? ''))
    if (r.error) throw r.error
    if (r.status !== 0) die(`${tool} ${version}: action exited with ${r.signal ?? r.status}`)
    validate(tool, version, files)
  } finally {
    fs.rmSync(runnerTemp, { recursive: true, force: true })
  }
}

// Runs the binary the action put on PATH and requires it to live in the tool cache.
function validate(tool, version, files) {
  const cacheReal = fs.realpathSync(toolCache)
  const addPaths = parseGithubPath(files.PATH)
  const bin = addPaths.map((d) => path.join(d, tool)).find((f) => {
    try { fs.accessSync(f, fs.constants.X_OK); return true } catch { return false }
  }) ?? die(`${tool}: no executable on GITHUB_PATH (${addPaths.join(':') || 'empty'})`)
  const binReal = fs.realpathSync(bin)
  if (!within(cacheReal, binReal)) die(`${tool}: ${bin} resolves outside ${cacheReal}`)
  const prefix = path.dirname(path.dirname(binReal))
  if (!fs.existsSync(`${prefix}.complete`)) die(`${tool}: missing tool cache marker ${prefix}.complete`)

  const env = { ...baseEnv(false) }
  for (const [k, v] of Object.entries(parseGithubEnv(files.ENV))) if (!BLOCKED_ENV.test(k)) env[k] = v
  env.PATH = [...addPaths, env.PATH].join(':')
  const spec = BINARIES[tool]
  const out = execFileSync(bin, spec.args, { env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] })
  if (!spec.ok(out, version)) die(`${tool}: expected ${version}, got ${JSON.stringify(out.trim())}`)
  log(`${tool} ${version} ok at ${prefix}`)
}

function main() {
  const opts = parseArgs(process.argv.slice(2))
  for (const tool of opts.tools) {
    const action = validateManifest(tool)
    const dest = path.join(actionsRoot, tool, action.revision)
    if (opts.verify) {
      if (!fs.existsSync(path.join(dest, '.source-complete'))) die(`${tool}: action source not cached at ${dest}`)
    } else {
      fetchAction(tool, action)
    }
    for (const version of manifest.tools[tool]) runAction(tool, action, dest, version, opts.verify)
  }
  log('done')
}

try {
  main()
} catch (e) {
  console.error(`[toolcache] ERROR: ${e.message}`)
  process.exit(1)
}
