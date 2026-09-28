/*
 * 全局常量：域名、接口路径、断点、日志域
 */

/** hilog 域与标签 */
export const LOG_DOMAIN: number = 0x1024;
export const LOG_TAG: string = 'SdjzuJw';

/**
 * 教务系统基地址（山东建筑大学）。
 *
 * ===== 必须用 https（踩过，别改回 http）=====
 * 服务器 http / https **两个端口都通**（都返回 200），但登录成功后的
 * 302 目标是 **https** 的 `xsMain.htmlx`：
 *
 *   http 提交登录 → 302 Location: https://…/xsMain.htmlx
 *   → 客户端跟随这条**跨协议**重定向 → 拿回来的是登录页（16002 字节）
 *   → 判定「登录未建立会话」→ 界面报错，而**会话其实已经建立**
 *     （用户退出再进，反而发现已经登上去了）。
 *
 * 全程 https 时实测正常：登录 + 课表 + 成绩 + 个人信息 + 空教室
 * 五个接口全部 200。因此这里统一 https，不做协议切换。
 */
export const BASE_ORIGIN: string = 'https://xjwgl.sdjzu.edu.cn';

/**
 * 登录相关。
 *
 * ===== 与山财（移植源）完全不同，别照搬 =====
 *   · 山建**没有** /Logon.do 那套握手 + 按位插字符的流程；
 *   · 验证码路径必须带 `/jsxsd` 前缀 —— 不带时服务器发的 Cookie 是
 *     `Path=/`，而登录接口在 `/jsxsd` 下收不到它，症状是「验证码永远错误」；
 *   · 登录页要先取一次，才能建立会话去拿验证码。
 */
export const PATH_LOGIN_PAGE: string = '/jsxsd/';
export const PATH_CAPTCHA: string = '/jsxsd/verifycode.servlet';
export const PATH_LOGON: string = '/jsxsd/xk/LoginToXk';
export const PATH_LOGOUT: string = '/jsxsd/logout';
export const PATH_MAIN: string = '/jsxsd/framework/xsMain.htmlx';

/** 业务页面 */
export const PATH_TIMETABLE: string = '/jsxsd/xskb/xskb_list.do';
export const PATH_SCORE_LIST: string = '/jsxsd/kscj/cjcx_list';
/**
 * 成绩查询页 —— **学期下拉的来源**（与列表页不是同一个地址）。
 *
 * `cjcx_frm` 只是个外壳（内嵌两个 iframe，自己没有下拉），
 * `kksj` 下拉在 `cjcx_query` 里。用错地址的症状是学期选择器只有
 * 「全部学期」一项，且不报任何错。
 */
export const PATH_SCORE_QUERY: string = '/jsxsd/kscj/cjcx_query';
/**
 * 个人信息。
 *
 * 山建没有「学籍卡片」页（`/grxx/xsxx` 返回非法访问），
 * 改走「毕业生信息核对」`/bygl/bysxx` —— 内容是只读的学籍基本信息
 * （院系/专业/班级/层次/学制/性别/证件号/学号/姓名），非毕业年级同样可访问。
 */
export const PATH_PROFILE: string = '/jsxsd/bygl/bysxx';
export const PATH_WEEK_CALENDAR: string = '/jsxsd/jxzl/jxzl_query';
/** 培养方案明细（与「修读情况」合并为一页，见 pages/PlanPage.ets） */
export const PATH_PLAN_DETAIL: string = '/jsxsd/pyfa/topyfamx';
/** 修读情况（山建叫「学习完成情况查看」）—— 合并页的第二个数据源 */
export const PATH_ELECTIVE: string = '/jsxsd/xxwcqk/xxwcqkOnkctxBy.do';

/**
 * 通选大类**详情**页 —— 课程明细的来源（GET 参数 `kctxmc=<大类名>`）。
 *
 * 通选主页是单表，只有各专业的学分统计；每行的「详情」是页面里
 * `window.open('/jsxsd/xxwcqk/xxwcqkOnkctxByxq.do?kctxmc=…')`。
 * 该地址可直接 GET（实测会话与 Referer 都无特殊要求），
 * 返回 8 列的课程表 —— 大类标题的下拉展开就靠它。
 */
