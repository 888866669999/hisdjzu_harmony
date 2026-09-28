/*
 * ClassroomPage：空教室查询
 *
 * 数据源：教务系统「教室借用」页的筛选器 + 结果表
 * （`GET /jsxsd/kbxx/jsjy_query` 拿选项，`POST /jsxsd/kbxx/jsjy_query2` 拿占用）。
 * 选择「校区 + 教学楼 + 节次 + 周次 + 星期」，列出该时段的空闲教室。
 *
 * ===== 一个重要实现决策（已实测）=====
 * 查询**不把周次交给服务端**。服务端的 zc/zc2 有两个问题：
 *   1. 「借用」类记录完全无视周次，第 2 周的借用在任何一周都会出现；
 *   2. 按周筛选后，该周没有任何占用记录的教室会被整行丢弃
 *      （实测：不筛 231 间，筛第 4 周只剩 196 间）。
 * 第 2 点对「找空教室」是致命的——真正全周空闲的教室恰好就是被丢掉的那批。
 *
 * 因此改为：一次取回该校区该节次的**全学期**占用文本，
 * 再在客户端按周次+节次逐格判断是否空闲（逻辑在 ClassroomModels，有单测覆盖）。
 *
 * ===== 交互设计 =====
 *   - **自动查询**：进页面即查一次；改动学期/校区/节次会重新请求，
 *     换教学楼/星期/周次只在本地重算（见下）。
 *   - 重新请求的目的不只是换条件，也是**刷新数据**：教室占用是实时变化的
 *     （借用记录随时被编辑），所以改动查询条件时重新取一次。
 *   - **周次与节次的过滤仍在客户端做**（原因见上：服务端 zc/zc2 不可靠），
 *     即「请求拿全量 → 客户端按周/节次筛」，两者并不矛盾。
 *   - **教学楼不进请求**：本校的教学楼联动端点被挡死（见 QzApi.getBuildingsHtml），
 *     查询一律不带楼栋参数、取回全区教室，楼栋筛选由教室名推导后在本地做。
 *   - 星期行同时承担「本周空闲速览」：每天空闲几间直接标在当天下面，
 *     点哪天就切到哪天（早先这两者分成两行，看起来是重复的 UI，已合并）。
 *   - 并发请求用序号丢弃过期响应，避免慢的旧响应覆盖新结果。
 *   - 默认落在「当前教学周 + 今天」。
 */
import { AppState } from '../data/AppState';
import { GlassKit } from '../theme/GlassKit';
import { WeekService } from '../data/WeekService';
import { AppError } from '../common/Result';
import { ReAuthService } from '../data/ReAuthService';
import { PageCache, PageDataLoader, PageLoadResult } from '../data/PageCache';
import { QzApi } from '../network/QzApi';
import { ClassroomParser } from '../parser/ClassroomParser';
import { CACHE_CLASSROOM_OPTIONS, CACHE_CLASSROOM_USAGE,
  TTL_CLASSROOM_OPTIONS, TTL_CLASSROOM_USAGE } from '../common/Constants';
import { Logger } from '../common/Logger';
import { Theme } from '../theme/Theme';
import { shortSectionLabel, SECTIONS, SectionDef, MAX_WEEKS } from '../common/Constants';
import { ClassroomResult, ClassroomFinder, FreeRoom, DayFreeStat } from '../model/ClassroomModels';
import { ClassroomOptions } from '../network/QzApi';
import { ChoiceItem } from '../model/Models';
import { EmptyView, ErrorView, LoadingView } from '../components/StateViews';

@Component
export struct ClassroomPage {
  @State loading: boolean = false;
  @State errorText: string = '';
  /**
   * 下拉刷新状态（`$$` 双向绑定给 Refresh）。
   * 刷新结束必须置回 false，否则指示器会一直转 —— 见 search 的 finally。
   */
  @State refreshing: boolean = false;
  /** 选项 */
  @State campuses: string[] = [];
  @State semesters: string[] = [];
  @State buildings: ChoiceItem[] = [];
  /** 当前选择 */
  @State campusIdx: number = 0;
  @State semesterIdx: number = 0;
  @State buildingIdx: number = 0;
  @State sectionRow: number = 0;
  @State week: number = 1;
  @State day: number = 0;
  /** 结果 */
  @State result: ClassroomResult = new ClassroomResult();
  @State loaded: boolean = false;
  /** 提示文本（如“已按官方校历定位到第 4 周”） */
  @State hint: string = '';
  /** 空闲列表/周统计的记忆化缓存（见 freeRooms / weekStats 的说明） */
  private freeCache: FreeRoom[] | null = null;
  private freeCacheWeek: number = -1;
  private freeCacheDay: number = -1;
  /** 节次与楼栋是**本地**过滤条件，不进请求 —— 但缓存键必须含它们，否则切条件会拿到旧列表 */
  private freeCacheSection: number = -1;
  private freeCacheBuilding: string = '';
  private freeCacheResult: ClassroomResult | null = null;
  private statsCache: DayFreeStat[] | null = null;
  private statsCacheWeek: number = -1;
  private statsCacheSection: number = -1;
  private statsCacheResult: ClassroomResult | null = null;
  /** 查询序号，用于丢弃过期响应（见 search） */
  private searchSeq: number = 0;

