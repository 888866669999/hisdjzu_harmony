/*
 * 成绩解析器：解析「课程成绩查询」结果页 (/jsxsd/kscj/cjcx_list)
 *
 * 列位置**按表头文本定位**而不是写死下标：建大的真实表头是
 * 序号 / 开课学期 / 课程编号 / 课程名称 / 成绩 / 成绩标识 / 学分 / 总学时 /
 * 绩点 / 补重学期 / 考核方式 / 考试性质 / 课程属性 / 课程性质 / 公选课类别 / 通选课类别，
 * 与旧校版式不同（列数、顺序都变了），写死下标会整行错位。
 *
 * 注意「学分」与「平均学分绩点」这类包含关系：先精确匹配，再退回包含匹配，
 * 否则「学分」会命中「平均学分绩点」那一列。
 */
import { HtmlLite, HtmlTable, HtmlRow, HtmlCell, HtmlOption } from './HtmlLite';
import { ScoreRecord, ScoreSummary, ChoiceItem } from '../model/Models';
import { Logger } from '../common/Logger';

/** 成绩表列索引；-1 表示表头里没有这一列（取值处会拿到空串，而不是别的列的值） */
class ScoreCols {
  index: number = -1;
  semester: number = -1;
  courseCode: number = -1;
  courseName: number = -1;
  score: number = -1;
  credit: number = -1;
  gpa: number = -1;
  examType: number = -1;
  courseNature: number = -1;
  courseAttr: number = -1;
  minor: number = -1;
}

/**
 * 成绩结果页的解析结果。
 *
 * `recognized` 表示「这页确实是成绩结果页」——与 `records` 是否为空是
 * **两件事**，调用方必须分开看（见 mergeScoreRecords 的说明）。
 */
export class ScorePageResult {
  records: ScoreRecord[] = [];
  recognized: boolean = false;

  constructor(records: ScoreRecord[], recognized: boolean) {
    this.records = records;
    this.recognized = recognized;
  }
}

/**
 * 决定成绩列表该采用新结果、还是保留旧数据。
 *
 * ===== 这段判断就是「成绩页学期筛选看起来没反应」那个缺陷的全部所在 =====
 * 原来写成「新结果非空才覆盖」，于是切到**没有成绩的学期**时，
 * 服务端如实回了空、判断却选择保留旧数据，列表里显示的仍是上一个学期的
 * 成绩 —— 用户看到的现象就是「学期选项点了没反应」。
 *
 * 服务端本身按 `kksj` 过滤得好好的（实测：不传回全部，传具体学期只回该学期）。
 *
 * 判据必须是 [ScorePageResult.recognized]（「这是不是结果页」），
 * **不能**是「记录是不是空的」—— 后者把「该学期没有成绩」与
 * 「这次查询没拿到结果」混为一谈。抽成纯函数是为了能用无设备的用例钉住它
 * （见 testdata/run-tests.mjs 的同名断言）。
 */
export function mergeScoreRecords(current: ScoreRecord[], page: ScorePageResult): ScoreRecord[] {
  if (page.recognized || current.length === 0) {
    return page.records;
  }
  return current;
}

export class ScoreParser {
  static parse(html: string): ScoreRecord[] {
    return ScoreParser.parsePage(html).records;
  }

