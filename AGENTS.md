# Agent 工作规范

本文件约定在 `tern-project-tabs` 仓库中进行开发、发版和本地验证时的默认行为。

## 配置项

| 配置项 | 当前值 | 说明 |
| --- | --- | --- |
| `apply_to_local_tern` | `true` | 每次修改插件代码或样式后，是否自动应用到本机 Tern（默认 `true`） |

- 当 `apply_to_local_tern` 为 `true` 时：每次完成插件功能、逻辑或样式修改后，必须在仓库根目录执行 `tern plugin install . --force` 应用到本机 Tern，并运行 `tern plugin list --json` 确认 `project-tabs` 的版本号已更新且状态为 `ready`、`problems` 为空。
- 当 `apply_to_local_tern` 为 `false` 时：仅修改仓库内文件（如需测试则在独立隔离的 `TERN_CONFIG_DIR` 中验证），不改动本机默认 Tern 配置目录下的插件。
- 若本次修改仅涉及文档或仓库元信息（如 `AGENTS.md`、`README.md`、`MAINTAINING.md`），无需触发本机重装。

## 版本号递增规则

插件版本号以 `plugin.toml` 中的 `version` 字段为唯一真源，采用 `MAJOR.MINOR.PATCH` 三段式：

- **小改**（Bug 修复、样式细节微调、文案或局部交互优化）：最后一位加 1，例如 `1.7.0` → `1.7.1` → `1.7.2`。
- **大改**（新增核心功能、较大规模的 UI/交互重构、数据或架构变更）：中间一位加 1 并将最后一位归零，例如 `1.7.x` → `1.8.0` → `1.9.0`。
- 同一轮任务内围绕同一需求反复微调时，在该轮最终定稿时递增一次版本号即可；只要产生了新的插件代码或样式改动，交付前必须同步更新 `plugin.toml` 的 `version`。
- 仅修改 `AGENTS.md` 等开发文档、未改动插件运行文件时，不递增版本号。

## 开发与验证约定

- **样式与主题**：`sidebar.css` 必须同时适配暗色与浅色主题，优先使用 Tern 主题变量（如 `--card`、`--hover`、`--l1`、`--l2`、`--accent`、`--ansi2`、`--ansi3`、`--warn`），避免硬编码深色/浅色固定背景色；同时保持 `@media (prefers-reduced-motion: reduce)` 与 `.sf-still` 兼容。
- **核心模块职责**：
  - `window.luau`：侧栏挂载、窗口状态恢复、标签与项目操作
  - `projects.luau`：路径规范化、项目分组与重名区分
  - `activity.luau` / `indicators.luau`：运行中、后台完成与等待输入状态指示
  - `history.luau` / `archive.luau` / `history-io.ps1` / `history-io.sh`：OMP 历史浮层、缓存索引与跨窗口归档
  - `sidebar.css`：侧栏布局、悬停操作栏、历史卡片与指示徽章样式
- **视觉与回归检查**：涉及 UI 修改时，优先在隔离配置下用 `tern shot --theme both` 核对暗色/浅色主题的渲染效果；发版前参考 `MAINTAINING.md` 完成完整回归清单与打包检查。
