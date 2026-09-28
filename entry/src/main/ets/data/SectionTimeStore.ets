/*
 * SectionTimeStore：节次作息时间配置
 *
 * 为什么必须可配置：
 *   教务系统的课表页面**只给出节次名称**（如「第一、二节」），
 *   并不提供每节课的具体起止时刻。而上课提醒必须知道精确时间，
 *   所以作息时间要由用户按学校实际安排设置，默认值只作参考。
 *
 * 存储：preferences 中的一个字符串，格式为
 *   "08:00-09:40;10:00-11:40;..."（按节次顺序）
 */
import { PrefStore } from './PrefStore';
import { Logger } from '../common/Logger';
import { SECTIONS, SectionDef, KEY_SECTION_TIMES, KEY_SECTION_TIMES_CUSTOM } from '../common/Constants';

/** 一个节次的作息 */
export class SectionTime {
  index: number = 0;
  label: string = '';
  start: string = '08:00';
  end: string = '09:40';

  constructor(index: number, label: string, start: string, end: string) {
    this.index = index;
    this.label = label;
    this.start = start;
    this.end = end;
  }

  /** 起始时间的分钟数（0:00 起算），解析失败返回 -1 */
  startMinutes(): number {
    return SectionTimeStore.toMinutes(this.start);
  }
}

export class SectionTimeStore {
  private static times: SectionTime[] = [];
  private static loaded: boolean = false;
  /**
   * 用户是否**手动改过**作息（来源标记，存 preferences）。
   *
   * 与 times 分开：自动同步（课表页解析）也会写入 times，
   * 那不代表用户自定义。判据的完整理由见 Constants.KEY_SECTION_TIMES_CUSTOM。
   */
  private static custom: boolean = false;

  /** 载入配置（幂等）；未配置过则使用内置默认值 */
  static async load(): Promise<void> {
    if (SectionTimeStore.loaded) {
      return;
    }
    const raw: string = await PrefStore.getText(KEY_SECTION_TIMES);
    SectionTimeStore.times = SectionTimeStore.migrate(raw);
    SectionTimeStore.custom = (await PrefStore.getText(KEY_SECTION_TIMES_CUSTOM)) === '1';
    SectionTimeStore.loaded = true;
    Logger.info('section times loaded: ' + SectionTimeStore.times.length);
  }

  /**
   * 迁移历史数据。
   *
   * 早期版本内置的是「08:00 起」这套参考时间，与学校官方作息表不符；
   * 若用户在设置页点过「保存」，就会把这套错值落盘。
   * 这里识别出「落盘值恰好等于旧默认值」的情况并丢弃它，
   * 让它回落到新的官方值 —— 真正的用户自定义值不受影响。
   */
  private static migrate(raw: string): SectionTime[] {
    const decoded: SectionTime[] = SectionTimeStore.decode(raw);
    if (decoded.length === 0) {
      return decoded;
    }
    if (SectionTimeStore.equalsLegacyDefault(decoded)) {
      Logger.info('discard legacy default section times, use official values');
      return [];
    }
    return decoded;
  }

  /** 是否为旧版本的「非官方」默认值（08:00 / 10:00 / 14:00 / 16:00 / 19:00） */
  private static equalsLegacyDefault(list: SectionTime[]): boolean {
    const legacy: string[] = ['08:00', '10:00', '14:00', '16:00', '19:00'];
    if (list.length !== legacy.length) {
      return false;
    }
    for (let i = 0; i < legacy.length; i++) {
      if (list[i].start !== legacy[i]) {
        return false;
      }
    }
    return true;
  }

  /** 当前作息表（未 load 时返回默认值） */
  static all(): SectionTime[] {
    if (SectionTimeStore.times.length === 0) {
      return SectionTimeStore.defaults();
    }
    return SectionTimeStore.times;
  }

  /** 取某个节次的作息 */
  static at(index: number): SectionTime | null {
    const list: SectionTime[] = SectionTimeStore.all();
    if (index < 0 || index >= list.length) {
      return null;
    }
    return list[index];
  }

