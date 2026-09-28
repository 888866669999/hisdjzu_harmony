/*
 * ElectivePage：通选课修读情况
 *
 * 两部分：
 *   1. 各通选类别的要求学分与已修/在修进度
 *   2. 已修（含在修）课程明细
 *
 * 实现注意：本校数据里「要求学分（大于等于）」列是空的（学校未录入），
 * 因此不能展示为「未达标」，而要明确标注「学校未设置要求」，
 * 否则会误判成学生没修够。进度条也仅在要求存在时才画。
 *
 * 正因为学校留空，本页允许用户**自行录入每个大类的要求学分**
 * （见 ElectiveRequirementStore）：录一次即可长期使用，
 * 之后达标判断与进度条都以它为准。
 */
import { AppState } from '../data/AppState';
import { ElectiveReport, ElectiveCategory, ElectiveCourse, ElectiveGroup } from '../model/Models';
import { ElectiveRequirementStore } from '../data/ElectiveRequirementStore';
import { AppError } from '../common/Result';
import { ReAuthService } from '../data/ReAuthService';
import { PageCache, PageDataLoader, PageLoadResult } from '../data/PageCache';
import { ElectiveParser } from '../parser/ElectiveParser';
import { CACHE_ELECTIVE, TTL_ELECTIVE } from '../common/Constants';
import { Theme } from '../theme/Theme';
import { EmptyView, ErrorView, LoadingView } from '../components/StateViews';
import { GlassOverlay } from '../components/GlassOverlay';
import { GlassKit } from '../theme/GlassKit';
import { AppIcon } from '../components/AppIcon';

@Component
export struct ElectivePage {
  @State loading: boolean = true;
  /**
   * 下拉刷新状态（`$$` 双向绑定给 Refresh）。
   * 刷新结束必须置回 false，否则指示器会一直转 —— 见 load 的 finally。
   */
  @State refreshing: boolean = false;
  @State errorText: string = '';
  @State report: ElectiveReport = new ElectiveReport();
  /** 归并后的大类（大类 → 具体课程） */
  @State groups: ElectiveGroup[] = [];
  /**
   * 已展开的大类名。
   *
   * 用 Set 而不是给每个组加布尔字段：组的对象每次归并都会重建，
   * 状态挂在「名字」上更稳，重新加载后展开态不会莫名其妙全丢。
   * 默认空集合 ⇒ 全部收起。
   */
  @State expanded: Set<string> = new Set<string>();
  /**
   * 正在拉取课程明细的大类名（显示加载态）。
   *
   * 明细要**逐个按需**去抓（见 ensureCourses），所以同一时刻通常只有
   * 一个；用集合而不是单个字符串，是为了让用户快速连点几个大类时
   * 每个都能显示自己的加载态、互不覆盖。
   */
  @State loadingCourses: Set<string> = new Set<string>();

  // ==================== 要求学分编辑浮层 ====================
  /** 正在编辑的大类名（空串表示浮层关闭） */
  @State reqCategory: string = '';
  /** 输入框内容 */
  @State reqInput: string = '';
  /** 浮层内的错误提示 */
  @State reqError: string = '';

  aboutToAppear(): void {
    // 先用内存缓存填首帧（切页回来不闪加载态），再决定要不要联网。
    // 缓存的是**原文**，所以归并/叠加自录要求仍按原路径做一遍 ——
    // 这样用户改过要求学分后，缓存数据也能正确叠加。
    const cached: ElectiveReport | null = this.loader().peek();
    if (cached !== null) {
      this.report = cached;
      this.groups = cached.grouped();
      this.loading = false;
      this.applyCustomRequirements();
    }
    this.load();
  }

  private loader(): PageDataLoader<ElectiveReport> {
    return new PageDataLoader<ElectiveReport>(
      PageCache.keyOf(AppState.account, CACHE_ELECTIVE),
      () => AppState.apiInstance().getElectiveHtml(),
      (body: string) => ElectiveParser.parse(body),
      TTL_ELECTIVE);
  }

