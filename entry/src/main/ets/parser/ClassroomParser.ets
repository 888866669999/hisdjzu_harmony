/*
 * ClassroomParser：解析空闲教室查询结果
 *
 * ===== 本校与旧校的页面结构不同，两种都要支持 =====
 *
 * 旧校（`/jsxsd/kbcx/kbxx_classroom_ifr`）返回一张 `#kbtable`：
 *   表头是 `教室 | 星期一 … 星期日`（8 列），数据行首列是教室名。
 *
 * 本校（`POST /jsxsd/kbxx/jsjy_query2`，返回 `#dataList`）是**三行表头** + 数据行：
 *   行 0：`功能区名称 | 教室名称 | 查询`（合并单元格，忽略）
 *   行 1：`星期 | 星期一 … 星期日` —— **8 格**，星期列是 colspan=5
 *   行 2：`'' | 0102 | 030405 | 0607 | 0809 | 101112 | 0102 …`
 *         —— **36 格** = 7 天 × 5 大节，每格是该大节的小节编号
 *   行 3+：`教室名(容量/人数) | 各节次格子（有内容=占用，空=空闲）`
 *
 *   **关键差别**：本校的节次维度在第 2 行表头（`0102` 这种小节编号），
 *   不能像旧校那样只靠「列数/位置」推断 —— 那样会把周三的占用算到周二去。
 *   因此本校结构必须读那一行才能建列映射。
 *
 * ===== 空闲的判定是共用的 =====
 * 两边返回的都是「按条件筛出的结果」：**格子里有内容 = 被占用**，空 = 空闲。
 *
 * ===== 表头列数不固定 =====
 * 结果表可能是 8 列（单节次）也可能是 36 列（多节次）。因此**不能按列下标
 * 硬映射星期**，必须按表头文本动态建映射；本校再叠加第 2 行的节次划分。
 *
 * 周次过滤**不交给服务端**：解析阶段原样保留格子里的周次说明，
 * 由 ClassroomModels 在客户端按周判断（原因见该文件顶部说明）。
 */
import { HtmlLite, HtmlTable, HtmlCell, HtmlOption } from './HtmlLite';
import { Logger } from '../common/Logger';
import {
  ClassroomResult, RoomSlot, RoomBooking, WeekSpec, WeekSpecParser
} from '../model/ClassroomModels';

/** 课表的大节数（本校 5 个）。解析器保持纯函数，不引 Constants */
const SECTION_COUNT: number = 5;

export class ClassroomParser {
  /** 解析查询页里的校区选项。下拉 name 各校不同：本校 xqbh，旧校 xqid */
  static parseCampuses(html: string): string[] {
    const names: string[] = ['xqbh', 'xqid'];
    for (let i = 0; i < names.length; i++) {
      const opts: HtmlOption[] = HtmlLite.findSelect(html, names[i]);
      const out: string[] = [];
      for (let k = 0; k < opts.length; k++) {
        const v: string = opts[k].value;
        const label: string = opts[k].label;
        // "-请选择-" 不作为可选项；拼成 "01|本部" 便于直接回传与展示
        if (v.length > 0 && label.length > 0) {
          out.push(v + '|' + label);
        }
      }
      if (out.length > 0) {
        return out;
      }
    }
    return [];
  }

  /**
   * 解析查询页里的学期选项。
   *
   * ===== 本校的学期**不是下拉**，是隐藏字段（实测）=====
   * 页面里写作 `<input type="hidden" name="xnxqh" value="2026-2027-1">`，
   * 另有一行只读文本；学校就是把下拉改成了固定值。
   *
   * 早先只查 `select`，于是永远返回空列表 → 空教室页直接卡在
   * 「请先选择学期」，一次查询都发不出去（而界面上看不出是为什么）。
   * 因此顺序是：先找下拉（别处仍是下拉），找不到再读隐藏字段。
   */
  static parseSemesters(html: string): string[] {
    const names: string[] = ['xnxqh', 'xnxq01id'];
    for (let i = 0; i < names.length; i++) {
      const opts: HtmlOption[] = HtmlLite.findSelect(html, names[i]);
      const out: string[] = [];
      for (let k = 0; k < opts.length; k++) {
        if (opts[k].value.length > 0) {
          out.push(opts[k].value);
        }
      }
      if (out.length > 0) {
        return out;
      }
    }
    // 兜底：隐藏字段里那个「当前学期」
    for (let i = 0; i < names.length; i++) {
      const v: string = HtmlLite.findInputValue(html, names[i]).trim();
      if (v.length > 0) {
        return [v];
      }
    }
    return [];
  }

