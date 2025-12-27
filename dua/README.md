# DUA 自动化处理与提交系统

本项目实现了一套基于 Gitea Actions 和 PowerShell 的全自动化 DUA (Driver Update Acceptable) 处理流程。用户只需通过 Issue 表单提交元数据，系统即可自动完成驱动下载、INF 修改、封装打包以及最终的 Partner Center 提交。

---

## 🏗️ 架构概览 (Architecture)

本系统采用模块化设计，核心逻辑封装在 PowerShell 模块中，并通过 Gitea Workflow 进行调度。

### 核心组件
1.  **Gitea Workflows (`.gitea/workflows/`)**:
    *   **WHQL Prepare**: 监听 Issue 创建/编辑事件，负责驱动处理流程。
    *   **WHQL Submit**: 监听评论 (`/submit`) 事件，负责向微软提交 HLKX 包。
2.  **PowerShell Entrypoints (`scripts/entrypoints/`)**:
    *   `Prepare.ps1`: 预处理入口，执行下载、Patch、打包逻辑。
    *   `Submit.ps1`: 提交入口，执行 HlkxTool 上传逻辑。
3.  **Core Modules (`scripts/modules/`)**:
    *   `PartnerCenter`: 封装 Partner Center API (下载/元数据)。
    *   `InfPatch`: 实现复杂的 INF 文件解析与修改逻辑 (端口自 Python 脚本)。
    *   `DuaShell`: 处理 DUA Shell (.hlkx) 文件的解包与驱动替换。
    *   `DriverPipeline`: 根据产品名称路由到不同的处理策略。
4.  **Configuration (`config/`)**:
    *   `product_routing.json`: 定义产品名到 pipeline 的映射。
    *   `inf_patch_rules.json`: 定义 INF 修改的高级规则 (DevID/SubsysID 映射)。
    *   `mapping/inf_locator.json`: 定义如何查找特定驱动的 INF 文件。

---

## ⚙️ 工作原理 (Principles)

### 1. 预处理阶段 (Prepare Phase)
*   **触发**: 用户提交包含 Project Name, Product ID, Submission ID 的 Issue。
*   **路由**: 系统根据 `Project Name` (如 "chogori") 在 `product_routing.json` 中查找对应的 Pipeline (如 `graphic-ext`)。
*   **下载**: 使用 Submission ID 调用 Partner Center API 下载原厂 Driver 和 DUA Shell。
*   **处理**:
    *   解压驱动，定位 INF 文件。
    *   加载 `inf_patch_rules.json` 中的规则。
    *   执行 `InfPatch` 模块，根据规则修改 ExtensionId, SubsysID, 注入 AddReg 等。
*   **打包**:
    *   调用 `HlkxTool` 将修改后的驱动替换进 DUA Shell。
    *   生成新的 Driver Zip 和 HLKX 文件。
*   **反馈**: 将生成的产物以附件形式上传至 Issue 评论区。

### 2. 提交阶段 (Submit Phase)
*   **触发**: 用户在 Issue 评论区回复 `/submit`。
*   **定位**: 系统自动扫描评论区，找到**最新**的 `.hlkx` 附件。
*   **提交**: 调用 `HlkxTool submit` 接口，结合 Issue 中的 Product ID 和 Submission ID，将 HLKX 上传至 Microsoft Partner Center。
*   **完成**: 评论通知用户提交结果。

---

## 📂 目录结构 (Directory Structure)

```text
dua/
├── .gitea/workflows/        # CI/CD 工作流定义
│   ├── whql_prepare.yml
│   └── whql_submit.yml
├── config/                  # 配置文件
│   ├── mapping/
│   │   ├── product_routing.json  # 产品路由规则
│   │   └── inf_locator.json      # INF 查找策略
│   └── inf_patch_rules.json      # INF 修改规则 (原 config.json)
├── scripts/
│   ├── entrypoints/         # 流程入口脚本
│   ├── modules/             # 功能模块 (PSM1)
│   ├── pipelines/           # 流程定义 (Pipeline JSON)
│   └── tools/               # 外部工具 (HlkxTool)
└── tests/                   # 单元测试与 Mock
```

---

## 🚀 使用说明 (Usage)

### 1. 创建请求
1.  进入 Gitea 仓库的 **Issues** 页面。
2.  点击 **New Issue** 并选择 **WHQL Request** 模板。
3.  填写表单：
    *   **Project Name**: 项目代号 (如 `chogori`, `kailash`)，用于匹配处理规则。
    *   **Product ID**: Partner Center 上的产品 ID。
    *   **Submission ID**: 原始提交的 ID (用于下载 Driver/Shell)。
4.  提交 Issue。
5.  等待 Workflow 自动运行，完成后会在评论区生成修改后的 Driver Zip 和 HLKX 文件。

### 2. 检查结果
*   下载评论区附件中的 `modified_driver.zip` 检查 INF 修改是否符合预期。
*   如有问题，修改 `inf_patch_rules.json` 并重新编辑 Issue Body 触发重跑。

### 3. 提交到微软
*   确认 HLKX 无误后，在 Issue 评论区输入：
    ```text
    /submit
    ```
*   Workflow 将自动捕获最新的 HLKX 并上传。

---

## 🔧 配置指南 (Configuration)

### 添加新项目
修改 `config/inf_patch_rules.json`，在 `project` 节点下增加新项目配置：

```json
"new_project": {
  "gfx": {
    "base": {
      "dev_id": ["9A49"],
      "subsys_id": ["12345678"]
    }
  }
}
```

### 修改路由规则
修改 `config/mapping/product_routing.json`，通过正则匹配 Project Name：

```json
{
  "pattern": ".*NewProject.*",
  "pipeline": "graphic-base"
}
```

---

## 🛠️ 开发与测试 (Development)

### 运行单元测试
项目包含 Pester 单元测试，位于 `tests/unit/`。

```powershell
# 在 dua 目录下运行
Invoke-Pester ./tests/unit/InfPatchAdvanced.Tests.ps1
Invoke-Pester ./tests/unit/PartnerCenter.Tests.ps1
```

### Mock 模式
目前的 `PartnerCenter.psm1` 包含 Mock 逻辑。在未配置真实 API 凭据时，它会生成 Dummy 文件以供测试流程通畅性。如需生产使用，请确保相关环境变量 (`PARTNER_CENTER_CLIENT_ID` 等) 已正确配置，并启用真实 API 代码。