  aboutToAppear(): void {
    this.initFromContext();
    this.loadOptions();
  }

  /** 用当前教学周与今天作为默认值 */
  private initFromContext(): void {
    const w: number = WeekService.cachedWeek();
    this.week = w > 0 ? w : 1;
    const dow: number = new Date().getDay();
    // JS: 0=周日；课表列 0=周一
    this.day = dow === 0 ? 6 : dow - 1;
  }

  /** 校区/学期选项的加载器（几乎不变的元数据，TTL 6 小时） */
  private optionsLoader(): PageDataLoader<ClassroomOptions> {
    return new PageDataLoader<ClassroomOptions>(
      PageCache.keyOf(AppState.account, CACHE_CLASSROOM_OPTIONS),
      () => AppState.apiInstance().getClassroomOptionsHtml(),
      (body: string) => QzApi.parseClassroomOptions(body),
      TTL_CLASSROOM_OPTIONS);
  }

  /**
   * 占用情况的加载器。
   *
   * key 带**全部查询条件**（含节次）：不同条件返回不同表格，混用会让用户
   * 看到别的条件的教室。星期与周次**不进 key** —— 服务端返回的本来就是
   * 整个学期的全周占用，那两项只是客户端读哪一列的选择。
   *
   * 教学楼参数传空串：服务端返回该校区**全部**教室，楼栋筛选改在客户端做
   * （见 ClassroomFinder.belongsTo 与 deriveBuildings）。原因：本校的教学楼
   * 联动端点被挡死（任何头部组合都回「非法访问」），拿不到楼栋 id；
   * 而教室名里本来就带着楼名，本地筛既准确又少一次请求。
   */
  private usageLoader(): PageDataLoader<ClassroomResult> {
    const sectionRow: number = this.sectionRow;
    return new PageDataLoader<ClassroomResult>(
      PageCache.keyOf(AppState.account, CACHE_CLASSROOM_USAGE,
        [this.semester(), this.campusId(), '', sectionRow.toString()]),
      () => AppState.apiInstance().getClassroomUsageHtml(
        this.semester(), this.campusId(), '', sectionRow),
      (body: string) => ClassroomParser.parseResult(body, sectionRow),
      TTL_CLASSROOM_USAGE);
  }

  /**
   * 从查询结果里推导教学楼候选。
   *
   * **不是**请求服务端拿的（那个端点被挡，见 usageLoader 的说明）：
   * 结果里每间教室都写着楼名（`信息楼211`、`博文馆101`），
   * 去重后就是完整的楼栋清单 —— 而且必然与当前查询结果自洽。
   */
  private deriveBuildings(r: ClassroomResult): void {
    const names: string[] = [];
    for (let i = 0; i < r.rooms.length; i++) {
      const b: string = ClassroomFinder.buildingOf(r.rooms[i].room);
      if (b.length > 0 && names.indexOf(b) < 0) {
        names.push(b);
      }
    }
    names.sort((a: string, b: string) => ClassroomFinder.compareRoom(a, b));
    // 换校区/换节次后原楼栋可能不存在，回到「全部」
    const current: string = this.buildingValue();
    const list: ChoiceItem[] = [];
    list.push(new ChoiceItem('全部教学楼', ''));
    for (let i = 0; i < names.length; i++) {
      list.push(new ChoiceItem(names[i], names[i]));
    }
    this.buildings = list;
    this.buildingIdx = (current.length > 0 && names.indexOf(current) >= 0)
      ? names.indexOf(current) + 1 : 0;
  }