export const PATH_ELECTIVE_DETAIL: string = '/jsxsd/xxwcqk/xxwcqkOnkctxByxq.do';

/**
 * 用户自录的「通选课各大类要求学分」。
 *
 * 学校页面的「要求学分（大于等于）」一列是空的，用户可按培养方案自行录入，
 * 见 ElectiveRequirementStore。按账号分片存储。
 */
export const KEY_ELECTIVE_REQUIRED: string = 'elective_required';

/** 空闲教室：筛选器页面（校区/学期下拉的来源） */
export const PATH_CLASSROOM: string = '/jsxsd/kbxx/jsjy_query';
/** 空闲教室查询结果（POST，参数见 QzApi.queryClassroom） */
export const PATH_CLASSROOM_QUERY: string = '/jsxsd/kbxx/jsjy_query2';
/**
 * 校区/教学区/教学楼/教室的**联动下拉**（返回 JSON）。
 *
 * `requestType` 取 `jxq`（教学区）/`jxl`（教学楼）/`js`（教室）。
 * ⚠️ 山建这道门是**关着的**：无论怎么组合请求头（裸请求 / X-Requested-With /
 * jQuery 的 JSON Accept / 带发起页 Referer / 去掉 Origin），一律返回
 * 736 字节的「提示：非法访问！」。因此楼栋筛选改在客户端做（从教室名推导），
 * 这个常量只为别校/未来复用保留。
 */
export const PATH_CLASSROOM_AJAX: string = '/jsxsd/kbxx/jsjy_processAjax';

/**
 * 「默认节次模式」的 id —— 教室查询的 `kbjcmsid` 参数。
 *
 * 取自页面下拉的默认项（换成「考试节次」会是另一个 id）。
 * 少带它会直接被服务端拒绝（提示「请选择时间模式」）。
 */
export const DEFAULT_SECTION_MODE_ID: string = '6CFDEBADC0D341D885CB8F8970F7528C';

/** 响应式断点（vp） */
export const BP_MEDIUM: number = 600;
export const BP_LARGE: number = 840;

/** 请求超时（ms） */
export const HTTP_CONNECT_TIMEOUT: number = 10000;
export const HTTP_READ_TIMEOUT: number = 15000;

/**
 * 节次定义：与教务课表行一一对应（山建是 5 个大节）。
 *
 * 时刻取自**课表页本身** —— 山建课表的节次行首格自带起止时刻
 * （形如「第一大节 (01,02小节) 07:50-09:25」），
 * 教务处官网只发校历 PDF、没有独立作息页。
 * 课表页解析出真值后会自动覆盖这里（见 SectionTimeStore），
 * 下面的值是取不到时的兜底，与 data/AcademicCalendar.ets 保持一致；
 * 用户仍可在设置里按实际作息调整（存 preferences）。
 */
export interface SectionDef {
  index: number;
  label: string;
  start: string;
  end: string;
}

export const SECTIONS: SectionDef[] = [
  { index: 0, label: '第一大节', start: '07:50', end: '09:25' },
  { index: 1, label: '第二大节', start: '09:40', end: '12:05' },
  { index: 2, label: '第三大节', start: '13:40', end: '15:15' },
  { index: 3, label: '第四大节', start: '15:30', end: '17:05' },
  { index: 4, label: '第五大节', start: '18:40', end: '21:05' }
];

/**
 * 课表表头（星期 + 日期）高度（vp）。
 *
 * 固定值、不参与均分：表头只有两行短文本，高度是已知量。抽成常量是因为
 * 它有**两个必须一致的用处** —— 渲染时的 height，以及 [fitRowHeight] 里
 * 「可用高度先减掉表头」这一步。两边各写各的字面量时，改一处漏一处就会
 * 让整周差出一整行的高度。
 */
export const GRID_HEADER_H: number = 46;

/** 单行课的最小高度（vp）：屏幕再矮也不压到这个值以下，否则文字无法阅读 */
export const GRID_MIN_ROW_H: number = 20;