  /**
   * 解析结果表。
   * @param sectionRow 本次查询的节次行号，写入结果便于界面回显
   */
  static parseResult(html: string, sectionRow: number): ClassroomResult {
    const result: ClassroomResult = new ClassroomResult();
    result.sectionRow = sectionRow;

    // 表 id 各校不同：本校 dataList、旧校 kbtable
    let table: HtmlTable | null = HtmlLite.findTableById(html, 'dataList');
    if (table === null) {
      table = HtmlLite.findTableById(html, 'kbtable');
    }
    if (table === null || table.rows.length === 0) {
      Logger.warn('classroom table not found');
      return result;
    }

    // 先按本校的三行表头结构试；不像就走旧校那套
    const local: ClassroomResult | null = ClassroomParser.parseLocalLayout(table, sectionRow);
    const parsed: ClassroomResult = local !== null
      ? local : ClassroomParser.parseReferenceLayout(table, sectionRow);
    Logger.info('classroom parsed: rooms=' + parsed.rooms.length +
      ' rows=' + table.rows.length + ' sectionRow=' + sectionRow);
    return parsed;
  }

  /**
   * 本校布局（三行表头 + `教室名(容量/人数)` 行首）。
   * 返回 null 表示「不是这个结构」，交给旧校布局的解析。
   */
  private static parseLocalLayout(table: HtmlTable, sectionRow: number): ClassroomResult | null {
    // ---- 找「星期表头行」与紧随其后的「节次编号行」----
    let dayRow: number = -1;
    const scan: number = table.rows.length < 4 ? table.rows.length : 4;
    for (let i = 0; i < scan; i++) {
      const t: string = table.rows[i].text;
      if (t.indexOf('星期一') >= 0 && t.indexOf('星期日') >= 0) {
        dayRow = i;
        break;
      }
    }
    if (dayRow < 0 || dayRow + 1 >= table.rows.length) {
      return null;
    }
    const dayCells: HtmlCell[] = table.rows[dayRow].cells;
    const secCells: HtmlCell[] = table.rows[dayRow + 1].cells;
    if (!ClassroomParser.looksLikeLocalHeader(dayCells, secCells)) {
      // 认错了代价极大：旧校宽表的表头也是「8 格星期」形态，一旦按本校的
      // 「5 列一天」规则去切，列会整体错位（数据看着正常，日子却是错的）
      return null;
    }

    // ===== 列映射必须靠**节次编号行**，不能靠星期表头 =====
    //
    // 早先按行 1（星期表头）的格号建映射：它只有 8 格，于是
    //   列1..5（周一的五个大节）被当成周一…周五，
    //   列6..7（周二前两节）被当成周六、周日，
    //   **周三到周日的数据一格都没读**。
    // 而查询「完全空闲」时所有格子都是空的，结果看起来完全正常 ——
    // 直到某间教室有占用，才会把周二的内容显示到周一。
    //
    // 正确做法：行 2 的格 i 对应「天 = (i-1) ÷ 5、大节 = (i-1) % 5」。
    const dayOfCol: number[] = [];
    const sectionOfCol: number[] = [];
    for (let c = 0; c < secCells.length; c++) {
      dayOfCol.push(-1);
      sectionOfCol.push(-1);
    }
    let mapped: number = 0;
    for (let c = 1; c < secCells.length; c++) {
      const day: number = Math.floor((c - 1) / SECTION_COUNT);
      const sec: number = (c - 1) % SECTION_COUNT;
      if (day >= 0 && day < 7) {
        dayOfCol[c] = day;
        sectionOfCol[c] = sec;
        mapped++;
      }
    }
    // 一格有效列都没有 → 不是本校结构（否则会把旧校页面解析成「全部空闲」，
    // 那种结果看起来完全正常，却是错的）
    if (mapped === 0) {
      return null;
    }

    const result: ClassroomResult = new ClassroomResult();
    result.sectionRow = sectionRow;
    for (let r = dayRow + 2; r < table.rows.length; r++) {
      const cells: HtmlCell[] = table.rows[r].cells;
      if (cells.length < 2) {
        continue;
      }
      const roomRaw: string = ClassroomParser.clean(cells[0].text);
      if (roomRaw.length === 0 || roomRaw.indexOf('教室名称') >= 0) {
        continue;
      }
      const slot: RoomSlot = new RoomSlot();
      slot.room = ClassroomParser.stripCapacity(roomRaw);
      for (let c = 1; c < dayOfCol.length && c < cells.length; c++) {
        const day: number = dayOfCol[c];
        if (day < 0) {
          continue;
        }
        const sec: number = sectionOfCol[c];
        // 同一格同时记两份：按天（粗粒度）与按天+节次（精确）。
        // 只记前者的后果见 RoomSlot.bySection 的说明。
        const bookings: RoomBooking[] = ClassroomParser.parseCell(cells[c]);
        for (let k = 0; k < bookings.length; k++) {
          slot.bySection[day][sec].push(bookings[k]);
          slot.days[day].push(bookings[k]);
        }
      }
      result.rooms.push(slot);
    }
    return result;
  }

