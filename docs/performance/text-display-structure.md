# 文字显示结构改造：LinkTextView 布局主权与测量解耦（11-24，3.0.19-dev）

## 症状

回复段落“文字完整但显示为等高空白”反复出现。此前五次修复不断叠加定时自愈（`height heal` 0.25 / 1 / 3 秒、`paint heal`），治标不治本，既引入多余重排，也没有消除空白的根因。

## 根因

代码与独立复现审计定位到两处结构性冲突：

1. **测量污染显示容器。** `height(forWidth:)` 在任意探测宽度上直接改写显示用 `textContainer.containerSize`，且缓存命中路径不会将其还原，导致显示排版停留在错误宽度。
2. **帧尺寸主权冲突。** `isVerticallyResizable = true` 允许 `NSTextView` 在排版过程中自行改写 `frame`，与 SwiftUI 的布局主权打架。实测宽度探测后 `frame` 从 `600×51` 自行变为 `(0, -136, 600, 187)`；微基准中外框高度从 `500` 被撑到 `6400`。

## 方案

涉及文件：`Tivano/UI/Markdown/LinkParagraphView.swift`、`Tivano/UI/Markdown/TextDisplayAudit.swift`。

1. **Frame 主权收归 SwiftUI。** `LinkTextView.init()` 设置 `isVerticallyResizable = false`、`isHorizontallyResizable = false`，不设 `autoresizingMask`；显示用 `NSTextContainer` 关闭 `widthTracksTextView` 与 `heightTracksTextView`（均设 `false`），`lineFragmentPadding = 0`。显示容器宽度只在 `setContainerWidth(_:)` 一处写入，惰性失效而不触发同步整段重排。
2. **有限宽在显示栈测量、无限宽走每视图测量器。** `height(forWidth:)` 保留 4 槽 FIFO 宽度缓存（命中直接返回，不触碰容器）。有限宽度仍在显示栈上测量——SwiftUI 几乎总是紧接着把 `frame` 设为刚询问的宽度，换宽只需排一次版；若探测宽度与当前 `bounds.width` 不同，则在 `viewWillDraw()`、`hitTest(_:)`、`setFrameSize(_:)`（仅真实宽度变化时）或下一拍 `reconcileDisplay` 前经 `matchContainerToBounds()` 还原为 `bounds.width`。仅无限宽（`!width.isFinite`，如内容贴合气泡的自然宽度探测）走每视图惰性创建的 `TextHeightMeasurer`，在同一 `NSTextStorage` 上挂独立 `NSLayoutManager`（不复制文本，随流式追加同步更新，内存压力时经 `TextHeightMeasurer.clear()` 释放）。显示与测量两套 `NSLayoutManager` 均关闭 `backgroundLayoutEnabled`。
3. **事件驱动核对替代定时自愈。** 删除原 `height heal`（0.25 / 1 / 3 秒）与 `paint heal` 定时自愈，改为由文本更新（`invalidateMeasuredText`）、异宽探测（`height(forWidth:)`）、尺寸变化（`setFrameSize`）、窗口挂载（`viewDidMoveToWindow`）、遮挡恢复（`windowDidChangeOcclusionState`）及取消隐藏（`viewDidUnhide`）触发、合并到下一拍主队列执行的 `reconcileDisplay`。高度偏差超过 `0.5 pt` 时请求 `invalidateIntrinsicContentSize()` 与 `superview?.needsLayout = true`，最多安排两次复核（延迟 `0.5 s`，若仍不一致再隔 `2.0 s` 复核一次），超时记录错误日志后停止。
4. **Release 内置轻量审计。** 新增 `TextDisplayAudit`，在 `reconcileDisplay` 末尾运行（流式期间 `streamVeil.isDissolving` 为真时跳过）。只检查可见、非隐藏、非空视图，仅对 `visibleRect` 局部排版，核查 `container_width`、`height_mismatch`、`no_glyphs_in_view`、`outside_host`、`ancestor_hidden`、`transparent_text` 六类异常。无定时器、不持有视图、不记录文本内容，仅检测到异常时写 `.fault` 日志（单进程限流 40 条，按视图与问题组合去重，上限 256 键）。

## 测量方法

- **线束与构建**：独立 `-O` 编译的 A/B 线束（仓库外 `private-artifacts/blank-hunt/bench/text_display_bench.py`），直接从真实源码提取被测实现——基线为 3.0.15 提交 `6a696b4f5`，候选为本分支最终提交（round 10）。
- **负载场景**（每场景 1 轮热身 + 5 轮取中位数）：
  - **S1（拖动改宽）**：30 个混合长度视图，宽度 `760 → 420 → 760` 逐 `1 pt` 步进，并逐次核对容器与高度一致性（共 20,430 次核对）。
  - **S2（流式追加）**：单视图 300 块流式追加至约 12,000 字符。
  - **S3（整栈重测）**：整栈多宽度重测。