  private async load(interactive: boolean = false,
    force: boolean = false): Promise<void> {
    // 已有内容时不铺整屏加载态。
    // report 是非空类型（`new ElectiveReport()`），所以用「有没有数据」判断。
    this.errorText = '';
    const hasData: boolean =
      this.report.categories.length > 0 || this.report.courses.length > 0;
    if (!hasData) {
      this.loading = true;
    }
    try {
      const r: PageLoadResult<ElectiveReport> = await this.loader().load(force);
      this.report = r.data;
      // 归并成「大类 → 具体课程」；归并逻辑在模型里（可单测）
      this.groups = r.data.grouped();
      // 叠加用户自录的要求学分（失败不影响主流程，只是没有覆盖值）
      await this.applyCustomRequirements();
    } catch (e) {
      // 会话失效：先试静默续期（已保存账号密码 + OCR 自动登录）。
      // 成功就直接重载，用户完全无感；失败时**自动加载不弹窗**、
      // 只给一句内联提示，等用户主动点重试才升级为弹窗。
      const renewed: boolean = await ReAuthService.recoverIfExpired(e, interactive);
      if (renewed) {
        await this.load(interactive);
        return;
      }
      const msg: string = AppError.describe(e);
      this.errorText = AppError.isAuthExpired(e)
        ? '登录状态已过期，重新加载即可自动登录' : msg;
    } finally {
      this.loading = false;
      // 复位下拉指示器（`$$` 双向绑定，不置回会一直转）
      this.refreshing = false;
    }
  }

  /**
   * 把用户自录的要求学分叠加到分组上。
   *
   * 单独一步而不是塞进 `grouped()`：分组是纯计算（可单测、不碰存储），
   * 存储读取是 IO，混在一起会让那个纯函数不再纯粹。
   * 同时**强制换一个新数组**，让 @State 一定触发刷新 ——
   * 只改数组里对象的字段时 ArkUI 不保证重新渲染。
   */
  private async applyCustomRequirements(): Promise<void> {
    const account: string = await AppState.resolveAccount();
    const saved: Map<string, number> = await ElectiveRequirementStore.load(account);
    if (saved.size === 0) {
      return;
    }
    const next: ElectiveGroup[] = [];
    for (let i = 0; i < this.groups.length; i++) {
      const g: ElectiveGroup = this.groups[i];
      const v: number | undefined = saved.get(g.name);
      next.push(v === undefined ? g : ElectivePage.withRequired(g, v));
    }
    this.groups = next;
  }

  /**
   * 复制一个大类并替换其要求学分。
   *
   * 为什么不就地改 `g.customRequired` 后 push 原对象：ForEach 判断某个数据项
   * 是否要重建，靠的是 key（见 build() 里的说明）；而 @Builder 拿到的若是
   * 同一个对象引用，复用时就可能继续画旧值。换一个**新对象**，让「数据项变了」
   * 这件事在对象身份上也成立，不依赖 key 计算这一个环节。
   * courses 与 info 直接共享引用即可 —— 它们没有变，复制一份反而浪费。
   */
  private static withRequired(g: ElectiveGroup, value: number): ElectiveGroup {
    const out: ElectiveGroup = new ElectiveGroup(g.name);
    out.courses = g.courses;
    out.info = g.info;
    out.customRequired = value;
    // 按需抓来的明细与「取过」标记必须一起带过去：漏掉的话，用户改一次
    // 要求学分就会把已展开的明细清空、还要重新抓一次。
    out.coursesLoaded = g.coursesLoaded;
    return out;
  }

  /** 打开要求学分编辑浮层 */
  private openRequirement(g: ElectiveGroup): void {
    this.reqCategory = g.name;
    // 已有要求（无论来自用户还是学校）就预填，方便微调
    const cur: number = g.requiredNumber();
    this.reqInput = cur >= 0 ? cur.toString() : '';
    this.reqError = '';
  }

