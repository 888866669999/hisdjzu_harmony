/*
 * PlanParser：解析「培养方案及完成情况」(/jsxsd/pyfa/topyfamx)
 *
 * 已核实页面结构：
 *   - #dataList 承载说明文本，按行给出：
 *       一、培养目标 …（培养目标正文）
 *       二、详细说明
 *       三、课程设置总表
 *     课程设置总表（#mxh）是嵌在其中的子表，解析时要跳过该行。
 *   - #mxh 为课程设置总表，双层表头（两行合并后共 15 列）：
 *       课程体系 | 选课组 | 课程编号 | 课程名称 | 完成情况 | 课程性质 |
 *       课程属性 | 学分 | 学时分类×6（末列是总学时） | 开设学期
 *     其中「学时分类」横跨 6 列（colspan），第二行只填这 6 个子列。
 *
 * ===== 列位置从表头推导，不写死 =====
 * 这张表的列数不是固定的：本校比旧校多了
 * 完成情况 / 课程性质 / 课程属性 三列。早先按「从右数第 9 格 = 课程名称」
 * 这类固定偏移读，在本校实际读到了**课程性质** —— 于是课程列表里每门课都
 * 显示成它所属的性质（「素质拓展必修课」重复 13 遍），课号列读到了完成情况。
 * 这类错位不会抛异常，只会安静地显示错的数据，所以一律以表头为准。
 *
 * 数据行**从右往左读**：左侧的「选课组/课号」列数因 rowspan 不固定，
 * 从右边数位置才是稳定的。
 */
import { HtmlLite, HtmlTable, HtmlRow, HtmlCell } from './HtmlLite';
import { PlanDetail, PlanCourse } from '../model/Models';
import { Logger } from '../common/Logger';

export class PlanParser {
  /** 需要单独成段的说明性段落前缀 */
  private static readonly SECTION_PREFIXES: string[] = ['一、', '二、', '三、', '四、', '五、'];

  static parse(html: string): PlanDetail {
    const plan: PlanDetail = new PlanDetail();

    const dl: HtmlTable | null = HtmlLite.findTableById(html, 'dataList');
    if (dl !== null) {
      PlanParser.parseIntro(dl, plan);
    }
    const mx: HtmlTable | null = HtmlLite.findTableById(html, 'mxh');
    if (mx === null) {
      Logger.warn('plan course table #mxh not found');
    } else {
      PlanParser.parseCourses(mx, plan);
    }
    plan.pdfPath = PlanParser.parsePdfPath(html);
    plan.buildGroups();

    Logger.info('plan parsed: courses=' + plan.courses.length + ' groups=' + plan.groups.length +
      ' paragraphs=' + plan.introParagraphs.length + ' pdf=' + (plan.pdfPath.length > 0 ? 'yes' : 'no'));
    return plan;
  }

  /**
   * 取培养目标等说明段落。
   *
   * 只认「一、」这类编号开头的行：页面上的说明文本与课程表混在同一张
   * #dataList 里，不按编号筛会把表头、表注都当成正文。
   */
  private static parseIntro(table: HtmlTable, plan: PlanDetail): void {
    for (let r = 0; r < table.rows.length; r++) {
      const row: HtmlRow = table.rows[r];
      // 课程表的行（含这些表头文字）不是引言
      const joined: string = row.text;
      if (joined.indexOf('学时分类') >= 0 && joined.indexOf('开设学期') >= 0) {
        continue;
      }
      for (let c = 0; c < row.cells.length; c++) {
        const raw: string = row.cells[c].text.trim();
        if (raw.length === 0) {
          continue;
        }
        // 一格可能有多行（<br>/块级标签换行），逐行判断
        const lines: string[] = raw.split('\n');
        for (let i = 0; i < lines.length; i++) {
          const t: string = lines[i].trim();
          if (t.length === 0 || !PlanParser.isSection(t)) {
            continue;
          }
          // 「课程设置总表」是分隔标题，正文在 #mxh 里
          if (t.indexOf('课程设置总表') >= 0) {
            continue;
          }
          const body: string = PlanParser.stripHeading(t);
          if (body.length === 0) {
            continue;
          }
          if (t.indexOf('培养目标') >= 0) {
            plan.introParagraphs.push(body);
          } else {
            plan.detailParagraphs.push(body);
          }
        }
      }
    }
  }

