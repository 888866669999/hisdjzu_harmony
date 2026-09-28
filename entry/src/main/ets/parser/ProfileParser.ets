/*
 * 个人信息解析器：解析「毕业生信息核对」(/jsxsd/bygl/bysxx)
 *
 * ===== 本校页面与参考实现不同，但形态更简单 =====
 * 参考实现（山财）是「学籍卡片」大表（#xjkpTable），一格里塞多组
 * 「标签：值」，还混着子表节标题，判据要写得很小心。
 * 本校没有学籍卡片页 —— 逐条试过所有候选后，用 /jsxsd/bygl/bysxx
 * （「毕业生信息核对」，实测非毕业年级同样可访问）：
 *
 *   | 所属院系 : | 热能工程学院 | 所属专业 : | 能源与动力工程… |
 *   | 所在班级 : | 能创251      | 培养层次 : | 普通本科         |
 *
 * 即**每行 4 格 = 两组「标签: 值」**，标签带冒号（全角/半角都有）。
 *
 * 因此这里保留参考实现的两条通路（单元格内冒号对 + 相邻成对），
 * 但**放宽表定位**：不再要求 #xjkpTable，而是扫所有表取第一张
 * 含「标签: 值」形态的 —— 本校的表没有 id。
 *
 * 另外三处差异（各自方法里有说明）：
 *   - 标签末尾冒号要清掉：页面写成 `所属院系 :`（冒号前还有空格），
 *     不清掉会让界面显示成「所属院系 :」这种带符号的怪标签；
 *   - 值可能只存在于 `<input value="...">` 里：姓名、证件号都是可编辑
 *     输入框，文本节点是空的；
 *   - 证件类字段不展示也不缓存，见 SENSITIVE_KEYWORDS。
 */
import { HtmlLite, HtmlTable, HtmlCell } from './HtmlLite';
import { StudentProfile, ProfileSection, ProfileField } from '../model/Models';
import { Logger } from '../common/Logger';

export class ProfileParser {
  /**
   * 基本信息字段（按此顺序展示；未列出的归入「其他信息」）。
   *
   * 前 9 个是本校叫法（带「所属/所在」前缀），后面保留参考实现那边的
   * 叫法：分组判据只认字面标签，两校字段名不同，两份都留着才能两校通用。
   */
  private static readonly BASIC_KEYS: string[] = [
    '学号', '姓名', '姓名拼音', '性别', '所属院系', '所属专业', '所在班级', '培养层次', '学制',
    '院系', '专业', '班级', '出生日期', '民族', '政治面貌', '学习层次', '学习形式', '外语种类', '籍贯', '婚否'
  ];

  /**
   * **不展示、也不缓存**的字段（命中任一关键词即剔除）。
   *
   * ===== 为什么要有这个名单 =====
   * 页面里有证件号这类高敏感信息，而本应用把「整页原文」落盘做离线缓存 ——
   * 不拦掉的话，证件号会以明文躺在应用私有目录里（虽然沙箱隔离，
   * 但没有必要承担这个风险：这些字段与本应用的任何功能都无关）。
   *
   * 拦在**解析层**而不是界面层，是为了让缓存也拿不到它们：
   * 缓存存的是原文、展示的是解析结果，只有在这里丢掉才两边都干净。
   *
   * 用关键词匹配而不是精确标签名：服务端这类字段的措辞不统一
   * （实测见过「身份证编号」，别处可能叫「身份证号」「证件号码」）。
   * 「证件」比「证件号」更宽：本校把这两个字段拆成「证件类型 / 证件号」
   * 两格，「证件类型」不含「号」字，只匹配「证件号」会漏掉它。
   */
  private static readonly SENSITIVE_KEYWORDS: string[] = [
    '身份证', '证件', '入学考号', '证书号', '考生号', '银行卡'
  ];

