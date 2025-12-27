# ✨ 如何创建 DUA 工单

请按照以下步骤准备并提交您的 **DUA 工单**：

---

## 1️⃣ 进入 Microsoft Partner Center

访问 👉 [**Microsoft Partner Center**](https://partner.microsoft.com/en-us/dashboard/hardware?newSearch=false)

---

## 2️⃣ 搜索 DUA Shell

- 在搜索框中输入关键词：
  - 驱动版本号，如 **`6733`**
  - 或关键词，如 **`Intel`**、**`Graphic`**
- 示例界面：

![图片1](https://ops.platformlabs.lenovo.com/PE/DUA/raw/main/assets/image1.png)

---

## 3️⃣ 下载并重命名 DUA Shell

- 选择对应版本的 **Download DUA Shell**。
- 下载后，请**重命名**文件为：
  - **`6733-base.hlkx`**
  - **`6733-ext.hlkx`**

示例界面：

![图片2](https://ops.platformlabs.lenovo.com/PE/DUA/raw/main/assets/image2.png)

---

## 4️⃣ 准备 Driver 文件夹结构

- 将客制化后的 Driver 文件分别放置到：
  - 文件夹 **`6733-base`**（对应 **`6733-base.hlkx`**）
  - 文件夹 **`6733-ext`**（对应 **`6733-ext.hlkx`**）

- 文件夹结构示例：

![图片3](https://ops.platformlabs.lenovo.com/PE/DUA/raw/main/assets/image3.png)

---

## 5️⃣ 打包 ZIP 文件

- 将以上 **`6733` 文件夹整体压缩**成一个 `.zip` 包。

示例界面：

![图片4](https://ops.platformlabs.lenovo.com/PE/DUA/raw/main/assets/image4.png)

---

## 6️⃣ 创建 DUA 工单并上传

- 进入 👉 [**DevOps 工单系统**](https://ops.platformlabs.lenovo.com/PE/DUA/issues)
- 创建新的 DUA 工单，**上传刚刚打包的 `.zip` 文件**。

示例界面：

![图片5](https://ops.platformlabs.lenovo.com/PE/DUA/raw/main/assets/image5.png)

- **请确保上传进度条走完，出现对勾图标后再提交**❗

示例界面：

![图片6](https://ops.platformlabs.lenovo.com/PE/DUA/raw/main/assets/image6.png)

---

# 📢 注意事项（必读）

- **`*.hlkx` 文件名**与**对应 Driver 文件夹名**必须**完全一致**。
- 每个 Driver 文件夹中必须包含至少一个 **`.inf`** 文件。
- **压缩包结构必须清晰正确**，否则将导致 **DUA 流程失败**❗
- **上传的 `.zip` 包大小**请合理控制，避免上传失败。

---

# 📦 额外操作：手动上传 repackaged HLKX 文件至微软PartnerCenter

完成 DUA 工单处理并重新打包后，请务必：

1. **手动下载生成的 _repackaged.hlkx 文件**（base 和 ext各一份）
2. **登录 Microsoft Partner Center**：
   
   👉 [**Microsoft Partner Center Upload New**](https://partner.microsoft.com/en-us/dashboard/hardware)

3. 点击 **"Upload New"**：

![图片7](https://ops.platformlabs.lenovo.com/PE/DUA/raw/main/assets/image7.png)

4. **修改 Submission Name**：
   - 加上项目名称，如：`6733-ProjectName`

5. **上传对应的 _repackaged.hlkx 文件**：
   - `6733-base_repackaged.hlkx`
   - `6733-ext_repackaged.hlkx`

示例界面：

![图片8](https://ops.platformlabs.lenovo.com/PE/DUA/raw/main/assets/image8.png)

---
