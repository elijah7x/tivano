import AppKit
import SwiftUI

// A project's mark: the emoji or the SF Symbol it wears in the activity list's icon style,
// and the picker that chooses it. Core owns the value (`ProjectIcon`); this file draws it,
// reads the generated catalogue of every symbol on offer, and presents the popover. Every symbol on offer
// is the filled mark, so a project's icon is a solid shape rather than an outline.

/// A project's mark as the rows draw it: the emoji or symbol the reader picked, or the
/// folder mark until one has been picked.
struct ProjectIconMark: View {
    let icon: ProjectIcon?
    var size: CGFloat = 13

    var body: some View {
        Group {
            if let emoji = icon?.emoji {
                Text(verbatim: emoji)
                    .font(.system(size: size))
            } else {
                Image(systemName: icon?.symbolName ?? "folder.fill")
                    .font(.system(size: size))
            }
        }
        .foregroundStyle(Chrome.primaryText.opacity(0.9))
    }
}

/// A project's mark as a button: clicking it opens the picker over it.
struct ProjectIconButton: View {
    @Binding var icon: ProjectIcon?
    var size: CGFloat = 13

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            ProjectIconMark(icon: icon, size: size)
                .frame(width: size + 9, height: size + 9)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: Chrome.localized("Choose this project's icon")))
        .accessibilityLabel(Text("Project icon"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ProjectIconPicker(icon: $icon)
        }
    }
}

/// Chooses a project's mark: categorized emoji, a search over emoji and SF Symbols,
/// and a Folder tile that clears the mark back to its default.
struct ProjectIconPicker: View {
    @Binding var icon: ProjectIcon?

    @State private var query = ""

    private struct EmojiEntry {
        let emoji: String
        let keywords: String
    }

    private struct EmojiGroup: Identifiable {
        let id: String
        let title: String
        let keywords: String
        let entries: [EmojiEntry]
    }