  /**
   * 是否仍为**官方**作息（即用户没手动改过）。
   *
   * 判据必须是**来源标记**而不是「有没有存值」或「值等于内置常量」：
   * 自动同步（见 CampusCalendarService.applyOfficialSectionsIfDefault）
   * 也会把值写进存储 —— 若拿它与常量逐项比对，同步过一次后就再也不相等，
   * 用户从没改过却被判成「已自定义」，此后课表页的新时刻**永远同步不进来**，
   * 而设置页还会显示「已自定义」。因此只认显式置位的 custom 标记。
   */
  static isDefault(): boolean {
    return !SectionTimeStore.custom;
  }

  /** 保存**用户手动编辑**的作息（置位自定义标记，此后不再被课表页同步覆盖） */
  static async save(list: SectionTime[]): Promise<void> {
    SectionTimeStore.times = list;
    SectionTimeStore.loaded = true;
    SectionTimeStore.custom = true;
    await PrefStore.putText(KEY_SECTION_TIMES, SectionTimeStore.encode(list));
    await PrefStore.putText(KEY_SECTION_TIMES_CUSTOM, '1');
  }

  /**
   * 保存**课表页同步来的**作息：只写值、**不置位**自定义标记。
   *
   * 与 [save] 的唯一区别就在这里：这是学校给的值，
   * 以后学校改了还要能再同步进来。
   */
  static async saveOfficial(list: SectionTime[]): Promise<void> {
    SectionTimeStore.times = list;
    SectionTimeStore.loaded = true;
    await PrefStore.putText(KEY_SECTION_TIMES, SectionTimeStore.encode(list));
  }

  /**
   * 恢复默认。
   *
   * 这是用户主动选择的行为，因此要**清掉**自定义标记，
   * 让后续课表页的同步重新生效（否则恢复完还停在「已自定义」，
   * 学校改作息再也进不来 —— 与按一下「恢复」的预期完全相反）。
   */
  static async resetToDefault(): Promise<void> {
    SectionTimeStore.times = [];
    SectionTimeStore.loaded = true;
    SectionTimeStore.custom = false;
    await PrefStore.putText(KEY_SECTION_TIMES, '');
    await PrefStore.putText(KEY_SECTION_TIMES_CUSTOM, '0');
  }

  /** 内置默认值：取自 Constants.SECTIONS 的参考时间 */
  private static defaults(): SectionTime[] {
    const out: SectionTime[] = [];
    for (let i = 0; i < SECTIONS.length; i++) {
      const s: SectionDef = SECTIONS[i];
      out.push(new SectionTime(s.index, s.label, s.start, s.end));
    }
    return out;
  }

  private static encode(list: SectionTime[]): string {
    const parts: string[] = [];
    for (let i = 0; i < list.length; i++) {
      parts.push(list[i].start + '-' + list[i].end);
    }
    return parts.join(';');
  }

  private static decode(raw: string): SectionTime[] {
    if (raw.length === 0) {
      return [];
    }
    const segs: string[] = raw.split(';');
    const out: SectionTime[] = [];
    for (let i = 0; i < segs.length; i++) {
      const pair: string[] = segs[i].split('-');
      if (pair.length !== 2) {
        continue;
      }
      const label: string = i < SECTIONS.length ? SECTIONS[i].label : ('第' + (i + 1).toString() + '节');
      out.push(new SectionTime(i, label, pair[0], pair[1]));
    }
    return out;
  }

  /** "HH:mm" -> 分钟数；非法返回 -1 */
  static toMinutes(hhmm: string): number {
    const parts: string[] = hhmm.split(':');
    if (parts.length !== 2) {
      return -1;
    }
    const h: number = parseInt(parts[0], 10);
    const m: number = parseInt(parts[1], 10);
    if (isNaN(h) || isNaN(m) || h < 0 || h > 23 || m < 0 || m > 59) {
      return -1;
    }
    return h * 60 + m;
  }
}
