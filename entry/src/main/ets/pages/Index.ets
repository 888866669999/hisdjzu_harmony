/*
 * 应用根页面：响应式外壳
 *
 * - 未登录：登录页
 * - 已登录：
 *     sm（手机，<600vp）：底部标签栏 + 单页内容
 *     md/lg（平板、折叠屏展开，>=600vp）：左侧导航 + 右侧内容的主从分栏
 *   断点变化（折叠屏展开/折叠）时实时切换布局。
 */
import { window, KeyboardAvoidMode } from '@kit.ArkUI';
import { AppState } from '../data/AppState';
import { ChoiceItem } from '../model/Models';
import { WeekService } from '../data/WeekService';
import { SemesterCalendarService } from '../data/SemesterCalendarService';
import { ReminderService } from '../data/ReminderService';
import { ContextHolder } from '../common/ContextHolder';
import { WindowService, Bp } from '../common/WindowService';
import { Theme } from '../theme/Theme';
import { GlassKit } from '../theme/GlassKit';
import { LoginPage } from './LoginPage';
import { SchedulePage } from './SchedulePage';
import { ScorePage } from './ScorePage';
import { PlanPage } from './PlanPage';
import { ElectivePage } from './ElectivePage';
import { ClassroomPage } from './ClassroomPage';
import { ProfilePage } from './ProfilePage';
import { SettingsPage } from './SettingsPage';
import { ReAuthDialog } from '../components/ReAuthDialog';
import { GlassOverlay } from '../components/GlassOverlay';
import { ReAuthService } from '../data/ReAuthService';
import { ProfileService } from '../data/ProfileService';
import { PrefStore } from '../data/PrefStore';
import { AppIcon } from '../components/AppIcon';
import { Logger } from '../common/Logger';
import { AS_LOGGED_IN, AS_STUDENT_NAME, AS_STUDENT_ID } from '../data/AppState';
import { AS_REAUTH_PENDING, AS_WINDOW_WIDTH, AS_WINDOW_HEIGHT, AS_BOTTOM_INSET, KEY_LAST_SEMESTER } from '../common/Constants';
import { StudentProfile } from '../model/Models';

/**
 * 底部 dock 的高度（vp）。
 *
 * 三处必须用同一个值，否则会出现「玻璃和图标不一样高」「最后一行被遮住」：
 *   1. dock 玻璃胶囊的高度（下面 dockBar 的 Row）
 *   2. 内容区底部让位的 padding（publishBottomInset）
 *   3. 浮层避让 dock 时用的那个值（GlassOverlay 读 Theme.bottomInset()）
 */
const DOCK_HEIGHT: number = 56;

/**
 * 宽屏侧边栏宽度（vp）。
 *
 * 必须是常量而不是 '100%'：顶栏与内容的分栏按它计算，侧栏自身也要靠它
 * 与内容区对齐（改这里就要同步改布局里的宽度，否则侧栏会与内容错位）。
 */
const SIDEBAR_W: number = 200;

/**
 * dock 四周留出的空隙（vp）。
 *
 * ===== 为什么是这个值（历史）=====
 * 旧版用第三方库 AppleUI 的透镜时，它会把画布向四周外扩 30vp 去截取背景，
 * 玻璃离父层边缘不足 30vp 时截帧越界、**静默不渲染**（真机日志
 * `Snapshot reigon out of range` → `snapshot fail 401`），因此左右边距与
 * 底部留白都被迫 ≥ 30。该库已移除（改为系统沉浸材质 + 磨砂降级），
 * 这条硬约束不再存在，但**这四个数保持原值**：dock 的尺寸是既有观感，
 * 顺手改会牵动页面底部让位与浮层避让。
 */
const DOCK_PAD: number = 30;
/** 左右边距：在 DOCK_PAD 基础上再多一点，让胶囊不贴边、更像浮层 */
const DOCK_MARGIN: number = DOCK_PAD + 4;
/** 底部留白：dock 与屏幕下沿之间的距离 */
const DOCK_BOTTOM: number = DOCK_PAD + 6;

