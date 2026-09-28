/*
 * ElectiveParser：解析「学习完成情况查看」(/jsxsd/xxwcqk/xxwcqkOnkctxBy.do)
 *
 * ===== 本校与旧校的页面结构不同，两种都支持 =====
 *
 * 旧校（两表）：
 *   - 类别表：表头含「要求学分」，列 = 名称 / 要求 / 已修 / 在修
 *   - 课程表：表头含「通选课类别」，列 = 编号 / 名称 / 学分 / 成绩 / 类别
 *
 * 本校（单表，标题「学习完成情况查看」）：
 *   - 只有一张表，表头是
 *     `课程体系(属性) | 毕业要求学分 | 已修学分 | 正修读学分 | 毕业还需学分 | 详情`
 *   - 主页**没有课程明细**；每行的「详情」指向另一个页面
 *     （`xxwcqkOnkctxByxq.do?kctxmc=<大类名>`），由界面在用户展开该大类时
 *     按需拉取，见 [parseDetail]。
 *
 * 因此这里**不写死列号**，而是先找到表头行、按表头文字定位各列。
 * 写死列号的代价很高：两校列数不同（旧校 4 列、本校 5 列），
 * 而且列顺序也可能变，一处错位就会把「已修学分」显示成「毕业还需学分」——
 * 数字看着正常，结论完全相反。
 *
 * ===== 必须保留的产品行为 =====
 * 旧校**确实留空了「要求学分」**，界面不能判成「未达标」，
 * 而要显示「学校未设置要求」。本校这一列是有值的，但那条逻辑仍然保留 ——
 * 只要读到空值就走「未设置」分支，不假设哪所学校有值。
 */
import { HtmlLite, HtmlTable, HtmlCell } from './HtmlLite';
import { ElectiveReport, ElectiveCategory, ElectiveCourse } from '../model/Models';
import { Logger } from '../common/Logger';

/** 表头里可能出现的列名（各校写法不同，按顺序尝试） */
const NAME_HEADERS: string[] = ['课程体系', '类别', '课程类别'];
const REQUIRED_HEADERS: string[] = ['毕业要求学分', '要求学分'];
const EARNED_HEADERS: string[] = ['已修学分', '已修'];
const ONGOING_HEADERS: string[] = ['正修读学分', '在修学分', '在修'];

export class ElectiveParser {
  static parse(html: string): ElectiveReport {
    const report: ElectiveReport = new ElectiveReport();

    // 类别表：表头里出现「要求学分」的那张（两校都是这个特征）
    const cat: HtmlTable | null = HtmlLite.findTableByHeader(html, '要求学分');
    if (cat === null) {
      Logger.warn('elective category table not found');
    } else {
      ElectiveParser.parseCategories(cat, report);
    }

    // 课程明细表：只有旧校那边有；本校没有，取不到就跳过
    const course: HtmlTable | null = HtmlLite.findTableByHeader(html, '通选课类别');
    if (course !== null) {
      ElectiveParser.parseCourses(course, report);
    }

    Logger.info('elective parsed: categories=' + report.categories.length +
      ' courses=' + report.courses.length + ' earned=' + report.totalEarned);
    return report;
  }

