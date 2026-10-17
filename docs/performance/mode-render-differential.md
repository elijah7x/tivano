# 普通模式额外渲染成本：源码差分调查

本次最强结论：性能模式一次改变整窗背景、控件玻璃和持续动效三组路径，且改变 `clearerBackdrop` 的持久值；“打开后明显改善”不能独立归因于玻璃。整窗背景和控件玻璃在会话停止后仍存在，设置窗口也使用相同背景与控件 modifier，值得先隔离测量。尚无采样证据证明任何一组是主要瓶颈，更不能据此判定 WindowServer 自身故障。

## 证据范围

- 现场信息由主负责人提供：运行正式版 1.3.8/build25，UUID `72F467BC-7A02-3FBE-8F8E-25C57D5847C8`；候选源码基准 `93f0d3394`。本报告沿用候选关系，没有重新证明二进制与该提交一致。
- 先查询索引 `Users-elijah-air-Universe-Oort-forked-tivano-tivano.dev`，再用 `git show` 分别阅读 `93f0d3394` 与 `4fc87d1ee` 的指定源码，并阅读本工作区实际符号。以下行号默认指正式版候选源码。
- 两提交的 Chrome.swift、ChatView.swift、ComposerView.swift、HydraGlyph.swift、OrbView.swift 全文相同；TimelineRows.swift 有其他功能差异，但本报告涉及的 HydraShimmer 与调用分支相同。工作区另带未提交的窗口可见性门控：不得把它当成正式版已有保护；本次不审查该动画补丁，也不复核隔离提交 `6ae497e87` 的打包产物。
- 仅源码调查与文档写入。未构建、测试、采样、操作应用、偏好、系统设置或用户会话。一次 Nowledge CLI thread 搜索 `Tivano performanceMode clearerBackdrop` 返回 0 条，未引入历史结论。

## 1. 整窗背景：停止会话仍在，开关对照有持久混杂

**符号与调用关系（高置信度，两个提交均适用）：**

`RootView.body` → `WindowBackdrop(opacity: settings.backdropOpacity, wallpaper: WallpaperStore.shared.image)`（RootView.swift:103）；独立 `SettingsView.body` → `WindowBackdrop(opacity:)`（SettingsView.swift:136，不传 wallpaper）。`WindowBackdrop` 位于 Chrome.swift:301–382，分支如下：

| 输入 | 普通模式 | 性能模式 |
| --- | --- | --- |
| 无 wallpaper，opacity < 0.98，未减少透明度 | clearerBackdrop=true：整窗 `.glassEffect`；false：`BehindWindowBlur`，再叠 scrim 与主题 tint | 黑/白实色底加主题 tint |
| 无 wallpaper，opacity ≥ 0.98 或减少透明度 | 已经是同一实色底 | 同左 |
| 有 wallpaper | 高质量插值、fill 缩放、opacity、clip；opacity < 0.98 时再叠玻璃 | 连 wallpaper 一并移除，使用实色底 |

`BehindWindowBlur.makeNSView`（386–395）创建 `.behindWindow` / `.underWindowBackground` / `.active` 的 `NSVisualEffectView`；`updateNSView` 为空。这里没有逐帧 Swift 计时器，也没有反复创建视图的源码证据。底层材质可随采样内容改变而合成，不能把合成成本与 SwiftUI body 重算混为一谈。

**更新来源与存续：** AppStorage 的 performanceMode、clearerBackdrop，颜色/透明度环境，父视图传入的 opacity、wallpaper 及容器尺寸。主题 tint 参与绘制，但这不等于每个聊天 token 都必然重算背景。上述背景不依赖 `runtime.isRunning`，停止会话不会移除；失焦也没有在此处关闭 `.active` 材质。设置窗口直接涉及同一路径，因此“设置页也卡”不能排除这一组；主窗有 wallpaper 时，设置窗与主窗的背景分支还可能不同。

**混杂因素：** AppSettings.swift:402–406 的 `performanceMode.didSet` 在开启时执行 `clearerBackdrop = false`，关闭时不恢复。无 wallpaper 且半透明时，普通→性能→普通可能实际是 **Liquid Glass→实色→NSVisualEffectView**，不是原路径往返。本次未读取或更改用户当前值。