/** 导航项 */
class NavItem {
  key: string;
  label: string;
  icon: string;

  constructor(key: string, label: string, icon: string) {
    this.key = key;
    this.label = label;
    this.icon = icon;
  }
}

@Entry
@Component
struct Index {
  @StorageProp('breakpoint') @Watch('publishBottomInset') bp: number = Bp.SM;
  @StorageProp(AS_LOGGED_IN) @Watch('publishBottomInset') loggedIn: boolean = false;
  @StorageProp(AS_STUDENT_NAME) studentName: string = '';
  /**
   * 窗口宽度（vp）。dock 是浮层，宽度要按窗口实算 ——
   * 用 '100%' 会贴到屏幕两边，浮层感就没了（左右要留 DOCK_MARGIN）。
   */
  @StorageProp(AS_WINDOW_WIDTH) winWidth: number = 360;
  /**
   * 窗口高度（vp）。顶部渐糊的区间要按它换算成比例
   * （fractionStops 是相对组件高度归一化的，见 topBlurStops）。
   */
  @StorageProp(AS_WINDOW_HEIGHT) winHeight: number = 800;
  /**
   * 系统沉浸材质是否已就绪（见 GlassKit.ensureMaterial）。
   *
   * @State 而不是现查：探测是异步的（老系统上模块不存在，只能动态加载），
   * 回来时赋值触发一次重建，dock 从磨砂底换成系统材质。在此之前用降级外观。
   */
  @State materialOn: boolean = false;

  /** 会话失效且已保存凭据时置位，界面弹出「重新验证」弹窗 */
  @StorageProp(AS_REAUTH_PENDING) reauthPending: boolean = false;
  @State active: string = 'schedule';
  @State restoring: boolean = true;

  // 图标用 media/ 下的 Material svg 资源（与 Flutter 版 Icons.*_outlined 同源）。
  // 原先用 emoji：无法着色、跟不了主题与选中态，不同设备字形也不一致。
  //
  // 导航项与 Flutter 端 `kNavItems` 逐项对齐（课表/成绩/培养/我的）。
  // 两项刻意不在其中：
  //   · 「空教室」挂在课表页顶栏 —— 看课表时最常接着问的就是「哪儿有空教室」，
  //     放在 dock 既多占一格，又与「查自己的教务数据」这几个主入口不同类；
  //   · 「通选」（修读情况）改从培养页进入 —— 它与「培养」是同一件事的两个视角，
  //     页面与路由都保留（见 content() 的 'elective' 分支），只是不占导航格。
  private navItems: NavItem[] = [
    new NavItem('schedule', '课表', 'calendar_month'),
    new NavItem('score', '成绩', 'bar_chart'),
    new NavItem('plan', '培养', 'menu_book'),
    new NavItem('profile', '我的', 'person')
  ];

  aboutToAppear(): void {
    // 键盘弹出时压缩可视区域（RESIZE），而不是整体上移（OFFSET），
    // 否则手机端登录表单的输入框会被顶出屏幕无法操作。
    try {
      this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    } catch (e) {
      // 忽略：不支持时用系统默认
    }
    // 探测系统沉浸材质（全局缓存；老系统上模块不存在，只能动态加载）。
    // 不 await：首帧按磨砂降级外观渲染，可用时再切到材质。
    this.materialOn = GlassKit.materialReady();
    GlassKit.ensureMaterial().then((ok: boolean) => {
      this.materialOn = ok;
    });
    this.bindWindow();
    this.restore();
    // 冷启动时 bp/loggedIn 不会再触发 @Watch，这里主动发布一次
    this.publishBottomInset();
  }

