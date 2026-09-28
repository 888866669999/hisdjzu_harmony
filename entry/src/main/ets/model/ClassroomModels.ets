/*
 * ClassroomModels：空教室查询的模型与纯计算
 *
 * 单独成文件的原因：这里包含「某教室在某周某天某节次是否空闲」的全部判断逻辑，
 * 不依赖任何 HarmonyOS API，可以在 Node 里直接单测（见 testdata/run-tests.mjs）。
 *
 * ===== 为什么必须自己按周次过滤（已实测，很关键）=====
 * 服务端 `POST /jsxsd/kbxx/jsjy_query2` 的 `zc`/`zc2`（周次区间）参数**不可靠**：
 *   1. 课程类占用会被正确过滤；
 *   2. 但「借用」类占用**完全无视周次**——第 2 周的借用记录在任何一周都会出现；
 *   3. 而且当周次筛选后，**该周没有任何占用记录的教室会被整行丢掉**
 *      （实测：不筛=231 间，筛第 4 周=196 间，筛第 10 周=225 间）。
 * 第 3 点对「找空教室」是致命的：真正全周空闲的教室恰恰就是被丢掉的那些。
 *
 * 因此本功能**一律不传周次**去查（拿到完整教室表与全学期占用文本），
 * 再由客户端按单元格里的周次说明自行过滤 —— 语义统一，也不会漏掉空教室。
 *
 * 单元格里两种周次写法都已覆盖：
 *   课程：(3-18周)、(5-18双周)、(1-2,4-8,10周)
 *   借用：被借用( 第(2周)(01-04节)周,王超,学生活动 )
 */

import { MAX_WEEKS, SECTIONS } from '../common/Constants';

/** 周次说明：区间集合 + 单双周约束 */
export class WeekSpec {
  /** 区间列表，每项为 [起, 止]（含两端） */
  ranges: number[][] = [];
  /** 0=每周 1=单周 2=双周 */
  parity: number = 0;
  /** 原始文本，便于界面回显与排查 */
  raw: string = '';

  /** 第 week 周是否命中该说明 */
  isActive(week: number): boolean {
    if (week <= 0) {
      return true;
    }
    if (this.ranges.length === 0) {
      // 拿不到周次说明时保守判为占用：宁可少报空闲，不能把有课的教室报成空的
      return true;
    }
    let inRange: boolean = false;
    for (let i = 0; i < this.ranges.length; i++) {
      const r: number[] = this.ranges[i];
      if (r.length !== 2) {
        continue;
      }
      if (week >= r[0] && week <= r[1]) {
        inRange = true;
        break;
      }
    }
    if (!inRange) {
      return false;
    }
    // 单双周只在「区间内」起过滤作用，且**必须与区间自洽**。
    //
    // 真实页面里存在 `(4单周)` 这种写法：第 4 周是偶数，却标了「单周」。
    // 若无条件按单双周过滤，这门课在任何一周都不会显示 —— 属于静默丢课。
    // 因此先判断「区间里是否真的存在符合该奇偶的周」，不存在就忽略奇偶标记，
    // 以显式写出的周次为准。
    if (this.parity === 0 || !this.parityPossible()) {
      return true;
    }
    if (this.parity === 1 && week % 2 === 0) {
      return false;
    }
    if (this.parity === 2 && week % 2 === 1) {
      return false;
    }
    return true;
  }

  /** 区间里是否存在符合单双周标记的周次 */
  private parityPossible(): boolean {
    for (let i = 0; i < this.ranges.length; i++) {
      const r: number[] = this.ranges[i];
      if (r.length !== 2) {
        continue;
      }
      for (let w = r[0]; w <= r[1]; w++) {
        if (this.parity === 1 && w % 2 === 1) {
          return true;
        }
        if (this.parity === 2 && w % 2 === 0) {
          return true;
        }
      }
    }
    return false;
  }

  /** 是否为「整学期每周」——这类占用在任何一周都算忙 */
  allowsAnyWeek(): boolean {
    if (this.parity !== 0) {
      return false;
    }
    for (let i = 0; i < this.ranges.length; i++) {
      const r: number[] = this.ranges[i];
      if (r.length === 2 && r[0] <= 1 && r[1] >= MAX_WEEKS) {
        return true;
      }
    }
    return false;
  }

