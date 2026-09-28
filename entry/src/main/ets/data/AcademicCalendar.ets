/*
 * AcademicCalendar：作息数据（只有作息，没有校历日期）
 *
 * ===== 数据来源与移植源（山财）不同 =====
 * 山建的教务处官网**没有公开作息时刻表页**（只有校历 PDF），
 * 但**教务系统的课表页自己就带时刻** —— 每个节次行的行首格写作：
 *   `第一大节 (01,02小节) 07:50-09:25`
 * 这是校内唯一的权威来源，因此：
 *   1. 下面这份内置值照它抄录，只作**冷启动/离线兜底**；
 *   2. 正常路径是从课表页解析后覆盖它 —— 见 CampusCalendarService。
 *
 * 为什么兜底也要有：作息决定「上课提醒」的触发时刻，
 * 首次安装、没网、还没打开过课表时，必须有个合理值可用。
 *
 * ===== 这里只有作息，没有校历日期 =====
 * 硬编码的日期（开学日、总周数）换学年后就静默变错，界面看不出来。
 * 那部分已删除，改由教务系统的**教学周历**实时提供 ——
 * 见 data/SemesterCalendarService.ets。
 * 校历图片本身也不随包内置：一张可能过期的校历比一块空缺更危险。
 */

/** 节次作息的权威默认值（官方「日常教学时刻表」，2026 年 7 月更新） */
export class OfficialSection {
  /** 课表中的行号（0 起） */
  row: number = 0;
  /** 教科书式标签，与课表行一致 */
  label: string = '';
  /** 起始时刻 */
  start: string = '';
  /** 结束时刻 */
  end: string = '';

  constructor(row: number, label: string, start: string, end: string) {
    this.row = row;
    this.label = label;
    this.start = start;
    this.end = end;
  }
}

/**
 * 官方日常教学时刻表，按课表的 5 个行归并。
 *
 *   第一大节  01,02 小节      07:50-09:25
 *   第二大节  03,04,05 小节   09:40-12:05
 *   第三大节  06,07 小节      13:40-15:15
 *   第四大节  08,09 小节      15:30-17:05
 *   第五大节  10,11,12 小节   18:40-21:05
 */
export const OFFICIAL_SECTIONS: OfficialSection[] = [
  new OfficialSection(0, '第一大节', '07:50', '09:25'),
  new OfficialSection(1, '第二大节', '09:40', '12:05'),
  new OfficialSection(2, '第三大节', '13:40', '15:15'),
  new OfficialSection(3, '第四大节', '15:30', '17:05'),
  new OfficialSection(4, '第五大节', '18:40', '21:05')
];

/**
 * 课间休息。
 * 用 followsRow 指向「排在哪个节次之后」，而不是按名称匹配 ——
 * 节次名各校写法不同（山建是「第一大节」），按名称匹配容易漏。
 *
 * 山建的课表页只给每个大节的起止时刻，**不给课间**，
 * 因此这张表是空的（大节之间的空档已包含在起止时刻里）。
 */
export class OfficialBreak {
  /** 排在第几行（0 起的课表行号）之后 */
  followsRow: number = 0;
  start: string = '';
  end: string = '';

  constructor(followsRow: number, start: string, end: string) {
    this.followsRow = followsRow;
    this.start = start;
    this.end = end;
  }
}

/** 官方课间休息安排 */
export const OFFICIAL_BREAKS: OfficialBreak[] = [];

/**
 * 教务处「信息公开」栏目 —— 用户从这里找当年校历。
 *
 * **不指向具体校历页**：那个地址逐年在变（`info/1024/3232.htm` 这类
 * 编号式路径），写死一个必然过期，而过期的表现是「打开校历显示去年的
 * 日期」—— 比没有更糟。设置页给用户这个栏目地址，由他自己找到那份填进来。
 */
export const CAMPUS_CALENDAR_INDEX_URL: string = 'https://www.sdjzu.edu.cn/jwc/xxgk.htm';

export class AcademicCalendar {
  /** 按学期代码取校历；找不到返回 null */


  /**
   * 猜测某个学期代码对应的校历。
   * 教务系统的学期代码形如 2026-2027-1 / 2026-2027-2；
   * 若没有精确匹配，退化为「同学年同学期」，便于跨学年复用规则。
   */


  /** 该学期是否有同学期但不同学年的校历（用于提示「沿用往年规则」） */


  /** 官方作息表的纯文本行，用于设置页与课表页展示 */
  static sectionLines(): string[] {
    const out: string[] = [];
    for (let i = 0; i < OFFICIAL_SECTIONS.length; i++) {
      const s: OfficialSection = OFFICIAL_SECTIONS[i];
      out.push(s.label + '  ' + s.start + ' - ' + s.end);
      // 在对应节次后插入课间休息（按行号匹配，见 OfficialBreak 的说明）
      for (let j = 0; j < OFFICIAL_BREAKS.length; j++) {
        const b: OfficialBreak = OFFICIAL_BREAKS[j];
        if (b.followsRow === i) {
          out.push('课间休息  ' + b.start + ' - ' + b.end);
        }
      }
    }
    return out;
  }
}
