/*
 * 课表解析器：解析「学期理论课表」页面 (/jsxsd/xskb/xskb_list.do)
 *
 * 已核实的页面结构：
 *   - 表格 #kbtable，第 0 行为表头：星期一..星期日
 *   - 第 1..5 行分别为节次：第一、二节 / 第三、四节 / 第五、六节 / 第七、八节 / 第九~十一节
 *   - 末行为备注（#bz_td，colspan=7），列出未排课表课程
 *   - 每个课程格内是两个同内容的 div：
 *       class="kbcontent1" 简略（课程名 / 周次 / 教室）
 *       class="kbcontent"  详细（多出教师）
 *     两者都用带语义的 font 承载字段：
 *       <font title="老师">张老师</font>
 *       <font title="周次(节次)">1-18(双周)</font>
 *       <font title="教室">7-120(章丘)</font>
 *   - 同一格可含多门课，以连续短横线分隔
 *
 * 因此优先按 font 语义属性提取（稳定），文本行启发式为兜底（兼容其他强智版本）。
 */
import { HtmlLite, HtmlTable, HtmlRow, HtmlCell } from './HtmlLite';
import { Timetable, CellData, CourseEntry } from '../model/Models';
import { MAX_WEEKS } from '../common/Constants';
import { Logger } from '../common/Logger';

/** 一个语义化 font 片段 */
class FontInfo {
  title: string;
  text: string;

  constructor(title: string, text: string) {
    this.title = title;
    this.text = text;
  }
}

export class TimetableParser {
  /** 节次行数 */
  private static readonly SECTION_COUNT: number = 5;
  /** 多门课的分隔符（页面为连续短横线） */
  private static readonly SPLIT_RE: RegExp = /-{6,}/;

  static parse(html: string): Timetable {
    const tt: Timetable = new Timetable();

    tt.semesters = TimetableParser.readOptions(html, 'xnxq01id');
    tt.weeks = TimetableParser.readOptions(html, 'zc');
    tt.semester = TimetableParser.readSelected(html, 'xnxq01id');
    tt.week = TimetableParser.readSelected(html, 'zc');

    // 表 id 各校不同：山建是 `#timetable`，别处常见 `#kbtable`。
    // 两个都试 —— 硬编码单一 id 会让整套解析在一所学校直接失效
    // （表现为「暂无数据」而不是报错，很难定位）。
    let table: HtmlTable | null = HtmlLite.findTableById(html, 'timetable');
    if (table === null) {
      table = HtmlLite.findTableById(html, 'kbtable');
    }
    if (table === null) {
      Logger.warn('timetable table (#timetable / #kbtable) not found');
      return tt;
    }

    // 逐行解析：第 0 行为星期表头，其后为 5 个节次行，末行为备注
    let sectionRow: number = 0;
    for (let r = 1; r < table.rows.length; r++) {
      const row: HtmlRow = table.rows[r];

      // 备注行要先判断，否则会被当成节次行
      if (TimetableParser.isRemarkRow(row)) {
        tt.remark = TimetableParser.remarkText(row);
        continue;
      }
      if (row.cells.length < 2 || sectionRow >= TimetableParser.SECTION_COUNT) {
        continue;
      }

      // 第 0 列是节次标签，第 1..7 列为星期一到星期日
      for (let c = 1; c < row.cells.length && c <= 7; c++) {
        const entries: CourseEntry[] = TimetableParser.parseCell(row.cells[c]);
        if (entries.length > 0) {
          const cd: CellData = new CellData();
          cd.row = sectionRow;
          cd.col = c - 1;
          cd.entries = entries;
          tt.cells.push(cd);
        }
      }
      sectionRow++;
    }

    Logger.info('timetable parsed: cells=' + tt.cells.length + ' semesters=' + tt.semesters.length +
      ' weeks=' + tt.weeks.length + ' remark=' + (tt.remark.length > 0 ? 'yes' : 'no'));
    TimetableParser.assignIds(tt);
    return tt;
  }