  static parse(html: string): StudentProfile {
    const p: StudentProfile = new StudentProfile();

    // 本校的表**没有 id**，因此扫所有表、取第一张含「标签: 值」形态的。
    // 仍优先找 #xjkpTable（参考实现那边用它），找不到再扫 ——
    // 这样两校都能用，不必为每所学校各写一份。
    let table: HtmlTable | null = HtmlLite.findTableById(html, 'xjkpTable');
    if (table === null) {
      const tables: HtmlTable[] = HtmlLite.parseTables(html);
      for (let i = 0; i < tables.length; i++) {
        if (ProfileParser.looksLikeProfileTable(tables[i])) {
          table = tables[i];
          break;
        }
      }
    }
    if (table === null) {
      Logger.warn('profile table not found');
      return p;
    }

    const raw: ProfileField[] = [];
    /**
     * 上一行是否为分节标题。为真时，当前行是子表的**列名行**，
     * 不能按「相邻两格 = 标签/值」解析（否则会产生 `起止年月=学校或工作单位`
     * 这类伪字段）。见 isSectionTitleRow 的说明。
     */
    let afterSectionTitle: boolean = false;

    for (let r = 0; r < table.rows.length; r++) {
      const cells: HtmlCell[] = table.rows[r].cells;

      // 分节标题行：标记下一行是列名行，并跳过本行
      if (ProfileParser.isSectionTitleRow(cells)) {
        afterSectionTitle = true;
        continue;
      }
      // 节标题后的那一行：只有**确实是子表列名**时才跳过。
      //
      // 这里必须再加一层判断，否则会误伤真实数据行 —— 实测「学籍卡片」
      // 标题（写成 `学 籍 卡 片`）后面紧跟的就是院系/专业/学制/班级/学号
      // 那一行，早期实现把它当列名整行丢掉，结果学号、姓名拼音等字段
      // 全部消失，而界面上看不出任何异常。
      //
      // 区分依据：列名行不含冒号（`起止年月 / 学 校 或 工 作 单 位 / 职务`），
      // 真实数据行含冒号（`院系：示例学院`）。
      if (afterSectionTitle) {
        afterSectionTitle = false;
        if (!ProfileParser.hasColonCell(cells)) {
          continue;
        }
      }

      // 形态一：单元格内含 "标签：值"，一个单元格可能有多组
      for (let c = 0; c < cells.length; c++) {
        const text: string = cells[c].text.replace(/\s+/g, ' ').trim();
        if (text.length === 0 || text.indexOf('：') < 0) {
          continue;
        }
        ProfileParser.pullColonPairs(text, raw);
      }

      // 形态二：相邻单元格成对（标签在左，值在右）
      ProfileParser.pullAdjacentPairs(cells, raw);
    }

    // 去重（保序）。
    //
    // **值为空的字段也保留**：学校常常留空某些格，丢掉会让用户以为
    // 「没有这个字段」，而实际是「学校没填」。界面会显示成 `姓名`（空值）。
    // 唯一的例外是完全没有标签的行（表头、装饰行）。
    const dedup: ProfileField[] = [];
    for (let i = 0; i < raw.length; i++) {
      const f: ProfileField = raw[i];
      if (f.label.length === 0) {
        continue;
      }
      let dup: boolean = false;
      for (let j = 0; j < dedup.length; j++) {
        if (dedup[j].label === f.label) {
          dup = true;
          break;
        }
      }
      if (!dup) {
        dedup.push(f);
      }
    }

    // 抽取姓名/学号
    for (let i = 0; i < dedup.length; i++) {
      if (dedup[i].label === '姓名' && p.name.length === 0) {
        p.name = dedup[i].value;
      }
      if (dedup[i].label === '学号' && p.studentId.length === 0) {
        p.studentId = dedup[i].value;
      }
    }
    // ===== 姓名回退到拼音 =====
    // 本校的「姓名」格可能是空的（学校没录入），而「姓名拼音」有值。
    // 不回退的话，外壳（顶栏/侧栏）与桌面卡片都会显示「未获取到姓名」——
    // 用户看着自己的名字明明在校网上，会以为应用坏了。
    // 用拼音显示是个可接受的折中：至少能认出是自己。
    if (p.name.length === 0) {
      for (let i = 0; i < dedup.length; i++) {
        const label: string = dedup[i].label;
        if ((label.indexOf('姓名拼音') >= 0 || label.indexOf('拼音') >= 0) &&
          dedup[i].value.length > 0) {
          p.name = dedup[i].value;
          break;
        }
      }
    }

    // 分组：基本信息 + 其他信息。
    // 敏感字段在这里被丢弃（见 SENSITIVE_KEYWORDS 的说明）——
    // 位置刻意放在「提取姓名/学号之后、分组之前」：
    // 万一将来把类别名加进黑名单，也不会影响姓名学号的提取。
    const basic: ProfileField[] = [];
    const others: ProfileField[] = [];
    for (let i = 0; i < dedup.length; i++) {
      const f: ProfileField = dedup[i];
      if (ProfileParser.isSensitive(f.label)) {
        continue;
      }
      if (ProfileParser.isBasic(f.label)) {
        basic.push(f);
      } else {
        others.push(f);
      }
    }
    // 按 BASIC_KEYS 的次序重排：页面上字段顺序各校不同，
    // 固定顺序（学号/姓名在前）才能让界面布局稳定。
    basic.sort((a: ProfileField, b: ProfileField) =>
      ProfileParser.BASIC_KEYS.indexOf(a.label) - ProfileParser.BASIC_KEYS.indexOf(b.label));

    if (basic.length > 0) {
      p.sections.push(new ProfileSection('基本信息', basic));
    }
    if (others.length > 0) {
      p.sections.push(new ProfileSection('其他信息', others));
    }
    Logger.info('profile parsed: fields=' + dedup.length + ' sections=' + p.sections.length);
    return p;
  }