  /** 旧校布局（表头单行星期、首列教室名） */
  private static parseReferenceLayout(table: HtmlTable, sectionRow: number): ClassroomResult {
    const result: ClassroomResult = new ClassroomResult();
    result.sectionRow = sectionRow;

    // 1) 建「列 → 星期」映射：表头可能重复出现（跨节次组合时 5 组），
    //    每个星期取第一次出现
    const dayOfCol: number[] = [];
    let seen: number = 0;
    const head: HtmlCell[] = table.rows[0].cells;
    for (let c = 0; c < head.length; c++) {
      const day: number = ClassroomParser.dayIndex(head[c].text);
      if (day >= 0 && (seen & (1 << day)) === 0) {
        seen = seen | (1 << day);
        dayOfCol.push(day);
      } else {
        dayOfCol.push(-1);
      }
    }
    // 表头识别失败时退回「第 1 列起依次为周一到周日」
    if (seen === 0) {
      for (let c = 0; c < dayOfCol.length; c++) {
        dayOfCol[c] = (c >= 1 && c <= 7) ? c - 1 : -1;
      }
    }

    // 宽表（≥30 列）时每 5 列一组：与本校布局同样的划分规则。
    // 窄表（8 列 = 单节次查询）时所有列都归第 0 节。
    let multiSection: boolean = false;
    for (let r = 0; r < table.rows.length; r++) {
      if (table.rows[r].cells.length >= SECTION_COUNT * 6) {
        multiSection = true;
        break;
      }
    }

    // 2) 数据行从第 2 行开始（第 1 行是节次标签）
    for (let r = 1; r < table.rows.length; r++) {
      const cells: HtmlCell[] = table.rows[r].cells;
      if (cells.length < 2) {
        continue;
      }
      const room: string = ClassroomParser.clean(cells[0].text);
      if (room.length === 0 || room.indexOf('教室') >= 0) {
        continue;
      }
      const slot: RoomSlot = new RoomSlot();
      slot.room = room;
      for (let c = 1; c < dayOfCol.length && c < cells.length; c++) {
        const day: number = dayOfCol[c];
        if (day < 0) {
          continue;
        }
        const sec: number = multiSection ? ((c - 1) % SECTION_COUNT) : 0;
        const bookings: RoomBooking[] = ClassroomParser.parseCell(cells[c]);
        for (let k = 0; k < bookings.length; k++) {
          slot.bySection[day][sec].push(bookings[k]);
          slot.days[day].push(bookings[k]);
        }
      }
      result.rooms.push(slot);
    }
    return result;
  }