- **定位方法**：先将单步拆为 `height / frame / layout / display / pump` 分段计时，配合 `sample` 确认热点后再做单点消融，避免凭猜测修改。

## 结果

最终版本（round 10）与 3.0.15 基线（`6a696b4f5`）对比，S2 含每次追加后的核对与审计：

| 场景 / 指标 | 基线（`6a696b4f5`） | 新结构 | 变化 |
| --- | --- | --- | --- |
| S1 拖动宽度（p50） | 41.72 ms/步 | 41.86 ms/步 | −0.1%（总时长） |
| S1 核对不一致次数 | 0 / 20,430 | 0 / 20,430 | 无 |
| S2 流式追加（p50） | 5.36 ms/块 | 5.37 ms/块 | −1.0%（总时长） |
| S3 整栈多宽度重测 | 173.6 ms | 167.4 ms | −3.5% |

中间版本曾有 S2 +10% → +6.5% → +5%：关审计对照（+5.2%）与关核对对照都排除了核对和审计本身，最后定位到“外框变化后整段重绘”（见教训 4）。

### 正确性与回归验证

- `scripts/text_height_heal_checks.py`：静态源码不变量检查（确认 `containerSize` 仅在 `setContainerWidth` 写入、禁用 `widthTracksTextView` / `isVerticallyResizable` / `autoresizingMask`、定时自愈已删、`TextDisplayAudit` 无定时器且不读 `.string` 等）+ 独立 AppKit 运行时线束（含可见窗口下的 `TextDisplayAudit` 测试），全部通过。
- `FoldReplyRepro`：9 个场景各 3 轮全通过；注入 0 高度 27 轮全部恢复；注入 0 高度并关闭核对（`debugHeightHealDisabled`）的负对照中，`front` 场景 3/3 失败（停留在 0 高度），确认恢复依赖本核对机制。

## 失败尝试与教训

1. **共享离屏测量器与每视图独立测量排版器（用于有限宽）。** 把所有宽度测量移到共享离屏测量器后，S1 拖动宽度耗时 +214%（41 → 131 ms/步）；换成共享同一 `NSTextStorage` 的每视图测量排版器后仍 +204%。原因不在复制文本，而是 SwiftUI 紧接着就会把 `frame` 设为刚测过的宽度，离屏测量后显示栈仍要再排一次版，等价于每个宽度排两遍。最终只把不会用于绘制的无限宽探测留给 `TextHeightMeasurer`。
2. **`widthTracksTextView = true`。** 开启后 AppKit 在每次宽度变化时都会同步排完整段文字，屏外视图也不例外。微基准 340 次改宽耗时 2,634 ms；改为 `widthTracksTextView = false` 并在 `setFrameSize` 里手动更新容器宽度（惰性失效，延迟到绘制或测量时排版）后降为 0.8 ms。
3. **`setFrameSize` 无条件还原容器宽度。** 在显示栈上测量时，修改容器宽度会让 `NSTextView` 以**相同尺寸**回调 `setFrameSize`。若在 `setFrameSize` 里无条件把容器拉回 `bounds.width`，会把正在进行的测量中途撤销：高度大面积出错（20,430 次核对中 1,021 次不一致），且排队任务里的重排暴涨（累计 343 s）。修正为仅在 `newSize.width != oldSize.width`（真实宽度变化）时对齐。
4. **整段重绘。** 核对里对文字变化、测量和外框变化都做了 `needsDisplay = true`，流式回复每追加一块高度就变一次，于是每块整段重画（S2 多出约 0.34 ms/块，全在 Core Animation 提交的绘制里）。布局管理器与 AppKit 本来只重画改动或新露出的区域；整段重绘只保留给进窗口、取消隐藏、窗口重新可见与复核。
5. **分段计时与 `sample` 定位法。** 先拆出 `height / frame / layout / display / pump` 各段耗时再配合 `sample` 消融，才排除了“复制文本导致变慢”等错误直觉，直接定位到双倍排版与 `setFrameSize` 重入。

## 遗留与监测

- **真机验证**：构建机上 FoldReplyRepro 每轮全场景通过、0 高度注入全部恢复、关核对负对照稳定失败；BlankWatch 真实 Antigravity 派子代理 11 个有效场景（切走、隐藏、遮挡、最小化、切换对话，1000/1600 宽）1000 次扫描零空白。真实故障从未在构建机上复现，最终确认依赖线上审计。
- **线上监测**：`TextDisplayAudit` 已随 Release 构建生效，正常无日志输出，仅在可见段落出现异常时写入持久化 `.fault` 日志。收集现场异常记录使用：

```bash
log show --predicate 'category == "TextDisplayAudit"' --last 1d
```