**推断边界与最小测量：** 整窗采样面积使此组值得优先测，但没有实际 GPU/帧时间证据。主负责人可在隔离诊断配置中固定普通模式、无 wallpaper、opacity、主题、窗口大小、显示器和其余动效，只切一个只读测试参数，将 `WindowBackdrop` 的非实色内容替换为既有 solidBackdrop；不要切全局 performanceMode 或写用户 defaults。相同滚动输入各采 30 秒、按 A/B/A 顺序记录帧耗时、Tivano CPU/GPU 与 WindowServer CPU/GPU。该替换仅用于归因，不能作为保留外观的优化交付；若无差异，再单独比较 clearerBackdrop 的两个采样实现。

## 2. 控件玻璃：顶栏隐藏仍挂载；有一个可保持外观的局部候选

**符号与调用关系（高置信度，两个提交均适用）：**

- `ChatChromeRow.chromeRowContent`（ChatView.swift:980–1030）普通模式将 `topControls` 放在 `GlassEffectContainer(spacing: 2)`，性能模式省去容器；容器内 `ChromeCapsule` → `.chromeGlassCapsule()` → `ChromeGlassSurface.surface`（Chrome.swift:268–281）。非玻璃面板中普通模式为带 tint 的玻璃，按钮还带 `.interactive()`；性能模式改 flat fill、hover hit shape，并取消此 modifier 自己的 hover 动画。玻璃面板内本来就走 flat 分支。
- 顶栏隐藏只用 `.opacity(0)`、禁用 hit testing 与 accessibility（ChatView.swift:1005–1007），没有卸载 `topControls` 或容器。`showsTopControls` 来自自动隐藏设置、hover、popover 状态（1064–1066）。这证明子树存续，**不证明透明后的玻璃仍被系统完整合成**。
- `ComposerArea.areaContent`（ComposerView.swift:39–45）将 tab 与 composer 放进 `.floatingGlassContainer()`；`FloatingGlassContainer`（Chrome.swift:197–207）只看 floatingGlassStyle，**性能模式下 upstream 容器仍存在**，不能说所有玻璃容器都被关掉。
- `ComposerView.body` → `ComposerSurface`（ComposerView.swift:195、1315–1350）。upstream 且不在玻璃面板时 → `FloatingGlassSurface`（Chrome.swift:209–243）：普通模式 regular tinted glass + active appearance + rim，性能模式/减少透明度为实色 fill + clip + 同一 rim。upstream 且在玻璃面板时已 flat。非 upstream 普通分支另有 `.regular` 玻璃、0.92 controlBackground 底色与 windowBackground 底色、clip；性能模式则 flat + rim。

**更新来源与存续：** 顶栏读取 sidebar、线程/功能设置、git repository 状态，子控件读取 terminal/diff 等 runtime 状态；本地 hover、宽度 geometry 与 presentation preference 会写其 State。surface 读取 AppStorage、配色、面板环境，flat 分支另读 hover。ComposerArea 读取 approvals、diff 等状态；composer 的 text/controls 各自更新，源码特意让外层不直接绑定 draft（ComposerView.swift:125–150），不能推定每个按键重建整个玻璃面。即使 body 不更新，玻璃下面的 timeline 滚动仍可能改变采样。会话停止不移除顶栏或输入框。设置页的主题 picker 调用 `.chromeGlassCapsule()`（SettingsView.swift:1360），共享 ChromeGlassSurface；它不经过 ChatChromeRow 或 ComposerSurface，是否 flat 仍由 isOnGlassPanel 决定。

**普通模式优化候选（中置信度，尚不能直接改产品）：** Chrome.swift:221–223 的 rim 永远执行 `.mask { Rectangle().padding(.bottom, hiddenRimBottom) }`，但 `.floatingGlass` 的默认 hiddenRimBottom 为 0（同文件:169–175），composer 正是使用默认值。可只在 hiddenRimBottom 非零时保留该 mask，零值时直接绘制原 `strokeBorder`。内描边理论上在 shape 边界内，零 padding 的矩形没有要隐藏的底边，因此可保留原玻璃、tint、边框、交互和动画；非零值用于隐藏边框的行为不动。这不是缓存、drawingGroup 或关闭效果。不过 SwiftUI 可能已消除该 mask，实际成本未知；边界抗锯齿/缩放也须目检，不能凭结构宣称视觉完全一致。