  // ==================== 大类下的课程明细（按需拉取）====================

  /**
   * 可展开的判据。
   *
   * 本校的通选主页是单表、**没有课程明细**，明细要按需去抓「详情」页
   * （见 ensureCourses）。因此「可展开」不能只看 hasCourses() ——
   * 首次进来时所有大类都还没加载，那样每个大类都点不开。判据改成
   * 「没试过 或 已经取到课程」：
   *   · 没试过   → 允许点开，点开时去抓；
   *   · 取过且有 → 正常展开/收起；
   *   · 取过但没有 → 不可点（点开是个空列表，没有意义）。
   */
  private isExpandable(g: ElectiveGroup): boolean {
    return g.hasCourses() || !g.coursesLoaded;
  }

  /**
   * 按需拉取某个大类的课程明细。
   *
   * 本校的明细在**另一个页面**：每行的「详情」是
   * `window.open('/jsxsd/xxwcqk/xxwcqkOnkctxByxq.do?kctxmc=…')`，
   * 该地址可直接 GET，因此这里在用户**展开时**才去抓 ——
   * 首屏不为 11 个大类打 11 个请求，用户不关心的大类一个请求都不发。
   *
   * 失败只提示、不整屏报错：明细是展开后的补充信息，
   * 拿不到不该把已经看到的学分统计一起换掉。
   */
  private async ensureCourses(g: ElectiveGroup): Promise<void> {
    if (g.coursesLoaded || this.loadingCourses.has(g.name)) {
      return;
    }
    this.loadingCourses = ElectivePage.setWith(this.loadingCourses, g.name, true);
    const list: ElectiveCourse[] | null = await this.fetchCourses(g.name);
    if (list === null) {
      // 不设 coursesLoaded：下次展开可以再试一次（错误说明已写进 errorText）
      this.loadingCourses = ElectivePage.setWith(this.loadingCourses, g.name, false);
      return;
    }
    // 明细写回分组，并把整条数组换成新的一份：@State 只认引用变化，
    // 就地改 g.courses 不会触发刷新。卡片 key 里带了 coursesLoaded 与
    // 课程数（见 groupKey），换数组后 ForEach 会重建这一张卡片。
    const next: ElectiveGroup[] = [];
    for (let i = 0; i < this.groups.length; i++) {
      const cur: ElectiveGroup = this.groups[i];
      if (cur.name === g.name) {
        cur.courses = list;
        // 取过就标记，避免每次展开都重抓；空结果也算取过（确实没有课程）
        cur.coursesLoaded = true;
      }
      next.push(cur);
    }
    this.groups = next;
    // 撤加载态放在**写回之后**：反过来的话，两次状态更新之间会有一帧
    // 「loading 已撤、明细还没写」，界面上闪一下「暂无课程记录」。
    this.loadingCourses = ElectivePage.setWith(this.loadingCourses, g.name, false);
  }

  /**
   * 取明细。会话失效时先静默续期再重试**一次**（与页面其它请求同一套恢复流程）。
   *
   * 返回 null = 这次没取到（原因已写进 errorText）；调用方据此保持
   * coursesLoaded = false，让用户下次展开还能再试。
   */
  private async fetchCourses(category: string): Promise<ElectiveCourse[] | null> {
    try {
      return await AppState.apiInstance().getElectiveCourses(category);
    } catch (e) {
      const renewed: boolean = await ReAuthService.recoverIfExpired(e, true);
      if (!renewed) {
        this.errorText = AppError.isAuthExpired(e)
          ? '登录状态已过期，重新展开即会自动登录' : AppError.describe(e);
        return null;
      }
      try {
        return await AppState.apiInstance().getElectiveCourses(category);
      } catch (e2) {
        this.errorText = AppError.describe(e2);
        return null;
      }
    }
  }