  /** 展示用文本，如 "3-18周" / "5-18周(双)" / "周次未知" */
  display(): string {
    const p: string = this.parity === 1 ? '(单)' : (this.parity === 2 ? '(双)' : '');
    if (this.ranges.length === 0) {
      return this.raw.length > 0 ? this.raw + p : '周次未知' + p;
    }
    const parts: string[] = [];
    for (let i = 0; i < this.ranges.length; i++) {
      const r: number[] = this.ranges[i];
      parts.push(r[0].toString() + '-' + r[1].toString());
    }
    return parts.join(',') + '周' + p;
  }
}

/** 一条占用记录（一节课或一次借用） */
export class RoomBooking {
  /** 课程名 / 借用事由 */
  label: string = '';
  /** 教师 / 借用人，可能为空 */
  person: string = '';
  /** 上课班级（借用记录没有） */
  className: string = '';
  /** 是否为「被借用」 */
  borrowed: boolean = false;
  /** 周次说明 */
  spec: WeekSpec = new WeekSpec();

  /** 在第 week 周是否占用 */
  isActive(week: number): boolean {
    // WeekSpec 在「没有周次说明」时也返回 true（保守判占用），这里无需再判空
    return this.spec.isActive(week);
  }
}

/** 一间教室的占用情况 */
export class RoomSlot {
  room: string = '';
  /** 7 项，索引 0=周一 … 6=周日；**全部节次合并**，只回答「这天有没有课」 */
  days: RoomBooking[][] = [];
  /**
   * 7 天 × 5 大节：`bySection[day][section]`。
   *
   * ===== 为什么需要它 =====
   * 结果表里每间教室每天有 5 个格子（对应 5 个大节）。原先把同一间教室
   * 一天里的 5 个格子全并进 days，于是「空闲」只能判成「整天都没课」——
   * 用户选了「第一大节」想找第一节没课的教室，拿到的却是**一整天都没课**
   * 的教室（少得多），而页面上那句摘要还写着「第一大节」。
   * 节次筛选形同虚设，且结果偏少时看起来像「今天教室都很紧张」。
   */
  bySection: RoomBooking[][][] = [];

  constructor() {
    for (let i = 0; i < 7; i++) {
      this.days.push([]);
      const secs: RoomBooking[][] = [];
      for (let k = 0; k < SECTIONS.length; k++) {
        secs.push([]);
      }
      this.bySection.push(secs);
    }
  }

  /**
   * 该教室在第 day 天、第 week 周是否被占用。
   * @param section 大节下标；<0（默认）表示「任意节次有课就算占用」（整天口径）
   */
  isBusy(day: number, week: number, section: number = -1): boolean {
    if (day < 0 || day > 6) {
      return false;
    }
    if (section < 0) {
      // 整天口径：读合并后的列表
      const all: RoomBooking[] = this.days[day];
      for (let i = 0; i < all.length; i++) {
        if (all[i].isActive(week)) {
          return true;
        }
      }
      return false;
    }
    if (section >= this.bySection[day].length) {
      return false;
    }
    const list: RoomBooking[] = this.bySection[day][section];
    for (let i = 0; i < list.length; i++) {
      if (list[i].isActive(week)) {
        return true;
      }
    }
    return false;
  }

  /** 该教室在第 day 天某节次的占用列表（不过滤周次，供详情展示） */
  bookingsOf(day: number, section: number = -1): RoomBooking[] {
    if (day < 0 || day > 6) {
      return [];
    }
    if (section < 0) {
      return this.days[day];
    }
    if (section >= this.bySection[day].length) {
      return [];
    }
    return this.bySection[day][section];
  }
}

/** 一次查询的结果 */
export class ClassroomResult {
  campus: string = '';
  building: string = '';
  semester: string = '';
  /** 节次行（0 起，对应 SECTIONS） */
  sectionRow: number = 0;
  rooms: RoomSlot[] = [];
}

/** 某一间空教室的信息（供列表展示） */
export class FreeRoom {
  room: string = '';
  /** 所属教学楼；解析不出时为 ''，界面归到「其他」而不是自成一栋楼 */
  building: string = '';

  constructor(room: string, building: string) {
    this.room = room;
    this.building = building;
  }
}

/** 一个星期的空闲统计，用于「本周哪天最空」的速览 */
export class DayFreeStat {
  day: number = 0;
  free: number = 0;
  total: number = 0;