  /**
   * 解析成绩结果页，并报告「这一页认得出来吗」。
   *
   * 两种「空」必须分得开：
   *   · recognized=true 且为空 → **该学期确实没有成绩**（服务端返回了结果表，
   *     表里是「未查询到数据」这类空行）。这是权威答案，应当如实显示空。
   *   · recognized=false → 这次响应根本不是成绩结果页（登录页/错误页/半截页），
   *     应当保留上一次的数据而不是清空。
   */
  static parsePage(html: string): ScorePageResult {
    const out: ScoreRecord[] = [];
    const table: HtmlTable | null = ScoreParser.locateTable(html);
    if (table === null) {
      Logger.warn('score table not found');
      return new ScorePageResult(out, false);
    }
    // 找表头行，并据此定位各列（不写死列序，便于兼容其他强智版本）
    let headerRow: number = -1;
    for (let i = 0; i < table.rows.length && i < 4; i++) {
      if (table.rows[i].text.indexOf('课程名称') >= 0) {
        headerRow = i;
        break;
      }
    }
    if (headerRow < 0) {
      // 有表但认不出表头 —— **不能**当成「该学期没有成绩」，
      // 那样会把用户手里的成绩清成空白。见 parsePage 的说明。
      return new ScorePageResult(out, false);
    }
    const col: ScoreCols = ScoreParser.resolveCols(table.rows[headerRow]);

    for (let r = headerRow + 1; r < table.rows.length; r++) {
      const row: HtmlRow = table.rows[r];
      if (row.cells.length < 5) {
        continue;
      }
      const cells: HtmlCell[] = row.cells;
      // 空态：只有一个“未查询到数据”
      if (cells.length === 1 || /未查询到数据/.test(row.text)) {
        continue;
      }
      const rec: ScoreRecord = new ScoreRecord();
      rec.index = ScoreParser.at(cells, col.index);
      rec.semester = ScoreParser.at(cells, col.semester);
      rec.courseCode = ScoreParser.at(cells, col.courseCode);
      rec.courseName = ScoreParser.at(cells, col.courseName);
      rec.score = ScoreParser.at(cells, col.score);
      rec.credit = ScoreParser.at(cells, col.credit);
      rec.gpa = ScoreParser.at(cells, col.gpa);
      rec.examType = ScoreParser.at(cells, col.examType);
      rec.courseNature = ScoreParser.at(cells, col.courseNature);
      rec.courseAttr = ScoreParser.at(cells, col.courseAttr);
      rec.minor = ScoreParser.at(cells, col.minor);
      if (rec.courseName.length === 0) {
        continue;
      }
      out.push(rec);
    }
    Logger.info('score records parsed: ' + out.length);
    // 走到这里说明表头认出来了 —— 即使 out 为空，那也是「该学期没有成绩」
    // 这个权威答案（服务端在表里放一行「未查询到数据」，上面已跳过）。
    return new ScorePageResult(out, true);
  }

  /** 按表头文本定位列索引，找不到的列留在 -1 */
  private static resolveCols(header: HtmlRow): ScoreCols {
    const c: ScoreCols = new ScoreCols();
    const labels: string[] = [];
    for (let i = 0; i < header.cells.length; i++) {
      labels.push(header.cells[i].text.trim());
    }
    c.index = ScoreParser.findCol(labels, '序号');
    c.semester = ScoreParser.findCol(labels, '开课学期');
    c.courseCode = ScoreParser.findCol(labels, '课程编号');
    c.courseName = ScoreParser.findCol(labels, '课程名称');
    c.score = ScoreParser.findCol(labels, '成绩');
    c.credit = ScoreParser.findCol(labels, '学分');
    c.gpa = ScoreParser.findCol(labels, '绩点');
    c.examType = ScoreParser.findCol(labels, '考试性质');
    c.courseNature = ScoreParser.findCol(labels, '课程性质');
    c.courseAttr = ScoreParser.findCol(labels, '课程属性');
    // 「辅修课程」不参与定位，minor 保持 -1（本校成绩表没有这一列）。
    // 若像旧实现那样回退到位置下标 10，本校第 10 列恰好是「考核方式」，
    // 「辅修」就会显示成「考试」—— 错列且不报任何错的静默错误。
    return c;
  }

  /**
   * 按表头文字定位列：先精确匹配，再包含匹配；**找不到返回 -1**。
   *
   * ===== 为什么不能退回位置下标 =====
   * 位置下标只是某一份表头的快照，一换学校/一换版式就整行错位，而错位是
   * **静默**的：页面上只会出现一个莫名其妙的值，不报任何错。返回 -1 后，
   * 取值处拿到空串 —— 一眼能看出「这一列不存在」，而不是被别的列的值冒充。
   */
  private static findCol(labels: string[], want: string): number {
    // 先精确匹配，避免「学分」误命中「平均学分绩点」这类包含关系
    for (let i = 0; i < labels.length; i++) {
      if (labels[i] === want) {
        return i;
      }
    }
    for (let i = 0; i < labels.length; i++) {
      if (labels[i].indexOf(want) >= 0) {
        return i;
      }
    }
    return -1;
  }