  /** 拉取校区与学期选项，并默认选中第一个校区 */
  private async loadOptions(interactive: boolean = false): Promise<void> {
    // 已有选项时不铺整屏加载态（切页回来直接命中缓存）
    this.errorText = '';
    if (this.campuses.length === 0) {
      this.loading = true;
    }
    try {
      // 先记住当前选中的校区：下面会覆盖 campuses，之后再取就读到新列表里
      // 同一下标对应的**另一个**校区了
      const previousCampus: string = this.campusLabel();
      const opt: ClassroomOptions = (await this.optionsLoader().load(false)).data;
      this.campuses = opt.campuses;
      this.semesters = opt.semesters;
      // 学期默认选中与当前课表学期一致的那个
      const tt = AppState.timetable;
      if (tt !== null && tt.semester.length > 0) {
        const idx: number = this.semesters.indexOf(tt.semester);
        if (idx >= 0) {
          this.semesterIdx = idx;
        }
      }
      // ===== 默认校区不用校名硬编码 =====
      // 早先这里写着「优先选章丘」（参考实现留下的），对本校毫无意义 ——
      // 本校（山建大）的校区是「本部 / 烟台产学研基地 / 考试」。
      // 现在取下拉里的**第一项**：那是学校自己排的顺序，通常就是主校区，
      // 且换学校、换校区都不必改代码；已选过的校区仍存在时保留用户选择。
      const keepIdx: number = previousCampus.length > 0
        ? this.campusIndexByName(previousCampus) : -1;
      this.campusIdx = keepIdx >= 0 ? keepIdx : 0;
      // 教学楼候选由**查询结果**推导（见 deriveBuildings），这里先只留
      // 「全部教学楼」一项，等首次查询回来再填别的 —— 否则会先闪一排
      // 上一次校区的楼栋；下拉也必须是「至少一项」，不能是空数组
      this.buildings = [new ChoiceItem('全部教学楼', '')];
      this.buildingIdx = 0;
      // 选项就绪后自动做首次查询，用户进页面即可看到结果（无需点按钮）
      await this.search(interactive);
    } catch (e) {
      // 会话失效：先试静默续期，成功就重跑初始化；失败时自动加载只给内联提示
      const renewed: boolean = await ReAuthService.recoverIfExpired(e, interactive);
      if (renewed) {
        await this.loadOptions(interactive);
        return;
      }
      const msg: string = AppError.describe(e);
      this.errorText = AppError.isAuthExpired(e)
        ? '登录状态已过期，重新加载即可自动登录' : msg;
    } finally {
      this.loading = false;
    }
  }

  private campusIndexByName(keyword: string): number {
    for (let i = 0; i < this.campuses.length; i++) {
      if (this.campuses[i].indexOf(keyword) >= 0) {
        return i;
      }
    }
    return -1;
  }

  /** 校区 value 部分 */
  private campusId(): string {
    if (this.campusIdx < 0 || this.campusIdx >= this.campuses.length) {
      return '';
    }
    const raw: string = this.campuses[this.campusIdx];
    const at: number = raw.indexOf('|');
    return at > 0 ? raw.substring(0, at) : raw;
  }

  private campusLabel(): string {
    if (this.campusIdx < 0 || this.campusIdx >= this.campuses.length) {
      return '';
    }
    const raw: string = this.campuses[this.campusIdx];
    const at: number = raw.indexOf('|');
    return at > 0 ? raw.substring(at + 1) : raw;
  }

  private semester(): string {
    return (this.semesterIdx >= 0 && this.semesterIdx < this.semesters.length)
      ? this.semesters[this.semesterIdx] : '';
  }

  /**
   * 教学楼下拉当前选中的名称（'' = 全部）。
   * 楼栋是**本地**过滤条件（见 usageLoader 的说明），不进请求。
   */
  private buildingValue(): string {
    return (this.buildingIdx >= 0 && this.buildingIdx < this.buildings.length)
      ? this.buildings[this.buildingIdx].value : '';
  }

  private buildingLabel(): string {
    return (this.buildingIdx >= 0 && this.buildingIdx < this.buildings.length)
      ? this.buildings[this.buildingIdx].label : '全部教学楼';
  }

