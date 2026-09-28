/*
 * PlanPage：培养方案（培养方案 + 修读情况的合并页）
 *
 * 由原「培养方案」页与原「通选课修读情况」页（ElectivePage，已删除）合并而来。
 * 两页的数据都以「课程体系」分组，实测两端给出的是同一组体系（各 11 个），
 * 于是按体系名对齐成一张列表：一个体系一张卡片，卡片里既是该体系的修读进度
 * （应修/已修/在修 + 进度条 + 「设置要求学分」），点开又是两组课程 ——
 *   · 培养方案课程：该体系应修的课（原培养方案的课程表）；
 *   · 修读记录：实际已修/在修的课（原通选页展开时才去抓的详情页）。
 * 合并的理由：学生看培养方案时最常接着问的就是「这个体系我还差多少」，
 * 之前要在两页之间来回按体系名对照。
 *
 * ===== 两个数据源独立加载（本页最要紧的约束）=====
 * 培养方案（一个请求）与修读情况（另一个请求）各自走缓存、各自报错。
 * 合并页最容易写坏的地方就是「任何一边失败整页空白」——一边失败只少
 * 一块内容，顶部给一条非阻断提示，另一边照常显示。因此两边的状态
 * （loading / error）刻意不共用：共用的话一边失败会把另一边的加载态也搅乱。
 *
 * ===== 为什么合并后不再有 PDF =====
 * 原页面带「培养方案 PDF 附件」的下载入口（从页面正则出附件路径、下载到
 * 沙箱、再走系统「另存为」）。实测本校的培养方案页面里没有任何附件
 * （`uploadfile`、`.pdf`、`附件` 均不出现），整套代码只服务一个本校没有的
 * 功能，已整块删除（附件路径解析、data/PdfStore、本页的 PDF 卡片）。
 * 注意：校历附件是**另一个功能**（用户填的公告页里挂的 PDF，见
 * CampusCalendarService 与 CalendarSheet），不在此列。
 */
import { AppState } from '../data/AppState';
import { ReAuthService } from '../data/ReAuthService';
import { ElectiveRequirementStore } from '../data/ElectiveRequirementStore';
import { PageCache, PageDataLoader, PageLoadResult } from '../data/PageCache';
import { PlanParser } from '../parser/PlanParser';
import { ElectiveParser } from '../parser/ElectiveParser';
import { CACHE_PLAN, TTL_PLAN, CACHE_ELECTIVE, TTL_ELECTIVE } from '../common/Constants';
import {
  PlanDetail, PlanGroup, PlanCourse, ElectiveReport, ElectiveCourse, ElectiveGroup,
  MergedPlanGroup, mergePlanAndElective, systemMergeKey
} from '../model/Models';
import { AppError } from '../common/Result';
import { Theme } from '../theme/Theme';
import { LoadingView, EmptyView, ErrorView } from '../components/StateViews';
import { GlassOverlay } from '../components/GlassOverlay';
import { GlassKit } from '../theme/GlassKit';
import { AppIcon } from '../components/AppIcon';

/**
 * 展开后「培养方案课程」里的一行：选课组小标题，或一门课。
 *
 * 网页上的表格是「课程体系 → 选课组 → 课程」三级，应用照它的层级显示；
 * 但**本校的选课组列是空的**（学校没录入），因此按「有组名才插小标题」
 * 处理：全空时不出现任何多余层级，有值时自动出现。
 * 小标题夹在课程之间，用这个扁平行列表表达，ForEach 才能一次铺开。
 */
class PlanRow {
  /** 小标题文本；空串表示这一行是课程 */
  header: string = '';
  /** 课程；为 null 表示这一行是选课组小标题 */
  course: PlanCourse | null = null;

  constructor(header: string, course: PlanCourse | null) {
    this.header = header;
    this.course = course;
  }
}

/**
 * 总览里的一个统计格。
 *
 * ===== 为什么是 @Component 而不是 @Builder =====
 * `@Builder` 的参数是**按值传递**的：父组件重新构建时参数被重新求值，
 * 但已有的子节点不随之更新。总览里的数字全部来自异步加载的 @State，
 * 用 @Builder 会永远停在首帧的空值上 —— 设置页 SettingRow 踩过同一个坑
 * （见 components/SettingRow.ets 文件头）。`@Prop` 是父 → 子单向同步，
 * 异步值到位时子组件会跟着刷新，与状态来源无关。
 */
@Component
struct StatCell {
  @Prop v: string = '';
  @Prop label: string = '';

  build() {
    Column({ space: 2 }) {
      Text(this.v)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Text(this.label)
        .fontSize(Theme.FS_TINY)
        .fontColor($r('app.color.text_tertiary'))
    }
    .layoutWeight(1)
  }
}

@Component
export struct PlanPage {
  // ==================== 培养方案侧 ====================
  @State loading: boolean = true;
  @State errorText: string = '';
  @State plan: PlanDetail = new PlanDetail();

  // ==================== 修读情况侧 ====================
  @State electiveLoading: boolean = true;
  @State electiveError: string = '';
  @State report: ElectiveReport = new ElectiveReport();
  /**
   * 修读情况分组（已叠加用户自录的要求学分）。
   *
   * 存下来而不是每次 build 现算：用户改过要求学分后要能**就地更新**
   * 这一项并立刻反映到界面，不必为了一个数字再请求一次服务器。
   */
  @State groups: ElectiveGroup[] = [];

  /**
   * 下拉刷新状态（`$$` 双向绑定给 Refresh）。
   * 刷新结束必须置回 false，否则指示器会一直转 —— 见 refreshAll 的 finally。
   */
  @State refreshing: boolean = false;