  private static at(cells: HtmlCell[], i: number): string {
    if (i < 0 || i >= cells.length) {
      return '';
    }
    return cells[i].text.replace(/\s+/g, ' ').trim();
  }

  /**
   * 由**分数**算绩点：`绩点 = (分数 - 50) ÷ 10`。
   *
   * ===== 为什么自己算而不是读页面 =====
   * 本校成绩页的「绩点」列**整列都是 0**（学校没有录入），
   * 直接读它会让界面显示成「每科 0 绩点、平均绩点 0.000」，
   * 而这看起来完全正常、只是数字不对 —— 属于静默错误。
   *
   * 规则来自用户：`绩点 = (分数 - 50) ÷ 10`。
   * 即 60 分 = 1.0、90 分 = 4.0、100 分 = 5.0 —— 国内高校常见的 5 分制。
   * 不除十时 60 分是 10 绩点，量纲和「绩点」这个说法对不上，
   * 汇总出的平均绩点（40.72 这种）看着也不像绩点。
   *
   * 对非数字成绩（「优秀」「良好」这类）返回 -1，表示「算不出」——
   * 调用方据此跳过，而不是当成 0 参与平均（那会把均值拖低）。
   */
  static gpaFromScore(score: string): number {
    const v: number = parseFloat(score.trim());
    if (isNaN(v) || v <= 0) {
      return -1;
    }
    return (v - 50) / 10;
  }

  /**
   * 汇总：门数、总学分、**平均绩点**（客户端计算）。
   *
   * 只统计「能算出绩点」的课程（`gpaFromScore` < 0 的跳过）——
   * 否则会把「优秀/合格」这类没有分数的课算成 0 参与平均（把均值拖低）。
   */
  static summarize(records: ScoreRecord[]): ScoreSummary {
    const s: ScoreSummary = new ScoreSummary();
    s.count = records.length;
    let creditSum: number = 0;
    let gpaSum: number = 0;
    let gpaCount: number = 0;
    for (let i = 0; i < records.length; i++) {
      const r: ScoreRecord = records[i];
      const g: number = ScoreParser.gpaFromScore(r.score);
      if (g < 0) {
        continue;
      }
      creditSum += r.creditNumber();
      gpaSum += g;
      gpaCount++;
    }
    s.totalCredit = Math.round(creditSum * 100) / 100;
    // 平均绩点 = 各科绩点之和 ÷ 科目数。
    // **不是**学分加权（用户的规则就是简单平均）：加权口径下 1 学分的
    // 体育课对均值几乎没有影响，而这所学校的评价方式是「每科绩点直接平均」。
    s.averageGpa = gpaCount > 0 ? Math.round((gpaSum / gpaCount) * 1000) / 1000 : 0;
    return s;
  }

  /** 读取学期下拉（用于筛选），仅保留有值的项 */
  static readSemesters(html: string): ChoiceItem[] {
    return ScoreParser.toOptions(HtmlLite.findSelect(html, 'kksj'));
  }

  /** 把原始 option 转成模型，过滤空值项 */
  private static toOptions(raw: HtmlOption[]): ChoiceItem[] {
    const out: ChoiceItem[] = [];
    for (let i = 0; i < raw.length; i++) {
      if (raw[i].value.length > 0) {
        out.push(new ChoiceItem(raw[i].label, raw[i].value));
      }
    }
    return out;
  }

  private static locateTable(html: string): HtmlTable | null {
    // 优先按表头关键字定位，避免依赖表格顺序
    const t: HtmlTable | null = HtmlLite.findTableByHeader(html, '课程名称');
    if (t !== null) {
      return t;
    }
    return HtmlLite.findTableById(html, 'dataList');
  }
}