  /**
   * 执行查询。
   *
   * 用递增的序号丢弃过期响应：自动查询会在用户连续改动筛选条件时
   * 并发发出多个请求，慢的那个可能后回来，若不丢弃就会把新结果覆盖成旧结果。
   */
  private async search(interactive: boolean = false,
    force: boolean = false): Promise<void> {
    if (this.semester().length === 0) {
      this.errorText = '请先选择学期';
      return;
    }
    this.searchSeq = this.searchSeq + 1;
    const seq: number = this.searchSeq;
    this.loading = true;
    this.errorText = '';
    try {
      const r: ClassroomResult = (await this.usageLoader().load(force)).data;
      if (seq !== this.searchSeq) {
        // 已被更晚的请求取代，结果作废
        return;
      }
      // 楼栋候选由结果推导（见 deriveBuildings），必须与 result 一起更新，
      // 否则会闪一帧空下拉
      this.deriveBuildings(r);
      this.result = r;
      this.loaded = true;
      this.hint = '共 ' + r.rooms.length.toString() + ' 间教室，'
        + this.sectionLabel() + '，第 ' + this.week.toString() + ' 周';
      Logger.info('classroom search done: rooms=' + r.rooms.length);
    } catch (e) {
      if (seq !== this.searchSeq) {
        return;
      }
      // 查询多由用户点按钮/切下拉触发，因此这里多半是主动路径
      const renewed: boolean = await ReAuthService.recoverIfExpired(e, interactive);
      if (renewed) {
        await this.search(interactive);
        return;
      }
      const msg: string = AppError.describe(e);
      this.errorText = AppError.isAuthExpired(e)
        ? '登录状态已过期，重新加载即可自动登录' : msg;
      // **不清 loaded/result**：用户已经看到的教室列表比「这次查询成败」重要，
      // 清掉会让页面突然变空。保留旧结果 + 顶部一条提示。
      this.loaded = true;
    } finally {
      if (seq === this.searchSeq) {
        this.loading = false;
      }
      // 复位下拉指示器：`$$` 双向绑定，不置回会一直转
      this.refreshing = false;
    }
  }

  /**
   * 改**查询条件**（学期 / 校区 / 教学楼 / 节次）后重新查询。
   *
   * 这几个条件变了就是换数据：key 变了，缓存也会正常联网。
   * 数据的实时性由 TTL 保证（2 分钟，见 TTL_CLASSROOM_USAGE）——
   * 超过 2 分钟再改任何条件都会真的联网。
   */
  private onFilterChanged(): void {
    // 用户改筛选条件 → 主动查询，失败时可以直接弹重新验证
    this.search(true);
  }

  /**
   * 换星期 / 换周次 / 换教学楼：**不需要联网**。
   *
   * 服务端返回的本来就是整个学期的全周占用，这三项只是客户端读哪一列、
   * 取哪一批教室的选择（星期/周次/楼栋都不进缓存 key，见 usageLoader 的说明）。
   * @State 赋值本身就会触发重绘，而 freeRooms / weekStats 的记忆化键含
   * day/week/section/building，会自行重算 —— 所以这里刻意是空的。
   *
   * **不能**在这里递增 searchSeq：search 用它丢弃过期响应，而 loading 只在
   * 「序号仍是最新」时才复位；递增会让在途响应被丢掉且 loading 永远停在 true
   * ——页面卡在加载态，却没有任何请求在跑。
   */
  private onViewChanged(): void {
  }

  private sectionLabel(): string {
    // 统一成「第一节」这种写法，与课表左侧列、设置页一致
    return (this.sectionRow >= 0 && this.sectionRow < SECTIONS.length)
      ? shortSectionLabel(SECTIONS[this.sectionRow].label) : '';
  }

  /**
   * 当前选择下的空闲教室。
   *
   * 带记忆化：结果依赖 (week, day, section, building, result)，在 build 里会被
   * 调用多次（数量文本、空态判断、分组、总计），每次都要遍历并按教室号排序
   * 200+ 条，不缓存会做多遍同样的活。只在输入变化时重算。
   *
   * **节次与楼栋是本地过滤条件**（不参与请求），所以它们也必须进缓存键 ——
   * 否则切换节次/楼栋时列表不会重算，显示的还是上一次条件的结果。
   */
  private freeRooms(): FreeRoom[] {
    if (this.freeCache !== null && this.freeCacheWeek === this.week
      && this.freeCacheDay === this.day && this.freeCacheSection === this.sectionRow
      && this.freeCacheBuilding === this.buildingValue()
      && this.freeCacheResult === this.result) {
      return this.freeCache;
    }
    const all: FreeRoom[] = ClassroomFinder.freeRooms(
      this.result, this.day, this.week, this.sectionRow);
    const building: string = this.buildingValue();
    const v: FreeRoom[] = [];
    for (let i = 0; i < all.length; i++) {
      // 楼栋比较走严格口径（1 不能匹配 11），绝不用 contains
      if (building.length === 0 || all[i].building === building) {
        v.push(all[i]);
      }
    }
    this.freeCache = v;
    this.freeCacheWeek = this.week;
    this.freeCacheDay = this.day;
    this.freeCacheSection = this.sectionRow;
    this.freeCacheBuilding = building;
    this.freeCacheResult = this.result;
    return v;
  }