  /**
   * 已展开的体系（按**归一后的名字**记）。
   *
   * 存「展开」而不是「收起」：空集即**全部收起**，这正是期望的默认值 ——
   * 一份 10 门课的分组一进页面就铺满好几屏，得先滚很久才看得到下一个。
   */
  @State expanded: Set<string> = new Set<string>();

  /**
   * 正在按需抓课程明细的体系（显示加载态）。
   *
   * 明细要**逐个按需**去抓（见 ensureCourses），同一时刻通常只有一个；
   * 用集合而不是单个字符串，是为了让用户快速连点几个体系时每个都能显示
   * 自己的加载态、互不覆盖。键用修读侧的**原始**名（与请求参数同源）。
   */
  @State loadingCourses: Set<string> = new Set<string>();

  /**
   * 页面级操作提示（保存要求学分的结果、明细抓取失败）。
   *
   * 为什么不用 promptAction 的 toast：这里要能持续显示、可点掉，
   * 与设置页那种「顶部一条横幅」的做法一致；toast 几秒就没了，
   * 用户还没看清失败原因就消失了。
   */
  @State hint: string = '';

  // ==================== 要求学分编辑浮层 ====================
  /** 正在编辑的体系**原始**名（空串表示浮层关闭）。存储键用它，见 openRequirement */
  @State reqCategory: string = '';
  /** 浮层标题里显示的体系名（归一后的那份，只用于展示） */
  @State reqDisplay: string = '';
  /** 输入框内容 */
  @State reqInput: string = '';
  /** 浮层内的错误提示 */
  @State reqError: string = '';

  aboutToAppear(): void {
    // 先用两个来源的内存缓存填首帧（切页回来不闪加载态），再决定要不要联网。
    // 缓存的是**原文**，所以归并/叠加自录要求仍按原路径做一遍 ——
    // 这样用户改过要求学分后，缓存数据也能正确叠加。
    const cachedPlan: PlanDetail | null = this.loader().peek();
    if (cachedPlan !== null) {
      this.plan = cachedPlan;
      this.loading = false;
    }
    const cachedElective: ElectiveReport | null = this.electiveLoader().peek();
    if (cachedElective !== null) {
      this.report = cachedElective;
      this.groups = cachedElective.grouped();
      this.electiveLoading = false;
      this.applyCustomRequirements().catch(() => {
        // 自录要求读不到不影响主流程：只是没有覆盖值
      });
    }
    // 两个来源各自加载：一边失败只影响自己那一半（见文件头说明）
    this.load();
    this.loadElective();
  }

  private loader(): PageDataLoader<PlanDetail> {
    return new PageDataLoader<PlanDetail>(
      PageCache.keyOf(AppState.account, CACHE_PLAN),
      () => AppState.apiInstance().getPlanHtml(),
      (body: string) => PlanParser.parse(body),
      TTL_PLAN);
  }

  private electiveLoader(): PageDataLoader<ElectiveReport> {
    return new PageDataLoader<ElectiveReport>(
      PageCache.keyOf(AppState.account, CACHE_ELECTIVE),
      () => AppState.apiInstance().getElectiveHtml(),
      (body: string) => ElectiveParser.parse(body),
      TTL_ELECTIVE);
  }

  // ==================== 两个来源各自的加载 ====================
  //
  // 结构完全对称：先清自己的错误、拉数据、成功替换、失败走会话续期。
  // 刻意不共用一份状态 —— 共用的话一边失败会把另一边的错误/加载态也搅乱，
  // 而「互不影响」正是这次合并的硬要求。

  private async load(interactive: boolean = false,
    force: boolean = false): Promise<void> {
    // 已有内容时不铺整屏加载态：切页回来该立刻看到旧数据，新数据到了再替换。
    // plan 是非空类型（`new PlanDetail()`），所以用「有没有数据」判断。
    this.errorText = '';
    if (this.plan.courses.length === 0 && this.plan.introParagraphs.length === 0) {
      this.loading = true;
    }
    try {
      const r: PageLoadResult<PlanDetail> = await this.loader().load(force);
      this.plan = r.data;
    } catch (e) {
      // 会话失效：先试静默续期（已保存账号密码 + OCR 自动登录）。
      // 成功就直接重载，用户完全无感；失败时**自动加载不弹窗**、
      // 只给一句内联提示，等用户主动点重试才升级为弹窗。
      const renewed: boolean = await ReAuthService.recoverIfExpired(e, interactive);
      if (renewed) {
        await this.load(interactive, force);
        return;
      }
      const msg: string = AppError.describe(e);
      this.errorText = AppError.isAuthExpired(e)
        ? '登录状态已过期，重新加载即可自动登录' : msg;
    } finally {
      this.loading = false;
    }
  }

  private async loadElective(interactive: boolean = false,
    force: boolean = false): Promise<void> {
    this.electiveError = '';
    const hasData: boolean =
      this.report.categories.length > 0 || this.report.courses.length > 0;
    if (!hasData) {
      this.electiveLoading = true;
    }
    try {
      const r: PageLoadResult<ElectiveReport> = await this.electiveLoader().load(force);
      this.report = r.data;
      // 归并成「体系 → 具体课程」；归并逻辑在模型里（可单测）
      this.groups = r.data.grouped();
      // 叠加用户自录的要求学分（失败不影响主流程，只是没有覆盖值）
      await this.applyCustomRequirements();
    } catch (e) {
      const renewed: boolean = await ReAuthService.recoverIfExpired(e, interactive);
      if (renewed) {
        await this.loadElective(interactive, force);
        return;
      }
      const msg: string = AppError.describe(e);
      this.electiveError = AppError.isAuthExpired(e)
        ? '登录状态已过期，重新加载即可自动登录' : msg;
    } finally {
      this.electiveLoading = false;
    }
  }

