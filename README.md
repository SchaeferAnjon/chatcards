# Anki Learn

把 Claude Code 会话、PDF、Markdown 和网页做成 Anki 卡片的 Mac 应用（Apple 芯片，macOS 14+，自用）。DeepSeek 读一遍内容，挑出值得长期记住的知识点做成问答卡；你在应用里看过、改好、勾好，再一键送进 Anki。

## 怎么把内容交给它

- **在 Claude Code 里输入 `/anki`**：把当前会话送过来（技能在 `ClaudeSkill/anki/`，已装进 `~/.dispatch/skills/anki` 并对 Claude 打开）。
- **粘贴 claude.ai/code/session_… 链接**（输入框，或菜单「编辑 › 从剪贴板导入链接」⇧⌘V）：会话记录里有一行 `bridgeSessionId = cse_<同一串>`，应用按它在 `~/.claude/projects` 里找到这台 Mac 上的完整记录，不用登录。不在这台 Mac 上的会话在应用里的网页窗口打开（第一次要登录 claude.ai）。
- **首页「最近的 Claude Code 会话」**点一个。`claude -p` 脚本跑的会话（录音整理、designer 复审、起分支名）不列。
- **把 PDF、Markdown、.jsonl 会话记录拖进窗口**；粘贴网址则在网页窗口里打开，点「用这页做卡片」。

## 出卡

- 模型默认 `deepseek-flash` 开思考（设置里可换 `deepseek-v4-pro`、关思考）。实测一段 1.1 万 token 的会话 49 秒、14 张卡。
- 长内容按 12 万字一段切开，最多 3 段同时发；问题一样的卡只留一张。
- 只读对话本身：我说的和 AI 的回答。工具调用、工具结果、思考过程、子 Agent、系统提醒、压缩摘要都去掉。
- 提示词在 `Core/Sources/AnkiLearnCore/CardMaker.swift`：一张卡一个点，问题离开对话也看得懂，答案尽量不超过 40 字，带一句原文出处，不做只对这一次有用的细节。

## 送进 Anki

- 要开着 Anki，装好 AnkiConnect（编号 2055492159）。没开时提示条上有「打开 Anki 再送」。
- 牌组：`Anki Learn::Claude Code`、`Anki Learn::文档`、`Anki Learn::网页`（设置里能改前缀）。笔记类型「Anki Learn 卡片」，五个字段：问题、答案、补充、原文、来源（带回原文的链接），浅色深色都有样式。
- 同一牌组里问题一样的不重复加。已经送进去的卡在应用里标「已在 Anki」；重新生成时留着它们，只换掉还没送的。

## 数据放在哪

- DeepSeek API Key：登录钥匙串（service `com.ankilearn.app`），只发给 api.deepseek.com。
- 做过的材料和卡片：`~/Library/Application Support/Anki Learn/sources.json`。
- 设置：`defaults read com.ankilearn.app`。

## 开发

```bash
make test      # 核心库测试：读会话、切段、解析卡片、DeepSeek 和 AnkiConnect 请求（假服务器）
make install   # 编 Release，装到 /Applications/Anki Learn.app
```

`project.yml`（XcodeGen）是唯一的工程定义，`AnkiLearn.xcodeproj` 不进 git。逻辑都在 `Core/`（Swift 包，能单独 `swift test`），界面在 `App/`（SwiftUI）。签名用 Apple Development（team TEAMID），重新编译后钥匙串里的 Key 照样能读。

测试和调试时用测试模式 `E2E=1`（或启动参数 `-E2E 1`）启动：窗口不出现在屏幕上、不抢焦点、不进 Dock，访达、浏览器、打开 Anki、提示框、弹出菜单都只记一行不真做（`App/TestMode.swift`）；做过的卡片在临时目录（`E2E_DATA_DIR`），Claude 会话从 `E2E_CLAUDE_DIR` 读，AnkiConnect 连 `E2E_ANKI_URL`（都没给就是空的、连不上），偏好用单独的一份，Key 只放在内存里，不碰你的真数据和真 Anki（`Core/.../E2EMode.swift`）。`E2E_SNAPSHOT=<png>` 把主窗口画成图。验证脚本 `bash scripts/e2e-hidden-check.sh`：编 Debug 版、测试模式下启动，1、5、10 秒查屏幕上没有它的窗口，查截图，把会占屏幕的事各试一遍。