  /**
   * 按当前断点发布「底部让位高度」。
   *
   * 窄屏（手机）有浮层 dock，滚动内容需要留出它的高度；宽屏（平板/折叠屏展开）
   * 是左侧导航，底部没有东西，让位为 0（否则白白空掉一条）。
   * 由 bp / loggedIn 的 @Watch 驱动，折叠屏展开/折叠时自动跟随。
   */
  private publishBottomInset(): void {
    const inset: number = (this.loggedIn && this.bp === Bp.SM)
      ? DOCK_HEIGHT + DOCK_BOTTOM
      : 0;
    if (AppStorage.get<number>(AS_BOTTOM_INSET) !== inset) {
      AppStorage.setOrCreate(AS_BOTTOM_INSET, inset);
    }
  }

  private bindWindow(): void {
    const ctx = ContextHolder.get();
    if (ctx === null) {
      return;
    }
    try {
      window.getLastWindow(ctx).then((win: window.Window) => {
        WindowService.bind(win);
      }).catch(() => {
        // 忽略：无法获取窗口时用默认断点
      });
    } catch (e) {
      // 忽略
    }
  }

  private async restore(): Promise<void> {
    // 先把「是否已保存凭据」同步到 AppStorage：QzApi 判断会话失效后
    // 该弹重新验证弹窗、还是彻底退出时，需要同步读取这个标志。
    await ReAuthService.refreshCredentialFlag();
    // 冷启动时清掉上次遗留的「等待验证」标记，避免一进来就弹窗
    ReAuthService.clearPending();

    const ok: boolean = await AppState.restoreSession();
    if (ok) {
      // 乐观恢复：先进入主界面，账号信息从本地解析（不请求服务器），
      // 个人信息等数据由各页面按需加载；会话有效性已在后台静默校验。
      await AppState.resolveAccount();
      // 姓名显示在**外壳**上（侧栏标题下、内容页顶栏右侧），而它原先只有
      // 「我的」页会往 AppStorage 里写 —— 冷启动后不点进那一页就一直是空的
      // （用户反馈的 bug）。这里在恢复会话后立刻补一次：只读缓存、零请求；
      // 缓存里没有的由续期之后那次允许联网的调用补上（见 trySilentRenewal）。
      await ProfileService.ensureIdentity(false);
    }
    // 会话恢复完成后对齐一次周次（AppStorage 中已有值，无 6h 内不重算）
    try {
      await WeekService.align(false);
    } catch (e) {
      // 忽略
    }
    this.restoring = false;

    // 进入界面后，在后台尝试一次「无感续期」：
    // 若会话已失效且设备支持 OCR，就自动识别验证码静默登录，用户完全察觉不到。
    //
    // 注意这里**只做静默尝试，绝不弹窗**：按需求，用户若只是看课表
    // （数据来自本地缓存、不需要联网），无论会话是否失效都不应被打扰；
    // 只有当他真正用到需要联网的功能、请求被打回登录页时，
    // 才由 QzApi.ensureAuthed 置位并弹出重新验证弹窗。
    if (ok) {
      this.trySilentRenewal();
      // 开学日期为空时用教学周历补上（见下方说明）
      this.deriveSemesterStartIfMissing().then(() => {
        // 滚一次提醒窗口（见 rescheduleSilently 的说明）。
        // 放在补开学日期**之后** —— 没有开学日期就算不出该提醒哪一天。
        ReminderService.rescheduleSilently();
      });
    }
  }