  /**
   * 给每门课分配稳定 ID。
   * 用「格位置 + 课程名 + 周次规则」组成，保证同一份服务器数据每次解析得到相同 ID，
   * 这样本地修改能准确对应到某一门课，而不会因为顺序变化错位。
   */
  private static assignIds(tt: Timetable): void {
    for (let i = 0; i < tt.cells.length; i++) {
      const cell: CellData = tt.cells[i];
      for (let j = 0; j < cell.entries.length; j++) {
        const e: CourseEntry = cell.entries[j];
        if (e.id.length === 0) {
          e.id = 'srv-' + cell.row.toString() + '-' + cell.col.toString() + '-' +
            e.courseName + '-' + e.startWeek.toString() + '-' + e.endWeek.toString() + '-' + e.parity.toString();
        }
      }
    }
  }

  /** 备注行：只有「备注」标签 + 一个大 colspan 单元格 */
  private static isRemarkRow(row: HtmlRow): boolean {
    if (row.cells.length === 1) {
      return row.cells[0].colspan >= 5 || row.cells[0].id === 'bz_td';
    }
    if (row.cells.length === 2) {
      return /备注/.test(row.cells[0].text) || row.cells[1].id === 'bz_td';
    }
    return false;
  }

  private static remarkText(row: HtmlRow): string {
    for (let i = 0; i < row.cells.length; i++) {
      const c: HtmlCell = row.cells[i];
      if (c.id === 'bz_td' || (c.colspan >= 5 && c.text.length > 0)) {
        return c.text.replace(/\s+/g, ' ').trim();
      }
    }
    for (let i = 0; i < row.cells.length; i++) {
      const t: string = row.cells[i].text;
      if (t.indexOf('备注') < 0 && t.length > 0) {
        return t.replace(/\s+/g, ' ').trim();
      }
    }
    return '';
  }

  /**
   * 解析一个课程格，可能含多门课。
   *
   * 关键：格内同时存在 kbcontent1（简略）与 kbcontent（详细）两个 div，
   * **两者包含完全相同的课程**（详细层多一个教师字段），由页面「放大」复选框切换显示。
   * 因此必须只选其中一层来切分，否则同一门课会被解析出两份。
   */
  private static parseCell(cell: HtmlCell): CourseEntry[] {
    const result: CourseEntry[] = [];
    const block: string = TimetableParser.pickBlock(cell.inner);
    if (block.length === 0) {
      return result;
    }
    // 在一层之内按分隔符切出多门课
    const segments: string[] = block.split(TimetableParser.SPLIT_RE);
    for (let i = 0; i < segments.length; i++) {
      const entry: CourseEntry | null = TimetableParser.parseSegment(segments[i]);
      if (entry !== null) {
        result.push(entry);
      }
    }
    return result;
  }

  /** 解析一段（一门课）的 HTML 片段，优先用语义化 font，失败则退回文本启发式 */
  private static parseSegment(segHtml: string): CourseEntry | null {
    const block: string = segHtml;
    if (block.replace(/<[^>]*>/g, '').replace(/[\s\u00a0\u3000]/g, '').length === 0) {
      return null;
    }

    const e: CourseEntry = new CourseEntry();
    const fonts: FontInfo[] = TimetableParser.parseFonts(block);

    for (let i = 0; i < fonts.length; i++) {
      const f: FontInfo = fonts[i];
      if (f.title.indexOf('老师') >= 0 || f.title.indexOf('教师') >= 0) {
        if (e.teacher.length === 0) {
          e.teacher = f.text;
        }
      } else if (f.title.indexOf('周次') >= 0 || f.title.indexOf('节次') >= 0) {
        if (e.weekText.length === 0) {
          e.weekText = f.text;
          TimetableParser.parseWeekRange(f.text, e);
        }
      } else if (f.title.indexOf('教室') >= 0 || f.title.indexOf('地点') >= 0) {
        if (e.room.length === 0) {
          TimetableParser.splitRoom(f.text, e);
        }
      }
    }

    // 课程名 = 去掉所有 font 与换行标签后的首段文本
    const withoutFonts: string = block.replace(/<font[\s\S]*?<\/font>/gi, '');
    const nameText: string = HtmlLite.toText(withoutFonts).split('\n')[0].trim();
    e.courseName = nameText;

    // 语义属性不完整时，用文本行补齐
    if (e.courseName.length === 0 || e.weekText.length === 0 || e.room.length === 0) {
      TimetableParser.fillFromText(block, e);
    }

    if (e.courseName.length === 0) {
      return null;
    }
    return e;
  }