  /** 一周空闲统计（用于速览条）。口径必须与列表一致：都按当前节次 */
  private weekStats(): DayFreeStat[] {
    if (this.statsCache !== null && this.statsCacheWeek === this.week
      && this.statsCacheSection === this.sectionRow
      && this.statsCacheResult === this.result) {
      return this.statsCache;
    }
    const v: DayFreeStat[] = ClassroomFinder.weekStats(this.result, this.week, this.sectionRow);
    this.statsCache = v;
    this.statsCacheWeek = this.week;
    this.statsCacheSection = this.sectionRow;
    this.statsCacheResult = this.result;
    return v;
  }

  /** 某天某节次被占用的教室数 */
  private busyCount(): number {
    return ClassroomFinder.busyRooms(this.result, this.day, this.week, this.sectionRow).length;
  }

  private isToday(day: number): boolean {
    const dow: number = new Date().getDay();
    const todayCol: number = dow === 0 ? 6 : dow - 1;
    return day === todayCol && this.isCurrentWeek();
  }

  private isCurrentWeek(): boolean {
    return WeekService.cachedWeek() === this.week;
  }

  // ==================== 视图 ====================

  /**
   * 下拉行一律**内联**在 filterBar 里，不抽成带参数的 @Builder。
   *
   * 原因：ArkUI 里 @Builder 的参数按值传递，只在首次构建时求值。
   * 学期/校区这两个下拉的选项是异步加载的，首帧还是空数组，
   * 若把 value/options 当参数传给 Builder，之后就会永远显示空白
   * （选中项不回显）。直接写在 build 里读 this.* 才能随 @State 更新。
   */