  /**
   * 判断「星期行 + 紧随其后的一行」是不是本校的三行表头结构。
   *
   * 两条互相独立的证据，命中一条即可：
   *   a) 星期行里至少 7 个格子的 colspan = 5 —— 说明底下的 36 列就是
   *      「每天连续 5 列」，正是本校「5 列一天」的划分前提；
   *   b) 下一行的格子里是本校那套小节编号循环 `0102/030405/0607/0809/101112`。
   *
   * 为什么必须判：旧校宽表的表头**同样是 8 格星期**（只是没有 colspan），
   * 一旦被误认为本校结构，就会按「5 列一天」去切旧校的「7 列一组」，
   * 两个布局的列序不同 → 整表错位，而错位后的结果看着完全正常。
   */
  private static looksLikeLocalHeader(dayCells: HtmlCell[], secCells: HtmlCell[]): boolean {
    // a) 星期列各自跨 5 列（本校）
    let spanned: number = 0;
    for (let c = 1; c < dayCells.length; c++) {
      if (dayCells[c].colspan === SECTION_COUNT) {
        spanned++;
      }
    }
    if (spanned >= 7) {
      return true;
    }
    // b) 节次编号行的 5 格循环（应对表头没写 colspan 的情况）
    if (secCells.length < SECTION_COUNT * 2 + 1) {
      return false;
    }
    const cycle: string[] = ['0102', '030405', '0607', '0809', '101112'];
    for (let c = 1; c < secCells.length; c++) {
      // 格子文本是 `01<br>02`，换行会变成空格，比较前先把空白全去掉
      const t: string = secCells[c].text.replace(/\s+/g, '');
      if (t !== cycle[(c - 1) % SECTION_COUNT]) {
        return false;
      }
    }
    return true;
  }