  /** 解析类别要求表（按表头文字定位列，见文件头说明） */
  private static parseCategories(table: HtmlTable, report: ElectiveReport): void {
    const headerRow: number = ElectiveParser.headerRowOf(table, '要求学分');
    if (headerRow < 0) {
      return;
    }
    const header: HtmlCell[] = table.rows[headerRow].cells;
    const colName: number = ElectiveParser.findColumn(header, NAME_HEADERS);
    const colReq: number = ElectiveParser.findColumn(header, REQUIRED_HEADERS);
    const colEarned: number = ElectiveParser.findColumn(header, EARNED_HEADERS);
    const colOngoing: number = ElectiveParser.findColumn(header, ONGOING_HEADERS);
    // 名称与已修学分是这张表存在的意义，缺一列说明表结构变了，宁可不显示
    if (colName < 0 || colEarned < 0) {
      Logger.warn('elective category columns not resolved');
      return;
    }

    for (let r = headerRow + 1; r < table.rows.length; r++) {
      const cells: HtmlCell[] = table.rows[r].cells;
      if (cells.length <= colName) {
        continue;
      }
      const name: string = ElectiveParser.at(cells, colName);
      if (name.length === 0) {
        continue;
      }
      // 「合计 / 总学分 / 总计」这类汇总行单独取，不算一个类别。
      //
      // ===== 为什么三个写法都要认（实测踩过）=====
      // 本校页面写的是 **`总计`**，而早先只认 `总学分` 与 `合计`：
      //   · 汇总值取不到 → 页面顶部「已修学分」显示 **0**，
      //     而下面表格里明明写着 159.0；
      //   · `总计` 还会被当成**第 12 个类别**渲染成一张可折叠卡片，
      //     用户能给它「设置要求学分」—— 而它根本不是一个课程类别。
      // 各校写法不同，因此按「是不是汇总行」判断，而不是死认某一个词。
      if (name.indexOf('总学分') >= 0 || name.indexOf('合计') >= 0 || name.indexOf('总计') >= 0) {
        report.totalEarned = ElectiveParser.at(cells, colEarned);
        report.totalOngoing = ElectiveParser.at(cells, colOngoing);
        continue;
      }
      const c: ElectiveCategory = new ElectiveCategory();
      c.name = name;
      c.required = ElectiveParser.at(cells, colReq);
      c.earned = ElectiveParser.at(cells, colEarned);
      c.ongoing = ElectiveParser.at(cells, colOngoing);
      report.categories.push(c);
    }
  }

  /** 解析已修课程明细表（旧校结构；本校没有这张表） */
  private static parseCourses(table: HtmlTable, report: ElectiveReport): void {
    const headerRow: number = ElectiveParser.headerRowOf(table, '通选课类别');
    if (headerRow < 0) {
      return;
    }
    for (let r = headerRow + 1; r < table.rows.length; r++) {
      const cells: HtmlCell[] = table.rows[r].cells;
      if (cells.length < 5) {
        continue;
      }
      const name: string = ElectiveParser.at(cells, 1);
      if (name.length === 0 || name === '课程名称') {
        continue;
      }
      const c: ElectiveCourse = new ElectiveCourse();
      c.courseCode = ElectiveParser.at(cells, 0);
      c.courseName = name;
      c.credit = ElectiveParser.at(cells, 2);
      c.score = ElectiveParser.at(cells, 3);
      c.category = ElectiveParser.at(cells, 4);
      report.courses.push(c);
    }
  }

