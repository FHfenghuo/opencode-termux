#!/usr/bin/env bun
// 扫描一个二进制里内嵌的所有 ELF 镜像，并列出它们的 NEEDED 依赖。
//
// 为什么需要：bun compile 会把 .so 原样嵌进产物（比如 bun-pty 的
// librust_pty_arm64.so）。主程序的 `readelf -d` 只看得到主程序的依赖，
// 看��内嵌的那个 .so 到底链接了 libc.so.6（glibc）还是 libc.so（Bionic）。
// 这个脚本把内嵌 ELF 逐个切出来单独检查。
//
// 用法：
//   bun scan-elf.ts <binary> [--json]
//
// 输出：每个内嵌 ELF 的偏移、类型、NEEDED 列表；--json 输出机器可读格式。

import { readFileSync, writeFileSync, mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { execFileSync } from "node:child_process"
import { createHash } from "node:crypto"

type Embedded = {
  offset: number
  size: number
  type: string
  machine: string
  sha256: string
  needed: string[]
  // 切片内出现的 glibc SONAME 字面量（readelf 的 NEEDED 之外的第二道保险；
  // 静态链接或手工 dlopen 的场景 NEEDED 可能为空，但字面量还在）
  glibcStrings: string[]
}

const GLIBC_SONAMES = [
  "libc.so.6",
  "libm.so.6",
  "libdl.so.2",
  "libpthread.so.0",
  "libutil.so.1",
  "librt.so.1",
  "ld-linux",
  "ld-linux-aarch64",
  "ld-musl",
]

function readElf(buf: Buffer, off: number): Embedded | undefined {
  if (off + 64 > buf.length) return undefined
  if (buf.readUInt32BE(off) !== 0x7f454c46) return undefined // \x7fELF
  const cls = buf[off + 4]
  const data = buf[off + 5]
  if (cls !== 2 || data !== 1) return undefined // 仅 64 位小端

  const eType = buf.readUInt16LE(off + 16)
  const eMachine = buf.readUInt16LE(off + 18)
  const ePhoff = Number(buf.readBigUInt64LE(off + 32))
  const ePentsize = buf.readUInt16LE(off + 54)
  const ePnum = buf.readUInt16LE(off + 56)
  const eShoff = Number(buf.readBigUInt64LE(off + 40))
  const eShentsize = buf.readUInt16LE(off + 58)
  const eShnum = buf.readUInt16LE(off + 60)

  const typeMap: Record<number, string> = { 0: "NONE", 1: "REL", 2: "EXEC", 3: "DYN", 4: "CORE" }
  const machineMap: Record<number, string> = { 0x3e: "AArch64", 0x3: "x86", 0xb7: "AArch64", 0x28: "ARM" }

  let end = off + 64
  // ePhoff / eShoff 是相对 ELF 头起点的偏移，必须加上基址 off
  if (ePnum > 0) end = Math.max(end, off + ePhoff + ePnum * ePentsize)
  if (eShnum > 0) end = Math.max(end, off + eShoff + eShnum * eShentsize)
  if (end > buf.length) end = buf.length
  const size = end - off
  if (size < 64) return undefined
  // eType==0 (NONE) 或 eMachine==0 是数据里的巧合字节，不是真的 ELF 头
  if (eType === 0 || eMachine === 0) return undefined

  return {
    offset: off,
    size,
    type: typeMap[eType] ?? `0x${eType.toString(16)}`,
    machine: machineMap[eMachine] ?? `0x${eMachine.toString(16)}`,
    sha256: "",
    needed: [],
    glibcStrings: [],
  }
}

function readNeeded(path: string): string[] {
  const readelf = ["greadelf", "readelf", "llvm-readelf"].find((c) => {
    try {
      execFileSync("sh", ["-c", `command -v ${c}`], { stdio: "ignore" })
      return true
    } catch {
      return false
    }
  })
  if (!readelf) return []
  try {
    const out = execFileSync(readelf, ["-dW", path], { encoding: "utf8" })
    return out
      .split("\n")
      .filter((l) => l.includes("NEEDED"))
      .map((l) => l.match(/\[([^\]]+)\]/)?.[1] ?? "")
      .filter(Boolean)
  } catch {
    return []
  }
}

const args = process.argv.slice(2)
const asJson = args.includes("--json")
const target = args.find((a) => !a.startsWith("--"))
if (!target) {
  console.error("usage: scan-elf.ts <binary> [--json] [--expect <sha256>[:label]]")
  process.exit(2)
}