  /**
   * 取格内用于解析的 HTML 块。
   * 优先详细层（含教师），其次简略层，最后整段兜底。
   */
  private static pickBlock(segHtml: string): string {
    const divs: string[] = HtmlLite.findAll(segHtml, 'div');
    let detailed: string = '';
    let simple: string = '';
    for (let i = 0; i < divs.length; i++) {
      const d: string = divs[i];
      const cls: string = HtmlLite.attr(d.substring(0, Math.max(0, d.indexOf('>') + 1)), 'class');
      if (cls.indexOf('kbcontent1') >= 0) {
        if (simple.length === 0) {
          simple = d;
        }
      } else if (cls.indexOf('kbcontent') >= 0) {
        if (detailed.length === 0) {
          detailed = d;
        }
      }
    }
    if (detailed.length > 0) {
      return TimetableParser.inner(detailed);
    }
    if (simple.length > 0) {
      return TimetableParser.inner(simple);
    }
    return segHtml;
  }

  /** 取元素内部 HTML */
  private static inner(outer: string): string {
    const gt: number = outer.indexOf('>');
    const closeIdx: number = outer.toLowerCase().lastIndexOf('</');
    return gt >= 0 && closeIdx > gt ? outer.substring(gt + 1, closeIdx) : outer;
  }

  /** 提取所有带 title 的 font 片段 */
  private static parseFonts(html: string): FontInfo[] {
    const out: FontInfo[] = [];
    const fonts: string[] = HtmlLite.findAll(html, 'font');
    for (let i = 0; i < fonts.length; i++) {
      const f: string = fonts[i];
      const gt: number = f.indexOf('>');
      const openTag: string = gt > 0 ? f.substring(0, gt + 1) : f;
      const title: string = HtmlLite.attr(openTag, 'title');
      const closeIdx: number = f.toLowerCase().lastIndexOf('</font');
      const body: string = gt >= 0 && closeIdx > gt ? f.substring(gt + 1, closeIdx) : '';
      const text: string = HtmlLite.toText(body).replace(/\n/g, ' ').trim();
      if (title.length > 0 && text.length > 0) {
        out.push(new FontInfo(title, text));
      }
    }
    return out;
  }

