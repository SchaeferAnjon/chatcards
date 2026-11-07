---
name: anki
description: 把当前这个 Claude Code 会话送进 Anki Learn，做成 Anki 卡片。用户输入 /anki，或说「把这次会话做成卡片」「这次聊的送进 Anki」时用。
---

# 把这个会话送进 Anki Learn

运行下面这条命令，别的都不用做：

```bash
open "ankilearn://session/${CLAUDE_SESSION_ID}"
```

然后回一句：「已送进 Anki Learn，卡片做好后在那边勾选、送进 Anki。」

- 不要自己总结对话、不要自己写卡片：读会话、挑知识点、出卡都由 Anki Learn 做。
- 命令说找不到能打开 ankilearn 链接的应用：告诉用户先装 Anki Learn（在 anki-learn 项目里跑 `make install`）。
