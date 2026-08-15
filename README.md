# dsh-portable

DeepSeek Harness（dsh）的便携版：`dsh.exe`（Windows）或 `dsh` 脚本（Linux、macOS）内嵌完整的
dsh 运行环境与 Node.js，双击（Windows）或一条命令（Linux/macOS）即可在浏览器打开 Web UI
（默认 http://127.0.0.1:3080），无需预先安装 Node.js。

## 特性

- **单文件/自包含分发**：Windows 为单个 `dsh.exe`；Linux/macOS 为自带 `node` + dsh 包的 tarball，无需预先安装任何运行时。
- **首次运行自动解压**（Windows）：解压到 `%LOCALAPPDATA%\dsh-exe\<version>`，之后直接启动。
- **幂等启动**：目标端口已由 dsh Web UI 使用时只打开浏览器并退出，重复启动不会产生重复服务器；其他服务占用端口时仍交由 dsh 报告冲突。
- **单实例保护**：同一数据目录只允许一个 dsh 服务器；再启动第二个实例会被拒绝，
  避免两个服务器并发写坏同一份会话历史。
- **会话日志自愈**：读取端自动处理被并发/过期写入者重写的日志段，"历史加载失败"不再出现。
- **启动检查更新**：启动时联网查询 GitHub Release，发现新版本在控制台提示下载链接（离线/超时自动跳过，不影响启动）。

## 快速开始

### Windows

1. 从 [Releases](../../releases) 下载 `dsh.exe`（约 110 MB，内嵌完整运行时）。
2. 双击运行，或命令行执行 `dsh.exe web`。
3. 浏览器自动打开 http://127.0.0.1:3080。

### Linux / macOS

1. 从 [Releases](../../releases) 下载对应平台的 `dsh-portable-<version>-<os>-<arch>.tar.gz`
   （`linux-x64`、`linux-arm64`、`darwin-arm64`）。
2. 解压并运行：
   ```sh
   tar -xzf dsh-portable-0.1.0-rc.8-linux-x64.tar.gz
   ./dsh          # 或 ./dsh web，等价于 dsh web
   ```
3. 浏览器自动打开 http://127.0.0.1:3080。可把解压目录里的 `dsh` 软链到 `~/.local/bin/dsh`
   （macOS 为 `/usr/local/bin/dsh`）以便全局使用。

> 说明：macOS 仅提供 Apple Silicon（`darwin-arm64`，覆盖 2020 年后的所有 Mac）；
> Intel Mac 因 GitHub 已弃用 Intel macOS 构建机（macos-13）暂不提供。

命令行用法与 `dsh` 一致，例如：

```text
dsh.exe web                  # Windows：启动 Web UI（默认端口 3080）
./dsh web --port 8080        # Linux/macOS：指定端口
dsh.exe --version            # 其他 CLI 用法透传
```

## 更新

1. 关闭正在运行的 dsh（关掉启动它的控制台窗口，或任务管理器结束 `dsh` / `node` 进程）。
2. 从 [Releases](../../releases) 下载新的 `dsh.exe`，覆盖旧的 `dsh.exe`。
3. 重新运行即可。

- 图标 / 启动器逻辑（互斥锁、端口、更新检查）改动 → 换 exe 立即生效。
- 内嵌 dsh 运行时改动 → 只有 `launcher.cs` 的 `Version` 升版后才会重新解压到新目录；数据始终在 `%USERPROFILE%\.dsh`，更新不丢会话。
- 自 v0.1.0-rc.7 起，启动时会自动提示新版本。

## 数据与文件位置

| 内容 | 位置 |
| --- | --- |
| 解压后的运行时 | `%LOCALAPPDATA%\dsh-exe\<version>\` |
| 会话、配置、凭据 | `%USERPROFILE%\.dsh\` |

可用环境变量 `DSH_EXE_HOME` 覆盖运行时解压根目录（便携模式）。

## 从源码构建

需要：Windows（自带 .NET Framework 编译器 `csc.exe`）、dsh 包、node.exe。

```powershell
# 1. 准备输入
#    dsh.zip  — dsh 包（含 node_modules 与 config 的完整目录压缩，根目录为 dsh\）
#    node.zip — 仅含 node.exe 的压缩包
# 2. 构建（产物为 dsh.exe，默认嵌入 build/app.ico 蓝鲸图标）
.\build\build.ps1 -DshZip .\dsh.zip -NodeZip .\node.zip -Out .\dsh.exe
```

`build.ps1` 用系统自带的 .NET Framework `csc.exe` 编译 `launcher.cs`，
并把两个 zip 作为托管资源嵌入，生成控制台子系统（subsystem 3）的 AnyCPU exe。

## 历史加载失败修复说明（自 v0.1.0-rc.6 起）

**背景**：同时运行两个 dsh 服务器（例如在会话里把打包好的 exe 当作后台任务启动测试，
而主服务器仍在运行）会对同一份会话日志并发追加。旧进程持有过期 seq，会重写一段已提交的
seq 区间，日志被读取端判定为损坏（`corrupt session log: seq gap in committed region`），
表现为打开旧会话时提示"历史加载失败：{message}（{code}）"。

**修复分三层**：

1. **数据修复工具** `build/repair-session-log.mjs`：扫描日志中的 seq 回退段，丢弃被覆盖的
   旧事件、保留权威的后续段并重建连续日志（自动备份原文件）。
   ```text
   node build/repair-session-log.mjs <session.jsonl.zstd>
   ```
2. **读取端自愈**：`dsh-session-persistence-jsonl` 的日志扫描器遇到 seq 回退时自动采用新段，
   不再整份拒绝日志（后续段视为权威续写）。
3. **单实例互斥锁**：`launcher.cs` 在 Web 模式下按数据根目录加命名互斥锁，同一数据目录
   只允许一个服务器实例（端口检查只防同端口重复，互斥锁补齐了跨端口场景）。

## 仓库结构

```text
dsh-portable/
├── README.md
├── LICENSE
├── .github/workflows/
│   └── release-unix.yml       # GitHub Actions：在各平台构建 Linux/macOS tarball
├── build/
│   ├── launcher.cs             # C# 启动器源码（Windows，自解压 + 端口检查 + 单实例互斥锁 + 更新检查）
│   ├── build.ps1               # Windows 构建脚本（csc 编译并嵌入 zip + 图标）
│   ├── launcher.sh             # POSIX 启动器（Linux/macOS：单实例锁 + 更新检查 + 浏览器打开）
│   ├── build-unix.sh           # Linux/macOS 打包脚本（组装 dsh + node + launcher 的 tarball）
│   ├── app.ico                 # 应用图标（DeepSeek 蓝鲸，多尺寸）
│   ├── app-icon.svg            # 蓝鲸图标 SVG 源文件
│   ├── make-ico.ps1            # 由 256px PNG 生成多尺寸 .ico
│   ├── repair-session-log.mjs  # 会话日志修复工具
│   └── strict-validate.mjs     # 日志严格校验工具（用真实解码器验证 seq 连续性）
```

发布产物（`dsh.exe`、`dsh.zip`、`node.zip`）体积大且可再生成，通过 GitHub Release 附件分发，
不进仓库。

## 许可证

- `launcher.cs`：MIT（见 [LICENSE](LICENSE)）
- 内嵌的 `@deepseek-ai/dsh` 运行时：MIT（见 [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)）
- 内嵌的 Node.js：MIT（见 [nodejs/node](https://github.com/nodejs/node)）
