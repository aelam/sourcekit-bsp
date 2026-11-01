# 构建进度

当前实现、通知示例和查看方式见 [构建进度与输出](TaskProgress-Usage-Example.md)。

实现入口为 `BSPTaskManager.executeTask`。构建输出经 `BuildOutputReporter` 解析和批量发送，
取消或失败时也会刷新剩余输出并发送 `taskFinish`。