  /**
   * 开学日期为空时，用教务系统的教学周历补上。
   *
   * ===== 为什么必须做（漏掉时整条功能链都用不了）=====
   * 周次显示、上课提醒、桌面卡片**全都依赖开学日期**，而它只能靠用户手动设置。
   * 首次安装（或换了新学期）时它为空，于是：
   *   · 课表页标不出「当前周」，日期栏是空的，提示「未设置开学日期」；
   *   · 打开上课提醒会直接失败：「请先在『学期与周次』里设置开学日期」；
   *   · 卡片算不出「今天第几周」。
   *
   * 权威值本来就在教务系统的周历里（学校排课时录入），取一次即可 ——
   * 不该让用户自己去查校历再手填。
   *
   * 早先只有打开「校历」弹窗时才会补（那是 SemesterCalendarService 的
   * 唯一调用方），所以不点校历的用户永远卡在上面那三种状态里。
   *
   * 失败静默：断网时什么都不做，界面与以前一致。
   */
  private async deriveSemesterStartIfMissing(): Promise<void> {
    try {
      if (WeekService.isConfigured()) {
        return;
      }
      // 优先用课表里带的学期（更贴合用户当前看的那个），
      // 课表还没加载过则退回上次用过的学期
      let code: string = '';
      if (AppState.timetable !== null) {
        code = AppState.timetable.semester;
      }
      if (code.length === 0) {
        code = await PrefStore.getText(KEY_LAST_SEMESTER);
      }
      if (code.length === 0) {
        // 两个都没有（全新安装、还没进过课表）→ 取服务端给的当前学期
        const sems: ChoiceItem[] = await SemesterCalendarService.semesters(false);
        if (sems.length === 0) {
          return;
        }
        code = sems[0].value;
      }
      await SemesterCalendarService.load(code, false);
    } catch (e) {
      // 补不上不影响任何主流程（用户仍可手动设置）
      Logger.warn('derive semester start failed: ' + e);
    }
  }

  /**
   * 后台静默续期。刻意不设置任何 UI 状态：
   * 成功就顺手刷新当前页，失败就什么都不做 —— 真正的兜底是
   * 「用户点开需要联网的功能 → 请求失败 → 弹出验证码弹窗」。
   *
   * 续期之后（会话此时一定可用）再补一次姓名/学号：启动时那次只看缓存
   * （见 restore），缓存里没有就靠这里联网取。放在续期之后，
   * 避免会话刚失效时白打一次请求。
   */
  private async trySilentRenewal(): Promise<void> {
    try {
      await this.renewIfExpired();
    } catch (e) {
      Logger.warn('silent renewal error');
    }
    await ProfileService.prefetchOnce();
  }

  /** 真正判断要不要续期；异常交给 trySilentRenewal 统一收口 */
  private async renewIfExpired(): Promise<void> {
    const alive: boolean = await AppState.apiInstance().isSessionAlive();
    if (alive) {
      return;
    }
    if (!ReAuthService.ocrAvailable()) {
      Logger.info('silent renewal skipped: no OCR capability');
      return;
    }
    Logger.info('silent renewal attempt with OCR');
    const out = await ReAuthService.tryAutoLogin();
    if (out.ok) {
      Logger.info('silent renewal succeeded');
      this.reloadCurrentPage();
    } else {
      Logger.info('silent renewal failed: ' + out.reason);
    }
  }

  private titleOf(): string {
    if (this.active === 'settings') {
      return '设置';
    }
    for (let i = 0; i < this.navItems.length; i++) {
      if (this.navItems[i].key === this.active) {
        return this.navItems[i].label;
      }
    }
    return 'hi山建';
  }

  @Builder
  content() {
    if (this.active === 'schedule') {
      SchedulePage({
        // 顶栏的空教室入口由外壳提供导航（页面自己不知道导航结构）
        onOpenClassroom: () => {
          this.active = 'classroom';
        }
      })
    } else if (this.active === 'score') {
      ScorePage()
    } else if (this.active === 'plan') {
      PlanPage()
    } else if (this.active === 'elective') {
      ElectivePage()
    } else if (this.active === 'classroom') {
      ClassroomPage()
    } else if (this.active === 'profile') {
      ProfilePage()
    } else {
      SettingsPage()
    }
  }