  /**
   * 下拉 / 重试：两个来源一起刷新。
   *
   * 两个 `load*` 自己消化异常（末尾不向外抛），因此串行 await 不会因为
   * 一边失败而把另一边也中断。refreshing 只在这里复位：若放进各自的
   * finally，先回来的那一个就会提前把指示器停掉 —— 两个请求还在跑，
   * 用户以为刷新已经结束。
   */
  private async refreshAll(): Promise<void> {
    try {
      await this.load(false, true);
      await this.loadElective(false, true);
    } finally {
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
   * 存储键是 `g.name`（**原始**名），与旧版通选页一致，换键会让已录的值失配。
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
      next.push(v === undefined ? g : PlanPage.withRequired(g, v));
    }
    this.groups = next;
  }

  /**
   * 复制一个体系并替换其要求学分。
   *
   * 为什么不就地改 `g.customRequired` 后 push 原对象：ForEach 判断某个数据项
   * 是否要重建，靠的是 key（见 groupKey 的说明）；而 @Builder 拿到的若是
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

  // ==================== 合并（按课程体系）====================

  /**
   * 归并后的分组（培养方案顺序优先，修读侧多出的追加在后）。
   *
   * 每次 build 现算：纯计算，而用户的操作（展开、保存要求）都是就地改
   * 同一批对象，现算才能立刻反映。
   */
  private mergedGroups(): MergedPlanGroup[] {
    return mergePlanAndElective(this.plan.groups, this.groups);
  }

  /** 培养方案侧是否有内容（决定列表/空态是否渲染） */
  private hasPlanContent(): boolean {
    return !(this.plan.courses.length === 0 && this.plan.introParagraphs.length === 0);
  }

  /** 修读情况侧是否有内容 */
  private hasElectiveContent(): boolean {
    return this.groups.length > 0;
  }

  /** 两个来源的错误合并成一段文案（哪个失败写哪个的名字） */
  private combinedError(): string {
    const parts: string[] = [];
    if (this.errorText.length > 0) {
      parts.push(this.errorText);
    }
    if (this.electiveError.length > 0) {
      parts.push(this.electiveError);
    }
    return parts.join('\n');
  }

  /** 去掉无意义的小数尾巴：12.0 显示成 12 */
  private static trimNum(v: number): string {
    return v === Math.round(v) ? v.toFixed(0) : v.toString();
  }

  // ==================== 卡片取数（为回调/构建器准备）====================
  //
  // 下面这些方法统一做**非空判断**再取数。原因：@Builder 体与 ForEach /
  // onClick 的回调都是闭包，在其中直接访问 `mg.elective`（可空字段）时
  // ArkTS 的类型收窄不成立，会报「可能为 null」；而每次现算又必须保证
  // 同一份状态（如展开态）被读到，才配合得上 groupKey 的重建机制。

  private hasElectiveOf(mg: MergedPlanGroup): boolean {
    return mg.elective !== null;
  }

  private hasPlanOf(mg: MergedPlanGroup): boolean {
    return mg.plan !== null;
  }

  /** 方案侧「N 门 · X 学分」摘要；没有方案侧时为空串 */
  private planSummaryOf(mg: MergedPlanGroup): string {
    const p: PlanGroup | null = mg.plan;
    if (p === null) {
      return '';
    }
    return p.courses.length.toString() + ' 门 · ' + PlanPage.trimNum(p.totalCredit) + ' 学分';
  }

  /** 方案侧课程是否非空（决定展开后是否渲染「培养方案课程」小节） */
  private hasPlanCoursesOf(mg: MergedPlanGroup): boolean {
    let n: number = 0;
    if (mg.plan !== null) {
      n = mg.plan.courses.length;
    }
    return n > 0;
  }

  /** 方案课程铺开成「小标题 + 课程」的扁平行；没有方案侧时为空数组 */
  private planRowsOf(mg: MergedPlanGroup): PlanRow[] {
    return mg.plan === null ? [] : this.planRows(mg.plan);
  }

  /** 修读侧课程（没有修读侧时为空数组，供 ForEach 直接用） */
  private electiveCoursesOf(mg: MergedPlanGroup): ElectiveCourse[] {
    return mg.elective === null ? [] : mg.elective.courses;
  }

  /** 修读侧分组的原始名（空串仅用于拼 key；空名不会进入 loadingCourses） */
  private electiveNameOf(mg: MergedPlanGroup): string {
    return mg.elective === null ? '' : mg.elective.name;
  }

  /** 取扁平行里的课程；小标题行返回空课（调用前已按 header 判过非空） */
  private rowCourse(row: PlanRow): PlanCourse {
    return row.course === null ? new PlanCourse() : row.course;
  }

  // ==================== 体系状态与统计行 ====================

  /**
   * 体系状态文案（没有修读侧时返回空串）。
   *
   * **只看 `requiredNumber()`**（它已经把「用户自录 > 服务器」的优先级算在内），
   * 不要再单独判断 info 有没有值 —— 用户自录了要求、而学校那一列是空时，
   * 那条判断仍会成立，于是状态显示「请设置学分要求」、副标题却已经写着
   * 「要求 ≥ X」，自相矛盾（实测踩到过）。
   */
  private statusTextOf(mg: MergedPlanGroup): string {
    const e: ElectiveGroup | null = mg.elective;
    if (e === null) {
      return '';
    }
    const req: number = e.requiredNumber();
    if (req < 0) {
      // 没有要求时给一句行动指引。学校那一列实测是空的，「没有要求」是常态
      // 而非异常 —— 与其陈述「学校未设置」这个事实，不如告诉用户下一步能做什么。
      return '请设置学分要求';
    }
    if (e.earnedNumber() + e.ongoingNumber() >= req) {
      return '已达标';
    }
    return '还差 ' + (req - e.earnedNumber() - e.ongoingNumber()).toFixed(1);
  }