    private static let emojiGroups: [EmojiGroup] = [
        EmojiGroup(id: "development-tools", title: "Development & Tools", keywords: "开发与工具", entries: [
            EmojiEntry(emoji: "🛠️", keywords: "tools hammer wrench repair 工具 锤子 扳手 维修"),
            EmojiEntry(emoji: "📦", keywords: "package box delivery 包裹 箱子 快递"),
            EmojiEntry(emoji: "🧩", keywords: "puzzle piece plugin 拼图 插件"),
            EmojiEntry(emoji: "⚙️", keywords: "gear settings configuration 齿轮 设置 配置"),
            EmojiEntry(emoji: "🏗️", keywords: "construction crane building 施工 起重机 建造"),
            EmojiEntry(emoji: "🔧", keywords: "wrench repair maintenance 扳手 维修 维护"),
            EmojiEntry(emoji: "🧰", keywords: "toolbox toolkit 工具箱 工具包"),
            EmojiEntry(emoji: "🧱", keywords: "brick wall building 砖 墙 建筑"),
            EmojiEntry(emoji: "🗝️", keywords: "key unlock access 钥匙 解锁 访问"),
            EmojiEntry(emoji: "🔐", keywords: "lock key security privacy 锁 钥匙 安全 隐私"),
            EmojiEntry(emoji: "🛡️", keywords: "shield protection security 盾牌 防护 安全"),
            EmojiEntry(emoji: "🤖", keywords: "robot bot ai automation 机器人 人工智能 自动化"),
        ]),
        EmojiGroup(id: "devices-technology", title: "Devices & Technology", keywords: "设备与科技", entries: [
            EmojiEntry(emoji: "🔋", keywords: "battery power charge 电池 电量 充电"),
            EmojiEntry(emoji: "🔌", keywords: "plug electricity power 插头 电源 电力"),
            EmojiEntry(emoji: "📡", keywords: "satellite antenna signal 卫星 天线 信号"),
            EmojiEntry(emoji: "🎛️", keywords: "control knobs mixer 控制 旋钮 调音台"),
            EmojiEntry(emoji: "🖲️", keywords: "trackball input 轨迹球 输入"),
            EmojiEntry(emoji: "🖨️", keywords: "printer print 打印机 打印"),
            EmojiEntry(emoji: "⌨️", keywords: "keyboard typing 键盘 打字"),
            EmojiEntry(emoji: "🖥️", keywords: "desktop computer monitor 台式电脑 显示器"),
            EmojiEntry(emoji: "💻", keywords: "laptop computer notebook 笔记本 电脑"),
            EmojiEntry(emoji: "🖱️", keywords: "mouse click cursor 鼠标 点击 光标"),
            EmojiEntry(emoji: "📱", keywords: "phone mobile smartphone 手机 移动 智能手机"),
            EmojiEntry(emoji: "⌚️", keywords: "watch time wearable 手表 时间 穿戴"),
            EmojiEntry(emoji: "🎧", keywords: "headphones audio music 耳机 音频 音乐"),
            EmojiEntry(emoji: "🔊", keywords: "speaker volume sound 扬声器 音量 声音"),
            EmojiEntry(emoji: "🎤", keywords: "microphone singing recording 麦克风 唱歌 录音"),
            EmojiEntry(emoji: "📷", keywords: "camera photo photography 相机 照片 摄影"),
            EmojiEntry(emoji: "🎥", keywords: "movie camera video filming 摄像机 视频 拍摄"),
        ]),
        EmojiGroup(id: "work-creativity", title: "Work & Creativity", keywords: "工作与创作", entries: [
            EmojiEntry(emoji: "🎨", keywords: "art palette paint design 艺术 调色盘 绘画 设计"),
            EmojiEntry(emoji: "📊", keywords: "chart data analytics 图表 数据 分析"),
            EmojiEntry(emoji: "📚", keywords: "books reading library 书籍 阅读 图书馆"),
            EmojiEntry(emoji: "🧵", keywords: "thread sewing craft 线 缝纫 手工"),
            EmojiEntry(emoji: "🏺", keywords: "amphora pottery vase 陶罐 陶艺 花瓶"),
            EmojiEntry(emoji: "🖼️", keywords: "picture frame art gallery 图片 相框 艺术 画廊"),
            EmojiEntry(emoji: "🖌️", keywords: "paintbrush painting 画笔 绘画"),
            EmojiEntry(emoji: "🖍️", keywords: "crayon drawing 蜡笔 画画"),
            EmojiEntry(emoji: "✏️", keywords: "pencil writing sketch 铅笔 写作 草图"),
            EmojiEntry(emoji: "📝", keywords: "memo note writing 备忘 笔记 写作"),
            EmojiEntry(emoji: "📌", keywords: "pushpin pin reminder 图钉 固定 提醒"),
            EmojiEntry(emoji: "📍", keywords: "pin location place 定位 位置 地点"),
            EmojiEntry(emoji: "📎", keywords: "paperclip attachment 回形针 附件"),
            EmojiEntry(emoji: "🗂️", keywords: "index dividers organize 分类 索引 整理"),
            EmojiEntry(emoji: "🗃️", keywords: "card file box archive 卡片 文件盒 档案"),
            EmojiEntry(emoji: "🗄️", keywords: "filing cabinet storage 文件柜 存储"),
            EmojiEntry(emoji: "📁", keywords: "folder directory files 文件夹 目录 文件"),
            EmojiEntry(emoji: "📂", keywords: "open folder directory 打开 文件夹 目录"),
            EmojiEntry(emoji: "🗓️", keywords: "spiral calendar schedule 日历 日程 排期"),
            EmojiEntry(emoji: "📅", keywords: "calendar date event 日历 日期 活动"),
            EmojiEntry(emoji: "🧮", keywords: "abacus calculation accounting 算盘 计算 会计"),
            EmojiEntry(emoji: "🎓", keywords: "graduation education learning 毕业 教育 学习"),
            EmojiEntry(emoji: "🧑‍🏫", keywords: "teacher teaching education 老师 教学 教育"),
            EmojiEntry(emoji: "💼", keywords: "briefcase business work 公文包 商务 工作"),
        ]),
        EmojiGroup(id: "science-exploration", title: "Science & Exploration", keywords: "科学与探索", entries: [
            EmojiEntry(emoji: "🚀", keywords: "rocket launch space 火箭 发射 太空"),
            EmojiEntry(emoji: "🧪", keywords: "test tube chemistry experiment 试管 化学 实验"),
            EmojiEntry(emoji: "🧠", keywords: "brain mind intelligence 大脑 思维 智力"),
            EmojiEntry(emoji: "🛰️", keywords: "satellite orbit space 卫星 轨道 太空"),
            EmojiEntry(emoji: "🧭", keywords: "compass navigation direction 指南针 导航 方向"),
            EmojiEntry(emoji: "🧲", keywords: "magnet magnetism physics 磁铁 磁力 物理"),
            EmojiEntry(emoji: "💡", keywords: "bulb light idea 灯泡 灯光 灵感"),
            EmojiEntry(emoji: "🔍", keywords: "magnifying glass search inspect 放大镜 搜索 检查"),
            EmojiEntry(emoji: "🔎", keywords: "magnifying glass search discover 放大镜 搜索 发现"),
            EmojiEntry(emoji: "🔭", keywords: "telescope astronomy observation 望远镜 天文 观测"),
            EmojiEntry(emoji: "🔬", keywords: "microscope laboratory research 显微镜 实验室 研究"),
            EmojiEntry(emoji: "🧫", keywords: "petri dish culture biology 培养皿 培养 生物"),
            EmojiEntry(emoji: "🧬", keywords: "dna genetics biology 基因 遗传 生物"),
            EmojiEntry(emoji: "🦠", keywords: "microbe bacteria virus 微生物 细菌 病毒"),
            EmojiEntry(emoji: "🌡️", keywords: "thermometer temperature 温度计 温度"),
            EmojiEntry(emoji: "☄️", keywords: "comet meteor space 彗星 流星 太空"),
            EmojiEntry(emoji: "🪐", keywords: "planet saturn space 行星 土星 太空"),
            EmojiEntry(emoji: "🛸", keywords: "ufo flying saucer alien 飞碟 外星人"),
            EmojiEntry(emoji: "🌍", keywords: "earth globe world 地球 世界"),
            EmojiEntry(emoji: "🗺️", keywords: "map world geography 地图 世界 地理"),
            EmojiEntry(emoji: "🩺", keywords: "stethoscope medicine health doctor 听诊器 医疗 健康 医生"),
        ]),
        EmojiGroup(id: "nature-animals", title: "Nature & Animals", keywords: "自然与动物", entries: [
            EmojiEntry(emoji: "🌱", keywords: "seedling sprout growth 幼苗 萌芽 生长"),
            EmojiEntry(emoji: "🔥", keywords: "fire flame heat 火 火焰 热"),
            EmojiEntry(emoji: "🐙", keywords: "octopus ocean 章鱼 海洋"),
            EmojiEntry(emoji: "🦀", keywords: "crab sea 螃蟹 海洋"),
            EmojiEntry(emoji: "🐝", keywords: "bee honey insect 蜜蜂 蜂蜜 昆虫"),
            EmojiEntry(emoji: "🦊", keywords: "fox animal 狐狸 动物"),
            EmojiEntry(emoji: "🌊", keywords: "wave ocean water 海浪 海洋 水"),
            EmojiEntry(emoji: "🌙", keywords: "moon crescent night 月亮 新月 夜晚"),
            EmojiEntry(emoji: "⚡️", keywords: "lightning bolt electricity 闪电 电力"),
            EmojiEntry(emoji: "🍀", keywords: "clover luck plant 四叶草 幸运 植物"),
            EmojiEntry(emoji: "🫧", keywords: "bubbles foam 泡泡 泡沫"),
            EmojiEntry(emoji: "🧊", keywords: "ice cold frozen 冰 寒冷 冰冻"),
            EmojiEntry(emoji: "🪵", keywords: "wood log timber 木头 原木 木材"),
            EmojiEntry(emoji: "🪨", keywords: "rock stone 石头 岩石"),
            EmojiEntry(emoji: "🌋", keywords: "volcano eruption lava 火山 喷发 熔岩"),
            EmojiEntry(emoji: "🏔️", keywords: "mountain snow peak 山 雪山 山峰"),
            EmojiEntry(emoji: "🌈", keywords: "rainbow weather color 彩虹 天气 色彩"),
            EmojiEntry(emoji: "🌳", keywords: "tree forest nature 树 森林 自然"),
            EmojiEntry(emoji: "🐱", keywords: "cat kitten pet 猫 小猫 宠物"),
            EmojiEntry(emoji: "🐶", keywords: "dog puppy pet 狗 小狗 宠物"),
            EmojiEntry(emoji: "🐼", keywords: "panda bear 熊猫 动物"),
            EmojiEntry(emoji: "🐳", keywords: "whale ocean spout 鲸鱼 海洋 喷水"),
            EmojiEntry(emoji: "🦉", keywords: "owl bird night 猫头鹰 鸟 夜晚"),
            EmojiEntry(emoji: "🌻", keywords: "sunflower flower plant 向日葵 花 植物"),
        ]),
        EmojiGroup(id: "everyday-life", title: "Everyday Life", keywords: "日常生活", entries: [
            EmojiEntry(emoji: "🪑", keywords: "chair seat furniture 椅子 座位 家具"),
            EmojiEntry(emoji: "🛋️", keywords: "couch sofa home 沙发 家居"),
            EmojiEntry(emoji: "🔦", keywords: "flashlight torch light 手电筒 照明"),
            EmojiEntry(emoji: "🕯️", keywords: "candle light 蜡烛 烛光"),
            EmojiEntry(emoji: "🚿", keywords: "shower water wash 淋浴 水 洗澡"),
            EmojiEntry(emoji: "🛁", keywords: "bathtub bath relax 浴缸 泡澡 放松"),
            EmojiEntry(emoji: "🧴", keywords: "lotion bottle skincare 乳液 瓶子 护肤"),
            EmojiEntry(emoji: "🧹", keywords: "broom sweep cleaning 扫帚 扫地 清洁"),
            EmojiEntry(emoji: "🧺", keywords: "basket laundry 篮子 洗衣"),
            EmojiEntry(emoji: "🧼", keywords: "soap wash cleaning 肥皂 洗涤 清洁"),
            EmojiEntry(emoji: "🪣", keywords: "bucket pail water 水桶 桶 水"),
            EmojiEntry(emoji: "🧽", keywords: "sponge scrub cleaning 海绵 擦洗 清洁"),
            EmojiEntry(emoji: "🪥", keywords: "toothbrush teeth dental 牙刷 牙齿 口腔"),
            EmojiEntry(emoji: "🪒", keywords: "razor shaving 剃须刀 刮胡子"),
            EmojiEntry(emoji: "⏰", keywords: "alarm clock time 闹钟 时间"),
            EmojiEntry(emoji: "⏳", keywords: "hourglass timer waiting 沙漏 计时 等待"),
            EmojiEntry(emoji: "🧳", keywords: "luggage suitcase travel 行李箱 行李 旅行"),
            EmojiEntry(emoji: "🎒", keywords: "backpack school bag 背包 书包 学校"),
            EmojiEntry(emoji: "☕", keywords: "coffee cup hot drink 咖啡 杯子 热饮"),
            EmojiEntry(emoji: "🍎", keywords: "apple fruit food 苹果 水果 食物"),
            EmojiEntry(emoji: "💰", keywords: "money bag savings finance 钱 钱袋 储蓄 财务"),
            EmojiEntry(emoji: "🍋", keywords: "lemon citrus fruit 柠檬 柑橘 水果"),
            EmojiEntry(emoji: "🍕", keywords: "pizza food meal 披萨 食物 餐饮"),
            EmojiEntry(emoji: "🏠", keywords: "house home building 房子 家 住宅"),
        ]),
        EmojiGroup(id: "leisure-entertainment", title: "Leisure & Entertainment", keywords: "休闲娱乐", entries: [
            EmojiEntry(emoji: "🕹️", keywords: "joystick game arcade 摇杆 游戏 街机"),
            EmojiEntry(emoji: "🎯", keywords: "target dart goal 靶心 飞镖 目标"),
            EmojiEntry(emoji: "🪄", keywords: "magic wand 魔法 魔杖"),
            EmojiEntry(emoji: "🍿", keywords: "popcorn movie snack 爆米花 电影 零食"),
            EmojiEntry(emoji: "🔮", keywords: "crystal ball fortune magic 水晶球 占卜 魔法"),
            EmojiEntry(emoji: "⚔️", keywords: "crossed swords battle 剑 战斗"),
            EmojiEntry(emoji: "🪓", keywords: "axe chopping 斧头 劈砍"),
            EmojiEntry(emoji: "🗡️", keywords: "dagger blade 匕首 刀刃"),
            EmojiEntry(emoji: "🏹", keywords: "bow arrow archery 弓箭 射箭"),
            EmojiEntry(emoji: "🪃", keywords: "boomerang throwing 回旋镖 投掷"),
            EmojiEntry(emoji: "🧿", keywords: "nazar amulet evil eye 护身符 蓝眼"),
            EmojiEntry(emoji: "🎬", keywords: "clapper movie film 场记板 电影 拍摄"),
            EmojiEntry(emoji: "🏕️", keywords: "camping tent outdoors 露营 帐篷 户外"),
            EmojiEntry(emoji: "🧗", keywords: "climbing climber sport 攀岩 攀登 运动"),
            EmojiEntry(emoji: "🪁", keywords: "kite flying 风筝 放飞"),
            EmojiEntry(emoji: "🎲", keywords: "dice game chance 骰子 游戏 随机"),
            EmojiEntry(emoji: "♟️", keywords: "chess pawn board game 国际象棋 棋子 桌游"),
            EmojiEntry(emoji: "🧸", keywords: "teddy bear toy 泰迪熊 玩具"),
            EmojiEntry(emoji: "🪩", keywords: "disco mirror ball dance 迪斯科 镜球 舞蹈"),
            EmojiEntry(emoji: "🎺", keywords: "trumpet brass music 小号 铜管 音乐"),
            EmojiEntry(emoji: "🎸", keywords: "guitar rock music 吉他 摇滚 音乐"),
            EmojiEntry(emoji: "🥁", keywords: "drum rhythm music 鼓 节奏 音乐"),
            EmojiEntry(emoji: "🏆", keywords: "trophy winner award 奖杯 冠军 奖励"),
            EmojiEntry(emoji: "🥇", keywords: "gold medal first winner 金牌 第一 冠军"),
            EmojiEntry(emoji: "🎵", keywords: "music note melody 音乐 音符 旋律"),
        ]),
        EmojiGroup(id: "symbols-communication", title: "Symbols & Communication", keywords: "标记与沟通", entries: [
            EmojiEntry(emoji: "💎", keywords: "diamond gem jewel 钻石 宝石 珠宝"),
            EmojiEntry(emoji: "⭐", keywords: "star favorite rating 星星 收藏 评分"),
            EmojiEntry(emoji: "❤️", keywords: "heart love like 心 爱 喜欢"),
            EmojiEntry(emoji: "💬", keywords: "speech chat message 对话 聊天 消息"),
            EmojiEntry(emoji: "✉️", keywords: "envelope mail letter 信封 邮件 信件"),
            EmojiEntry(emoji: "✅", keywords: "check done complete success 勾选 完成 成功"),
            EmojiEntry(emoji: "🌐", keywords: "globe web internet network 全球 网页 互联网 网络"),
            EmojiEntry(emoji: "🤝", keywords: "handshake agreement collaboration 握手 协议 合作"),
        ]),
    ]