  /** 文本启发式补全（用于语义属性缺失的强智版本） */
  private static fillFromText(block: string, e: CourseEntry): void {
    const lines: string[] = HtmlLite.toText(block).split('\n');
    const cleaned: string[] = [];
    for (let i = 0; i < lines.length; i++) {
      const t: string = lines[i].replace(/[\u00a0\u3000]/g, ' ').trim();
      if (t.length > 0) {
        cleaned.push(t);
      }
    }
    // 逐行尝试拆分「课程名+教师+周次」这类粘连文本
    for (let i = 0; i < cleaned.length; i++) {
      const line: string = cleaned[i];
      if (e.weekText.length === 0) {
        // 兼容逗号列表：`2,4,6,8(周)` / `1-8,13-16(周)`
        const wk: RegExpMatchArray | null =
          line.match(/[\d,\-—~、\s]+\(\s*(单|双)?周\s*\)|\(\s*(单|双)?周\s*\)/);
        if (wk !== null) {
          e.weekText = wk[0];
          TimetableParser.parseWeekRange(wk[0], e);
        }
      }
      if (e.room.length === 0) {
        // 形态一：`7-120(章丘)`
        const rm: RegExpMatchArray | null = line.match(/([0-9A-Za-z\-]+)\s*\(\s*([\u4e00-\u9fa5]{2,6})\s*\)/);
        if (rm !== null && /^\d/.test(rm[1])) {
          e.room = rm[1];
          e.campus = rm[2];
        } else {
          // 形态二（山建）：`外文馆211[媒159]` —— 楼名与房号连写，
          // 靠「汉字 + 数字」的边界切开。
          //
          // **必须排除落在课名里的匹配**：课名带数字很常见
          // （「碳中和与碳循环（能创25）」「大学英语3」），这条正则会
          // 正好把「能创25」切成楼名+房号 —— 实测后果是那门课在课表上
          // 显示一个虚构的地点。宁可没有教室，也不能给错教室。
          const local: RegExpMatchArray | null =
            line.match(/([\u4e00-\u9fa5]{2,8})(\d{2,4}[0-9A-Za-z\-]*)/);
          if (local !== null && e.courseName.indexOf(local[0].trim()) < 0) {
            e.room = local[1] + local[2];
          }
        }
      }
      if (e.courseName.length === 0) {
        // 课程名取到第一个「周次」或「教室」出现之前
        let name: string = line;
        const cut: number = TimetableParser.firstCut(name);
        if (cut > 0) {
          name = name.substring(0, cut);
        }
        name = name.replace(/[\d\-—~]+\(\s*(单|双)?周\s*\)/g, '').trim();
        if (name.length > 0) {
          e.courseName = name;
        }
      } else if (e.teacher.length === 0 && TimetableParser.looksLikeTeacher(line)) {
        e.teacher = line;
      }
    }
  }

  /** 返回课程名应当截断的位置（周次出现处；兼容逗号列表写法） */
  private static firstCut(line: string): number {
    let cut: number = -1;
    const m1: RegExpMatchArray | null = line.match(/[\d,\-—~、\s]+\(\s*(单|双)?周\s*\)/);
    if (m1 !== null && m1.index !== undefined) {
      cut = cut < 0 ? m1.index : Math.min(cut, m1.index);
    }
    const m2: RegExpMatchArray | null = line.match(/\d+\s*\(\s*(单|双)?周\s*\)/);
    if (m2 !== null && m2.index !== undefined) {
      cut = cut < 0 ? m2.index : Math.min(cut, m2.index);
    }
    return cut;
  }