  /**
   * 解析「大类详情」页 —— 本校课程明细的来源。
   *
   * 地址：`/jsxsd/xxwcqk/xxwcqkOnkctxByxq.do?kctxmc=<大类名>`
   * （主页每行的「详情」就是 `window.open` 这个地址）。
   *
   * 实测表头 8 列：
   *   `课程编号 | 课程名称 | 学分 | 课程属性 | 课程性质 | 总成绩 | 备注 | 是否学位课`
   * 数据行同宽；首行往往是「大类名」单独一格（跨列标题），跳过。
   *
   * 列位置同样**按表头文字定位**，不写死列号（理由见文件头）；
   * 取不到课程名整列时返回空列表，绝不猜列号 —— 猜错会把「学分」
   * 读成「成绩」这类静默错误。
   */
  static parseDetail(html: string): ElectiveCourse[] {
    const out: ElectiveCourse[] = [];
    const table: HtmlTable | null = HtmlLite.findTableByHeader(html, '课程名称');
    if (table === null) {
      return out;
    }
    const headerRow: number = ElectiveParser.headerRowOf(table, '课程名称');
    if (headerRow < 0) {
      return out;
    }
    const labels: string[] = [];
    const headerCells: HtmlCell[] = table.rows[headerRow].cells;
    for (let i = 0; i < headerCells.length; i++) {
      labels.push(ElectiveParser.at(headerCells, i));
    }
    const colCode: number = ElectiveParser.findColumnIn(labels, ['课程编号', '课程代码']);
    const colName: number = ElectiveParser.findColumnIn(labels, ['课程名称']);
    const colCredit: number = ElectiveParser.findColumnIn(labels, ['学分']);
    const colAttr: number = ElectiveParser.findColumnIn(labels, ['课程属性']);
    const colScore: number = ElectiveParser.findColumnIn(labels, ['总成绩', '成绩']);
    const colRemark: number = ElectiveParser.findColumnIn(labels, ['备注']);

    for (let r = headerRow + 1; r < table.rows.length; r++) {
      const cells: HtmlCell[] = table.rows[r].cells;
      // 数据行与表头同宽（8 列）；「大类名」那种跨列标题行只有 1 格，
      // 据此过滤 —— 它没有课程名，按名字判空也能滤掉，但先按列数滤更省。
      if (cells.length < 5) {
        continue;
      }
      const name: string = ElectiveParser.at(cells, colName);
      if (name.length === 0 || name === '课程名称') {
        continue;
      }
      const c: ElectiveCourse = new ElectiveCourse();
      c.courseCode = ElectiveParser.at(cells, colCode);
      c.courseName = name;
      c.credit = ElectiveParser.at(cells, colCredit);
      c.attr = ElectiveParser.at(cells, colAttr);
      c.score = ElectiveParser.at(cells, colScore);
      c.remark = ElectiveParser.at(cells, colRemark);
      out.push(c);
    }
    return out;
  }

  /** 表头行是第几行？（含关键字的行；只看前 4 行，避免把数据行当表头） */
  private static headerRowOf(table: HtmlTable, keyword: string): number {
    const limit: number = table.rows.length < 4 ? table.rows.length : 4;
    for (let i = 0; i < limit; i++) {
      if (table.rows[i].text.indexOf(keyword) >= 0) {
        return i;
      }
    }
    return -1;
  }

  /** 在表头行里找出某个列名对应的列号；找不到返回 -1 */
  private static findColumn(header: HtmlCell[], names: string[]): number {
    for (let w = 0; w < names.length; w++) {
      for (let i = 0; i < header.length; i++) {
        if (header[i].text.indexOf(names[w]) >= 0) {
          return i;
        }
      }
    }
    return -1;
  }

  /**
   * 找列号：先按**整格相等**匹配，再退到包含匹配；两步都是「列名优先」。
   *
   * 为什么要与 findColumn 分开：详情页有「总成绩」与「课程属性」这类
   * **互相包含**的列名，只按包含匹配时，先出现的那个列名可能吃到别的列。
   * 例如 ['总成绩','成绩'] 在只有「成绩」列的页面上，包含匹配也能命中；
   * 而「课程性质」不会被「课程属性」误吃的前提是整格相等这一步先跑完。
   */
  private static findColumnIn(labels: string[], names: string[]): number {
    for (let w = 0; w < names.length; w++) {
      for (let i = 0; i < labels.length; i++) {
        if (labels[i] === names[w]) {
          return i;
        }
      }
    }
    for (let w = 0; w < names.length; w++) {
      for (let i = 0; i < labels.length; i++) {
        if (labels[i].indexOf(names[w]) >= 0) {
          return i;
        }
      }
    }
    return -1;
  }

  /** 取第 i 格文本（越界返回空串），空白折叠成单空格 */
  private static at(cells: HtmlCell[], i: number): string {
    if (i < 0 || i >= cells.length) {
      return '';
    }
    return cells[i].text.replace(/\s+/g, ' ').trim();
  }
}