    /// The marks the picker opens on, each checked against this Mac's own catalogue as the
    /// list is first read, so a name the system does not have is never offered. Every one is
    /// a filled mark: a project's icon reads as a solid shape, never an outline.
    private static let favourites: [String] = shortlist.filter {
        NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
    }

    private static let shortlist = [
        "hammer.fill", "wrench.and.screwdriver.fill", "gearshape.fill", "terminal.fill",
        "curlybraces.square.fill", "chevron.left.square.fill", "shippingbox.fill", "cube.fill",
        "tray.full.fill", "doc.fill", "square.stack.3d.up.fill", "memorychip.fill",
        "cpu.fill", "externaldrive.fill", "paintbrush.fill", "paintpalette.fill",
        "book.closed.fill", "graduationcap.fill", "lightbulb.fill", "key.fill",
        "lock.fill", "leaf.fill", "flame.fill", "drop.fill",
        "sun.max.fill", "moon.stars.fill", "cloud.fill", "bolt.fill",
        "star.fill", "heart.fill", "diamond.fill", "crown.fill",
        "trophy.fill", "medal.fill", "checkmark.seal.fill", "gift.fill",
        "gamecontroller.fill", "dpad.fill", "popcorn.fill", "film.fill",
        "mic.fill", "speaker.wave.3.fill", "camera.fill", "photo.fill",
        "globe.fill", "point.3.filled.connected.trianglepath.dotted", "hand.point.up.left.fill", "person.fill",
        "person.2.fill", "pawprint.fill", "bird.fill", "fish.fill",
        "cup.and.saucer.fill", "waterbottle.fill", "takeoutbag.and.cup.and.straw.fill", "theatermasks.fill",
    ]