// --expect <sha256>[:label]  —— 要求产物里必须内嵌一个 sha256 完全相同的 ELF。
// 用于核对「内嵌的确实是我们放进构建树的那个 Bionic 资产」，而不只是「没有 glibc」。
const expects: { sha: string; label: string }[] = []
for (let i = 0; i < args.length; i++) {
  if (args[i] !== "--expect") continue
  const raw = args[i + 1] ?? ""
  const [sha, label] = raw.includes(":") ? [raw.slice(0, raw.indexOf(":")), raw.slice(raw.indexOf(":") + 1)] : [raw, "?"]
  expects.push({ sha: sha.toLowerCase(), label: label || "?" })
}

const buf = readFileSync(target)
const results: Embedded[] = []

// 先收集所有 ELF magic 的偏移，再逐个独立解析。
// 不能用 "跳过 size" 的方式推进游标：主程序 ELF 的 size 就是整个文件，
// 那样会把后面内嵌的 .so 全部跳过。
for (let i = 0; i + 4 <= buf.length; i++) {
  if (buf[i] !== 0x7f || buf[i + 1] !== 0x45 || buf[i + 2] !== 0x4c || buf[i + 3] !== 0x46) continue
  const elf = readElf(buf, i)
  if (!elf) continue
  results.push(elf)
}

// 逐个落盘，用 readelf 取 NEEDED，并扫描切片内的 glibc 字面量
const dir = mkdtempSync(join(tmpdir(), "scanelf-"))
try {
  for (const r of results) {
    const p = join(dir, `elf-${r.offset}.so`)
    const slice = buf.subarray(r.offset, r.offset + r.size)
    writeFileSync(p, slice)
    r.needed = readNeeded(p)
    r.sha256 = createHash("sha256").update(slice).digest("hex")
    r.glibcStrings = GLIBC_SONAMES.filter((g) => slice.includes(Buffer.from(g, "latin1")))
  }
} finally {
  rmSync(dir, { recursive: true, force: true })
}

// 主程序（offset 0）自身的运行时里会混进 "libc.so.6" 这类字面量
// （例如 Bun 自己的字符串表），那是数据不是依赖 —— 主程序是否依赖 glibc
// 由 readelf -d / -V 判定。
//
// 字面量扫描只对「动态链接」的 ELF 生效：NEEDED 为空说明它是完全静态的，
// 根本不走动态链接器，里面出现 "ld-musl" 之类的字符串无意义
// （Rust/musl 工具链的静态产物里就有这种残留字面量）。
const isMain = (r: Embedded) => r.offset === 0
const isDynamic = (r: Embedded) => r.needed.length > 0
const hasGlibc = (r: Embedded) =>
  r.needed.some((n) => GLIBC_SONAMES.some((g) => n.includes(g))) ||
  r.needed.some((n) => n.includes("GLIBC_")) ||
  (!isMain(r) && isDynamic(r) && r.glibcStrings.length > 0)
const glibcHits = results.filter(hasGlibc)

// --expect 校验：内嵌资产必须与指定的 sha256 逐字节一致
const expectResults = expects.map((e) => {
  const hit = results.find((r) => r.sha256 === e.sha)
  return { label: e.label, sha: e.sha, found: !!hit, offset: hit?.offset, size: hit?.size }
})
const missing = expectResults.filter((e) => !e.found)

if (asJson) {
  console.log(
    JSON.stringify(
      {
        total: results.length,
        glibcHits: glibcHits.length,
        expects: expectResults,
        embedded: results,
      },
      null,
      2,
    ),
  )
} else {
  console.log(`扫描 ${target}：发现 ${results.length} 个内嵌 ELF`)
  for (const r of results) {
    const bad = hasGlibc(r)
    const label = isMain(r) ? "主程序" : isDynamic(r) ? "内嵌 .so" : "内嵌 .so(静态)"
    const flag = bad ? "  ✘ glibc!" : ""
    console.log(
      `  [${label}] @${r.offset.toString().padStart(10)}  ${r.type.padEnd(4)} ${r.machine.padEnd(8)} ${String(r.size).padStart(10)} B  NEEDED=[${r.needed.join(", ")}]  sha=${r.sha256.slice(0, 16)}${flag}`,
    )
    if (!isMain(r) && isDynamic(r) && r.glibcStrings.length > 0)
      console.log(`      glibc 字面量: ${r.glibcStrings.join(", ")}`)
  }
  if (glibcHits.length > 0) {
    console.log(`\n✘ ${glibcHits.length} 个内嵌 ELF 依赖 glibc`)
  } else {
    console.log("✔ 所有内嵌 ELF 均无 glibc 依赖")
  }
  for (const e of expectResults) {
    if (e.found) console.log(`✔ 内嵌 ${e.label}：@${e.offset} ${e.size} B sha=${e.sha.slice(0, 16)}`)
    else console.log(`✘ 缺少内嵌资产 ${e.label}（期望 sha=${e.sha.slice(0, 16)}）`)
  }
}

if (glibcHits.length > 0 || missing.length > 0) {
  process.exit(1)
}