  /**
   * 手机：底部标签栏（浮在内容之上的玻璃胶囊）
   *
   * ===== 底的实现（两条路径，按设备能力二选一）=====
   * 有系统沉浸材质（API ≥ 26）时用 `systemMaterial`：THIN 档 + 极淡底色
   * （GlassKit.dockMaterial），厚度最小、中心尽量透 —— 内容从下面滚过时
   * 能看清被遮住的是什么，这正是 dock 做成浮层而不是一条实心栏的原因。
   * 没有材质时退回 `dockEffect()` 磨砂 + 一条高光细边 + 投影。
   *
   * `systemMaterial` 属性本身是 @since 26，**老系统上不能调用它**（连传
   * undefined 都不行），所以两条路径必须写成 if/else 分支：条件为假时那一行
   * 根本不执行（见 GlassKit 文件头的能力探测说明）。
   *
   * ===== dock 与内容是同一个 Stack 的兄弟 =====
   * dock 作为后画的兄弟叠在内容之上；内容占满整屏并从玻璃下面滚过，
   * 底部让位由各页面订阅 AS_BOTTOM_INSET 处理（见 publishBottomInset）。
   */
  @Builder
  dockBar() {
    if (this.materialOn) {
      Row() {
        this.dockTabs()
      }
      .width(Math.max(1, this.winWidth - DOCK_MARGIN * 2))
      .height(DOCK_HEIGHT)
      .borderRadius(DOCK_HEIGHT / 2)
      // 只给材质，**不再叠背景色/边框/投影**：SDK 明确建议 systemMaterial 不要与
      // 这几个属性同用（低算力设备上材质本身就是通过它们生效的，叠上去会互相打架）。
      // 材质自带模糊、厚度与阴影；极淡的底色由材质自己的 materialColor 提供
      // （见 theme/MaterialProbe 的 dockMaterial）。
      .systemMaterial(GlassKit.dockMaterial())
      .margin({ bottom: DOCK_BOTTOM })
    } else {
      Row() {
        this.dockTabs()
      }
      .width(Math.max(1, this.winWidth - DOCK_MARGIN * 2))
      .height(DOCK_HEIGHT)
      .borderRadius(DOCK_HEIGHT / 2)
      .backgroundEffect(GlassKit.dockEffect())
      // 极细高光边：磨砂底没有轮廓，暗色主题下会与背景糊在一起
      .border({ width: 0.5, color: GlassKit.FIELD_EDGE })
      .shadow(GlassKit.FLOAT_SHADOW)
      .margin({ bottom: DOCK_BOTTOM })
    }
  }

  /** dock 的标签行：图标 + 文字（底由 dockBar 提供，两者尺寸相同所以天然对齐） */
  @Builder
  dockTabs() {
    Row() {
      ForEach(this.navItems, (item: NavItem) => {
        Column({ space: 2 }) {
          AppIcon({
            res: item.icon,
            iconSize: 22,
            color: this.active === item.key
              ? $r('app.color.brand') : $r('app.color.text_secondary')
          })
          Text(item.label)
            .fontSize(Theme.FS_TINY)
            .fontColor(this.active === item.key ? $r('app.color.brand') : $r('app.color.text_secondary'))
        }
        .layoutWeight(1)
        // 显式声明水平居中：图标与文字都以此为基准对齐。
        // 之前依赖默认值，加上 AppIcon 自身尺寸不一致，
        // 结果每个图标相对文字系统性左偏（实测约 12–17px）。
        .alignItems(HorizontalAlign.Center)
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.active = item.key;
        })
      }, (item: NavItem) => item.key)

