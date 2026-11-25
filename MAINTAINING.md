# 维护与发布

本仓库的根目录就是可安装的 Tern 插件。插件 ID 是 `project-tabs`，版本号在 `plugin.toml`。源码直接由 Tern 加载。

## 从哪里开始

| 文件 | 职责 |
| --- | --- |
| `window.luau` | 侧栏挂载、窗口恢复、标签操作和 Tern 事件 |
| `projects.luau` | 目录规范化、项目归组和重名区分 |
| `activity.luau`、`indicators.luau` | 运行状态、后台完成标记和等待确认提示 |
| `history.luau` | 两种历史视图、分页、多选、恢复和归档操作 |
| `history-io.ps1`、`history-io.sh` | Windows 与 POSIX 的历史读取和归档批次写入 |
| `archive.luau` | 按会话标识持久化隐藏记录，合并多个窗口的变更 |
| `sidebar.css` | 侧栏宽度、标题换行、悬停菜单和状态样式 |

要在测试用 Tern 中加载本地修改，从仓库根目录运行 `tern plugin install . --force`。用 `tern plugin list --json` 检查 `project-tabs` 的版本和 `ready` 状态。

## 回归验证

1. 在独立的测试配置里启动 Tern。给测试进程单独设置 `TERN_CONFIG_DIR`、`TERN_DAEMON_SOCKET` 和 `PI_CODING_AGENT_DIR`，并为测试用户设置独立的主目录。用两个不同的启动目录生成同标题的 OMP 对话。
2. 展开和隐藏项目栏，切换项目和会话。执行托盘菜单的 **Stop Sessions and Quit**，重新启动后在原标签和另一会话之间来回切换，每次应只看到一个项目栏。
3. 在项目的「⋯」中新建对话，检查启动目录。重命名标签，确认标题覆盖整行，移入后出现操作菜单。检查后台完成的黄点在首次查看时清除，折叠项目显示未读数。
4. 打开一条历史记录两次，第二次应回到原标签。用普通「关闭标签」关闭后，记录仍可从历史恢复。
5. 选「关闭并移出历史」后，核对「按项目」「按时间」都隐藏对应记录。用有两个 OMP 分屏的标签重复验证。若取消 Tern 自己的关闭提示，标签保持打开，历史移出保持生效。
6. 分别验证单条移除、跨页多选、清理一个项目和清空全部。核对同名项目的剩余记录、分页和数量，重启后再次检查。清理完成后新建的对话应能正常出现，先前的 OMP 原始记录仍可在测试数据目录找到。
7. 在测试历史目录放入数百条会话，包含首条提示靠后、首轮很长和只有头部的记录。记录打开卡片前的标签位置，展开项目、翻页、滚动并收起卡片后再次核对。在上下分屏和减少动态效果下重复。再次打开卡片时应先看到缓存，新增或修改的记录应在刷新后出现，已删除或归档的记录应消失。

## 发布安装包

运行上述验证后，提交新版本的源码和 `plugin.toml`，在该提交创建同版本标签，例如 `v1.7.0`。在 PowerShell 中用对应标签打包。

```powershell
$tag = 'v1.7.0'
New-Item -ItemType Directory -Path dist -Force | Out-Null
git archive --format=zip -o dist/project-tabs.zip $tag
tar -tf dist/project-tabs.zip
```

检查 ZIP 根目录含有 `plugin.toml`、全部 Luau 模块、两个历史读写脚本、CSS、README 和许可证。把分支和标签推送到 GitHub，然后创建对应的 Release 并附上 `project-tabs.zip`。在测试用的 Tern 配置中从解压目录安装，核对显示的版本。