  /**
   * 把教室名里的**冗余后缀**去掉，只留教室本身的名字。
   *
   * 服务端给的是 `博文馆101[媒159](159/72)`，三段各有各的毛病：
   *   - `(159/72)` 是「容量/当前人数」。留着的后果不只是多一截数字：
   *     同一间教室人数一变就被当成两间，排序与计数都会乱。
   *   - `[媒159]` 是教室编码前缀（媒=多媒体、智=智慧教室，数字与容量相同），
   *     纯粹是内部标记，学生找教室用不到，却占掉卡片近一半宽度。
   *
   * 因此两段都去掉，只留 `博文馆101` —— 那才是要找的名字。
   */
  private static stripCapacity(raw: string): string {
    let s: string = raw.trim();
    // 先剥尾部的 `(容量/人数)`；个别行没这一段，剥不到就原样继续
    const cap: RegExpMatchArray | null =
      s.match(/^(.+?)\s*[（(]\s*\d+\s*\/\s*\d+\s*[)）]\s*$/);
    if (cap !== null && cap.length >= 2) {
      s = cap[1].trim();
    }
    // 再剥尾部的 `[编码]`
    const br: RegExpMatchArray | null = s.match(/^(.+?)\s*\[[^\]]*\]\s*$/);
    if (br !== null && br.length >= 2) {
      s = br[1].trim();
    }
    return s.length === 0 ? raw.trim() : s;
  }

  /**
   * 解析一个单元格。一个格子可能有多条占用（多门课 / 课程 + 借用），
   * 以 <br> 分隔，这里逐段识别。
   */
  private static parseCell(cell: HtmlCell): RoomBooking[] {
    const out: RoomBooking[] = [];
    const raw: string = cell.inner;
    if (raw.length === 0 || raw.trim().length === 0) {
      return out;
    }
    const parts: string[] = raw.split(/<br\s*\/?>/i);
    for (let i = 0; i < parts.length; i++) {
      const text: string = ClassroomParser.clean(HtmlLite.toText(parts[i]));
      if (text.length === 0) {
        continue;
      }
      const b: RoomBooking | null = ClassroomParser.parseBooking(text);
      if (b !== null) {
        out.push(b);
      }
    }
    // 兜底：有文本但按 <br> 切分后什么都没解析出来，
    // 保守判为占用（宁可少报空闲，不要误报）——周次说明能取到就取
    if (out.length === 0) {
      const text: string = ClassroomParser.clean(HtmlLite.toText(raw));
      if (text.length > 0) {
        const b: RoomBooking = new RoomBooking();
        const lines: string[] = text.split('\n');
        b.label = lines[0];
        const spec: WeekSpec | null = WeekSpecParser.first(text);
        if (spec !== null) {
          b.spec = spec;
        }
        out.push(b);
      }
    }
    return out;
  }

  /** 把一段文本解析成占用记录 */
  private static parseBooking(text: string): RoomBooking | null {
    const b: RoomBooking = new RoomBooking();
    b.label = text;
    const parsed: WeekSpec | null = WeekSpecParser.first(text);
    b.spec = parsed !== null ? parsed : new WeekSpec();

    // ---- 借用形态：被借用( 第(2周)(01-04节)周,王超,学生活动 ) ----
    const bi: number = text.indexOf('被借用');
    if (bi >= 0) {
      b.borrowed = true;
      const after: string = text.substring(bi + 3);
      // 第一个括号段的内容
      const m: RegExpMatchArray | null = after.match(/\(\s*([^)]*)\s*\)/);
      const inner: string = (m !== null && m.length >= 2) ? m[1].trim() : '';
      const segs: string[] = [];
      const rawSegs: string[] = inner.split(/[,，]/);
      for (let i = 0; i < rawSegs.length; i++) {
        const s: string = rawSegs[i].trim();
        if (s.length > 0) {
          segs.push(s);
        }
      }
      let person: string = '';
      let label: string = '被借用';
      if (segs.length >= 2 && segs[1].indexOf('第') < 0) {
        person = segs[1];
      }
      if (segs.length >= 3) {
        label = '借用：' + segs[2].replace(/[)）\s]+$/, '');
      }
      if (person.length > 0) {
        label = label + ' · ' + person;
      }
      // 周次说明应从「被借用」之后找起，别把前面的杂项也吃进来
      const weekSrc: string = text.indexOf('(') >= 0 ? after : text;
      const spec: WeekSpec | null = WeekSpecParser.first(weekSrc);
      b.label = label;
      b.person = person;
      b.spec = spec !== null ? spec : new WeekSpec();
      return b;
    }

    // ---- 课程形态：`课程名 教师\n(3-18周)\n班级` ----
    // 先取出周次说明所在括号的位置，把它之前的整段作为「课程名 + 教师」
    const at: number = text.indexOf('(');
    const head: string = at > 0 ? ClassroomParser.clean(text.substring(0, at)) : text;
    if (head.length === 0) {
      return null;
    }
    // 「课程名 教师」以空格分隔，最后一段通常是教师名（2-6 个汉字）
    const sp: string[] = head.split(/\s+/);
    if (sp.length >= 2) {
      const last: string = sp[sp.length - 1];
      if (ClassroomParser.looksLikeName(last)) {
        b.person = last;
        const nameParts: string[] = [];
        for (let i = 0; i < sp.length - 1; i++) {
          nameParts.push(sp[i]);
        }
        b.label = nameParts.join(' ');
      } else {
        b.label = head;
      }
    } else {
      b.label = head;
    }
    // 周次括号之后的剩余部分通常是班级
    if (at > 0) {
      const rest: string = text.substring(at);
      const close: number = rest.indexOf(')');
      if (close >= 0 && close + 1 < rest.length) {
        b.className = ClassroomParser.clean(rest.substring(close + 1));
      }
    }
    return b;
  }

  /** 2-6 个汉字视为人名 */
  private static looksLikeName(s: string): boolean {
    if (s.length < 2 || s.length > 6) {
      return false;
    }
    return /^[\u4e00-\u9fa5·]+$/.test(s);
  }

  /** 星期的短标签 → 索引；"星期一" → 0 */
  private static dayIndex(text: string): number {
    const t: string = text.replace(/\s/g, '');
    const names: string[] = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
    for (let i = 0; i < names.length; i++) {
      if (t.indexOf(names[i]) >= 0) {
        return i;
      }
    }
    // 有的页面用「周一」写法
    const short: string[] = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    for (let i = 0; i < short.length; i++) {
      if (t.indexOf(short[i]) >= 0) {
        return i;
      }
    }
    return -1;
  }

  /** 清理文本：去 &nbsp;、多余空白与换行 */
  private static clean(s: string): string {
    if (s === undefined || s === null) {
      return '';
    }
    return s.replace(/\u00a0/g, ' ').replace(/\s+/g, ' ').trim();
  }
}