  /** Set 就地增删不会触发刷新，一律复制出新的一份 */
  private static setWith(src: Set<string>, name: string, add: boolean): Set<string> {
    const next: Set<string> = new Set<string>();
    src.forEach((n: string) => {
      if (n !== name) {
        next.add(n);
      }
    });
    if (add) {
      next.add(name);
    }
    return next;
  }

  /**
   * 大类卡片的 ForEach key。
   *
   * ===== 为什么要把渲染相关的状态全编进 key =====
   * ForEach 对 key 不变的数据项会**复用**已建好的子组件、不重新渲染。
   * 这张卡片的画面取决于：自录要求学分（customRequired）、明细取没取过
   * （coursesLoaded）、课程数、是否展开、是否正在加载 —— 只换数组而 key
   * 不变，这些变化一个都不会反映到界面上（实测：保存要求后要退出重进才看到）。
   * 把它们全部编进 key，任一变化即重建该卡片。
   */
  private groupKey(g: ElectiveGroup): string {
    const loading: boolean = this.loadingCourses.has(g.name);
    return 'grp-' + g.name + '-' + g.customRequired.toString()
      + (g.coursesLoaded ? '-L' : '-U')
      + '-' + g.courses.length.toString()
      + (this.expanded.has(g.name) ? '-O' : '-C')
      + (loading ? '-B' : '-I');
  }

  /** 课程行的类别标签：本校详情页给的是「课程属性」，旧校结构给的是 category */
  private courseTag(c: ElectiveCourse): string {
    return c.category.length > 0 ? c.category : c.attr;
  }

  private closeRequirement(): void {
    this.reqCategory = '';
    this.reqInput = '';
    this.reqError = '';
  }

  /** 保存要求学分（value < 0 表示清除自定义，回落到服务器值） */
  private async saveRequirement(category: string, value: number): Promise<void> {
    const account: string = await AppState.resolveAccount();
    if (account.length === 0) {
      this.reqError = '未获取到账号，无法保存';
      return;
    }
    const ok: boolean = await ElectiveRequirementStore.save(account, category, value);
    if (!ok) {
      this.reqError = '保存失败，请重试';
      return;
    }
    // 更新内存里的分组，避免为了一个数字再请求一次服务器。
    // 变化的那个大类换成新对象（见 withRequired 的说明），
    // 其余原样带过去；整条数组也换新，确保界面立刻反映新值。
    const next: ElectiveGroup[] = [];
    for (let i = 0; i < this.groups.length; i++) {
      const g: ElectiveGroup = this.groups[i];
      next.push(g.name === category ? ElectivePage.withRequired(g, value) : g);
    }
    this.groups = next;
    this.closeRequirement();
  }

  /** 提交输入框里的数值 */
  private submitRequirement(category: string): void {
    const v: number = ElectiveRequirementStore.parseInput(this.reqInput);
    if (v < 0) {
      this.reqError = '请输入 0 ~ 200 之间的学分，最多一位小数';
      return;
    }
    this.saveRequirement(category, v);
  }

  @Builder
  summaryCard() {
    Row({ space: Theme.GAP }) {
      Column({ space: 2 }) {
        Text(this.report.earnedNumber().toString())
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.brand'))
        Text('已修学分')
          .fontSize(Theme.FS_TINY)
          .fontColor($r('app.color.text_tertiary'))
      }
      .layoutWeight(1)

      Column({ space: 2 }) {
        Text(this.report.ongoingNumber().toString())
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.warning'))
        Text('正在修读')
          .fontSize(Theme.FS_TINY)
          .fontColor($r('app.color.text_tertiary'))
      }
      .layoutWeight(1)

      Column({ space: 2 }) {
        Text(this.report.courses.length.toString())
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text('门课程')
          .fontSize(Theme.FS_TINY)
          .fontColor($r('app.color.text_tertiary'))
      }
      .layoutWeight(1)

      Column({ space: 2 }) {
        Text(this.report.categories.length.toString())
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text('个类别')
          .fontSize(Theme.FS_TINY)
          .fontColor($r('app.color.text_tertiary'))
      }
      .layoutWeight(1)
    }
    .width('100%')
    .padding(Theme.GAP_L)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(Theme.RADIUS_SM)
  }