      Column({ space: 2 }) {
        AppIcon({
          res: 'settings',
          iconSize: 22,
          color: this.active === 'settings'
            ? $r('app.color.brand') : $r('app.color.text_secondary')
        })
        Text('设置')
          .fontSize(Theme.FS_TINY)
          .fontColor(this.active === 'settings' ? $r('app.color.brand') : $r('app.color.text_secondary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.active = 'settings';
      })
    }
    .width('100%')
    .height('100%')
    .padding({ left: Theme.GAP_S, right: Theme.GAP_S })
  }

  /**
   * 大屏：侧边导航。
   *
   * 侧栏铺一层磨砂（`panelEffect`），**不挂系统材质**：
   * 材质与磨砂都要看「背后是什么」才有意义，而侧栏背后是页面底色、没有内容
   * 从它下面穿过，模糊出来的是一块纯色 —— 观感与直接铺半透明底色几乎一样，
   * 却多一层合成开销。这是从旧版 AppleUI 时代延续下来的判断（当时实测侧栏
   * 没有可截取的兄弟层，玻璃一格都不画），换成系统材质后结论不变。
   * 右沿的分隔线由外层容器画（见本 builder 末尾），这里不再补高光细边 ——
   * 四条白边围一圈会像嵌在页面里的一个框，与「贴边的导航栏」不符。
   */
  @Builder
  sideBar() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundEffect(GlassKit.panelEffect())

      Column({ space: Theme.GAP_S }) {
      Column({ space: 2 }) {
        Text('hi山建')
          .fontSize(Theme.FS_SECTION)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        if (this.studentName.length > 0) {
          Text(this.studentName)
            .fontSize(Theme.FS_TINY)
            .fontColor($r('app.color.text_tertiary'))
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: Theme.GAP, top: Theme.GAP, bottom: Theme.GAP_L })

      ForEach(this.navItems, (item: NavItem) => {
        Row({ space: Theme.GAP_S }) {
          AppIcon({
            res: item.icon,
            iconSize: 18,
            color: this.active === item.key
              ? $r('app.color.brand') : $r('app.color.text_secondary')
          })
          Text(item.label)
            .fontSize(Theme.FS_BODY)
            .fontColor(this.active === item.key ? $r('app.color.brand') : $r('app.color.text_secondary'))
            .fontWeight(this.active === item.key ? FontWeight.Medium : FontWeight.Normal)
        }
        .width('100%')
        .height(44)
        .padding({ left: Theme.GAP })
        .borderRadius(Theme.RADIUS_SM)
        .backgroundColor(this.active === item.key ? $r('app.color.brand_soft') : Color.Transparent)
        .onClick(() => {
          this.active = item.key;
        })
      }, (item: NavItem) => item.key)

      Blank()

      Row({ space: Theme.GAP_S }) {
        AppIcon({
          res: 'settings',
          iconSize: 18,
          color: this.active === 'settings'
            ? $r('app.color.brand') : $r('app.color.text_secondary')
        })
        Text('设置')
          .fontSize(Theme.FS_BODY)
          .fontColor(this.active === 'settings' ? $r('app.color.brand') : $r('app.color.text_secondary'))
      }
      .width('100%')
      .height(44)
      .padding({ left: Theme.GAP })
      .borderRadius(Theme.RADIUS_SM)
      .backgroundColor(this.active === 'settings' ? $r('app.color.brand_soft') : Color.Transparent)
      .onClick(() => {
        this.active = 'settings';
      })
      }
      .width('100%')
      .height('100%')
      .padding({ left: Theme.GAP_S, right: Theme.GAP_S, bottom: Theme.GAP })
    }
    .width(SIDEBAR_W)
    .height('100%')
    .border({ width: { right: 0.5 }, color: $r('app.color.divider') })
  }

  /** 大屏下的内容页标题栏 */
  @Builder
  contentHeader() {
    Row() {
      Text(this.titleOf())
        .fontSize(Theme.FS_SECTION)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Blank()
      if (this.studentName.length > 0) {
        Text(this.studentName)
          .fontSize(Theme.FS_SMALL)
          .fontColor($r('app.color.text_tertiary'))
      }
    }
    .width('100%')
    .height(52)
    .padding({ left: Theme.GAP_L, right: Theme.GAP_L })
    // 磨砂而不是实色：内容会从它下面穿过，实色会把渐变模糊整个挡住，
    // 「越靠顶越糊」就看不出来了。这一条同时是 Flutter 端顶栏的做法。
    .backgroundEffect(GlassKit.barEffect())
    .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
  }

  /** 宽屏布局：左导航 + 右内容（顶栏浮于内容之上，其他页顶部渐糊） */
  @Builder
  wideLayout() {
    Row() {
      this.sideBar()
      // ===== 顶栏浮在内容之上 =====
      //
      // 早先是 Column{ 顶栏; 内容 }：内容被顶栏挤在下面、永远到不了顶栏区域，
      // 于是「内容从顶栏下滚过 + 顶部渐糊」这个效果根本无从谈起（没东西可糊）。
      //
      // 现在改成 Stack：内容占满、从顶栏下穿过；顶栏浮在其上。
      // 顶栏本体用 barEffect 磨砂而不是实色，穿过的内容在它后面就是「透过」的。
      Stack({ alignContent: Alignment.TopStart }) {
        Column() {
          this.content()
        }
        .width('100%')
        .height('100%')
        // 顶栏是浮层，内容必须自己让出它的高度 —— 否则各页顶部的筛选栏
        // （周次/学期/校历那一行）会被压在顶栏下面看不见。
        // 让位放在**内容容器**上而不是滚动内容里：这样它是一次性偏移，
        // 不必改动六个页面各自的滚动结构（每个页面内部都有自己的
        // 固定筛选栏 + 滚动区，逐个改风险与工作量都大得多）。
        .padding({ top: Index.HEADER_H })
        // 顶部渐糊（**课表页不做**，见 topBlurStops 的说明）。
        // 放在内容层上而不是「顶栏位置的一个空模糊层」—— 后者模糊的是一块
        // 纯色，白白多一层绘制（旧版用 AppleUI 时它还会把截帧目标弄成空白）。
        .linearGradientBlur(this.topBlurRadius(), {
          fractionStops: this.topBlurStops(),
          direction: GradientDirection.Bottom
        })

        this.contentHeader()
      }
      .layoutWeight(1)
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }

  private static readonly HEADER_H: number = 52;

  /**
   * 课表页不做顶部模糊。
   *
   * 用户明确要求。原因也说得通：课表是**整屏网格**，顶部那几行本身就是
   * 要读的内容（节次/日期），糊掉等于降低可读性；而其余页面顶部是
   * 标题栏 + 可选中的列表，糊一层只是装饰。
   */
  private topBlurRadius(): number {
    return this.active === 'schedule' ? 0 : 14;
  }

  /**
   * 顶部模糊的渐变区间：**只覆盖顶栏那一段高度**。
   *
   * ===== 为什么必须按真实高度算，不能写死比例 =====
   * fractionStops 的位置是相对**组件高度**归一化的。早先写死 0.34，
   * 在 800vp 高的窗口上等于糊掉顶部 272vp —— 远超 52vp 的顶栏，
   * 于是「划到该区域的内容才模糊」变成了「上面一大片都是糊的」。
   * 现在按 HEADER_H / 窗口高度 算出真实比例，只有顶栏那一条受影响。
   *
   * 多个 stop 是为了近似 smoothstep：SDK 只在 stop 之间线性插值，
   * 点少了会看出折线感（Flutter 端实测「24 条模糊带仍有条纹」，
   * 这里用同样的思路：一次绘制、多点近似）。
   */
  private topBlurStops(): FractionStop[] {
    const h: number = this.winHeight > 0 ? this.winHeight : 800;
    // 模糊带比顶栏略高一点（1.35 倍）：顶栏下沿留一段过渡，
    // 否则内容滚到顶栏正下方时会「啪」地一下从清晰变糊，边界很硬。
    const end: number = Math.min(0.5, (Index.HEADER_H * 1.35) / h);
    return [
      [1, 0],
      [0.94, end * 0.18],
      [0.78, end * 0.38],
      [0.55, end * 0.59],
      [0.30, end * 0.76],
      [0.10, end * 0.91],
      [0, end]
    ];
  }

  /**
   * 窄屏布局：内容 + 浮在内容之上的玻璃 dock。
   *
   * dock 是浮层而非把内容挤上去的一条栏：内容占满整屏并从玻璃下面滚过，
   * 玻璃中心足够透，于是能看到被遮挡的内容。底部让位由各页面订阅
   * AS_BOTTOM_INSET 处理。
   *
   * 只有两个子节点（内容、dock），且都是这个 Stack 的直接子节点：
   * dock 叠在内容之上，尺寸（宽 = 窗口宽 − 2×边距、高 = DOCK_HEIGHT）
   * 与内容区底部让位用的是同一组常量，所以两者永远对得上。
   */
  @Builder
  narrowLayout() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        this.content()
      }
      .width('100%')
      .height('100%')

      this.dockBar()
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 外壳底色：**成绩页刻意不铺**，其余页面铺。
   *
   * 成绩页要的是「列表之外（尤其是底部）透出下层」—— 窗口背景已在
   * EntryAbility 里设为透明，所以不铺底色就能透出桌面/壁纸。
   *
   * 其余页面必须铺：它们的内容常常不满一屏（培养方案、通识、设置等），
   * 不铺的话会直接露出桌面，看起来像渲染坏了。
   * 课表页虽然也不铺自己的底色，但网格自带 sched_bg，所以这里照铺无妨。
   */
  private pageBackground(): ResourceColor {
    if (this.loggedIn && this.active === 'score') {
      return Color.Transparent;
    }
    return $r('app.color.bg');
  }

  build() {
    Stack() {
      Column() {
        if (this.restoring) {          Column({ space: Theme.GAP }) {
            LoadingProgress()
              .width(44)
              .height(44)
              .color($r('app.color.brand'))
            Text('hi山建')
              .fontSize(Theme.FS_SMALL)
              .fontColor($r('app.color.text_tertiary'))
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor($r('app.color.bg'))
        } else if (!this.loggedIn) {
          LoginPage({
            onSuccess: () => {
              this.active = 'schedule';
            }
          })
        } else if (this.bp === Bp.SM) {
          this.narrowLayout()
        } else {
          this.wideLayout()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.pageBackground())

      /**
       * 会话失效且已保存账号密码时，用居中弹窗覆盖在当前页面上补验证码，
       * 而不是把用户踢回登录页 —— 页面与浏览位置都保持不变。
       * 验证成功后刷新当前页数据，让刚才失败的请求重来一次。
       */
      if (this.loggedIn && this.reauthPending) {
        GlassOverlay({
          panelWidthRatio: 0.86,
          panelHeightRatio: 0.62,
          maxPanelWidth: 420,
          // 不加自动关闭：这是「必须处理」的浮层，点遮罩不该让它消失
          // （用户会以为已经登录成功）。只能通过内部的取消/提交离开。
          onDismiss: () => {}
        }) {
          ReAuthDialog({
            onDone: () => {
              this.reauthPending = false;
              this.reloadCurrentPage();
            },
            onGiveUp: () => {
              this.reauthPending = false;
              ReAuthService.giveUp();
            }
          })
        }
      }
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }

  /**
   * 重新验证成功后刷新当前页。
   *
   * 做法是把 active 先清空再设回：ArkUI 会销毁并重建该页面组件，
   * 从而重新触发它的 aboutToAppear → 重新拉数据。
   * （这些页面都带会话内缓存，但会话失效时缓存已被判定无效，
   *   重建会重新请求；即使命中缓存也不会报错。）
   */
  private reloadCurrentPage(): void {
    const cur: string = this.active;
    this.active = '';
    this.active = cur;
  }
}