  private statusColorOf(mg: MergedPlanGroup): ResourceColor {
    const e: ElectiveGroup | null = mg.elective;
    if (e === null) {
      return $r('app.color.text_tertiary');
    }
    const req: number = e.requiredNumber();
    if (req < 0) {
      return $r('app.color.brand');
    }
    if (e.earnedNumber() + e.ongoingNumber() >= req) {
      return $r('app.color.success');
    }
    return $r('app.color.warning');
  }

  /**
   * 已修/在修/要求 一行。要求学分的来源要标出来：
   * 用户自录的显示为「要求 ≥ X」，学校给了值的显示为「学校要求 ≥ X」，
   * 都没有则只陈述已修/在修（「去设置」的指引交给状态位与左侧按钮）。
   */
  private statsLineOf(mg: MergedPlanGroup): string {
    const e: ElectiveGroup | null = mg.elective;
    if (e === null) {
      return '';
    }
    const earned: string = (e.info !== null && e.info.earned.length > 0)
      ? e.info.earned : '0';
    const ongoing: string = (e.info !== null && e.info.ongoing.length > 0)
      ? e.info.ongoing : '0';
    let out: string = '已修 ' + earned + ' · 在修 ' + ongoing;
    if (e.hasCustomRequired()) {
      out = out + ' · 要求 ≥ ' + PlanPage.trimNum(e.requiredNumber());
    } else if (e.requiredNumber() >= 0) {
      out = out + ' · 学校要求 ≥ ' + PlanPage.trimNum(e.requiredNumber());
    }
    return out;
  }

  /** 是否画进度条：有修读侧且分母为正（学校会留空要求学分） */
  private canShowProgressOf(mg: MergedPlanGroup): boolean {
    return mg.elective !== null && mg.elective.canShowProgress();
  }

  private progressDoneOf(mg: MergedPlanGroup): number {
    const e: ElectiveGroup | null = mg.elective;
    return e === null ? 0 : e.earnedNumber() + e.ongoingNumber();
  }

  private progressTotalOf(mg: MergedPlanGroup): number {
    const e: ElectiveGroup | null = mg.elective;
    return e === null ? 0 : e.requiredNumber();
  }

  private progressColorOf(mg: MergedPlanGroup): ResourceColor {
    if (this.progressDoneOf(mg) >= this.progressTotalOf(mg)) {
      return $r('app.color.success');
    }
    return $r('app.color.brand');
  }

  /** 展开后是否显示「修读记录」小节的加载转圈 */
  private coursesLoadingOf(mg: MergedPlanGroup): boolean {
    const name: string = this.electiveNameOf(mg);
    return name.length > 0 && this.loadingCourses.has(name);
  }

  // ==================== 展开与按需拉取明细 ====================

  /**
   * 可展开的判据。
   *
   * 方案侧有课程，或修读明细「还没取过 / 取到了课程」。明细要按需去抓
   * （见 ensureCourses），首次进来所有人都还没加载 —— 只看 hasCourses()
   * 会让每个体系都点不开。
   */
  private isExpandable(mg: MergedPlanGroup): boolean {
    if (this.hasPlanCoursesOf(mg)) {
      return true;
    }
    const e: ElectiveGroup | null = mg.elective;
    return e !== null && (e.hasCourses() || !e.coursesLoaded);
  }

  /** 展开/收起一个体系；首次展开时顺手去抓修读明细 */
  private toggle(mg: MergedPlanGroup): void {
    const open: boolean = this.expanded.has(mg.name);
    // Set 的就地修改不会触发刷新，必须换一个新 Set
    this.expanded = PlanPage.setWith(this.expanded, mg.name, !open);
    if (open) {
      return;
    }
    // 明细还没取过才去抓（取过则直接用，不重复打请求；失败后不设标记，
    // 再次展开还能重试）
    const e: ElectiveGroup | null = mg.elective;
    if (e !== null) {
      this.ensureCourses(e);
    }
  }