  constructor(day: number, free: number, total: number) {
    this.day = day;
    this.free = free;
    this.total = total;
  }
}

export class ClassroomFinder {
  /**
   * 取某周某天**某节次**的空闲教室。
   *
   * @param section 大节下标。**必须指明**：问「哪个教室现在空着」就得说第几节，
   *                否则会把「整天没课」的教室当成「这一节没课」（见 RoomSlot.bySection）。
   */
  static freeRooms(result: ClassroomResult, day: number, week: number,
    section: number): FreeRoom[] {
    const out: FreeRoom[] = [];
    for (let i = 0; i < result.rooms.length; i++) {
      const slot: RoomSlot = result.rooms[i];
      if (!slot.isBusy(day, week, section)) {
        out.push(new FreeRoom(slot.room, ClassroomFinder.buildingOf(slot.room)));
      }
    }
    out.sort((a: FreeRoom, b: FreeRoom) => ClassroomFinder.compareRoom(a.room, b.room));
    return out;
  }

  /** 取某周某天某节次被占用的教室（用于核对与展示） */
  static busyRooms(result: ClassroomResult, day: number, week: number,
    section: number): FreeRoom[] {
    const out: FreeRoom[] = [];
    for (let i = 0; i < result.rooms.length; i++) {
      const slot: RoomSlot = result.rooms[i];
      if (slot.isBusy(day, week, section)) {
        out.push(new FreeRoom(slot.room, ClassroomFinder.buildingOf(slot.room)));
      }
    }
    return out;
  }

  /**
   * 一周 7 天的空闲数统计。
   *
   * 口径必须与教室列表一致：都按当前选中的节次统计。早先这里按「整天没课」算，
   * 于是星期几下面的数字与点进去的列表对不上（数字比列表里的间数小得多）。
   */
  static weekStats(result: ClassroomResult, week: number, section: number): DayFreeStat[] {
    const out: DayFreeStat[] = [];
    const total: number = result.rooms.length;
    for (let d = 0; d < 7; d++) {
      let free: number = 0;
      for (let i = 0; i < result.rooms.length; i++) {
        if (!result.rooms[i].isBusy(d, week, section)) {
          free++;
        }
      }
      out.push(new DayFreeStat(d, free, total));
    }
    return out;
  }

  /**
   * 教室名是否属于某教学楼。
   *
   * 严格比较，**绝不做后缀匹配**：`1` 不能匹配 `11-101`。
   * 早期用 contains 导致选「1 号楼」时把 11 号楼的教室也算进来。
   */
  static belongsTo(room: string, building: string): boolean {
    if (building.length === 0) {
      return true;
    }
    const head: string = ClassroomFinder.buildingOf(room);
    if (head === building) {
      return true;
    }
    // 纯数字时要求完全相等（'1' 与 '11' 必须区分开）
    const a: number = ClassroomFinder.pureInt(head);
    const b: number = ClassroomFinder.pureInt(building);
    if (!isNaN(a) && !isNaN(b)) {
      return a === b;
    }
    return false;
  }

  /** 整段数字才转数值；'11a' 这类返回 NaN（否则 '1' 会与 '11a' 混为一谈） */
  private static pureInt(s: string): number {
    return /^\d+$/.test(s) ? parseInt(s, 10) : NaN;
  }

  /**
   * 从教室名里取「楼」。
   *
   * 各校写法不同，**两种都要认**：
   *   - `1-101`（数字楼号 + 短横分段）→ `1`
   *   - `信息楼211`（楼名 + 房号连写，本校）→ `信息楼`
   *
   * 早先只处理第一种，于是本校的 `信息楼211` 整串被当成楼名 ——
   * 界面上每张卡片都只有一间教室，标题还写成「信息楼211（1）」，
   * 与下面药丸里的教室名重复一遍。
   *
   * 取不到楼名时返回**空串**（而不是整串）：调用方用空串表示
   * 「无教学楼信息」，会归到「其他」一组；返回整串会让每间教室自成一栋楼。
   */
  static buildingOf(room: string): string {
    const i: number = room.indexOf('-');
    if (i > 0) {
      return room.substring(0, i);
    }
    // `信息楼211` / `博文馆407` / `产融B202东`：切在「最后一个汉字/字母之后、数字之前」
    const m: RegExpMatchArray | null = room.match(/^([\u4e00-\u9fa5A-Za-z]+?)[\s\-]?\d/);
    if (m !== null && m.length >= 2) {
      return m[1];
    }
    // 纯汉字（`操场`、`体育馆`）整体当楼名；其余（含数字却匹配不上）返回空
    if (/^[\u4e00-\u9fa5]+$/.test(room)) {
      return room;
    }
    return '';
  }