/**
 * 单行课的最大高度（vp）：屏幕再高也不让一行占掉半屏。
 *
 * 上限只在**极端高窗口**（如自由窗口拉到很高）时生效，那时整周不铺满、
 * 底部留白 —— 这是有意的：把每一行都拉到 400vp 只会让课表显得松散。
 */
export const GRID_MAX_ROW_H: number = 420;

/**
 * 把「网格实测可用高度」等分成行高 —— 「任何屏幕比例都一页装下整周」的
 * 数学保证就在这里。
 *
 * ===== 为什么要做成纯函数（而不是留在页面里）=====
 * 这是整个适配里唯一**可以被证明**的部分：只要
 * `表头 + 行数 × 行高 ≤ 实测高度`，整周就装得下，不存在「某种比例下
 * 溢出」的可能。把它抽出来是为了让测试能直接对这条不变式断言
 * （见 testdata/run-tests.mjs），而不是靠改完去设备上一屏屏试。
 *
 * 早先的做法是「按窗口高度乘一个比例估行高」，那是在猜可用高度 ——
 * 可用高度由顶栏 + 筛选栏 + 备注 + dock 让位 + 安全区共同决定，
 * 其中好几项随窗口比例变，没有任何系数能对所有比例都对。
 */
export function fitRowHeight(availH: number): number {
  const rows: number = SECTIONS.length;
  const each: number = (availH - GRID_HEADER_H) / rows;
  if (isNaN(each) || each < GRID_MIN_ROW_H) {
    return GRID_MIN_ROW_H;
  }
  return each > GRID_MAX_ROW_H ? GRID_MAX_ROW_H : each;
}

/**
 * 节次名的**统一显示写法**：`第一大节` → `第一节`。
 *
 * ===== 为什么需要它（同一个概念在三处三种叫法）=====
 * 数据里存的是「第一大节」，而三个页面各自处理：
 *   · 课表左侧列：`label.replace('第','').replace('节','')` → 「一大」
 *     （末尾那个「大」没被去掉）；
 *   · 设置页摘要：「第1大节」；
 *   · 空教室筛选：「第一大节」。
 * 用户看到的是同一件事被叫了三个名字。这里统一成「第一节」——
 * 课表左侧列最窄，这个写法也最短。
 *
 * 自定义节次名（设置页允许改）原样返回：只有「纯序数」才改写，
 * 否则「早自习」会被套成「第早自习节」。
 */
export function shortSectionLabel(label: string): string {
  const raw: string = label.trim();
  let t: string = raw;
  if (t.indexOf('第') === 0) {
    t = t.substring(1);
  }
  t = t.replace('大节', '').replace('节', '').trim();
  // 纯序数才改写：中文数字（一…十二）或阿拉伯数字
  if (t.length === 0 || !/^[一二三四五六七八九十0-9]{1,3}$/.test(t)) {
    return raw;
  }
  return '第' + t + '节';
}

/** 星期标签 */
export const WEEKDAY_LABELS: string[] = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];

/** preferences 存储键 */
export const PREF_STORE: string = 'sdjzu_jw_pref';
export const KEY_COOKIE: string = 'session_cookie';
export const KEY_ACCOUNT: string = 'remembered_account';
export const KEY_REMEMBER: string = 'remember_account';
export const KEY_LAST_SEMESTER: string = 'last_semester';
export const KEY_THEME: string = 'theme_mode';
/** 学期第 1 周周一的日期，格式 YYYY-MM-DD，由用户在设置里填写 */
export const KEY_SEMESTER_START: string = 'semester_start_monday';
/** 上次与系统时间对齐周次的时刻（毫秒时间戳） */
export const KEY_WEEK_ALIGN_AT: string = 'week_align_at';
/** 上次对齐得到的周次 */
export const KEY_WEEK_ALIGN_VALUE: string = 'week_align_value';
/** 上次选择周次（课表），空串表示「全部」 */
export const KEY_LAST_WEEK: string = 'last_timetable_week';
/** 上次选择成绩学期 */
export const KEY_LAST_SCORE_SEMESTER: string = 'last_score_semester';
/**
 * 桌面卡片的数据快照。
 *
 * 定义在这里而不是 CardSnapshotStore 里，是为了让 AppState 在「退出登录清理」
 * 时能直接引用它 —— CardSnapshotStore 反过来引用了 AppState，
 * 若把键留在那边就会形成循环依赖。
 */
