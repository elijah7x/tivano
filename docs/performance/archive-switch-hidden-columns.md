# 归档后切到邻居会话：隐藏列的显示代价（11-17，preview.43）

## 症状

preview.28 把归档本身压到了 ~15 ms，但归档后自动选中邻居会话时仍“顿一下”。本轮只测这一段：按键到行开始消失为阶段 A，选中邻居到主线程空闲为阶段 B。

## 测量方法

- 本机隔离实例（`--website-captures` 独立存储与 defaults，不碰 Keychain），200 会话合成库，⇧⌘⌫ 每轮 12 次，修复前后交替 A/B。
- 读 `SwitchLatency`（subsystem `dev.tivano.Tivano`，category `switch`）的 `archive steps`、`column …: cached/recycled/made`、`switch to …: blocked N ms, busy M ms in 1 s`。
- 用 `sample` 抓阶段 B 的主线程调用树定位热点，再逐项消融。
- 脚本、合成库与原始日志：`private-artifacts/archive-latency-thor-1117`（`ab-local.sh`、`make_library.py`、`fulltree.py`、`local-runs/`）。

## 根因

1. **预建列刚建好就被裁掉。** `ThreadColumns.prebuild` 满员时把新列插进 `order` 后从队首裁剪，队首正是刚插入的列。邻居会话因此几乎总是走 recycled/made 而不是 cached（命中 2/12）。
2. **显隐翻转让整列失效。** `chatColumnIsShown` 是环境值，列从隐藏变为显示时整棵子树的 body 都重新求值，ChatView、ThreadTimeline、ComposerView 这类大视图首当其冲。单独去掉这一项：195 → 42 ms。
3. **预建早于历史加载。** 预建在 `isLoadingHistory` 期间就建列，历史到达后列在后台又整体重排，显示时还要再来一次。
4. **从未显示过的列也会标记“显示时整栈重测”。** 后台首次布局稳定后宽度记录路径会设 `needsRemeasure`，显示时触发整栈重建。

`.disabled(!isShown)` 与 `.allowsHitTesting(isShown)` 也随显隐翻转，但单独去掉几乎无变化；`FrameHostingView` 本身已拒绝隐藏列的点击、第一响应者与快捷键，所以一并去掉。`WindowLiveResize` 的 `isLayoutActive` 保留（单独去掉也无明显变化，剩余约 28 ms 可能与它有关，未做）。

## 改动

- `RootView.ThreadColumns.prebuild`：满员时先腾出最旧的、非当前且非本次预建目标的列，再插入。
- `ThreadColumns.updateNSView`：已归档或已无运行时的会话的列先释放名额。
- 预建任务等 `isLoadingHistory` 结束再建列。
- 新增 `Tivano/UI/Common/ChatColumnVisibility.swift`：每列一个稳定的 `@Observable` 对象经环境下发，翻转只让读取 `isShown` 的视图重新求值；大视图 body 不再读显隐，读取下沉到小的修饰器或子视图。
- `ThreadTimeline`：`hasBeenShown` 之前的后台布局不标记 `needsRemeasure`。
- 顺带：`LinkParagraphView.invalidateMeasuredText` 改为排队失效固有尺寸，避免在布局过程中失效导致文本未绘制（用户报告的“空白气泡”的可能原因，未复现确认）；侧栏 `activityGroups` 按天缓存分组标题。

## 结果（本机，200 会话库，每组 12 次）

| 指标 | 修复前 | 修复后 |
| --- | --- | --- |
| 阶段 B 主线程阻塞（中位） | 182–234 ms | 49 ms |
| 阶段 B 之后 1 s 忙碌 | ~300 ms | ~103 ms |
| 命中预建列 | 2/12 | 12/12 |
| 阶段 A（按键到行开始消失） | ~18 ms | ~14 ms |

消融（单项关闭）：环境值翻转 195 → 42 ms；`.disabled` 或 `WindowLiveResize` 单独关闭几乎无变化；三项同时 14 ms（仅作上限参考，`WindowLiveResize` 保留）。

截图目检（`local-runs/visual`）：归档后 0.25 s 邻居会话正常渲染。

## 未做

- `WindowLiveResize` 显隐代理（约再省 28 ms）。
- 大库下邻居查找仍为整段 O(section)。
- 预建裁剪的离线检查尚未加入 `verify.py`。
