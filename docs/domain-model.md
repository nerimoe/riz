# Riz 项目、文件夹与会话模型

状态：已确定（v2，2026-07-28）。这是数据库、协议、daemon、provider adapter 和
Flutter UI 的规范依据。实现不得重新引入“主文件夹”、隐藏的临时项目或 provider
定义的项目层级。

## 1. 用户领域模型

```text
Daemon
├── Project 0..N
│   ├── Folder 0..N（全部平级）
│   └── Session 0..N
└── Session 0..N（未加入项目，即快速聊天历史）
```

- **Project** 是用户命名的会话分组，同时保存一组可访问的真实文件夹。
- **Folder** 是目标电脑上的 canonical absolute path。同一项目内所有 folder 平级。
- **Session** 是一段 agent 对话，可以属于一个项目，也可以不属于项目。
- **Quick chat** 是 `project_id = NULL` 的普通 session，不是特殊项目或会话类型。
- provider 自己的 project、workspace 和 conversation ID 只属于 adapter 私有状态。

## 2. 不变量

1. `Session.project_id` 可为空；一个 session 最多属于一个 project。
2. 一个 project 可以绑定零个或多个 folder；不存在 primary/secondary folder。
3. folder 的顺序仅用于展示，不改变 cwd、权限、provider binding 或项目身份。
4. 同一 canonical folder 可绑定多个 project；同一 project 内不得重复绑定。
5. 每个 project 拥有稳定的 Riz runtime；每个 session 也拥有自己的受管目录。
6. 项目 session 的 CLI cwd 永远是 project runtime；未加入项目的 session 使用自己的
   session runtime。添加、移除和排序 folder 都不改变 cwd。
7. 项目的全部 folder 每轮都作为平级 additional directories 交给 provider。
8. 删除或移除 project/folder 永远不删除用户的真实文件夹。
9. 新会话在第一条消息提交前只存在于客户端草稿状态，不出现在 daemon session 列表。
10. Riz 永远不调用 provider 自带的快速会话目录分配流程，不允许 agy 创建或接管
    `~/.gemini/antigravity/playground/*`。

## 3. 受管目录

```text
~/.riz/
├── projects/<project-id>/
│   └── runtime/
│       └── AGENTS.md
└── sessions/<session-id>/
    ├── runtime/
    │   └── AGENTS.md
    ├── attachments/
    └── artifacts/
```

Project runtime 是项目内所有 session 共享的稳定 CLI 技术锚点。它不是用户绑定的
folder，也不在 UI 中伪装成一个项目文件夹。Session runtime 仅在 session 未加入项目时
作为 CLI cwd；attachments 和 artifacts 始终归 session 所有。

Riz 完全管理 runtime 中的 `AGENTS.md`，内容固定且不维护 folder 列表：

```markdown
# Riz Runtime Directory

This directory is managed by Riz for runtime files, temporary files, and generated artifacts.

It is not an existing user project or source repository.
```

folder 的可见性和权限由 provider 参数提供，不能依赖 `AGENTS.md`。

## 4. 执行上下文

每轮开始时计算并保存不可变快照：

```text
project session:
  cwd = ~/.riz/projects/<project-id>/runtime
  additional_directories = project.folders（全部）

unbound session / quick chat:
  cwd = ~/.riz/sessions/<session-id>/runtime
  additional_directories = []
```

Files 和 Terminal 的默认根目录与 cwd 相同。项目 Files 还应提供所有绑定 folder 的入口；
项目 Skills 来自全部 folder 的 `.agents/skills`，不能暗中选择某个“主”目录。

## 5. 名称

- Project 可设置自定义名称。
- 未设置名称且有 folder 时，默认显示最早添加 folder 的 basename。
- 未设置名称且没有 folder 时显示“未命名项目”。
- Session 初始显示“新会话”；首条消息提交后可由消息生成标题。
- Quick chat 在侧边栏直接显示 session 标题，不显示虚构的项目名称。

名称只影响展示，不参与路径或 provider binding 计算。

## 6. 创建与首条消息

### 项目

创建 project 时立即创建 project runtime 和固定 `AGENTS.md`。用户可以绑定零个或多个
folder；创建项目不会创建 session 或启动 CLI。

### 项目会话