  /**
   * 一个大类卡片。
   *
   * 交互刻意分成**两个互不嵌套的可点区域**：
   *   - 上半（大类名行 + 进度条）：展开/收起该大类的课程；
   *   - 下半（要求学分行）：编辑该大类的要求学分。
   * 之所以不把「编辑」按钮塞进可展开的那一块里：ArkUI 里子节点与父节点
   * 都有 onClick 时要靠手势竞争裁决，点编辑顺带把列表展开/收起一次，
   * 是很容易出现、又很难解释的交互 bug。分成两个兄弟区域就不会有歧义。
   */
  @Builder
  groupCard(g: ElectiveGroup) {
    Column() {
      // ---- 可点区域一：展开/收起 ----
      Column({ space: 6 }) {
        Row({ space: Theme.GAP_S }) {
          Text(g.name)
            .fontSize(Theme.FS_BODY)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          // 有要求才显示达标判断；没有要求时给一句行动指引
          // （学校那一列实测是空的，所以「没有要求」是常态而非异常，
          //  与其陈述「学校未设置」这个事实，不如告诉用户下一步能做什么）
          if (g.requiredNumber() < 0) {
            Text('请设置学分要求')
              .fontSize(Theme.FS_TINY)
              .fontColor($r('app.color.brand'))
          } else if (g.earnedNumber() + g.ongoingNumber() >= g.requiredNumber()) {
            Text('已达标')
              .fontSize(Theme.FS_TINY)
              .fontColor($r('app.color.success'))
          } else {
            Text('还差 ' + (g.requiredNumber() - g.earnedNumber() - g.ongoingNumber()).toFixed(1))
              .fontSize(Theme.FS_TINY)
              .fontColor($r('app.color.warning'))
          }

          // 可展开就给箭头：判据是 isExpandable（没试过或已取到课程），
          // 不再只看 hasCourses —— 本校明细要按需去抓，首屏谁都还没加载。
          if (this.isExpandable(g)) {
            Text(this.expanded.has(g.name) ? '︿' : '﹀')
              .fontSize(Theme.FS_TINY)
              .fontColor($r('app.color.text_tertiary'))
          }
        }
        .width('100%')

        // 学分进度：只有存在要求时才画进度条（没有分母时画出来的长度没有意义）
        if (g.canShowProgress()) {
          Progress({
            value: Math.min(g.earnedNumber() + g.ongoingNumber(), g.requiredNumber()),
            total: g.requiredNumber(),
            type: ProgressType.Linear
          })
            .color($r('app.color.brand'))
            .width('100%')
        }
      }
      .width('100%')
      .padding({ left: Theme.GAP, right: Theme.GAP, top: 12, bottom: 12 })
      .alignItems(HorizontalAlign.Start)
      .onClick(() => {
        if (!this.isExpandable(g)) {
          return;
        }
        const open: boolean = this.expanded.has(g.name);
        // Set 的就地修改不会触发刷新，必须换一个新 Set
        this.expanded = ElectivePage.setWith(this.expanded, g.name, !open);
        if (open) {
          return;
        }
        // 明细还没取过就去取（取过则直接用，不重复打请求）
        this.ensureCourses(g);
      })

      // ---- 可点区域二：要求学分 ----
      // 独立成行而不是混进副标题：这里要能点、上面那块也要能点，
      // 两者共处一行就会抢手势（见 groupCard 的说明）。
      //
      // 按钮在**左**、学分统计在右：按钮是这一行的行动入口，放左侧更容易
      // 被扫到，也让各卡片的按钮纵向对齐（想改哪个大类时不用横向找）；
      // 统计是结果，退到右边。
      Row({ space: Theme.GAP_S }) {
        Row({ space: 4 }) {
          AppIcon({
            res: 'edit',
            iconSize: 13,
            color: $r('app.color.brand')
          })
          Text(g.hasCustomRequired() ? '修改要求' : '设置要求学分')
            .fontSize(Theme.FS_TINY)
            .fontColor($r('app.color.brand'))
            .maxLines(1)
        }
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius(Theme.RADIUS_SM)
        .backgroundColor($r('app.color.brand_soft'))
        .onClick(() => {
          this.openRequirement(g);
        })

        Text(this.earnedLine(g))
          .fontSize(Theme.FS_TINY)
          .fontColor($r('app.color.text_tertiary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding({ left: Theme.GAP, right: Theme.GAP, bottom: 12 })
      .alignItems(VerticalAlign.Center)

      if (this.expanded.has(g.name)) {
        // 正在抓明细 → 转圈；抓完是空 → 说清楚「确实没有」而不是留白
        // （本校正是在这里才第一次知道该大类有没有课）
        if (this.loadingCourses.has(g.name)) {
          Row() {
            LoadingProgress()
              .width(16)
              .height(16)
              .color($r('app.color.brand'))
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding({ top: 14, bottom: 14 })
        } else if (g.courses.length === 0) {
          Text('该大类下暂无课程记录')
            .fontSize(Theme.FS_TINY)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .padding({ left: Theme.GAP, right: Theme.GAP, top: 12, bottom: 12 })
        } else {
          ForEach(g.courses, (c: ElectiveCourse) => {
            this.courseRow(c)
          }, (c: ElectiveCourse) => 'gc-' + g.name + '-' + c.courseCode + '-' + c.courseName)
        }
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.surface'))
    .borderRadius(Theme.RADIUS_SM)
    .clip(true)
  }

  /**
   * 大类的「已修/在修/要求」一行。
   *
   * 要求学分统一在这里说清楚并标出来源：用户自录的显示为「要求 ≥ X」，
   * 学校给了值的显示为「学校要求 ≥ X」；两者都没有时这一行只陈述已修/在修，
   * 「去设置」的指引交给上方状态位的「请设置学分要求」与左侧按钮，不重复第三遍。
   */
  private earnedLine(g: ElectiveGroup): string {
    const earned: string = g.info !== null && g.info.earned.length > 0
      ? g.info.earned : '0';
    const ongoing: string = g.info !== null && g.info.ongoing.length > 0
      ? g.info.ongoing : '0';
    let out: string = '已修 ' + earned + ' · 在修 ' + ongoing;
    if (g.hasCustomRequired()) {
      out = out + ' · 要求 ≥ ' + g.requiredNumber().toString();
    } else if (g.requiredNumber() >= 0) {
      out = out + ' · 学校要求 ≥ ' + g.requiredNumber().toString();
    }
    return out;
  }

  /**
   * 要求学分编辑浮层的内容。
   *
   * 为什么提示里要说「培养方案」：用户第一次看到这个入口时最自然的疑问是
   * 「我该填多少」。学校那一列是空的，答案只能来自他自己专业的培养方案，
   * 因此直接在界面上点明来源，而不是留一个空输入框让人猜。
   */
  @Builder
  requirementEditor() {
    Column({ space: Theme.GAP }) {
      Column({ space: 2 }) {
        Text('要求学分')
          .fontSize(Theme.FS_SECTION)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Text(this.reqCategory)
          .fontSize(Theme.FS_SMALL)
          .fontColor($r('app.color.brand'))
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Text('填写培养方案里这一大类要求修满的总学分，填好后即可算出还差多少。')
        .fontSize(Theme.FS_TINY)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')

      TextInput({ placeholder: '例如 12', text: this.reqInput })
        .type(InputType.NUMBER_DECIMAL)
        .height(46)
        .fontSize(Theme.FS_BODY)
        .backgroundColor($r('app.color.surface_variant'))
        .backgroundEffect(GlassKit.fieldEffect())
        .borderRadius(Theme.RADIUS_SM)
        .onChange((v: string) => {
          this.reqInput = v;
          this.reqError = '';
        })

      if (this.reqError.length > 0) {
        Text(this.reqError)
          .fontSize(Theme.FS_TINY)
          .fontColor($r('app.color.danger'))
          .width('100%')
      }

      // 已设置过才给「清除」：否则这里只是一个「取消」的重复按钮
      if (this.isCategoryCustom(this.reqCategory)) {
        Button('清除该要求')
          .width('100%')
          .height(42)
          .fontSize(Theme.FS_SMALL)
          .backgroundColor($r('app.color.surface_variant'))
          .fontColor($r('app.color.danger'))
          .onClick(() => {
            this.saveRequirement(this.reqCategory, -1);
          })
      }

      Row({ space: Theme.GAP_S }) {
        Button('取消')
          .layoutWeight(1)
          .height(46)
          .fontSize(Theme.FS_BODY)
          .backgroundColor($r('app.color.surface_variant'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            this.closeRequirement();
          })
        Button('保存')
          .layoutWeight(1)
          .height(46)
          .fontSize(Theme.FS_BODY)
          .backgroundColor($r('app.color.brand'))
          .fontColor($r('app.color.on_brand'))
          .onClick(() => {
            this.submitRequirement(this.reqCategory);
          })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(GlassKit.PANEL_PAD)
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 浮层面板高度（vp），按内容实算。
   *
   * 为什么不用固定值：面板里「清除该要求」是**条件出现**的，
   * 固定高度必然在其中一种状态下留一大块空白或裁掉按钮。
   * 计算口径 = 标题(20) + 类别名(18) + 间距 + 说明(16) + 输入框(46)
   *           + [清除按钮(42)] + 按钮行(46) + 上下内边距(2×PANEL_PAD)
   */
  private reqPanelHeight(): number {
    const base: number = 20 + 18 + 12 + 16 + 12 + 46 + 12 + 12 + 46 + GlassKit.PANEL_PAD * 2;
    const withClear: number = this.isCategoryCustom(this.reqCategory) ? (42 + 12) : 0;
    return base + withClear;
  }

  /** 某个大类当前是否有用户自录的要求（用于决定是否显示「清除」） */
  private isCategoryCustom(name: string): boolean {
    for (let i = 0; i < this.groups.length; i++) {
      if (this.groups[i].name === name) {
        return this.groups[i].hasCustomRequired();
      }
    }
    return false;
  }

  @Builder
  courseRow(c: ElectiveCourse) {
    Row({ space: Theme.GAP_S }) {
      Column({ space: 2 }) {
        Text(c.courseName)
          .fontSize(Theme.FS_BODY)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row({ space: 8 }) {
          Text(c.courseCode)
            .fontSize(Theme.FS_TINY)
            .fontColor($r('app.color.text_tertiary'))
          // 标签优先用旧校结构的「通选课类别」；本校详情页给的是「课程属性」
          // （必修/选修/实践），两处都取不到就不显示这块空壳。
          if (this.courseTag(c).length > 0) {
            Text(this.courseTag(c))
              .fontSize(Theme.FS_TINY)
              .fontColor($r('app.color.text_secondary'))
              .backgroundColor($r('app.color.surface_variant'))
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .borderRadius(4)
          }
          if (c.credit.length > 0) {
            Text(c.credit + ' 学分')
              .fontSize(Theme.FS_TINY)
              .fontColor($r('app.color.text_tertiary'))
          }
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 成绩列：未出分（在修读）用文字+品牌色，出分的用大字重数字 ——
      // 两者都要能一眼区分「还没考」与「考了多少」。
      if (c.isOngoing()) {
        Text('在修')
          .fontSize(Theme.FS_TINY)
          .fontColor($r('app.color.warning'))
      } else if (c.score.length > 0) {
        Text(c.score)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
      }
    }
    .width('100%')
    .padding({ left: Theme.GAP, right: Theme.GAP, top: 12, bottom: 12 })
    .border({ width: { top: 0.5 }, color: $r('app.color.divider') })
  }

  build() {
    // 下拉刷新：以 force 调用，**绕过 TTL 强制联网**（对齐 Flutter 端
    // 每页的 onRefresh: () => _load(force: true)）。没有它的话，
    // TTL 内（本页 10 分钟）即使学校刚改了数据，下拉也只会重读缓存。
    Refresh({ refreshing: $$this.refreshing }) {
    Stack() {
      Column() {
        if (this.loading) {
          LoadingView({ message: '正在获取通选课修读情况…' })
        } else if (this.errorText.length > 0 && this.report.courses.length === 0 &&
          this.report.categories.length === 0) {
          // 没有任何内容可显示时才整屏报错（首次进入且失败）
          ErrorView({
            message: this.errorText,
            onRetry: () => {
              this.load(true);
            }
          })
        } else if (this.report.categories.length === 0 && this.report.courses.length === 0) {
          EmptyView({ title: '暂无通选课数据' })
        } else {
          Scroll() {
            Column({ space: Theme.GAP }) {
              // 刷新失败的提示：只加一条横幅，不换掉页面。
              // 用户已经看到的修读情况比「这次刷新成功与否」重要得多。
              if (this.errorText.length > 0) {
                Text(this.errorText)
                  .fontSize(Theme.FS_TINY)
                  .fontColor($r('app.color.warning'))
                  .width('100%')
                  .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                  .borderRadius(Theme.RADIUS_SM)
                  .backgroundColor($r('app.color.warning'))
                  .opacity(0.92)
              }
              this.summaryCard()

              // 大类 → 具体课程。学校原页面是两张独立的表，要学生自己对类别名；
              // 这里合成一条线，大类行给修读要求与达标状态，点开才列出课程。
              //
              // key 里带上所有参与渲染的状态（自录要求 / 明细取没取过 / 课程数 /
              // 展开态 / 加载态）：ForEach 的 key 不变时会**复用**已建的子组件、
              // 不重新渲染 —— 只换数组、key 还是 'grp-名字' 的话，用户刚保存的
              // 要求学分、刚抓回来的明细都不会立刻显示（要退出重进才看到，实测如此）。
              // 见 groupKey 的说明。
              ForEach(this.groups, (g: ElectiveGroup) => {
                this.groupCard(g)
              }, (g: ElectiveGroup) => this.groupKey(g))

              Text('点大类标题展开课程 · 点「设置要求学分」录入培养方案里的要求')
                .fontSize(Theme.FS_TINY)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
            }
            .width('100%')
            // 底部多留出浮层 dock 的高度，否则最后一条会被玻璃压住
            .padding({ left: Theme.GAP, right: Theme.GAP, top: Theme.GAP,
              bottom: Theme.GAP + Theme.bottomInset() })
          }
          .layoutWeight(1)
          .align(Alignment.Top)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg'))

      // 要求学分编辑浮层：作为页面内容之后的后序兄弟，叠在 Scroll 之上，
      // 玻璃透出的是真实的页面内容（层级约束见 GlassOverlay 类注释）。
      if (this.reqCategory.length > 0) {
        GlassOverlay({
          // 内容高度固定（标题 + 说明 + 输入框 + 按钮行），给精确 vp：
          // 比例是按可用高度算的，平板上会算得比内容矮、按钮被裁掉（实测过）。
          // 「清除」是条件出现的，高度由 reqPanelHeight() 按当前状态实算。
          panelWidthVp: 360,
          panelHeightVp: this.reqPanelHeight(),
          onDismiss: () => {
            this.closeRequirement();
          }
        }) {
          this.requirementEditor()
        }
      }
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
    }
    .onRefreshing(() => {
      this.load(false, true);
    })
    .layoutWeight(1)
    .width('100%')
  }
}