  /** 该字段是否属于敏感信息（命中任一关键词） */
  private static isSensitive(label: string): boolean {
    for (let i = 0; i < ProfileParser.SENSITIVE_KEYWORDS.length; i++) {
      if (label.indexOf(ProfileParser.SENSITIVE_KEYWORDS[i]) >= 0) {
        return true;
      }
    }
    return false;
  }

  /** 该行是否含「标签：值」形态的单元格（只看全角冒号，与提取通路一致） */
  private static hasColonCell(cells: HtmlCell[]): boolean {
    for (let i = 0; i < cells.length; i++) {
      if (cells[i].text.indexOf('：') >= 0) {
        return true;
      }
    }
    return false;
  }

  private static isBasic(label: string): boolean {
    for (let i = 0; i < ProfileParser.BASIC_KEYS.length; i++) {
      if (ProfileParser.BASIC_KEYS[i] === label) {
        return true;
      }
    }
    return false;
  }

  /**
   * 该行是否是「分节标题」行（形如 `学 籍 卡 片`、`学 习 及 工 作 简 历`、
   * `家 庭 成 员 情 况`）。
   *
   * 为什么需要判断：学籍卡片里嵌了若干子表（工作简历/家庭成员/异动/奖励/处分），
   * 每个子表前面有一行合并单元格的分节标题，紧随其后的就是该子表的**列名行**
   * （如 `起止年月 | 学 校 或 工 作 单 位 | 职务`）。
   * 若把列名行也按「相邻两格 = 标签/值」解析，就会生成
   * `起止年月=学 校 或 工 作 单 位` 这类伪字段。
   *
   * 判据（只用结构，不猜内容）：整行只有 1 个非空格子，
   * 且该文本较短、不含数字与冒号。这正是分节标题的形态；
   * 而真实字段行不会只有一个非空格子（`籍贯 | 空` 也有两个）。
   *
   * 判长度前必须先去掉**字间空白**：真实页面把标题写成 `学 籍 卡 片`
   * （字间带空格），直接量长度会虚高。
   */
  private static isSectionTitleRow(cells: HtmlCell[]): boolean {
    let nonEmpty: number = 0;
    let text: string = '';
    for (let i = 0; i < cells.length; i++) {
      const t: string = cells[i].text.trim();
      if (t.length > 0) {
        nonEmpty++;
        text = t;
      }
    }
    if (nonEmpty !== 1) {
      return false;
    }
    const compact: string = text.replace(/\s+/g, '');
    if (compact.length < 3 || compact.length > 16) {
      return false;
    }
    if (/\d/.test(compact) || compact.indexOf('：') >= 0) {
      return false;
    }
    return true;
  }

  /** 从 "院系：A 专业：B" 里提取多组标签值 */
  private static pullColonPairs(text: string, sink: ProfileField[]): void {
    // 先按冒号切出「值」，再判断值里是否混入了下一个标签
    const segs: string[] = text.split('：');
    for (let i = 0; i < segs.length - 1; i++) {
      const label: string = ProfileParser.lastLabel(segs[i]);
      let value: string = segs[i + 1];
      if (i + 1 < segs.length - 1) {
        // 值的尾部可能粘着下一个标签（如 `A 专业`）
        const m: RegExpMatchArray | null = value.match(/^(.+?)\s+([\u4e00-\u9fa5A-Za-z]{2,10})$/);
        if (m !== null) {
          value = m[1];
        }
      }
      const v: string = value.trim();
      const clean: string = ProfileParser.cleanLabel(label);
      // 标签也要过同一套校验：页脚有「注：毕业生信息核对时间未到！」，
      // 它含全角冒号、会从这个通路进来 —— 单字标签被长度判据挡掉。
      if (ProfileParser.isPlausibleLabel(clean) && v.length > 0) {
        sink.push(new ProfileField(clean, v));
      }
    }
  }

  /**
   * 取 `A：` 里的 A：按空白切分取最后一段，并限制长度。
   *
   * 不能按冒号再切（调用方已经切过），也不能用「末尾 2–10 个连续汉字」
   * 的正则：遇到含括号的标签会被截断（`毕(结)业证书号` → `业证书号`）。
   */
  private static lastLabel(seg: string): string {
    const t: string = seg.trim();
    if (t.length === 0) {
      return '';
    }
    const parts: string[] = t.split(/\s+/);
    const last: string = parts[parts.length - 1].trim();
    if (last.length === 0 || last.length > 12) {
      return '';
    }
    return last;
  }