点击“新会话”只打开客户端草稿。用户可先选择模型、权限并附加图片。首条消息提交时，
daemon 原子创建 session、用户消息和 turn；失败不得留下空 session。

### 快速聊天

点击“快速聊天”打开 `project_id = NULL` 的客户端草稿。首条消息提交时创建 session
目录及其 runtime，之后直接出现在快速聊天历史中。Riz 不创建隐藏 project。

## 7. 会话移动与 provider conversation

允许未加入项目、项目 A 和项目 B 之间移动 session。进行中的 turn 不允许移动。

- 移动不删除消息、附件、产物或旧 provider conversation ID。
- 下一轮使用新归属计算 execution context。
- 如果 provider 不能让原 conversation 安全切换 workspace，adapter 创建 continuation，
  将旧 binding 标记为 superseded 并保留 lineage 和原因。
- 每个 turn 保存 `cwd_snapshot` 与 `additional_directories_snapshot`，历史不随移动修改。

## 8. Folder 变更

- 添加、移除和排序只影响之后的 turn；运行中的 turn 使用已保存快照。
- folder 变化不改变 project runtime、agy project binding 或 conversation lineage。
- 移除最后一个 folder 后项目仍然有效，CLI 继续在同一个 project runtime 中运行。
- UI 不提供“设为主文件夹”。

## 9. 删除语义

- 移除 folder：只解除绑定。
- 删除 session：停止活动任务，删除 session 数据和 `~/.riz/sessions/<id>`；不删除任何
  project folder 或 project runtime。
- 删除 project 前必须选择：
  - `detach_sessions`：session 变为未加入项目，下一轮使用各自 session runtime。
  - `delete_sessions`：同时删除项目内 sessions 的受管数据。
- 两种模式都只删除 project runtime，绝不删除绑定的真实 folder。

## 10. Provider adapter 边界

所有 provider 共用相同产品行为。adapter 接收：

```text
session_id
provider_conversation_id?
provider_workspace_binding?
cwd
additional_directories[]
prompt
attachments[]
model?
permission_mode
```

provider 不得反向定义 Riz 的 Project/Folder/Session 结构。

### agy

- 项目 session：进程 cwd 为 project runtime；每个绑定 folder 都重复传入
  `--add-dir <path>`。
- 快速聊天：cwd 为 session runtime，不传 `--add-dir`。
- 首次使用 execution root 时传 `--new-project`，之后恢复持久化的
  `--project <agy-project-id>`；conversation 使用 `--conversation <id>`。
- agy project binding 以稳定 execution root 为作用域：项目 session 按 Riz project
  共享，未加入项目 session 按 session 独立。
- adapter 在新建后验证 agy project workspace URI 等于预期 runtime，并检测新增
  playground；不一致即兼容性失败。
- agy 能从 CLI 参数看到 additional directories，`AGENTS.md` 不重复列出它们。

## 11. 协议基线

```text
project.create(name?, folders[])
project.rename(projectId, name?)
project.folder.add(projectId, path)
project.folder.remove(projectId, folderId)
project.folder.reorder(projectId, folderIds)
project.remove(projectId, mode: detach_sessions | delete_sessions)

session.start(projectId?, provider, permissionMode, content)
session.move(sessionId, projectId?)
session.delete(sessionId)
session.executionContext(sessionId)
```

`projectId: null` 明确表示未加入项目。协议不使用 `temporary`、`primaryPath`、
`isPrimary` 或 provider project ID 表达产品状态。

## 12. 持久化基线

```text
projects:
  id, custom_name, runtime_path, created_at, updated_at

project_folders:
  id, project_id, path, position, created_at

sessions:
  id, project_id?, provider, workspace_path, title, status,
  permission_mode, archived_at?, created_at, updated_at

session_provider_conversations:
  id, session_id, provider, external_id, provider_workspace_id?,
  cwd_snapshot, additional_directories_snapshot, status,
  created_at, ended_at?, end_reason?

turns:
  id, session_id, message_id, status, cwd_snapshot,
  additional_directories_snapshot, created_at, updated_at
```

项目尚未发布，因此本轮 schema 可直接重建，不要求兼容旧开发数据库。但从该模型开始，
任何后续 schema 变更都必须有明确版本或重置策略，不能静默混用两个模型。