  /** 是否以「一、二、三…」这类编号开头（只有这些才算正文小标题） */
  private static isSection(line: string): boolean {
    for (let i = 0; i < PlanParser.SECTION_PREFIXES.length; i++) {
      if (line.indexOf(PlanParser.SECTION_PREFIXES[i]) === 0) {
        return true;
      }
    }
    return false;
  }

  /** 去掉「一、培养目标」这类编号标题 */
  private static stripHeading(text: string): string {
    let t: string = text;
    for (let i = 0; i < PlanParser.SECTION_PREFIXES.length; i++) {
      if (t.indexOf(PlanParser.SECTION_PREFIXES[i]) === 0) {
        t = t.substring(PlanParser.SECTION_PREFIXES[i].length);
        break;
      }
    }
    // 再削掉「培养目标」这类小标题（其后紧跟正文）
    const known: string[] = ['培养目标', '详细说明'];
    for (let i = 0; i < known.length; i++) {
      if (t.indexOf(known[i]) === 0) {
        t = t.substring(known[i].length);
        break;
      }
    }
    return t.trim();
  }

  /**
   * 解析课程设置总表：课程行 + 由课程行求和得出的学分/总学时。
   *
   * **合计不读「合计/小计」行，而是把课程行自己加起来。**
   * 原因（实测，别再改回去）：小计行的列数与课程行**不一样** ——
   * 数据行 14–15 列，小计行只有 9 列（丢掉体系/选课组/课号/课程名称/
   * 完成情况/性质/属性这些文字列，只留学分与 6 个学时分类再跟一个空列）。
   * 用固定偏移去读小计行，会在两个不同列数的行上悄悄读错列：
   * 界面上会出现一个来源不明、且不报错的总数。
   * 求和法还有个附带好处：它天然与「课程设置总表」逐门课对得上，
   * 用户能自己核对。
   */
  private static parseCourses(table: HtmlTable, plan: PlanDetail): void {
    let currentSystem: string = '';

    // 列位置从**表头**推导，不硬编码（见 headerOffsets 的说明）
    const cols: Map<string, number> = PlanParser.headerOffsets(table);

    for (let r = 0; r < table.rows.length; r++) {
      const row: HtmlRow = table.rows[r];
      const cells: HtmlCell[] = row.cells;
      if (cells.length === 0) {
        continue;
      }
      const first: string = cells[0].text.replace(/\s+/g, ' ').trim();

      // 合计 / 小计行：列布局与课程行不同，跳过（总数由课程行求和得出）
      if (first.indexOf('合计') === 0 || first.indexOf('小计') === 0) {
        continue;
      }
      // 表头行（第一格是「体系」，或含「讲课学时」）
      if (first === '体系' || row.text.indexOf('讲课学时') >= 0) {
        continue;
      }
      // 数据行的第一格是课程体系（分组首行有值、后续行为空），
      // 而引言段落的行只有一格且是长文 —— 用格数把两者分开。
      if (cells.length < 12) {
        continue;
      }

      const course: PlanCourse = PlanParser.readCourseFromRight(cells, currentSystem, cols);
      if (course.courseName.length === 0) {
        continue;
      }
      if (course.system.length > 0) {
        currentSystem = course.system;
      }
      plan.courses.push(course);
    }

    // 学分与总学时：由课程行累加（见上方说明）
    let credit: number = 0;
    let hours: number = 0;
    for (let i = 0; i < plan.courses.length; i++) {
      const c: PlanCourse = plan.courses[i];
      const cv: number = parseFloat(c.credit);
      const hv: number = parseFloat(c.totalHours);
      credit += isNaN(cv) ? 0 : cv;
      hours += isNaN(hv) ? 0 : hv;
    }
    plan.totalCredit = credit;
    plan.totalHours = hours;
  }

