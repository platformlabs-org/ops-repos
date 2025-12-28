# WHQL 仓库

本仓库包含用于自动化 WHQL 测试和签名的工具与脚本。主要通过 Gitea Actions 响应 Issue 事件来执行。

## 目录结构

```
whql/
├── .gitea/
│   ├── workflows/         # Gitea Actions 工作流定义
│   └── ISSUE_TEMPLATE/    # Issue 模板
├── config/                # 配置文件
│   └── config.json        # 项目映射与全局配置
├── HlkxTool/              # HlkxTool 工具 (需自行放入 exe)
├── scripts/               # PowerShell 脚本
│   ├── modules/           # 公共模块 (OpsApi, WhqlCommon, Config)
│   ├── PrepareHlkJob.ps1  # 准备阶段：解析 Issue，下载附件，校验输入
│   ├── RunHlkJob.ps1      # 执行阶段：调用 HlkxTool 生成包
│   ├── PublishHlkResult.ps1 # 发布阶段：回传 HLKX 并更新标题
│   └── SubmitHlkJob.ps1   # 提交阶段：响应 /submit 指令
└── Readme.md              # 本文档
```

## 架构概览

整个流程由单一的工作流 `process_request.yml` 驱动，根据 Issue 模板中的选择自动分发任务。

1.  **Workflows**: Gitea 监听到 Issue 事件（创建或重新打开）后触发。
2.  **Scripts**: YAML 调用 `scripts/` 下的 PowerShell 脚本。
3.  **Modules**: 脚本调用 `scripts/modules/` 下的公共模块，实现配置读取、API 调用重试、工具封装等。
4.  **HlkxTool**: 核心逻辑（打包、签名、提交）由 `HlkxTool.exe` 完成。

## 使用指南

### 1. 触发请求
用户在 Gitea 创建 Issue，选择 `General WHQL/Sign Request` 模板。

#### 场景 A: 驱动 WHQL 打包 (Driver WHQL Build)
1.  **Driver Project**: 选择具体的项目名称 (例如 "Lenovo Dispatcher")。
2.  **Architecture**: 选择架构 (AMD64 或 ARM64)。
3.  **Driver Version**: 输入版本号。
4.  **附件**: 创建 Issue 后，**必须**上传一个 `.zip` 格式的驱动包。
5.  **流程**: 系统会自动寻找对应的 HLK 模板，注入驱动，签名并生成 HLKX。

#### 场景 B: 仅签名 (HLKX Sign Only)
1.  **Driver Project**: 选择 `HLKX Sign Request`。
2.  **附件**: 创建 Issue 后，**必须**上传一个 `.hlkx` 文件。
3.  **流程**: 系统会直接对上传的 HLKX 进行签名。

### 2. 触发提交 (Submit)
当测试完成并生成 HLKX 包后（通常由 Bot 回传到 Issue 评论区），用户可以在 Issue 评论中输入：
```
/submit
```
系统会自动抓取最新的 Bot 生成的 HLKX 包并提交到微软。

## 开发指南

### 配置修改
如果需要新增 Driver 项目或修改架构映射，请编辑 `whql/config/config.json`：
```json
{
    "DriverProjectMap": {
        "NewProjectName": "MappedNameInHlkxTemplate"
    },
    "SignRequestOption": "HLKX Sign Request"
}
```

### 脚本开发
所有脚本均依赖 `whql/scripts/modules`。
*   **Config.psm1**: `Get-WhqlConfig` 获取配置。
*   **OpsApi.psm1**: 封装与 Gitea/Ops 平台的交互，包含自动重试机制。
*   **WhqlCommon.psm1**: 通用工具函数（如 `Get-SafeFileName`, `Get-HlkxToolPath` 等）。

### 环境变量
*   `HLKX_TOOL_PATH`: 可选，指定 `HlkxTool.exe` 的绝对路径。若未设置，脚本会自动在 `../HlkxTool/` 寻找。

### 本地测试
可以在 PowerShell 中加载模块进行单元测试：
```powershell
Import-Module ./whql/scripts/modules/Config.psm1
$cfg = Get-WhqlConfig
Write-Host $cfg.BaseUrl
```