  /** 教室串拆分。 */
  private static splitRoom(text: string, e: CourseEntry): void {
    const t: string = text.trim();
    if (t.length === 0) {
      return;
    }
    // 形态一：`房间(校区)`，例如 `9-316(章丘)`
    const m: RegExpMatchArray | null = t.match(/^(.+?)\s*[（(]\s*([^)）]+)\s*[)）]\s*$/);
    if (m !== null) {
      e.room = m[1].trim();
      e.campus = m[2].trim();
      return;
    }
    // 形态二（山建）：`楼名+房号[编码]`，例如 `外文馆211[媒159]`。
    //
    // 方括号里**不是校区**：校区总是纯汉字（章丘/燕山/舜耕），而 `媒159`
    // 这种是学校内部的教室编码（媒=多媒体、智=智慧教室，数字与容量相同）。
    // 它对学生没有用处，却要占掉卡片近一半宽度 —— 含数字的直接丢弃。
    const br: RegExpMatchArray | null = t.match(/^(.+?)\s*\[([^\]]*)\]\s*$/);
    if (br !== null) {
      e.room = br[1].trim();
      const mark: string = br[2].trim();
      if (mark.length > 0 && !/\d/.test(mark)) {
        e.campus = mark;
      }
      return;
    }
    e.room = t;
  }

  /** 教师行特征 */
  private static looksLikeTeacher(line: string): boolean {
    if (/讲师|副教授|教授|助教|工程师|研究员/.test(line)) {
      return true;
    }
    return /^[\u4e00-\u9fa5·]{2,6}$/.test(line);
  }

  /** 解析周次规则：1-18(周) / 1-18(双周) / 1-18(单周) */
  private static parseWeekRange(text: string, e: CourseEntry): void {
    const t: string = text.replace(/[（）]/g, '(');
    if (/双周/.test(t)) {
      e.parity = 2;
    } else if (/单周/.test(t)) {
      e.parity = 1;
    } else {
      e.parity = 0;
    }
    // ===== 山建的周次写法比移植源复杂，必须都覆盖 =====
    //   `1-16(周)`          → 1..16（最常见）
    //   `3(周)`             → 3..3（单周上课）
    //   `1-8,13-16(周)`     → 1..16（**分段**：去掉中间几周）
    //   `2,4,6,8(周)`       → 2..8（**隔周**）
    //   `1-18(周)[03-04节]` → 后面还跟着节次，取前面周次即可
    //
    // 旧实现只认 `a-b`，遇到逗号列表会取到**第一个数字**当起止
    // （`2,4,6,8` 变成单周 2；`1-8,13-16` 变成 1~8）——
    // 结果是这些课在多数周次里不显示，看起来像「课表漏课」。
    //
    // 策略是**宁宽勿漏**：取所有数字里的最小值当起始、最大值当结束。
    // 代价是分段之间的空档也会显示课程，但那只是「多显示」；
    // 反过来漏课会让用户以为没课，性质更严重。
    // 必须先切掉 `(周)` 之后的内容再取数字：那里是节次（`[03-04节]`）。
    // 不切的话节次数字会被当成周次 —— `9-12(周)[03-04节]` 读成 3-12、
    // `3(周)[06-07节]` 读成 3-7，课在错误的周次里出现/消失，
    // 界面上不报任何错。Dart 参考实现（timetable_parser.dart）同样只取 `(` 之前。
    const paren: number = t.indexOf('(');
    const head: string = paren > 0 ? t.substring(0, paren) : t;
    const nums: number[] = [];
    const all: RegExpMatchArray | null = head.match(/\d+/g);
    if (all !== null) {
      for (let i = 0; i < all.length; i++) {
        const v: number = parseInt(all[i], 10);
        // 只收 1..MAX_WEEKS：周次字段之外的脏数据（服务端偶发把某行写成 99）
        // 不该把区间撑到学期之外
        if (!isNaN(v) && v >= 1 && v <= MAX_WEEKS) {
          nums.push(v);
        }
      }
    }
    if (nums.length === 0) {
      e.startWeek = 1;
      e.endWeek = 1;
      return;
    }
    let lo: number = nums[0];
    let hi: number = nums[0];
    for (let i = 1; i < nums.length; i++) {
      if (nums[i] < lo) {
        lo = nums[i];
      }
      if (nums[i] > hi) {
        hi = nums[i];
      }
    }
    e.startWeek = lo;
    e.endWeek = hi;
  }

  /** 读取下拉选项值列表 */
  private static readOptions(html: string, name: string): string[] {
    const opts = HtmlLite.findSelect(html, name);
    const result: string[] = [];
    for (let i = 0; i < opts.length; i++) {
      if (opts[i].value.length > 0) {
        result.push(opts[i].value);
      }
    }
    return result;
  }

  /** 读取下拉当前选中值 */
  private static readSelected(html: string, name: string): string {
    const opts = HtmlLite.findSelect(html, name);
    for (let i = 0; i < opts.length; i++) {
      if (opts[i].selected) {
        return opts[i].value;
      }
    }
    return opts.length > 0 ? opts[0].value : '';
  }
}