  /**
   * 从表头推导「列名 → 距右端的偏移」。
   *
   * ===== 为什么必须推导而不能写死 =====
   * 这张表的列**不只是顺序，连数量都随学校/年级变**：本校有
   * `完成情况 / 课程性质 / 课程属性` 三列，旧校只有 `类别` 一列。
   * 早先按固定的「从右数第 9 格 = 课程名称」去读，在本校实际读到了
   * **课程性质** —— 于是课程列表里每门课都显示成它所属的性质
   * （「素质拓展必修课」重复 13 遍），课号列读到了「完成情况」。
   * 这类错位不会抛异常，只会安静地显示错的数据。
   *
   * 表头是**两行**：第一行带 rowspan/colspan（`学时分类` 横跨 6 列），
   * 第二行只填那 6 个子列（`总学时` 在最后一个）。因此先把两行展开成
   * 一条等宽的列名数组，再算每个名字距右端多少格。
   *
   * 数据行左侧会因为 rowspan 少掉格子（分组首行有「选课组」、
   * 后续行没有），但**右侧永远对齐** —— 所以偏移一律从右端算。
   */
  private static headerOffsets(table: HtmlTable): Map<string, number> {
    let hr: number = -1;
    const rowLimit: number = table.rows.length < 8 ? table.rows.length : 8;
    for (let i = 0; i < rowLimit; i++) {
      const t: string = table.rows[i].text;
      if (t.indexOf('课程编号') >= 0 || t.indexOf('课程名称') >= 0) {
        hr = i;
        break;
      }
    }
    const out: Map<string, number> = new Map<string, number>();
    if (hr < 0) {
      return out;   // 认不出表头 → 用调用方的兜底偏移
    }

    const names: string[] = [];
    // 哪些列留给下一行填（本行 rowspan<2 的那些）
    const open: boolean[] = [];
    const head: HtmlCell[] = table.rows[hr].cells;
    for (let ci = 0; ci < head.length; ci++) {
      const c: HtmlCell = head[ci];
      const w: number = c.colspan < 1 ? 1 : c.colspan;
      for (let k = 0; k < w; k++) {
        names.push(c.text.trim());
        open.push(c.rowspan < 2);
      }
    }
    if (hr + 1 < table.rows.length) {
      const sub: HtmlCell[] = table.rows[hr + 1].cells;
      let idx: number = 0;
      for (let ci = 0; ci < sub.length; ci++) {
        const c: HtmlCell = sub[ci];
        const w: number = c.colspan < 1 ? 1 : c.colspan;
        for (let k = 0; k < w; k++) {
          while (idx < open.length && !open[idx]) {
            idx++;
          }
          if (idx >= open.length) {
            break;
          }
          const t: string = c.text.trim();
          if (t.length > 0) {
            names[idx] = t;   // 子列名覆盖上去（「总学时」就是这时来的）
          }
          idx++;
        }
      }
    }

    const last: number = names.length - 1;
    for (let i = 0; i <= last; i++) {
      const n: string = names[i];
      // 同名列（学时分类的 6 个子列里 5 个无名、值为空串）不覆盖
      if (n.length > 0 && !out.has(n)) {
        out.set(n, last - i);
      }
    }
    return out;
  }