  /**
   * 筛选栏：四个条件排成 2×2，教学楼单独占一行。
   *
   * ===== 为什么改成这个布局 =====
   * 早先是「标签 + 选择器」一行一个，五个条件占五行 —— 而这一页的主角是
   * **下面那份空教室列表**。筛选栏越高，能同时看到的教室就越少。
   * 现在：
   *   ┌──────────┬──────────┐
   *   │ 学期      │ 节次      │
   *   ├──────────┼──────────┤
   *   │ 校区      │ 周次      │
   *   ├──────────┴──────────┤
   *   │ 教学楼（单独一行）      │
   *   └─────────────────────┘
   * 五行压到三行，省下的高度全给列表。
   *
   * 标签从「左侧一列」改成「控件上方的小字」：半宽格里再切出 46vp 给标签，
   * 选择器只剩一百来 vp，学期名那样长的选项会被截断成「2026-2027 学…」。
   * 标签上移后选择器拿到整个格宽。
   *
   * ===== 为什么每个都内联、不抽 @Builder =====
   * ArkUI 里 @Builder 的参数按值传递，只在首次构建时求值。学期/校区这两个
   * 的选项是异步加载的，首帧还是空数组 —— 若把 value/options 当参数传给
   * Builder，之后就会永远显示空白（选中项不回显）。直接写在 build 里读
   * this.* 才能随 @State 更新。
   */
  @Builder
  filterBar() {
    Column({ space: Theme.GAP_S }) {
      // ---- 第一行：左上学期，右上节次 ----
      Row({ space: Theme.GAP_S }) {
        Column({ space: 4 }) {
          Text('学期')
            .fontSize(Theme.FS_TINY)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          Select(this.semesters.map((v: string) => {
            const opt: SelectOption = { value: v };
            return opt;
          }))
            .selected(this.semesterIdx)
            .value(this.semester())
            .font({ size: Theme.FS_SMALL })
            .width('100%')
            .backgroundColor($r('app.color.surface_variant'))
            .backgroundEffect(GlassKit.fieldEffect())
            .borderRadius(Theme.RADIUS_SM)
            .onSelect((index: number) => {
              this.semesterIdx = index;
              this.onFilterChanged();
            })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Column({ space: 4 }) {
          Text('节次')
            .fontSize(Theme.FS_TINY)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          Select(this.sectionLabels().map((v: string) => {
            const opt: SelectOption = { value: v };
            return opt;
          }))
            .selected(this.sectionRow)
            .value(this.sectionLabel())
            .font({ size: Theme.FS_SMALL })
            .width('100%')
            .backgroundColor($r('app.color.surface_variant'))
            .backgroundEffect(GlassKit.fieldEffect())
            .borderRadius(Theme.RADIUS_SM)
            .onSelect((index: number) => {
              this.sectionRow = index;
              this.onFilterChanged();
            })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // ---- 第二行：左下校区，右下周次 ----
      Row({ space: Theme.GAP_S }) {
        Column({ space: 4 }) {
          Text('校区')
            .fontSize(Theme.FS_TINY)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          Select(this.campusLabels().map((v: string) => {
            const opt: SelectOption = { value: v };
            return opt;
          }))
            .selected(this.campusIdx)
            .value(this.campusLabel())
            .font({ size: Theme.FS_SMALL })
            .width('100%')
            .backgroundColor($r('app.color.surface_variant'))
            .backgroundEffect(GlassKit.fieldEffect())
            .borderRadius(Theme.RADIUS_SM)
            .onSelect((index: number) => {
              this.campusIdx = index;
              // 教学楼候选随结果重新推导（deriveBuildings），无需单独拉列表
              this.onFilterChanged();
            })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Column({ space: 4 }) {
          Text('周次')
            .fontSize(Theme.FS_TINY)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          Select(this.weekLabels().map((v: string) => {
            const opt: SelectOption = { value: v };
            return opt;
          }))
            .selected(this.week - 1)
            .value('第 ' + this.week.toString() + ' 周' + (this.isCurrentWeek() ? '（本周）' : ''))
            .font({ size: Theme.FS_SMALL })
            .width('100%')
            .backgroundColor($r('app.color.surface_variant'))
            .backgroundEffect(GlassKit.fieldEffect())
            .borderRadius(Theme.RADIUS_SM)
            .onSelect((index: number) => {
              this.week = index + 1;
              this.onViewChanged();
            })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // ---- 第三行：教学楼单独占一行 ----
      //
      // 它是唯一选项文案可能很长（如「烟台产学研基地」）的条件，独占一行
      // 才不会截断；选项列表由查询结果推导（见 deriveBuildings），
      // 未出结果前只有「全部教学楼」一项。
      Column({ space: 4 }) {
        Text('教学楼')
          .fontSize(Theme.FS_TINY)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        Select(this.buildingLabels().map((v: string) => {
          const opt: SelectOption = { value: v };
          return opt;
        }))
          .selected(this.buildingIdx)
          .value(this.buildingLabel())
          .font({ size: Theme.FS_SMALL })
          .width('100%')
          .backgroundColor($r('app.color.surface_variant'))
          .backgroundEffect(GlassKit.fieldEffect())
          .borderRadius(Theme.RADIUS_SM)
          .onSelect((index: number) => {
            // 楼栋是纯本地过滤：换它不查服务端，但结果集必须重算
            // （freeRooms 的记忆化键里含楼栋）
            this.buildingIdx = index;
            this.onViewChanged();
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      /**
       * 星期选择（同时也是「本周空闲速览」）。
       *
       * 这里**只保留一行**：早先另有一张「本周空闲速览」卡片也画了同样的周一到周日，
       * 两行内容重复、看起来像 bug。现在把「选星期」和「每天空闲几间」合并到同一行，
       * 点哪天就切到哪天，各天的空闲数直接标在当天下面。
       */
      Row({ space: Theme.GAP_S }) {
        ForEach(this.weekStats(), (st: DayFreeStat) => {
          Column({ space: 1 }) {
            Text(ClassroomFinder.dayLabel(st.day))
              .fontSize(Theme.FS_SMALL)
              .fontWeight(this.day === st.day || this.isToday(st.day)
                ? FontWeight.Medium : FontWeight.Normal)
              // 只有「选中」用品牌色文字；「今天」改用描边标记（见下方 border）。
              // 早先今天也用品牌色文字，导致切到别的星期后仍有两处蓝色，
              // 看起来像「周三还是被选中」。
              .fontColor(this.day === st.day
                ? $r('app.color.on_brand') : $r('app.color.text_primary'))
            // 空闲数在首次查询完成前不显示，避免先闪一排 0
            if (this.loaded) {
              Text(st.free.toString())
                .fontSize(Theme.FS_TINY)
                .fontColor(this.day === st.day
                  ? $r('app.color.on_brand') : $r('app.color.text_secondary'))
            } else if (this.isToday(st.day)) {
              Text('今天')
                .fontSize(9)
                .fontColor(this.day === st.day
                  ? $r('app.color.on_brand') : $r('app.color.text_tertiary'))
            }
          }
          .layoutWeight(1)
          .height(52)
          .justifyContent(FlexAlign.Center)
          .borderRadius(Theme.RADIUS_SM)
          .backgroundColor(this.day === st.day
            ? $r('app.color.brand') : $r('app.color.surface_variant'))
          // 今天：未选中时用一圈描边表示，与「选中」的实心蓝区分开
          .border({
            width: (this.isToday(st.day) && this.day !== st.day) ? 1 : 0,
            color: $r('app.color.brand')
          })
          .onClick(() => {
            // 星期只决定读哪一列，不重新请求（数据本就是全周的）
            this.day = st.day;
            this.onViewChanged();
          })
        }, (st: DayFreeStat) => 'cd' + st.day.toString() + '-' + st.free.toString())
      }
      .width('100%')
    }
    .width('100%')
    .padding(Theme.GAP)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(Theme.RADIUS_SM)
  }

  private campusLabels(): string[] {
    const out: string[] = [];
    for (let i = 0; i < this.campuses.length; i++) {
      const raw: string = this.campuses[i];
      const at: number = raw.indexOf('|');
      out.push(at > 0 ? raw.substring(at + 1) : raw);
    }
    return out;
  }

  private buildingLabels(): string[] {
    const out: string[] = [];
    for (let i = 0; i < this.buildings.length; i++) {
      out.push(this.buildings[i].label);
    }
    return out;
  }

  private sectionLabels(): string[] {
    const out: string[] = [];
    for (let i = 0; i < SECTIONS.length; i++) {
      const s: SectionDef = SECTIONS[i];
      out.push(s.label + '  ' + s.start);
    }
    return out;
  }

  private weekLabels(): string[] {
    const out: string[] = [];
    for (let i = 1; i <= MAX_WEEKS; i++) {
      out.push('第 ' + i.toString() + ' 周');
    }
    return out;
  }

  /**
   * 一周速览已合并进 filterBar 的星期行（见那里的说明），
   * 这里不再单独渲染一张卡片，避免出现两行一模一样的「周一到周日」。
   */

  /** 空教室列表 */
  @Builder
  freeList() {
    Column({ space: Theme.GAP_S }) {
      Row() {
        Text(ClassroomFinder.dayLabel(this.day) + ' 空闲教室')
          .fontSize(Theme.FS_SECTION)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text(this.freeRooms().length.toString() + ' 间')
          .fontSize(Theme.FS_SMALL)
          .fontColor($r('app.color.brand'))
      }
      .width('100%')

      if (this.freeRooms().length === 0) {
        Text('该时段没有空闲教室')
          .fontSize(Theme.FS_SMALL)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 20, bottom: 20 })
      } else {
        // 按教学楼分组展示，便于按楼找教室
        ForEach(this.groupedFree(), (grp: RoomGroup) => {
          Column({ space: 4 }) {
            Text(grp.title() + '（' + grp.rooms.length.toString() + '）')
              .fontSize(Theme.FS_TINY)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(grp.rooms, (f: FreeRoom) => {
                // 教室名已在解析层剥掉 `(容量/人数)` 与 `[编码]`（见
                // ClassroomParser.stripCapacity），这里直接显示，不再截断
                Text(f.room)
                  .fontSize(Theme.FS_SMALL)
                  .fontColor($r('app.color.text_primary'))
                  .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                  .margin({ right: 6, bottom: 6 })
                  .backgroundColor($r('app.color.surface_variant'))
                  .borderRadius(Theme.RADIUS_SM)
              }, (f: FreeRoom) => f.room)
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }, (grp: RoomGroup) => 'g' + grp.building)
      }

      if (this.busyCount() > 0) {
        Text('该时段有 ' + this.busyCount().toString() + ' 间教室在上课或已被借用')
          .fontSize(Theme.FS_TINY)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
    }
    .width('100%')
    .padding(Theme.GAP)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(Theme.RADIUS_SM)
    .alignItems(HorizontalAlign.Start)
  }

  /** 按教学楼分组 */
  private groupedFree(): RoomGroup[] {
    const rooms: FreeRoom[] = this.freeRooms();
    const groups: RoomGroup[] = [];
    for (let i = 0; i < rooms.length; i++) {
      // 楼名在解析层已提取（ClassroomFinder.buildingOf），这里只做归并；
      // 空串（取不出楼名）统一归到「其他」一组，不能每间自成一栋
      const head: string = rooms[i].building;
      let found: RoomGroup | null = null;
      for (let j = 0; j < groups.length; j++) {
        if (groups[j].building === head) {
          found = groups[j];
          break;
        }
      }
      if (found === null) {
        const g: RoomGroup = new RoomGroup(head);
        g.rooms.push(rooms[i]);
        groups.push(g);
      } else {
        found.rooms.push(rooms[i]);
      }
    }
    // 组间按楼名排序，保证「信息楼」不会忽前忽后
    groups.sort((a: RoomGroup, b: RoomGroup) => ClassroomFinder.compareRoom(a.building, b.building));
    return groups;
  }

  build() {
    Column({ space: Theme.GAP }) {
      // 筛选栏固定在外：它是操作控件，让它跟着下拉一起位移会显得整页在动
      // （Flutter 端也是筛选栏固定、只有列表区可下拉）。
      this.filterBar()

      if (this.loading) {
        LoadingView({ message: '正在查询教室占用…' })
      } else if (this.errorText.length > 0 && !this.loaded) {
        // 没有任何结果可显示时才整屏报错；有结果时错误降级为列表上方横幅
        ErrorView({
          message: this.errorText,
          onRetry: () => {
            this.loadOptions(true);
          }
        })
      } else if (!this.loaded) {
        EmptyView({
          title: '正在准备教室数据…',
          hint: '进入页面会自动查询；调整校区、教学楼或节次后也会自动刷新'
        })
      } else if (this.result.rooms.length === 0) {
        EmptyView({
          title: '没有查到教室',
          hint: '该条件下没有教室数据，可换教学楼或节次再试'
        })
      } else {
        // 下拉刷新：force 重查，**绕过 2 分钟 TTL 强制联网**
        // （对齐 Flutter 端本页的 onRefresh: () => _search(force: true)）。
        //
        // Refresh 的子树**只放一个容器组件**（这里是 Scroll）：
        // ArkUI 对 Refresh 的子节点有这一条要求，塞进 if/else 链或多层容器
        // 会让属性链解析错位（实测报 「Property 'onRefreshing' does not exist
        // on type 'ColumnAttribute'」——编译器把 onRefreshing 挂到了内层 Column）。
        Refresh({ refreshing: $$this.refreshing }) {
          Scroll() {
            Column({ space: Theme.GAP }) {
              if (this.hint.length > 0) {
                Text(this.hint)
                  .fontSize(Theme.FS_TINY)
                  .fontColor($r('app.color.text_tertiary'))
                  .width('100%')
              }
              // ===== 失败提示必须真的显示出来 =====
              // 查询失败时**刻意保留**上一次的教室列表（用户已经看到的比
              // 「这次查询成败」重要），但保留旧数据的同时必须说清楚
              // 「这是旧数据」—— 否则换个节次查询失败时，页面照样列着
              // 上一个节次的空闲教室，而标题已被换成新条件，看起来像查成功了。
              //
              // 早先这条横幅只在 `!loaded` 时渲染，而 catch 里又把 loaded
              // 置成了 true —— 于是提示**永远不会出现**，用户看到的现象
              // 就是「切了节次，列表没变」。
              if (this.errorText.length > 0) {
                Row({ space: Theme.GAP_S }) {
                  Text(this.errorText)
                    .fontSize(Theme.FS_SMALL)
                    .fontColor($r('app.color.danger'))
                    .layoutWeight(1)
                  Text('重试')
                    .fontSize(Theme.FS_SMALL)
                    .fontColor($r('app.color.brand'))
                    .onClick(() => {
                      this.search(true, true);
                    })
                }
                .width('100%')
                .padding({ top: 2, bottom: 2 })
              }
              this.freeList()
            }
            .width('100%')
            // 底部多留出浮层 dock 的高度，否则最后一间教室会被玻璃压住
            .padding({ bottom: Theme.bottomInset() })
          }
          .layoutWeight(1)
          .align(Alignment.Top)
        }
        .onRefreshing(() => {
          this.search(false, true);
        })
        .layoutWeight(1)
        .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .padding(Theme.GAP)
    .backgroundColor($r('app.color.bg'))
  }
}

/** 按教学楼分组的空闲教室 */
class RoomGroup {
  building: string = '';
  rooms: FreeRoom[] = [];

  constructor(building: string) {
    this.building = building;
  }

  /** 组标题：取不出楼名时显示「其他」，不能留空标题 */
  title(): string {
    return this.building.length > 0 ? this.building : '其他';
  }
}