export const KEY_CARD_SNAPSHOT: string = 'card_snapshot';

/**
 * 桌面卡片的**周级载荷**。
 *
 * 与 card_snapshot 的区别：那份是「写入那一刻算好的今天」，
 * 卡片只能重画；这份是整周课表，卡片自己按当前时间算今天，
 * 因此跨天自愈、`done` 与「下一节」会随时间变化。
 * 见 CardSnapshotStore 的类注释。
 */
export const KEY_CARD_WEEK: string = 'card_week';
/**
 * 已添加的桌面卡片 id 列表（逗号分隔）。
 *
 * 为什么必须存：卡片要能被**主动刷新**，就必须知道 formId。
 * `onAddForm` 的 want 里带着 formId，而 `formProvider.updateForm(formId, …)`
 * 是唯一能把新数据推给已经渲染着的卡片的手段 —— 没有它，
 * 主应用改了快照也只是改了磁盘，卡片会一直显示旧内容，
 * 直到系统按周期（本应用是约 60 分钟）调用 onUpdateForm，
 * 用户表现为「加了课卡片不变，得删掉重加」。
 * SDK 文档也明确要求把 onAddForm 里的表单信息「作为持久化数据管理，供后续更新与删除使用」。
 */
export const KEY_CARD_FORM_IDS: string = 'card_form_ids';

/** 上课提醒相关 */
export const KEY_SECTION_TIMES: string = 'section_times';
/**
 * 作息是否被**用户手动改过**（'1' = 改过，其它 = 跟随官方）。
 *
 * ===== 为什么必须存「来源」而不是比字符串 =====
 * 课表页解析出的作息会自动覆盖本地值（见 SectionTimeStore.saveOfficial）。
 * 若拿存储值与包内常量逐项比对来判断「是否自定义」，那么自动同步一次之后
 * 两者就不再相等，此后被判成「用户自定义」而**再也不跟随官方** ——
 * 而用户从没改过任何东西。因此只认这个显式的来源标记：
 * 只有用户在设置页点保存时才置位。与 Flutter 端 kKeySectionTimesCustom 同值。
 */
export const KEY_SECTION_TIMES_CUSTOM: string = 'section_times_custom';
export const KEY_REMINDER_ON: string = 'reminder_enabled';
export const KEY_REMINDER_ADVANCE: string = 'reminder_advance_min';
export const KEY_REMINDER_RING: string = 'reminder_ring_sec';
export const KEY_REMINDER_SNOOZE_TIMES: string = 'reminder_snooze_times';
export const KEY_REMINDER_SNOOZE_INTERVAL: string = 'reminder_snooze_interval';
/** 是否把课表写入系统日历 */
/** 已写入系统日历的事件 id（按课程实例聚合，便于整体清理） */
/** 已写入系统日历时所用的课表指纹，用于判断是否需要重建 */

/** 应用包名，供代理提醒的点击跳转、桌面卡片等使用 */
export const APP_BUNDLE_NAME: string = 'com.sdjzu.hijianzhu';

/** 桌面卡片 */
export const FORM_NAME_TODAY: string = 'todayCourseCard';

/**
 * 校历缓存。
 * 抓取成功才写；离线时读这里，再退回内置数据（见 AcademicCalendar）。
 *
 * 作息（KEY_CAMPUS_SECTIONS）来自**课表页**解析 —— 教务处不公开作息表；
 * 附件（KEY_CAMPUS_IMAGES / KEY_CAMPUS_IMAGE_URLS）是**用户填写的**
 * 校历公告页里挂的 PDF / 图片，键名沿用旧版与 Flutter 端，未随语义改名。
 */
export const KEY_CAMPUS_SECTIONS: string = 'campus_sections';
export const KEY_CAMPUS_IMAGES: string = 'campus_images';
export const KEY_CAMPUS_IMAGE_URLS: string = 'campus_image_urls';
export const KEY_CAMPUS_UPDATED: string = 'campus_updated';
export const KEY_CAMPUS_FETCHED_AT: string = 'campus_fetched_at';
/** 校历附件在 filesDir 下的子目录名 */
export const CAMPUS_DIR: string = 'campus';

