# 构建进度与输出

编译、测试和索引准备使用标准 BSP 通知。Xcode 专用解析留在服务端；客户端只展示协议消息。

| 通知 | 内容 |
| --- | --- |
| `build/taskStart` | 开始任务 |
| `build/taskProgress` | 当前阶段和已观察到的构建步骤数 |
| `build/taskFinish` | 成功 `1`、失败 `2`、取消 `3` |
| `build/logMessage` | 易读构建输出；错误、警告和普通输出分别标记级别 |
| `build/publishDiagnostics` | 按文件和 target 发布诊断，位置使用从零开始的 UTF-16 坐标 |

`taskId` 使用 `{ "id": "..." }`，`eventTime` 使用 Unix 毫秒时间戳。
没有可靠总量时省略 `total`，客户端显示阶段，不计算百分比。

```json
{
  "jsonrpc": "2.0",
  "method": "build/taskProgress",
  "params": {
    "taskId": { "id": "sourcekit-bsp-task" },
    "originId": "compile-request",
    "eventTime": 1793538000000,
    "message": "Compile Swift — Hello",
    "progress": 4,
    "unit": "build steps"
  }
}
```

输出按约 100 毫秒批量发送，剩余日志和诊断在 `taskFinish` 前刷新。
原始日志保存在项目 DerivedData 的 `Logs/sourcekit-bsp/*.log`，输出中会给出路径。
日志保存在 server 所在机器上；远程客户端需要通过该机器访问。
若文件写入失败，则通过 `build/logMessage` 发送未简化的输出。

编译诊断由文本输出解析。无法确定所属 target 的诊断仍保留在输出中，避免误归属。
重新构建会清理相关 target 的旧诊断；客户端必须按文件和 target 处理 `reset`。

在 vscode-bsp 中，进度在右下角通知，诊断在 Problems，日志在输出面板的 `vscode-bsp-log`。
使用 `Scripts/bsp_client.py --verbose` 可查看原始通知 JSON。
