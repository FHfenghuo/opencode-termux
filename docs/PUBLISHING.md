# 发布说明（GitHub）

> 目标：把本仓库发到 GitHub 后，**别人能方便地拿到可用的 ELF 并安装**，
> 而仓库本身保持干净、不臃肿。

---

## 1. 二进制为什么走 Release 而不是进 git

GitHub 官方限制：

> **GitHub blocks files larger than 100 MiB.**
> （超过 100 MiB 的文件会被 GitHub 阻止）

本产物 `artifact/opencode` = **199 821 576 B ≈ 191 MiB**，超过该硬限制，
直接 `git push` 会被服务端拒收。仓库容量本身够（官方推荐 <1 GB），
卡点是**单文件 100 MiB**。

官方对此的推荐做法是 **Release**：

> If you need to distribute large files within your repository, you can create
> **releases** on GitHub. **We don't limit the total size of the binary files in
> the release or the bandwidth used to deliver them.**

因此：

| 内容 | 去向 |
|---|---|
| 源码补丁 / 构建脚本 / 安装脚本 / 文档 | **进 git**（仓库本体）|
| `artifact/opencode`（191 MiB）| **不发 git**，作为 **Release 附件** |
| `artifact/opencode.sha256` | 进 git（几十字节，用于校验）|

`.gitignore` 已排除 `artifact/opencode`。

---

## 2. 仓库包含什么

```
opencode-build/
├── README.md                 入口文档
├── .gitignore
├── env.sh                    构建/校验路径真源
├── artifact/
│   └── opencode.sha256       校验和（ELF 本体不发 git）
├── installer/
│   └── opencode-termux.sh    安装器（定位 / 校验 / 依赖 / 菜单）
├── build/
│   ├── build.sh              一键构建
│   ├── verify.sh             产物校验
│   ├── package-release.sh    生成 Release 离线包
│   ├── scan-elf.ts           内嵌 ELF 扫描器
│   ├── patches/              本项目原创补丁（0001..0004）
│   └── overrides/            整树覆盖
├── upstream/
│   └── opencode-bionic/      第三方构建器（158 KB，build.sh 必需输入）
└── docs/                    # 随仓库发布
    ├── HANDOVER.md           主交接文档
    ├── CHANGES.md            改动清单（改了什么、为什么）
    ├── INSTALLER.md          安装器设计
    ├── ARCHITECTURE.md       架构与安装流程
    ├── ARTIFACT-ANALYSIS.md  产物分析
    ├── TROUBLESHOOTING.md    故障排查
    └── PUBLISHING.md         本文档
```

> `docs/` 已随仓库发布。`opencode.zip` 为完整离线包（Release 资产），不进入 git。

`upstream/` 保留进仓库：仅 158 KB，且 `build.sh` 依赖它（`versions.json` 提供
Bionic 资产 URL/版本，`termux/patches/` 是上游补丁层）。它带有自己的 MIT LICENSE。

---

## 3. 首次发布步骤

### 3.1 建仓库并推源码

```bash
cd opencode-build
git init
git add README.md .gitignore env.sh artifact/opencode.sha256 installer build upstream docs
git status          # 确认没有 artifact/opencode、opencode.zip 或构建树
git commit -m "Initial commit: OpenCode Termux (aarch64/Bionic) package"
git branch -M main
git remote add origin git@github.com:<你的账号>/<仓库名>.git
git push -u origin main
```

> 推送前**务必**确认 `git status` 里**没有** `artifact/opencode`。
> 若已被误加入历史，用 `git filter-repo` 清理（见 GitHub 文档
> "Removing files from a repository's history"）。

### 3.2 建 Release 并上传 ELF

在 GitHub 网页：**Releases → Draft a new release**

- **Tag**：建议与产物版本一致，例如 `v2.1.2-dev`
- **Title**：`OpenCode Termux/Bionic v2.1.2-dev`
- **附件**：上传 `artifact/opencode`（191 MiB，单文件上限 2 GB，没问题）
- **说明**：附上 sha256，方便下载者核对：

```
SHA256: 25cde8a86433852d9e981efde4ee5c1a477dee96bf483d5e14469a0433edb50e
```

或用命令行（需 `gh`）：

```bash
gh release create v2.1.2-dev \
  artifact/opencode \
  --title "OpenCode Termux/Bionic v2.1.2-dev" \
  --notes "SHA256: $(cut -d' ' -f1 artifact/opencode.sha256)"
```

---

## 4. 使用者怎么装

```bash
# 1) clone 源码（不含 ELF，很快）
git clone <仓库地址>
cd opencode-build

# 2) 下载 ELF（从 Releases 页面，或直接 wget）
#    放进 artifact/ 或任意目录

# 3) 安装（指定 ELF 所在目录或文件）
bash installer/opencode-termux.sh install ./artifact
```

安装器会**先校验 SHA256**，不匹配立即终止。详见 `docs/INSTALLER.md`。

---

## 5. 更新产物的发布流程

1. 本地重新构建：`bash build/build.sh`
2. 校验：`bash build/verify.sh`
3. 更新 `installer/opencode-termux.sh` 里的 `EXPECTED_SHA256`，与
   `artifact/opencode.sha256` 保持一致
4. 提交源码改动与新的 `artifact/opencode.sha256`
5. 生成离线包：`bash build/package-release.sh`（输出 `$HOME/opencode.zip`）
6. 新建 Release，上传新的 `artifact/opencode`（以及可选的 `opencode.zip`）

> 主程序 sha256 每次构建都会变（Bun bundle 非逐字节可复现），
> 所以**每次发版都要同步更新安装器内置的 `EXPECTED_SHA256`**，
> 否则安装器会拒绝新产物。这是刻意的安全设计。