/**
 * 用户填写的**校历公告页地址**（空串 = 还没填）。
 *
 * ===== 为什么是用户填而不是内置 =====
 * 本校教务处的校历是**按年份发的公告**（「山东建筑大学 2026 年校历」），
 * 地址里带内容 id（`info/1024/3232.htm` 这类），**每年都不一样**，
 * 且挂的是 PDF 而非图片。内置一个「当前年份」的地址，换年就静默失效 ——
 * 而界面上看不出来，属于最危险的那类失败。改成用户填写后：
 *   - 应用不假设任何具体网址，不会因学校改版或跨年而失效；
 *   - 用户自己知道要看哪一年，也知道去哪里找（设置页给了引导入口）。
 * 与 Flutter 端 kKeyCalendarUrl 同值，两端偏好可互相沿用。
 */
export const KEY_CALENDAR_URL: string = 'calendar_page_url';

/**
 * 周次与系统时间的对齐间隔：6 小时。
 * 超过该间隔后再次进入应用会重新计算周次，保证跨周/跨天时能自动跟上。
 */
export const WEEK_ALIGN_INTERVAL_MS: number = 6 * 60 * 60 * 1000;

/** 一天毫秒数 */
export const DAY_MS: number = 24 * 60 * 60 * 1000;

/** 一学期最多周数（用于校验与下拉） */
export const MAX_WEEKS: number = 30;

/**
 * AppStorage 键集中定义在这里。
 * 原因：这些键被多个模块共享（AppState / QzApi / 各页面），
 * 若定义在 AppState 里，QzApi 引用时就会与 AppState 形成循环依赖。
 */
export const AS_LOGGED_IN: string = 'loggedIn';
export const AS_STUDENT_NAME: string = 'studentName';
export const AS_STUDENT_ID: string = 'studentId';

/**
 * 「已经取到过姓名的是哪个账号」（空串 = 还没取到过）。
 *
 * 用**账号**而不是布尔量：换账号后必然要重取；布尔量换账号后仍是 true，
 * 姓名（显示在外壳上）就再也不更新了。
 *
 * 放 AppStorage 而不是 ProfileService 的静态字段里：AppState 登出清理时
 * 必须把它一并清掉 —— 否则同一账号再次登录时会被判成「已取过」而跳过预取，
 * 外壳上的姓名一直空着。而 ProfileService 反过来依赖 AppState（要读账号、
 * 要取 api 实例），AppState 直接引用 ProfileService 会形成循环 import。
 * 与 AS_REAUTH_PENDING 同一手法：共享值放这里，两边各自读写。
 */
export const AS_PROFILE_LOADED_FOR: string = 'profileLoadedFor';
export const AS_CURRENT_WEEK: string = 'currentWeekNo';
export const AS_SEMESTER_START: string = 'semesterStartMonday';
export const AS_WEEK_CONFIGURED: string = 'weekConfigured';
export const AS_WINDOW_WIDTH: string = 'windowWidth';
export const AS_BREAKPOINT: string = 'breakpoint';

/**
 * 是否已保存过账号密码（凭据在系统密钥库里）。
 *
 * 缓存在 AppStorage 里的原因：QzApi 判断「会话失效后该弹重新验证还是彻底退出」
 * 时是同步上下文，没法 await 去查密钥库。启动时由 AppState.restoreSession
 * 读一次写进来，登录成功/取消记住时同步更新。
 */
export const AS_HAS_CREDENTIAL: string = 'hasStoredCredential';
/** 是否正在等待用户重新验证（会话失效且已有凭据）。界面据此弹验证码弹窗。 */
export const AS_REAUTH_PENDING: string = 'reauthPending';
/**
 * 会话保活：最近一次保活成功的时间戳（毫秒），0 表示本次启动尚未成功过。
 * 设置页据此显示「上次保活」状态。
 */
/** 会话保活：最近一次保活的结果描述（供设置页显示，含失败原因） */

