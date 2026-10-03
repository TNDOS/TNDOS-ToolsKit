# 贡献者 / Contributors

## 项目作者 / Author

**Tanzizhao** —— 方向、取舍、决策、真机验证、构建与发布。

## AI 辅助 / AI assistance

| | |
|---|---|
| 工具 | DeepSeek Harness（`deepseek-v4-flash` / `deepseek-flash`） |
| 参与范围 | 架构讨论、设计与取舍、内核与工具链代码、文档、调试 |
| 人的角色 | 定方向、做决定、在真机上验证、构建与发布 |

**AI 没有任何仓库的写权限。所有提交都是人推上来的。**

### 提交署名

提交带一条 trailer：

```
Co-authored-by: DeepSeek <noreply@deepseek.com>
```

这和 Claude Code 用的 `Co-authored-by: Claude <noreply@anthropic.com>` 是同一个做法。
**它只是提交信息里的一行文本** —— 不需要账号、不需要权限、不需要谁批准，
任何工具都能加。GitHub 会把它算进贡献者列表，名字会出现在提交页面和贡献者墙上。

### 关于头像

GitHub 按「邮箱 → 账号」解析头像。`noreply@deepseek.com` 没有对应的 GitHub 账号时，
显示的是默认头像。

想要一个明确标识（比如蓝鲸），唯一的可靠办法是**建一个专用机器人账号**、
用它做 trailer —— 就像 `dependabot[bot]` 和 `github-actions[bot]` 那样。
那是锦上添花，不是署名能不能生效的前提。

### 为什么写这份文件

因为含糊的署名比没有署名更糟。写清楚谁做了什么、用什么做的，
比造一个看起来很正式但经不起追问的贡献记录有价值得多。

### 这个项目的原则

> 保留 DOS 的交互模型，丢掉 DOS 的内存模型。

同样的态度用在这里：**保留诚实，丢掉好看。**