    /// The sections the picker scrolls: the shortlist it used to open on under the name
    /// Popular, then every symbol the generated catalogue holds, in the SF Symbols app's
    /// own category order.
    private static let groups: [ProjectSymbolCatalogue.Group] =
        [ProjectSymbolCatalogue.Group(id: "popular", title: "Popular", names: favourites)]
        + ProjectSymbolCatalogue.groups

    private static let columns = Array(repeating: GridItem(.fixed(26), spacing: 4), count: 9)

    private var searchQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matchingEmojiGroups: [EmojiGroup] {
        let needle = searchQuery
        guard !needle.isEmpty else { return Self.emojiGroups }
        return Self.emojiGroups.compactMap { group in
            let matchesCategory = group.title.localizedCaseInsensitiveContains(needle)
                || group.keywords.localizedCaseInsensitiveContains(needle)
            let entries = group.entries.filter {
                matchesCategory || $0.emoji.contains(needle)
                    || $0.keywords.localizedCaseInsensitiveContains(needle)
            }
            guard !entries.isEmpty else { return nil }
            return EmojiGroup(id: group.id, title: group.title, keywords: group.keywords, entries: entries)
        }
    }

    /// The symbols the query names, with the one the reader typed in front when the
    /// catalogue knows that name in a filled form the shortlist does not hold.
    private var matchingSymbols: [String] {
        let needle = searchQuery
        guard !needle.isEmpty else { return [] }
        var names = ProjectSymbolCatalogue.all.filter { $0.localizedCaseInsensitiveContains(needle) }
        if let typed = Self.filledForm(of: needle), !names.contains(typed) {
            names.insert(typed, at: 0)
        }
        return names
    }