  /**
   * 从右往左读一行的课程数据。
   *
   * `cols` 是 headerOffsets 从表头推出来的「列名 → 距右端偏移」。
   * 拿不到（表头变了）时用兜底常量，那组常量是按上面 15 列表头数出来的。
   *
   * 关键点：**「课程体系」只在每个分组的首行出现**，后续行第 0 格是空的
   * （靠 rowspan 视觉合并）。所以要向下继承，否则整表会归成一组。
   *
   * ===== 从右侧数是唯一稳的做法 =====
   * 左侧列数会变：
   *   · 分组首行的「课程体系」占多行（rowspan），该行还有「选课组」，
   *     于是 15 格；后续行两个都没有，14 格 —— 按固定下标读会**首行错位**；
   *   · 本校的「选课组」列**整列为空**（学校没填），但它确实占一列。
   * 右侧那些列（学期 / 总学时 / 学时分类 / 学分 / 性质 / 属性 / 完成情况
   * / 课程名称 / 课号）的顺序与数量在一份表里是稳定的，因此从右往左数。
   */
  private static readCourseFromRight(cells: HtmlCell[], inheritSystem: string,
    cols: Map<string, number>): PlanCourse {
    const system: string = PlanParser.cellText(cells, 0);

    // 「选课组」= 课号左边那一格。
    //
    // 不能按固定下标（cells[1]）读：分组首行的课程体系占多行（rowspan），
    // 于是该行的课号提前一格、cells[1] 恰好是**课程编号** ——
    // 界面会冒出一个组名叫「AQ25000001」的假分组。
    // 这里改成「先定位课号，再取它左邻」。
    const codeOff: number = PlanParser.off(cols, '课程编号', 12);
    const code: string = PlanParser.atFromEnd(cells, codeOff);
    let group: string = '';
    if (code.length > 0) {
      const ci: number = cells.length - 1 - codeOff;
      if (ci >= 2) {
        group = PlanParser.cellText(cells, ci - 1);
      }
    }
    // 左邻若是课程体系自身（首行 rowspan 的情形），说明这行没有选课组
    if (group === system) {
      group = '';
    }

    const course: PlanCourse = new PlanCourse();
    course.semester = PlanParser.atFromEnd(cells, PlanParser.off(cols, '开设学期', 0));
    course.totalHours = PlanParser.atFromEnd(cells, PlanParser.off(cols, '总学时', 1));
    // 学时分类的 5 个子列本校**表头是空的**（学校没填名），只能按位置读；
    // 界面不展示它们，只展示总学时，因此不影响显示。
    course.computerHours = PlanParser.atFromEnd(cells, 2);
    course.labHours = PlanParser.atFromEnd(cells, 3);
    course.seminarHours = PlanParser.atFromEnd(cells, 4);
    course.practiceHours = PlanParser.atFromEnd(cells, 5);
    course.lectureHours = PlanParser.atFromEnd(cells, 6);
    course.credit = PlanParser.atFromEnd(cells, PlanParser.off(cols, '学分', 7));
    // 「课程性质」才是界面上那个彩色标签（素质拓展必修课 / 公共必修课…）。
    // 「课程属性」是另一个字段（必修 / 实践 / 选修），别拿错。
    course.category = PlanParser.atFromEnd(cells, PlanParser.off(cols, '课程性质', 9));
    course.courseName = PlanParser.atFromEnd(cells, PlanParser.off(cols, '课程名称', 11));
    course.courseCode = code;
    course.group = group;
    course.system = system.length > 0 ? system : inheritSystem;
    return course;
  }

  /** 取第 i 格文本（越界返回空串），空白折叠成单空格 */
  private static cellText(cells: HtmlCell[], i: number): string {
    if (i < 0 || i >= cells.length) {
      return '';
    }
    return cells[i].text.replace(/\s+/g, ' ').trim();
  }

  /**
   * 取「距右端第 fromEnd 格」的文本。
   *
   * 偏移一律从右端算：数据行左侧会因 rowspan 少格（见 readCourseFromRight）。
   */
  private static atFromEnd(cells: HtmlCell[], fromEnd: number): string {
    return PlanParser.cellText(cells, cells.length - 1 - fromEnd);
  }

  /** 表头偏移；推导不出时用兜底值（兜底值按 15 列表头数出） */
  private static off(cols: Map<string, number>, name: string, fallback: number): number {
    const v: number | undefined = cols.get(name);
    return v === undefined ? fallback : v;
  }

  /**
   * 取 PDF 相对地址。页面里的形态是 iframe 的 src，例如：
   *   <iframe src="/ewebeditor/uploadfile/2025033110250359448.pdf">
   * 这里直接匹配路径本身，避免依赖引号与属性的排列顺序。
   */
  private static parsePdfPath(html: string): string {
    const m: string[] | null = html.match(/\/[A-Za-z0-9_\/.-]*uploadfile\/[A-Za-z0-9_.%-]+\.pdf/i);
    if (m !== null && m.length > 0 && m[0].length > 0) {
      return m[0];
    }
    // 兜底：任意位置的 .pdf 路径
    const m2: string[] | null = html.match(/[A-Za-z0-9_\/.-]+\.pdf/i);
    return (m2 !== null && m2.length > 0) ? m2[0] : '';
  }
}
