# DUA 自动化处理与提交系统

本项目实现了一套基于 Gitea Actions 和 PowerShell 的全自动化 DUA (Driver Update Acceptable) 处理流程。系统引入了基于 Git 的人工审查机制，将自动化流程分为“准备”与“完成”两个阶段，确保 INF 修改的准确性与可追溯性。

---

## 🏗️ 架构概览 (Architecture)

本系统采用模块化设计，核心逻辑封装在 PowerShell 模块中，并通过 Gitea Workflow 进行调度。

### 核心组件
1.  **Gitea Workflows (`.gitea/workflows/`)**:
    *   **DUA Prepare**: 监听 Issue 创建/编辑事件。负责下载资源、创建 Git 分支、应用修改并生成 Pull Request。
    *   **DUA Finish**: 监听 Pull Request 合并事件。负责恢复驱动环境、打包 HLKX、清理分支并通知用户。
    *   **DUA Submit**: 监听评论 (`/submit`) 事件，负责向微软提交 HLKX 包。
2.  **PowerShell Step Scripts (`scripts/steps/`)**:
    *   `1_ParseConfig.ps1`: 解析配置与路由。
    *   `2_DownloadAssets.ps1`: 下载并缓存驱动资源 (NAS 缓存)。
    *   `3_ProcessDriver.ps1`: (Prepare 阶段) 创建 Git 分支、提取 INF、修改并提交 PR。
    *   `3_RestoreDriver.ps1`: (Finish 阶段) 从缓存恢复驱动，并应用 Git 仓库中的 INF 修改。
    *   `4_UpdateHlkx.ps1` / `5_PackageResults.ps1`: 更新 HLKX 包与结果打包。
3.  **Core Modules (`scripts/modules/`)**:
    *   `InfPatch`: 实现复杂的 INF 文件解析与修改逻辑。
    *   `Gitea`: 封装 Gitea API 操作 (Issue, PR, Comments)。
    *   `PartnerCenter`: 封装 Partner Center API。

---

## ⚙️ 工作原理 (Principles)

本流程采用 **Prepare -> Review -> Finish** 的三段式设计：

### 1. 准备阶段 (Prepare Phase)
*   **触发**: 用户提交 Issue (包含 Product ID 等元数据)。
*   **缓存**: 系统根据 Issue ID 检查 NAS 缓存 (`\\nas\labs\RUNNER\tmp\issue-<ID>`)，如果不存在则从 Partner Center 下载 Driver 和 Shell 并缓存。
*   **Git 分支**:
    *   创建基准分支 `dua/issue-<ID>/base`：仅提交原始 INF 文件。
    *   创建补丁分支 `dua/issue-<ID>/patch`：提交修改后的 INF 文件。
*   **Pull Request**: 自动创建 PR (Patch -> Base)，并指派给 Issue 提交者。

### 2. 审查阶段 (Review Phase)
*   用户收到 PR 通知。
*   在 Gitea 界面查看 INF 的 Diff (仅展示文本文件的修改，便于审查)。
*   确认无误后，点击 **Merge Pull Request**。

### 3. 完成阶段 (Finish Phase)
*   **触发**: PR 被合并。
*   **恢复**: 系统从 NAS 缓存中解压原始驱动，并将 Git 仓库中合并后的 INF 文件覆盖回去。
*   **打包**: 使用 `HlkxTool` 将最终的驱动注入 DUA Shell，生成 `.hlkx` 文件。
*   **清理**: 自动删除临时的 Git 分支 (`base`, `patch`) 和 NAS 缓存目录。
*   **通知**: 在 Issue 评论区发布最终产物链接。

---

## 🚀 使用说明 (Usage)

### 1. 创建请求
1.  进入 Gitea 仓库的 **Issues** 页面，创建一个 **WHQL Request**。
2.  填写 **Project Name**, **Product ID** 等信息并提交。

### 2. 审查代码
1.  等待 Workflow (Prepare) 运行完毕。
2.  你会收到一个被指派的 **Pull Request** 链接。
3.  点击进入 PR，查看 **Files Changed** 标签页，确认 INF 的修改内容是否符合预期。
4.  如果满意，点击 **Merge Pull Request**。

### 3. 获取产物与提交
1.  PR 合并后，系统自动触发 Finish 流程。
2.  完成后，在原 Issue 下方会生成一条评论，包含 `modified.hlkx` 和驱动包的下载链接。
3.  确认无误后，回复 `/submit` 即可触发自动上传至 Microsoft Partner Center。

---

## 📂 目录结构 (Directory Structure)

```text
dua/
├── .gitea/workflows/        # Gitea Actions 定义
│   ├── dua_prepare.yml      # 阶段一：准备与 PR
│   ├── dua_finish.yml       # 阶段二：打包与清理
│   └── dua_submit.yml       # 阶段三：提交
├── config/                  # 配置文件
│   ├── mapping/             # 路由与定位规则
│   └── inf_patch_rules.json # INF 修改规则
├── scripts/
│   ├── steps/               # 原子化步骤脚本 (1-6)
│   ├── modules/             # PowerShell 核心模块
│   └── tools/               # HlkxTool 等工具
└── tests/                   # 单元测试
```

---

## 🔧 配置指南 (Configuration)

### 修改路由规则
修改 `config/mapping/product_routing.json`，配置产品名到处理策略的映射。

### INF 策略配置
修改 `config/inf_patch_rules.json` 来定义针对特定 Project 的 INF 修改规则 (如 DevID 替换逻辑)。

---

## 🛠️ 开发与测试 (Development)

### 运行单元测试
```powershell
Invoke-Pester ./tests/unit/InfPatchAdvanced.Tests.ps1
```

### 缓存机制
开发时请注意，流程依赖 `\\nas\labs\RUNNER\tmp` 路径进行大文件缓存。在本地调试时，脚本会尝试使用该路径，请确保网络通畅或修改 `2_DownloadAssets.ps1` 中的缓存逻辑。