    /// A typed name as the grid may offer it: the name itself when it is already a filled
    /// mark, its `.fill` mark when the catalogue has one, and nothing at all otherwise, so
    /// a symbol chosen from the search is as solid as the ones in the shortlist.
    private static func filledForm(of name: String) -> String? {
        if name.hasSuffix(".fill") || name.hasSuffix(".inverse") {
            return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : nil
        }
        let filled = name + ".fill"
        return NSImage(systemSymbolName: filled, accessibilityDescription: nil) != nil ? filled : nil
    }

    var body: some View {
        let emojiGroups = matchingEmojiGroups
        let symbols = matchingSymbols
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: Chrome.localized("Project icon"))
                .font(.ui(.callout, weight: .medium))
                .foregroundStyle(Chrome.primaryText)
            searchField
            Text(verbatim: Chrome.localized("Try cat, 猫, or folder"))
                .font(.ui(.footnote))
                .foregroundStyle(Chrome.secondaryText)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(emojiGroups) { group in
                        emojiSection(group)
                    }
                    if searchQuery.isEmpty {
                        ForEach(Self.groups) { group in
                            symbolSection(group)
                        }
                    } else if !symbols.isEmpty {
                        symbolGrid(symbols)
                    } else if emojiGroups.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(verbatim: Chrome.localized("No matching icons"))
                                .font(.ui(.callout, weight: .medium))
                            Text(verbatim: Chrome.localized("Try another keyword or clear the search."))
                                .font(.ui(.footnote))
                        }
                        .foregroundStyle(Chrome.secondaryText)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.never)
            Divider()
                .overlay(Chrome.overlay(0.12))
            HStack(spacing: 8) {
                IconTile(isSelected: icon == nil, action: { icon = nil }) {
                    Image(systemName: "folder.fill")
                        .font(.ui(.callout))
                        .foregroundStyle(Chrome.secondaryText)
                }
                Text(verbatim: Chrome.localized("Folder"))
                    .font(.ui(.callout))
                    .foregroundStyle(Chrome.secondaryText)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(width: 300, height: 420)
    }

    private func symbolSection(_ group: ProjectSymbolCatalogue.Group) -> some View {
        section(group.title) {
            LazyVGrid(columns: Self.columns, spacing: 4) {
                ForEach(group.names, id: \.self) { name in
                    IconTile(isSelected: icon?.symbolName == name, action: { icon = .symbol(name) }) {
                        Image(systemName: name)
                            .font(.ui(.callout))
                            .foregroundStyle(Chrome.primaryText.opacity(0.9))
                    }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.secondaryText)
            TextField(text: $query) {
                Text(verbatim: Chrome.localized("Search emoji or symbols"))
            }
                .textFieldStyle(.plain)
                .font(.ui(.callout))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Chrome.overlay(0.10))
        }
    }

    private func emojiSection(_ group: EmojiGroup) -> some View {
        section(group.title) {
            LazyVGrid(columns: Self.columns, spacing: 4) {
                ForEach(group.entries, id: \.emoji) { entry in
                    IconTile(isSelected: icon?.emoji == entry.emoji, action: { icon = .emoji(entry.emoji) }) {
                        Text(verbatim: entry.emoji)
                            .font(.ui(.title3))
                    }
                }
            }
        }
    }

    private func symbolGrid(_ names: [String]) -> some View {
        section("Symbols") {
            LazyVGrid(columns: Self.columns, spacing: 4) {
                ForEach(names, id: \.self) { name in
                    IconTile(isSelected: icon?.symbolName == name, action: { icon = .symbol(name) }) {
                        Image(systemName: name)
                            .font(.ui(.callout))
                            .foregroundStyle(Chrome.primaryText.opacity(0.9))
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: Chrome.localized(title))
                .font(.ui(.footnote, weight: .medium))
                .foregroundStyle(Chrome.secondaryText)
            content()
        }
    }
}

/// One mark in the picker's grid: a tile that fills as the pointer crosses it and wears the
/// accent ring when it is the project's mark.
private struct IconTile<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            content()
                .frame(width: 26, height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Chrome.overlay(isHovering || isSelected ? 0.14 : 0))
                }
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Chrome.accent, lineWidth: 1.5)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
    }
}