/** 会话保活：开关（默认开启） */
/** 会话保活：最近一次成功时间戳落盘，重启后设置页仍能显示 */

/**
 * 底部 dock 浮层占用的高度（vp），0 表示当前布局没有底部 dock。
 *
 * 为什么需要这个值：dock 现在是**浮在内容之上**的玻璃胶囊（内容从它下面滚过，
 * 这样玻璃中心透明才能看到被遮挡的内容）。代价是滚动到底时最后一行会压在
 * dock 下面，因此页面滚动内容必须留出这么高的底部空白。
 *
 * 为什么走 AppStorage 而不是各页面写死常量：平板（宽屏）布局用左侧导航栏，
 * 底部没有 dock，多留这段空白只会浪费屏幕。由 Index 按当前布局写入，
 * 页面订阅后可在折叠屏展开/折叠时自动适配。
 */
export const AS_BOTTOM_INSET: string = 'bottomInset';

/**
 * 窗口高度（vp）。顶部渐糊的区间要按「顶栏高度 / 窗口高度」换算，
 * 因此需要真实高度值（与 AS_WINDOW_WIDTH 配对）。
 */
export const AS_WINDOW_HEIGHT: string = 'windowHeight';

// ==================== 页面缓存 ====================
//
// 见 data/PageCache.ets。这里只放「缓存标识」与「新鲜期」。
// 与 Flutter 端 common/constants.dart 的 kCache* / kTtl* 一一对应，
// 两端的过期策略保持一致 —— 改一边就要改另一边。

/** 缓存标识：页面名（参与缓存 key，不要随意改名，否则旧缓存会失配） */
export const CACHE_SCORE_LIST: string = 'score_list';
export const CACHE_SCORE_SEMESTERS: string = 'score_semesters';
export const CACHE_PLAN: string = 'plan';
export const CACHE_ELECTIVE: string = 'elective';
export const CACHE_PROFILE: string = 'profile';
export const CACHE_CLASSROOM_OPTIONS: string = 'classroom_options';
export const CACHE_CLASSROOM_BUILDINGS: string = 'classroom_buildings';
export const CACHE_CLASSROOM_USAGE: string = 'classroom_usage';
export const CACHE_SEMESTER_CALENDAR: string = 'semester_calendar';
export const CACHE_SEMESTER_LIST: string = 'semester_list';

/**
 * 新鲜期（毫秒）。
 *
 * 判据：数据多久变一次 vs 重复请求的代价。
 *   成绩：出分时段学生反复刷 → 2 分钟
 *   空教室占用：反映「此刻哪间空着」→ 2 分钟
 *   修读进度：变动不频繁 → 10 分钟
 *   培养方案/个人信息/校历/静态配置：一学期甚至一年才变 → 6 小时
 *
 * 宁可偏保守（短）：实机观察后可调，而调长的风险只是多几次请求，
 * 调太长才会让用户看到过期数据。
 */
export const TTL_SCORE_LIST: number = 2 * 60 * 1000;
export const TTL_SCORE_SEMESTERS: number = 6 * 60 * 60 * 1000;
export const TTL_ELECTIVE: number = 10 * 60 * 1000;
export const TTL_PLAN: number = 6 * 60 * 60 * 1000;
export const TTL_PROFILE: number = 6 * 60 * 60 * 1000;
export const TTL_CLASSROOM_OPTIONS: number = 6 * 60 * 60 * 1000;
export const TTL_CLASSROOM_BUILDINGS: number = 6 * 60 * 60 * 1000;
export const TTL_CLASSROOM_USAGE: number = 2 * 60 * 1000;
export const TTL_SEMESTER_CALENDAR: number = 6 * 60 * 60 * 1000;
export const TTL_SEMESTER_LIST: number = 6 * 60 * 60 * 1000;

/**
 * 上次「因系统时间已超出周历而自动拉取」的日期（`yyyy-MM-dd`）。
 *
 * 用于把这种自动拉取限制为**每天一次**：触发条件（今天晚于周历最后一周）
 * 在放假期间持续成立，不限制就会每次启动/每次打开校历都联网。
 */
export const KEY_SEMESTER_AUTO_FETCH_DAY: string = 'semester_auto_fetch_day';