  /** 教室排序：数字楼号在前升序，非数字在后，再按字典序 */
  static compareRoom(a: string, b: string): number {
    const na: number = ClassroomFinder.pureInt(ClassroomFinder.buildingOf(a));
    const nb: number = ClassroomFinder.pureInt(ClassroomFinder.buildingOf(b));
    if (!isNaN(na) && !isNaN(nb)) {
      if (na !== nb) {
        return na - nb;
      }
    } else if (!isNaN(na)) {
      return -1;
    } else if (!isNaN(nb)) {
      return 1;
    }
    return a < b ? -1 : (a > b ? 1 : 0);
  }

  /** 节次行 → 服务端节次代码区间，如 0 → ["01","02"]，4 → ["09","11"] */
  static sectionCodes(row: number): string[] {
    if (row < 0 || row >= SECTIONS.length) {
      return ['01', '02'];
    }
    if (row === 4) {
      // 第九~十一节：服务端把 09/10/11 合成一组，查询参数用 09/11
      return ['09', '11'];
    }
    const first: number = row * 2 + 1;
    const second: number = row * 2 + 2;
    return [ClassroomFinder.pad2(first), ClassroomFinder.pad2(second)];
  }

  private static pad2(n: number): string {
    return n < 10 ? ('0' + n.toString()) : n.toString();
  }

  /** 星期标签（短），如 "周一" */
  static dayLabel(day: number): string {
    const full: string[] = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return (day >= 0 && day < 7) ? full[day] : '';
  }
}

export class WeekSpecParser {
  /** 匹配 (3-18周) / (5-18双周) / (2单周) / (1-2,4-8,10周) 等写法 */
  private static readonly ONE: RegExp = /\(([0-9][0-9,\-]*)\s*(单|双)?\s*周\)/;
  /** 全局版，用于一个单元格里有多个时间段的课程 */
  private static readonly ALL: RegExp = /\(([0-9][0-9,\-]*)\s*(单|双)?\s*周\)/g;

  /** 从单元格文本里提取第一个周次说明；提取不到返回 null */
  static first(text: string): WeekSpec | null {
    const m: RegExpMatchArray | null = text.match(WeekSpecParser.ONE);
    if (m === null || m.length < 2) {
      return null;
    }
    return WeekSpecParser.build(m[1], m.length >= 3 && m[2] !== undefined ? m[2] : '');
  }

  /** 提取单元格里所有周次说明（一个格子可能有多门课） */
  static all(text: string): WeekSpec[] {
    const out: WeekSpec[] = [];
    const found: string[] | null = text.match(WeekSpecParser.ALL);
    if (found === null) {
      return out;
    }
    for (let i = 0; i < found.length; i++) {
      const spec: WeekSpec | null = WeekSpecParser.first(found[i]);
      if (spec !== null) {
        out.push(spec);
      }
    }
    return out;
  }

  /** 由数字串（可含逗号与短横）与单双周标记构造 WeekSpec */
  static build(digits: string, parityText: string): WeekSpec {
    const spec: WeekSpec = new WeekSpec();
    spec.raw = digits + parityText + '周';
    if (parityText === '单') {
      spec.parity = 1;
    } else if (parityText === '双') {
      spec.parity = 2;
    }
    const segs: string[] = digits.split(',');
    for (let i = 0; i < segs.length; i++) {
      const seg: string = segs[i].trim();
      if (seg.length === 0) {
        continue;
      }
      const dash: number = seg.indexOf('-');
      if (dash > 0) {
        const a: number = parseInt(seg.substring(0, dash), 10);
        const b: number = parseInt(seg.substring(dash + 1), 10);
        if (!isNaN(a) && !isNaN(b)) {
          spec.ranges.push(a <= b ? [a, b] : [b, a]);
        }
      } else {
        const v: number = parseInt(seg, 10);
        if (!isNaN(v)) {
          spec.ranges.push([v, v]);
        }
      }
    }
    return spec;
  }
}