  /**
   * 这张表像不像「个人信息」表？
   *
   * 判据：**至少两行**出现「标签(可带冒号) + 值」的相邻配对，
   * 且标签是简短中文。用「至少两行」而不是「一行」是为了避开
   * 页面上的零碎小表（分页器、按钮条也会成对出现）。
   *
   * 这里只看单元格**文本**：本判据只用于定位表，读 input 会把
   * 装饰性的空输入框也算成有值，定位反而更松。
   */
  private static looksLikeProfileTable(t: HtmlTable): boolean {
    let hits: number = 0;
    for (let r = 0; r < t.rows.length; r++) {
      const cells: HtmlCell[] = t.rows[r].cells;
      for (let i = 0; i + 1 < cells.length; i += 2) {
        const label: string = ProfileParser.cleanLabel(cells[i].text);
        const value: string = cells[i + 1].text.trim();
        if (ProfileParser.isPlausibleLabel(label) && value.length > 0) {
          hits++;
          break;
        }
      }
      if (hits >= 2) {
        return true;
      }
    }
    return false;
  }

  /** 标签是否像字段名：2–12 个汉字（可含括号），不含数字与长串英文 */
  private static isPlausibleLabel(label: string): boolean {
    // 长度下限 2：页脚有一行「注：毕业生信息核对时间未到！」，
    // 它的标签只有一个「注」字 —— 长度判据正好把它挡在外面
    // （之前它作为「其他信息 → 注」出现在界面上）。
    if (label.length < 2 || label.length > 12) {
      return false;
    }
    if (/^\d+$/.test(label)) {
      return false;
    }
    // 允许汉字与括号（「毕(结)业证书号」这类），不含数字与英文
    return /^[一-龥()（）]+$/.test(label);
  }

  /**
   * 去掉标签末尾的冒号与空白：`所属院系 :` → `所属院系`。
   *
   * 只在末尾去：字段名内部不会出现冒号。半角/全角/小号冒号都要处理，
   * 页面混用（本校标签写的是半角 `:`，冒号前还带一个空格）。
   */
  private static cleanLabel(raw: string): string {
    let s: string = raw.replace(/\s+/g, ' ').trim();
    while (s.length > 0) {
      const last: string = s.charAt(s.length - 1);
      if (last === ':' || last === '：' || last === '﹕') {
        s = s.substring(0, s.length - 1).trim();
      } else {
        break;
      }
    }
    return s;
  }

  /**
   * 相邻单元格成对：如 | 姓名 | 张xx | 性别 | 男 |。
   *
   * **值为空也收**：学校会留空某些格，丢掉会让用户以为字段不存在。
   * 界面显示成 `姓名`（空值）才如实。
   */
  private static pullAdjacentPairs(cells: HtmlCell[], sink: ProfileField[]): void {
    for (let i = 0; i + 1 < cells.length; i += 2) {
      // 统一清掉末尾冒号（本校页面写成 `所属院系 :`）
      const label: string = ProfileParser.cleanLabel(cells[i].text);
      if (!ProfileParser.isPlausibleLabel(label)) {
        continue;
      }
      sink.push(new ProfileField(label, ProfileParser.cellValue(cells[i + 1])));
    }
  }

  /**
   * 取一个单元格的「值」。
   *
   * ===== 为什么不能只读文本（本校踩过的坑）=====
   * 本校页面把部分字段做成**可编辑输入框**，值在属性里而不在文本节点：
   *   <td>姓名 :</td><td><input type="text" id="xm" name="xm" value="李示例"></td>
   * 只读 cell.text 会得到空串 —— 于是「姓名」永远为空，外壳只能显示
   * 「未获取到姓名」，而**页面上明明有名字**。
   *
   * 取不到 input 时退回文本，两种版式都能用。
   */
  private static cellValue(cell: HtmlCell): string {
    const text: string = cell.text.trim();
    if (text.length > 0) {
      return text;
    }
    // 退而看 input 的 value（取第一个：一个格里可能有多个 input，
    // 但字段值通常就是第一个）
    const re: RegExp = new RegExp('<input[^>]*\\bvalue\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\')', 'i');
    const m: RegExpMatchArray | null = cell.inner.match(re);
    if (m === null) {
      return '';
    }
    let raw: string = '';
    if (m[1] !== undefined && m[1] !== null) {
      raw = m[1];
    } else if (m[2] !== undefined && m[2] !== null) {
      raw = m[2];
    }
    return HtmlLite.decode(raw.trim());
  }
}