  /**
   * 按需拉取某个体系的课程明细。
   *
   * 本校的通选主页只有学分统计，课程明细在**另一个页面**：每行的「详情」是
   * `window.open('/jsxsd/xxwcqk/xxwcqkOnkctxByxq.do?kctxmc=…')`。
   * 该地址可直接 GET，因此只在用户**展开时**才去抓 ——
   * 首屏不为 11 个体系打 11 个请求，用户不关心的体系一个请求都不发。
   *
   * 查询用体系裸名（systemMergeKey）：页面自己的「详情」链接就是裸名，
   * 名称里的 `(属性)` 后缀不属于 kctxmc。
   *
   * 失败只提示、不整屏报错：明细是展开后的补充信息，
   * 拿不到不该把已经看到的进度统计一起换掉。
   */
  private async ensureCourses(g: ElectiveGroup): Promise<void> {
    if (g.coursesLoaded || this.loadingCourses.has(g.name)) {
      return;
    }
    this.loadingCourses = PlanPage.setWith(this.loadingCourses, g.name, true);
    const list: ElectiveCourse[] | null = await this.fetchCourses(g.name);
    if (list === null) {
      // 不设 coursesLoaded：下次展开可以再试一次（错误说明已写进 hint）
      this.loadingCourses = PlanPage.setWith(this.loadingCourses, g.name, false);
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
    // 「loading 已撤、明细还没写」，界面上闪一下「暂无修读记录」。
    this.loadingCourses = PlanPage.setWith(this.loadingCourses, g.name, false);
  }

  /**
   * 取明细。会话失效时先静默续期再重试**一次**（与页面其它请求同一套恢复流程）。
   *
   * 返回 null = 这次没取到（原因已写进 hint）；调用方据此保持
   * coursesLoaded = false，让用户下次展开还能再试。
   */
  private async fetchCourses(rawName: string): Promise<ElectiveCourse[] | null> {
    const query: string = systemMergeKey(rawName);
    try {
      return await AppState.apiInstance().getElectiveCourses(query);
    } catch (e) {
      const renewed: boolean = await ReAuthService.recoverIfExpired(e, true);
      if (!renewed) {
        this.hint = AppError.isAuthExpired(e)
          ? '登录状态已过期，重新展开即会自动登录' : AppError.describe(e);
        return null;
      }
      try {
        return await AppState.apiInstance().getElectiveCourses(query);
      } catch (e2) {
        this.hint = AppError.describe(e2);
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
   * 体系卡片的 ForEach key。
   *
   * ===== 为什么要把渲染相关的状态全编进 key =====
   * ForEach 对 key 不变的数据项会**复用**已建好的子组件、不重新渲染。
   * 这张卡片的画面取决于：方案侧的门数与学分、注记、修读侧的
   * 自录要求学分、明细取没取过、课程数、是否展开、是否正在加载 ——
   * 只换数组而 key 不变，这些变化一个都不会反映到界面上
   * （实测：保存要求后要退出重进才看到）。把它们全部编进 key，
   * 任一变化即重建该卡片 —— 这也是展开态能立刻生效的机制：
   * expanded / loadingCourses 都是 @State，变了就换 key。
   */
  private groupKey(mg: MergedPlanGroup): string {
    let k: string = 'mg-' + mg.name + '-' + mg.planNote;
    if (mg.plan !== null) {
      k = k + '-p' + mg.plan.courses.length.toString()
        + '-' + mg.plan.totalCredit.toString();
    } else {
      k = k + '-pn';
    }
    const e: ElectiveGroup | null = mg.elective;
    if (e === null) {
      return k + '-en';
    }
    const loading: boolean = this.loadingCourses.has(e.name);
    return k + '-e' + e.customRequired.toString()
      + (e.coursesLoaded ? '-L' : '-U')
      + '-' + e.courses.length.toString()
      + (this.expanded.has(mg.name) ? '-O' : '-C')
      + (loading ? '-B' : '-I');
  }

  /**
   * 方案课程按**选课组**铺开（有组名时插一行小标题）。
   *
   * 保持原始顺序（不重排），与网页上看到的顺序一致。
   */
  private planRows(g: PlanGroup): PlanRow[] {
    const out: PlanRow[] = [];
    let lastGroup: string = '';
    for (let i = 0; i < g.courses.length; i++) {
      const c: PlanCourse = g.courses[i];
      const grp: string = c.group.trim();
      if (grp.length > 0 && grp !== lastGroup) {
        out.push(new PlanRow(grp, null));
        lastGroup = grp;
      }
      out.push(new PlanRow('', c));
    }
    return out;
  }

  // ==================== 要求学分编辑浮层 ====================

  /**
   * 打开「要求学分」编辑浮层。
   *
   * [displayName] 是归一后的体系名（卡片标题那份），只用于浮层展示；
   * **存储键仍用 `g.name` 原始值** —— 旧版通选页存的就是带 `(必修)` 后缀的
   * 原名，换键会让用户已录的要求全部失配（要重录一遍）。
   */
  private openRequirement(g: ElectiveGroup, displayName: string): void {
    this.reqCategory = g.name;
    this.reqDisplay = displayName;
    // 已有要求（无论来自用户还是学校）就预填，方便微调
    const cur: number = g.requiredNumber();
    this.reqInput = cur >= 0 ? cur.toString() : '';
    this.reqError = '';
  }

  /** 从卡片打开浮层（卡片侧的可空判断收在这里，回调里不做收窄） */
  private openRequirementOf(mg: MergedPlanGroup): void {
    const e: ElectiveGroup | null = mg.elective;
    if (e !== null) {
      this.openRequirement(e, mg.name);
    }
  }

  private closeRequirement(): void {
    this.reqCategory = '';
    this.reqDisplay = '';
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
    // 变化的那个体系换成新对象（见 withRequired 的说明），其余原样带过去；
    // 整条数组也换新，确保界面立刻反映新值。
    const next: ElectiveGroup[] = [];
    for (let i = 0; i < this.groups.length; i++) {
      const g: ElectiveGroup = this.groups[i];
      next.push(g.name === category ? PlanPage.withRequired(g, value) : g);
    }
    this.groups = next;
    this.hint = '';
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

  /** 某个体系当前是否有用户自录的要求（用于决定是否显示「清除」） */
  private isCategoryCustom(name: string): boolean {
    for (let i = 0; i < this.groups.length; i++) {
      if (this.groups[i].name === name) {
        return this.groups[i].hasCustomRequired();
      }
    }
    return false;
  }

  /**
   * 浮层面板高度（vp），按内容实算。
   *
   * 为什么不用固定值：面板里「清除该要求」是**条件出现**的，
   * 固定高度必然在其中一种状态下留一大块空白或裁掉按钮。
   * 计算口径 = 标题(20) + 体系名(18) + 间距 + 说明(16) + 输入框(46)
   *           + [清除按钮(42)] + 按钮行(46) + 上下内边距(2×PANEL_PAD)
   */
  private reqPanelHeight(): number {
    const base: number = 20 + 18 + 12 + 16 + 12 + 46 + 12 + 12 + 46 + GlassKit.PANEL_PAD * 2;
    const withClear: number = this.isCategoryCustom(this.reqCategory) ? (42 + 12) : 0;
    return base + withClear;
  }

  // ==================== 视图 ====================

  /** 操作结果提示条：可点掉，与设置页的提示条同一形态 */
  @Builder
  hintBanner() {
    Text(this.hint)
      .fontSize(Theme.FS_TINY)
      .fontColor($r('app.color.brand'))
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .borderRadius(Theme.RADIUS_SM)
      .backgroundColor($r('app.color.brand_soft'))
      .onClick(() => {
        this.hint = '';
      })
  }

  /**
   * 「刷新失败，以下是已有内容」提示条（哪个来源失败就写哪个）。
   *
   * 只写「刷新失败」会让人分不清是培养方案没了还是修读情况没了，
   * 而这两件事的处理完全不同。
   */
  @Builder
  staleBanner() {
    Column({ space: 2 }) {
      if (this.errorText.length > 0) {
        Text('培养方案：' + this.errorText)
          .fontSize(Theme.FS_TINY)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
      if (this.electiveError.length > 0) {
        Text('修读情况：' + this.electiveError)
          .fontSize(Theme.FS_TINY)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .borderRadius(Theme.RADIUS_SM)
    .backgroundColor($r('app.color.warning'))
    .opacity(0.92)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  introCard() {
    Column({ space: 8 }) {
      Text('培养目标')
        .fontSize(Theme.FS_SECTION)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      ForEach(this.plan.introParagraphs.concat(this.plan.detailParagraphs),
        (p: string, i: number) => {
          Text(p)
            .fontSize(Theme.FS_SMALL)
            .lineHeight(21)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
        }, (p: string, i: number) => 'intro-' + i.toString())
    }
    .width('100%')
    .padding(Theme.GAP)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(Theme.RADIUS_SM)
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 顶部总览：培养方案一行（门数/学分/学时），修读情况一行（已修/在修/体系数）。
   *
   * 两块各自独立：哪一边的数据没拿到（或本身就是空的）就少哪一行，
   * 另一边照常显示 —— 修读情况那侧有数据时，方案侧的空值不能显示成
   * 一排 0，那会让人以为「培养方案有 0 门课」而不是「这次没取到」。
   */
  @Builder
  summaryCard() {
    Column({ space: 10 }) {
      if (this.plan.courses.length > 0) {
        Row({ space: Theme.GAP }) {
          StatCell({ v: this.plan.courses.length.toString(), label: '门课程' })
          StatCell({ v: PlanPage.trimNum(this.plan.totalCredit), label: '总学分' })
          StatCell({ v: PlanPage.trimNum(this.plan.totalHours), label: '总学时' })
        }
        .width('100%')
      }
      if (this.plan.courses.length > 0 && this.groups.length > 0) {
        Divider()
          .strokeWidth(0.5)
          .color($r('app.color.divider'))
      }
      if (this.groups.length > 0) {
        Row({ space: Theme.GAP }) {
          StatCell({
            v: this.report.totalEarned.length === 0 ? '—' : this.report.totalEarned,
            label: '已修学分'
          })
          StatCell({
            v: this.report.totalOngoing.length === 0 ? '—' : this.report.totalOngoing,
            label: '正在修读'
          })
          // 这里**不显示「门课程」**：修读情况那一页本身不含课程明细
          // （明细在按需拉取的「详情」页里），该值恒为 0；而上一行
          // 已经给出了培养方案的课程门数。两个「门课程」并列时，
          // 一个 89、一个 0，看着像数据缺失，实际是重复指标。
          StatCell({ v: this.groups.length.toString(), label: '个体系' })
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(Theme.GAP_L)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(Theme.RADIUS_SM)
  }

  /** 小节标题（「培养方案课程 / 修读记录」），与体系卡片标题拉开层级 */
  @Builder
  sectionLabel(text: string) {
    Text(text)
      .fontSize(Theme.FS_SMALL)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .padding({ left: Theme.GAP, right: Theme.GAP, top: 10, bottom: 2 })
  }

  /** 选课组小标题（缩进 + 更淡的底色，与「课程体系」拉开层级） */
  @Builder
  subGroupHeader(name: string) {
    Text(name)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .padding({ left: Theme.GAP, right: Theme.GAP, top: 8, bottom: 8 })
      .backgroundColor($r('app.color.surface_variant'))
      .opacity(0.6)
  }

  @Builder
  courseRow(c: PlanCourse) {
    Row({ space: Theme.GAP_S }) {
      Column({ space: 2 }) {
        Text(c.courseName)
          .fontSize(Theme.FS_SMALL)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row({ space: 8 }) {
          if (c.courseCode.length > 0) {
            Text(c.courseCode)
              .fontSize(Theme.FS_TINY)
              .fontColor($r('app.color.text_tertiary'))
          }
          if (c.semester.length > 0) {
            Text('第' + c.semester + '学期')
              .fontSize(Theme.FS_TINY)
              .fontColor($r('app.color.text_tertiary'))
          }
          if (c.category.length > 0) {
            Text(c.category)
              .fontSize(Theme.FS_TINY)
              .fontColor($r('app.color.text_secondary'))
              .backgroundColor($r('app.color.surface_variant'))
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .borderRadius(4)
          }
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text(c.credit + ' 学分')
        .fontSize(Theme.FS_SMALL)
        .fontColor($r('app.color.brand'))
    }
    .width('100%')
    .padding({ left: Theme.GAP, right: Theme.GAP, top: 10, bottom: 10 })
    .border({ width: { top: 0.5 }, color: $r('app.color.divider') })
  }

  /**
   * 修读记录的一行（已出分 / 在修两种形态要能一眼区分）。
   *
   * 与旧版通选页同一套画法：左侧课名与课号，右侧学分与成绩；
   * 未出分（在修读）用文字「在修」+ 品牌色，出分的用大字重数字。
   */
  @Builder
  electiveCourseRow(c: ElectiveCourse) {
    Row({ space: Theme.GAP_S }) {
      Column({ space: 2 }) {
        Text(c.courseName)
          .fontSize(Theme.FS_BODY)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (c.courseCode.length > 0) {
          Text(c.courseCode)
            .fontSize(Theme.FS_TINY)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Column({ space: 2 }) {
        if (c.credit.length > 0) {
          Text(c.credit + ' 学分')
            .fontSize(Theme.FS_SMALL)
            .fontColor($r('app.color.text_secondary'))
        }
        Text(c.isOngoing() ? '在修' : c.score)
          .fontSize(c.isOngoing() ? Theme.FS_SMALL : 15)
          .fontWeight(c.isOngoing() ? FontWeight.Normal : FontWeight.Bold)
          .fontColor(c.isOngoing() ? $r('app.color.brand') : $r('app.color.text_primary'))
      }
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .padding({ left: Theme.GAP, right: Theme.GAP, top: 10, bottom: 10 })
    .border({ width: { top: 0.5 }, color: $r('app.color.divider') })
  }

  /** 扁平行列表：小标题行画底色标题，课程行画课程 */
  @Builder
  planRowList(rows: PlanRow[]) {
    ForEach(rows, (row: PlanRow) => {
      if (row.header.length > 0) {
        this.subGroupHeader(row.header)
      } else if (row.course !== null) {
        this.courseRow(this.rowCourse(row))
      }
    }, (row: PlanRow, i: number) => 'pr-' + i.toString() + '-'
      + row.header + '-' + (row.course === null ? '' : row.course.courseCode))
  }

  /**
   * 一个合并后的体系卡片。
   *
   * 交互刻意分成**两个互不嵌套的可点区域**：
   *   - 上半（体系名 + 门数学分 + 状态 + 注记 + 进度条）：展开/收起两类课程；
   *   - 下半（要求学分行）：编辑该体系的要求学分。
   * 之所以不把「编辑」按钮塞进可展开的那一块里：ArkUI 里子节点与父节点
   * 都有 onClick 时要靠手势竞争裁决，点编辑顺带把列表展开/收起一次，
   * 是很容易出现、又很难解释的交互 bug。分成两个兄弟区域就不会有歧义。
   *
   * 卡片的刷新由 groupKey 保证（见其说明）：这里读的所有状态
   * （expanded / loadingCourses / 明细与自录值）都在 key 里，
   * 任一变化都会让 ForEach 重建这张卡片，避开 @Builder 按值传递不刷新。
   */
  @Builder
  groupCard(mg: MergedPlanGroup) {
    Column() {
      // ---- 可点区域一：展开/收起 ----
      Column({ space: 6 }) {
        Row({ space: Theme.GAP_S }) {
          Text(mg.name)
            .fontSize(Theme.FS_BODY)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          // 方案侧：门数与学分（原培养方案卡片右上角那一截）
          if (this.hasPlanOf(mg)) {
            Text(this.planSummaryOf(mg))
              .fontSize(Theme.FS_TINY)
              .fontColor($r('app.color.text_tertiary'))
          }
          // 修读侧：达标状态（原通选卡片右上角那一截）
          if (this.hasElectiveOf(mg)) {
            Text(this.statusTextOf(mg))
              .fontSize(Theme.FS_TINY)
              .fontColor(this.statusColorOf(mg))
          }
          // 可展开就给箭头：收起时朝下（提示「点开」），展开时朝上（提示「收起」）
          if (this.isExpandable(mg)) {
            Text(this.expanded.has(mg.name) ? '︿' : '﹀')
              .fontSize(Theme.FS_TINY)
              .fontColor($r('app.color.text_tertiary'))
          }
        }
        .width('100%')

        // 培养方案格里附带的注记（如 `(应修 10 / 已修 6.5)`）：
        // 归一后名字单独作标题，注记单独一行 —— 它是真实数字，不丢
        if (mg.planNote.length > 0) {
          Text(mg.planNote)
            .fontSize(Theme.FS_TINY)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        }

        // 学分进度：只有存在要求时才画进度条（没有分母时画出来的长度没有意义）
        if (this.canShowProgressOf(mg)) {
          Progress({
            value: Math.min(this.progressDoneOf(mg), this.progressTotalOf(mg)),
            total: this.progressTotalOf(mg),
            type: ProgressType.Linear
          })
            .color(this.progressColorOf(mg))
            .width('100%')
        }
      }
      .width('100%')
      .padding({ left: Theme.GAP, right: Theme.GAP, top: 12, bottom: 12 })
      .alignItems(HorizontalAlign.Start)
      .onClick(() => {
        if (!this.isExpandable(mg)) {
          return;
        }
        this.toggle(mg);
      })

      // ---- 可点区域二：要求学分 ----
      // 按钮在**左**、学分统计在右：按钮是行动入口，放左侧更容易被扫到，
      // 也让各卡片的按钮纵向对齐；统计是结果，退到右边。
      if (this.hasElectiveOf(mg)) {
        Row({ space: Theme.GAP_S }) {
          Row({ space: 4 }) {
            AppIcon({
              res: 'edit',
              iconSize: 13,
              color: $r('app.color.brand')
            })
            Text(this.electiveHasCustomOf(mg) ? '修改要求' : '设置要求学分')
              .fontSize(Theme.FS_TINY)
              .fontColor($r('app.color.brand'))
              .maxLines(1)
          }
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .borderRadius(Theme.RADIUS_SM)
          .backgroundColor($r('app.color.brand_soft'))
          .onClick(() => {
            this.openRequirementOf(mg);
          })

          Text(this.statsLineOf(mg))
            .fontSize(Theme.FS_TINY)
            .fontColor($r('app.color.text_tertiary'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding({ left: Theme.GAP, right: Theme.GAP, bottom: 12 })
        .alignItems(VerticalAlign.Center)
      }

      // ---- 展开后的两组内容 ----
      if (this.expanded.has(mg.name)) {
        Divider()
          .strokeWidth(0.5)
          .color($r('app.color.divider'))

        // 培养方案课程（保留原培养方案的「选课组 → 课程」层级）
        if (this.hasPlanCoursesOf(mg)) {
          this.sectionLabel('培养方案课程')
          this.planRowList(this.planRowsOf(mg))
        }

        // 实际修读的课程（展开时才去抓详情页）
        if (this.hasElectiveOf(mg)) {
          this.sectionLabel('修读记录')
          if (this.coursesLoadingOf(mg)) {
            Row() {
              LoadingProgress()
                .width(16)
                .height(16)
                .color($r('app.color.brand'))
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding({ top: 14, bottom: 14 })
          } else if (this.electiveCoursesOf(mg).length === 0) {
            Text('该体系下暂无修读记录')
              .fontSize(Theme.FS_TINY)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .padding({ left: Theme.GAP, right: Theme.GAP, top: 12, bottom: 12 })
          } else {
            ForEach(this.electiveCoursesOf(mg), (c: ElectiveCourse) => {
              this.electiveCourseRow(c)
            }, (c: ElectiveCourse) => 'ec-' + this.electiveNameOf(mg) + '-'
              + c.courseCode + '-' + c.courseName)
          }
        }
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.surface'))
    .borderRadius(Theme.RADIUS_SM)
    .clip(true)
  }

  /** 修读侧是否已有用户自录要求（决定按钮文案「修改要求 / 设置要求学分」） */
  private electiveHasCustomOf(mg: MergedPlanGroup): boolean {
    const e: ElectiveGroup | null = mg.elective;
    return e !== null && e.hasCustomRequired();
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
        // 展示用归一后的体系名（与卡片标题一致）；存储键不在这里，见 openRequirement
        Text(this.reqDisplay)
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

  /** 页面主体列表 */
  @Builder
  contentList() {
    Scroll() {
      Column({ space: Theme.GAP }) {
        // 操作结果提示（成功/失败都走这里，可点掉）
        if (this.hint.length > 0) {
          this.hintBanner()
        }
        // 有缓存内容但这次刷新失败：提示一下，但**不**清掉内容
        if (this.errorText.length > 0 || this.electiveError.length > 0) {
          this.staleBanner()
        }
        if (this.plan.introParagraphs.length > 0
          || this.plan.detailParagraphs.length > 0) {
          this.introCard()
        }
        // 两边都没有数据时不出空卡片（例如方案侧失败、修读侧也空）
        if (this.plan.courses.length > 0 || this.groups.length > 0) {
          this.summaryCard()
        }

        Text('课程设置总表')
          .fontSize(Theme.FS_SECTION)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')

        ForEach(this.mergedGroups(), (mg: MergedPlanGroup) => {
          this.groupCard(mg)
        }, (mg: MergedPlanGroup) => this.groupKey(mg))

        Text('点分组标题可展开培养方案课程与修读记录')
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

  build() {
    // 下拉刷新：以 force 调用，**绕过 TTL 强制联网**（对齐 Flutter 端
    // 每页的 onRefresh: () => _load(force: true)）。没有它的话，
    // TTL 内（本页 6 小时）即使学校刚改了数据，下拉也只会重读缓存。
    Refresh({ refreshing: $$this.refreshing }) {
      Stack() {
        Column() {
          // 只要**任一**来源有内容就渲染列表：刷新/加载失败只在列表顶部提示。
          // 整屏替换会把用户已经在看的另一边内容也清掉 —— 培养方案是基本不变的
          // 数据，修读情况也是历史累计，都没有「失败就整页变空」的道理。
          if (this.hasPlanContent() || this.hasElectiveContent()) {
            this.contentList()
          } else if (this.loading || this.electiveLoading) {
            LoadingView({ message: '正在获取培养方案…' })
          } else if (this.combinedError().length > 0) {
            // 两边都不再加载、也都没有内容：错误优先，其次是「确实没有数据」
            ErrorView({
              message: this.combinedError(),
              onRetry: () => {
                this.load(true, true);
                this.loadElective(true, true);
              }
            })
          } else {
            // 两个请求都成功但都是空的（服务器上确实没有）：下拉仍然重新请求
            EmptyView({ title: '暂无培养方案数据' })
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.bg'))

        // 要求学分编辑浮层：作为页面内容之后的后序兄弟，叠在内容之上，
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
      this.refreshAll();
    })
    .layoutWeight(1)
    .width('100%')
  }
}