**最小单变量测量：** 普通模式、upstream、同一 composer 与滚动内容固定，只在隔离诊断构建切换“零值 rim mask 是否存在”，其他所有效果保持一致；相同输入 A/B/A 各 30 秒，比较 GPU 合成/离屏 pass 与帧耗时，并由主负责人对照亮暗主题、Retina、缩放及非零 hiddenRimBottom 的成品截图。先证明这层 pass 存在及成本下降，再考虑产品修改。顶栏隐藏存续可另做测量，但不能用直接卸载作为成品方案：当前宽度测量、hover 揭示和 popover 保持均依赖这棵树。

## 3. 持续动效：三种调度机制，不能统称为玻璃成本

**符号与调用关系（高置信度，正式版候选与提交 dev 均适用）：**

| 路径 | 普通模式调度/更新 | 性能模式 | 停止会话及设置页边界 |
| --- | --- | --- | --- |
| `HydraGlyph.body` → `HydraBreathRing`（HydraGlyph.swift:23–26、73–85） | 仅 isRunning 创建 ring；`installAnimation`（185–212）用 CA group 重复 scale/opacity，周期 1.6 秒；不是 SwiftUI 每帧刷新整个父树。布局/configure/激活通知会更新图层或安装动画 | 移除 ring，保留图标和 outcome badge | 取决于每个调用者传入 isRunning，主会话停下不保证其他 head 停止；全部相应 running=false 才无 ring。普通设置内容本身无此调用证据 |
| `ThinkingOrb`（OrbView.swift:40–86） | `isOnScreen && !paused && !reduced` 时 TimelineView 最小间隔 1/30 秒 → Canvas → player.advance/paint；输入还有 voice state/audio、尺寸、配色 | reduced=true，暂停 timeline、显示静态代表帧，并 hide player | 不绑定文本 runtime.isRunning；语音仍 live 时可继续。索引的 VoiceComposerOrb/VoiceSidebarTrigger/VoiceStage 调用提供语音状态和可见性参数，不能用“文本会话停止”排除。独立设置窗口没有此调用；背后语音视图是否仍挂载需主负责人另查 |
| `HydraShimmer`（TimelineRows.swift:547–589） | 几何宽度 State；TimelineView 最小间隔 1/30 秒计算 1.8 秒相位，gradient offset 后 `.mask { content }`；ScrollActivity.isScrolling 时暂停 | 返回 content，完全移除 sweep overlay/timeline | HydraBriefRow 仅 `!hasOutput && runtime.isRunning` 时使用（615–629）；HydraMergeRow 仅未收到 outcome 且 isHydraMerging 的内容路径使用（1005–1017、1064、1132）。这些状态都结束才移除；普通设置内容本身无此调用证据 |

工作区的 Orb/Shimmer/ring 另有窗口可见性保护；以上调度说明依据 `git show` 的两个提交，未将工作区保护倒推为正式版事实。这里列的是限定符号，不是全 App 动效清单；同一个 performanceMode 还会移除 ComposerWorkingDotsSlot，故全局开关也不是仅这三种动效的实验。

**推断边界与最小测量：** CA ring 仍可能消耗合成资源，但其存在不能证明 SwiftUI 父视图逐帧重算；Orb 和 Shimmer 才有明确 timeline 驱动。主负责人在隔离、可重复的对应活动场景中，每次只通过局部诊断参数暂停一种调度（ring 保留静态层；Orb 固定同一帧；Shimmer 固定相位），保持普通玻璃、背景和其余动画不变，A/B/A 各采 30 秒。分别记录实际 timeline 回调/Canvas 绘制次数、SwiftUI 更新耗时和 GPU/帧耗时。暂停只是归因实验，不是优化建议，也不降低交付的可见帧率。全无 head、无 merge、无语音的静止场景若仍改善，应先追前两组；仍不能排除本次限定范围以外的工作。
