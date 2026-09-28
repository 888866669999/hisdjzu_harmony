/*
 * CampusCalendarService：校历附件与作息表的获取
 *
 * ===== 与移植源（山财）的关键差别：校历地址由用户提供 =====
 * 移植源把「学校官网校历页」写死成一个常量。对本校不可行：
 *   1. 本校**没有稳定的校历页** —— 教务处是按年份发一篇公告
 *      （「山东建筑大学 2026 年校历」），地址里带内容 id
 *      （`info/1024/3232.htm` 这类），每年都不一样；
 *   2. 那个页面挂的是 **PDF 附件**，不是图片，无法直接显示；
 *   3. 硬编码一个「当前年份」的地址，换年就静默失效 ——
 *      而界面上看不出来，属于最危险的那类失败。
 * 因此改成**用户填地址**：设置页给一个输入框，引导用户到
 * 教务处「信息公开 → 校历」列表里找到当年那份，把地址粘进来。
 * 应用只负责抓取、缓存、解析，不假设任何具体网址。
 *
 * ===== 作息表不靠官网 =====
 * 本校教务处不公开作息时刻表，但**教务课表页自己带时刻**
 * （节次行首格写作「第一大节 (01,02小节) 07:50-09:25」）。
 * 因此作息从**课表页**解析，见 [parseSectionTimesFromTimetable]，
 * 由课表页在联网取回课表后顺手同步（见 SchedulePage）。
 *
 * ===== 安全 =====
 * 用户填的地址属**不可信输入**，抓取前必须过 [UrlGuard]（拒绝环回/私有/
 * 保留地址，见其说明），并逐跳校验重定向 —— 否则一个恶意地址能把请求
 * 指向内网。同时**刻意不复用教务系统的 HttpClient**：那个客户端的
 * CookieJar 不带域名作用域、请求头还硬编码了教务 Origin/Referer，
 * 用它访问用户填的任意站点等于把会话 JSESSIONID 发出去。
 */
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { ContextHolder } from '../common/ContextHolder';
import { Logger } from '../common/Logger';
import { UrlGuard } from '../common/UrlGuard';
import {
  KEY_CAMPUS_SECTIONS, KEY_CAMPUS_IMAGES, KEY_CAMPUS_IMAGE_URLS,
  KEY_CAMPUS_UPDATED, KEY_CAMPUS_FETCHED_AT, KEY_CALENDAR_URL, CAMPUS_DIR
} from '../common/Constants';
import { PrefStore } from './PrefStore';
import { CampusCalendarParser } from '../parser/CampusCalendarParser';
import { AcademicCalendar, OFFICIAL_SECTIONS, OfficialSection } from './AcademicCalendar';
import { SectionTimeStore, SectionTime } from './SectionTimeStore';

/**
 * 抓取校历时允许的主机**白名单**（空 = 不限制，仅做 SSRF 校验）。
 *
 * 默认不限制具体域名：用户填的地址可能是学校官网、教务处子站、
 * 甚至校外镜像，写死一个清单会让「换了个地址就抓不到」。
 * 真正的安全边界是 [UrlGuard]（拒绝内网/环回/保留地址）与
 * 「只接受 http/https」这两条，与具体域名无关。
 */
const CAMPUS_ALLOWED_HOSTS: string[] = [];

/** 重定向上限：防止「A→B→A」循环把请求打成死循环 */
const MAX_REDIRECTS: number = 5;

/** 抓取所用的 UA（不带任何 Cookie） */
const USER_AGENT: string =
  'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

/** 一次抓取的超时（ms）；附件比页面大，读取给得更宽 */
const CONNECT_TIMEOUT: number = 15000;
const READ_TIMEOUT: number = 30000;

/** 抓取结果 */
export class CampusCalendar {
  /** 作息行（`第一大节  07:50 - 09:25`） */
  sections: string[] = [];
  /**
   * 校历附件的**本地绝对路径**（下载成功才有）。
   * 本校是 PDF，参考实现那边是图片 —— 两种都存下来，
   * 图片直接显示，PDF 交给外部应用打开。
   */
  images: string[] = [];
  /** 页面上标注的更新时间，如 `2026年9月` */
  updated: string = '';
  /** true = 本次联网抓到的；false = 缓存或内置兜底 */
  live: boolean = false;

  /** 是否有可展示的校历附件 */
  hasAttachments(): boolean {
    return this.images.length > 0;
  }
}

/** 逐跳跟随重定向后的一次 GET 结果 */
class GetOutcome {
  ok: boolean = false;
  /** HTTP 状态码；0 表示本地就失败了（被 UrlGuard 拒绝 / 重定向异常） */
  status: number = 0;
  /** 服务端应答 304：本地文件即最新 */
  notModified: boolean = false;
  bytes: ArrayBuffer | null = null;
  /** 失败说明（空 = 成功） */
  error: string = '';
}

export class CampusCalendarService {
  private static mem: CampusCalendar | null = null;
  /** 上次刷新的错误（供设置页展示，空表示没问题） */
  private static lastError: string = '';

  static errorText(): string {
    return CampusCalendarService.lastError;
  }

  private static fail(message: string): null {
    CampusCalendarService.lastError = message;
    return null;
  }

  // ==================== 缓存路径 ====================

  private static baseDir(): string {
    const ctx = ContextHolder.get();
    if (ctx === null) {
      return '';
    }
    return ctx.filesDir + '/' + CAMPUS_DIR;
  }

  private static ensureDir(): string {
    const dir: string = CampusCalendarService.baseDir();
    if (dir.length === 0) {
      return '';
    }
    try {
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
    } catch (e) {
      Logger.warn('campus dir create failed');
      return '';
    }
    return dir;
  }

  // ==================== 读取（不联网）====================

  /** 从缓存 / 内置构造数据 */
  private static async offline(): Promise<CampusCalendar> {
    const out: CampusCalendar = new CampusCalendar();
    const cachedSections: string[] = CampusCalendarService.split(
      await PrefStore.getText(KEY_CAMPUS_SECTIONS));
    out.sections = cachedSections.length > 0
      ? cachedSections : AcademicCalendar.sectionLines();
    out.images = CampusCalendarService.existingFiles(
      CampusCalendarService.split(await PrefStore.getText(KEY_CAMPUS_IMAGES)));
    out.updated = await PrefStore.getText(KEY_CAMPUS_UPDATED);
    out.live = false;
    return out;
  }

  /** 当前可用的校历（内存 → 缓存 → 内置） */
  static async load(): Promise<CampusCalendar> {
    if (CampusCalendarService.mem !== null) {
      return CampusCalendarService.mem;
    }
    CampusCalendarService.mem = await CampusCalendarService.offline();
    return CampusCalendarService.mem;
  }

  /** 缓存是否过期（从未抓过也算过期），默认 7 天 */
  static async isStale(maxAgeMs: number = 7 * 24 * 3600 * 1000): Promise<boolean> {
    const at: number = await CampusCalendarService.lastFetchedAt();
    if (at <= 0) {
      return true;
    }
    return Date.now() - at > maxAgeMs;
  }

  // ==================== 用户配置的地址 ====================

  /** 用户配置的校历页地址（空串 = 还没填） */
  static async pageUrl(): Promise<string> {
    return await PrefStore.getText(KEY_CALENDAR_URL);
  }

  /**
   * 保存用户填的地址。
   *
   * 只做**格式**校验（http/https + 有主机），不做域名白名单 ——
   * 学校换域名、或用别的子站都不该让这里失效；真正的安全边界在
   * 抓取时（UrlGuard + 逐跳校验）。留空表示「不使用校历附件」，
   * 是合法输入（作息仍从课表页获取），返回 true。
   */
  static async setPageUrl(url: string): Promise<boolean> {
    const u: string = url.trim();
    if (u.length === 0) {
      await PrefStore.putText(KEY_CALENDAR_URL, '');
      return true;
    }
    const scheme: string = UrlGuard.schemeOf(u);
    if (scheme !== 'http' && scheme !== 'https') {
      return false;
    }
    if (UrlGuard.hostOf(u).length === 0) {
      return false;
    }
    await PrefStore.putText(KEY_CALENDAR_URL, u);
    return true;
  }

  // ==================== 抓取 ====================

  /**
   * 联网抓用户配置的校历页；成功则落盘并返回，失败返回 null（保留原缓存）。
   *
   * **从不抛异常**：校历抓不到不该影响任何主流程。
   */
  static async refresh(): Promise<CampusCalendar | null> {
    CampusCalendarService.lastError = '';
    const url: string = await CampusCalendarService.pageUrl();
    if (url.length === 0) {
      return CampusCalendarService.fail('尚未设置校历地址');
    }
    try {
      const since: number = await CampusCalendarService.lastFetchedAt();
      const page: GetOutcome = await CampusCalendarService.followGet(
        url, 'text/html,application/xhtml+xml', 0);
      if (!page.ok || page.bytes === null) {
        return CampusCalendarService.fail('获取校历页失败：' + page.error);
      }
      const html: string = CampusCalendarService.decodeUtf8(page.bytes);

      // 附件地址：图片与 PDF 都要 —— 本校校历是 PDF，
      // 而参考实现那边是图片，两种都得支持
      const urls: string[] = CampusCalendarService.parseAttachmentUrls(html, url);
      const updated: string = CampusCalendarParser.updated(html);

      const local: string[] = [];
      const limit: number = urls.length < 4 ? urls.length : 4;
      for (let i = 0; i < limit; i++) {
        const name: string = CampusCalendarService.fileNameFor(urls[i], i);
        const p: string = await CampusCalendarService.downloadIfChanged(urls[i], name, i, since);
        if (p.length > 0) {
          local.push(p);
        }
      }

      // 解析不到任何东西就不要覆盖已有缓存（学校改版时宁可继续用旧的）
      if (local.length === 0) {
        return CampusCalendarService.fail('未能从该页面解析出校历附件');
      }

      const out: CampusCalendar = new CampusCalendar();
      out.sections = (await CampusCalendarService.offline()).sections;
      out.images = local;
      out.updated = updated;
      out.live = true;

      await CampusCalendarService.savePrefs(out, urls);
      CampusCalendarService.mem = out;
      Logger.info('campus calendar refreshed, attachments=' + out.images.length.toString());
      return out;
    } catch (e) {
      CampusCalendarService.lastError = '网络异常';
      Logger.warn('campus calendar refresh failed: ' + JSON.stringify(e));
      return null;
    }
  }

  /**
   * 根据附件地址推断本地文件名（保留扩展名，图片/PDF 通用）。
   *
   * 带扩展名而不是一律 `.jpg`：PDF 要交给外部应用打开，
   * 系统按扩展名/类型挑选应用，名字错了会「打不开」。
   */
  private static fileNameFor(url: string, index: number): string {
    const cut: number = url.indexOf('?');
    const path: string = (cut >= 0 ? url.substring(0, cut) : url).toLowerCase();
    const exts: string[] = ['.jpg', '.jpeg', '.png', '.gif', '.pdf'];
    let ext: string = '.bin';
    for (let i = 0; i < exts.length; i++) {
      if (path.endsWith(exts[i])) {
        ext = exts[i];
        break;
      }
    }
    return 'calendar_' + (index + 1).toString() + ext;
  }

  /**
   * 下载一个附件；**地址与上次相同且本地文件还在时直接跳过**。
   *
   * 判据用 URL 而不是文件时间/大小：URL 变了才意味着学校换了附件，
   * 这是「内容变了」的直接证据，比任何启发式都可靠。
   */
  private static async downloadIfChanged(url: string, name: string, index: number,
    sinceMs: number): Promise<string> {
    try {
      const path: string = CampusCalendarService.filePath(name);
      if (path.length === 0) {
        return '';
      }
      const prev: string[] = CampusCalendarService.split(
        await PrefStore.getText(KEY_CAMPUS_IMAGE_URLS));
      const sameUrl: boolean = index < prev.length && prev[index] === url;
      if (sameUrl && CampusCalendarService.sizeOf(path) > 512) {
        return path;
      }
      return await CampusCalendarService.download(url, path, sinceMs);
    } catch (e) {
      return '';
    }
  }

  /**
   * 下载一个附件到缓存目录。
   *
   * 地址来自**页面解析结果**，属不可信输入，因此走 [followGet]：
   * 逐跳过 UrlGuard。只带 `Accept`，不带任何 Cookie。
   */
  private static async download(url: string, path: string, sinceMs: number): Promise<string> {
    try {
      const got: GetOutcome = await CampusCalendarService.followGet(url, '*/*', sinceMs);
      const existed: string = CampusCalendarService.exists(path) ? path : '';
      if (!got.ok) {
        return existed;
      }
      if (got.notModified) {
        // 服务端应答 304（未修改）：本地文件就是最新的
        return existed;
      }
      const buf: ArrayBuffer | null = got.bytes;
      if (buf === null || buf.byteLength < 512) {
        return existed;
      }
      // 内容校验：抓回来的可能是 HTML 错误页，别把错误页当附件存下来。
      // 允许两类：图片（JPEG/PNG/GIF）与 PDF。
      if (!CampusCalendarService.looksLikeAttachment(buf)) {
        return existed;
      }
      const file = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, buf);
      } finally {
        fileIo.closeSync(file);
      }
      return path;
    } catch (e) {
      Logger.warn('campus attachment download failed: ' + JSON.stringify(e));
      return CampusCalendarService.exists(path) ? path : '';
    }
  }

  /** 是否是受支持的附件（图片或 PDF）—— 只看魔数，不看扩展名 */
  private static looksLikeAttachment(buf: ArrayBuffer): boolean {
    if (buf.byteLength < 4) {
      return false;
    }
    const b: Uint8Array = new Uint8Array(buf.slice(0, 4));
    // JPEG
    if (b[0] === 0xFF && b[1] === 0xD8) {
      return true;
    }
    // PNG
    if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4E && b[3] === 0x47) {
      return true;
    }
    // GIF
    if (b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46) {
      return true;
    }
    // PDF: "%PDF"
    if (b[0] === 0x25 && b[1] === 0x50 && b[2] === 0x44 && b[3] === 0x46) {
      return true;
    }
    return false;
  }

  /**
   * GET 一个地址，**逐跳**校验重定向目标后返回正文。
   *
   * 为什么自己跟重定向（`maxRedirects: 0`）而不是交给系统：系统跟随
   * 重定向时中间那跳的 `Location` 拿不到，也就无从校验 ——
   * 合法主机可以 302 到 `http://192.168.x.x`，请求就打到内网去了。
   * 因此每一跳都先过 [UrlGuard]，并限制总跳数。
   */
  private static async followGet(url: string, accept: string, sinceMs: number): Promise<GetOutcome> {
    const out: GetOutcome = new GetOutcome();
    let current: string = url;
    for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
      try {
        UrlGuard.check(current, CAMPUS_ALLOWED_HOSTS);
      } catch (e) {
        out.error = '地址不允许：' + CampusCalendarService.errText(e);
        return out;
      }
      const req: http.HttpRequest = http.createHttp();
      try {
        const headers: Record<string, string> = {
          // 只带最小必要头；实测校网站点对 UA 不挑剔，给个常规值更稳妥
          'User-Agent': USER_AGENT,
          'Accept': accept,
          'Accept-Language': 'zh-CN,zh;q=0.9'
          // 刻意不带 Cookie / Origin / Referer
        };
        if (sinceMs > 0) {
          headers['If-Modified-Since'] = CampusCalendarService.httpDate(sinceMs);
        }
        const options: http.HttpRequestOptions = {
          method: http.RequestMethod.GET,
          header: headers,
          connectTimeout: CONNECT_TIMEOUT,
          readTimeout: READ_TIMEOUT,
          usingCache: false,
          // 一律按字节取：正文用 UTF-8 容错解码（见 decodeUtf8），
          // 附件本来就是二进制，按 STRING 取会损坏 PDF/JPEG
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          maxRedirects: 0
        };
        const res: http.HttpResponse = await req.request(current, options);
        const code: number = res.responseCode;
        if (code >= 300 && code < 400) {
          const loc: string = CampusCalendarService.headerOf(res, 'location');
          if (loc.length === 0) {
            out.error = '重定向缺少 Location';
            return out;
          }
          current = CampusCalendarParser.absoluteUrl(loc, current);
          continue;
        }
        out.status = code;
        if (code === 304) {
          out.ok = true;
          out.notModified = true;
          return out;
        }
        if (code !== 200) {
          out.error = 'HTTP ' + code.toString();
          return out;
        }
        if (res.result instanceof ArrayBuffer) {
          out.ok = true;
          out.bytes = res.result as ArrayBuffer;
          return out;
        }
        out.error = '响应不是二进制数据';
        return out;
      } catch (e) {
        out.error = '网络异常';
        return out;
      } finally {
        req.destroy();
      }
    }
    out.error = '重定向次数过多';
    return out;
  }

  /**
   * 解码响应体。
   *
   * 只做 UTF-8（容错模式）。**不引入 GBK 解码**：那需要额外的字符集表，
   * 而这里真正要拿的是**附件地址**（纯 ASCII），即使正文乱码也不影响；
   * 唯一的代价是「更新时间」这类展示文本可能显示成乱码 ——
   * 为它引入一个依赖包不划算。乱码时用户仍能正常打开附件。
   */
  private static decodeUtf8(buf: ArrayBuffer): string {
    try {
      const dec: util.TextDecoder = util.TextDecoder.create('utf-8');
      return dec.decodeToString(new Uint8Array(buf));
    } catch (e) {
      Logger.warn('campus page decode failed');
      return '';
    }
  }

  /** 读响应头（不区分大小写）。ArkTS 不允许动态属性访问，因此走 JSON 序列化。 */
  private static headerOf(res: http.HttpResponse, name: string): string {
    try {
      const json: string = JSON.stringify(res.header);
      if (json === undefined || json === null || json.length < 3) {
        return '';
      }
      const lower: string = json.toLowerCase();
      const at: number = lower.indexOf('"' + name.toLowerCase() + '":"');
      if (at < 0) {
        return '';
      }
      const from: number = at + name.length + 4;
      const rest: string = json.substring(from);
      const end: number = rest.indexOf('"');
      return end >= 0 ? rest.substring(0, end) : '';
    } catch (e) {
      return '';
    }
  }

  /** RFC 1123 时间（If-Modified-Since 用），如 `Mon, 14 Sep 2026 07:00:00 GMT` */
  private static httpDate(ms: number): string {
    const days: string[] = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
    const months: string[] = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    const d: Date = new Date(ms);
    const two = (n: number): string => n < 10 ? '0' + n.toString() : n.toString();
    return days[d.getUTCDay()] + ', ' + two(d.getUTCDate()) + ' ' + months[d.getUTCMonth()] +
      ' ' + d.getUTCFullYear().toString() + ' ' + two(d.getUTCHours()) + ':' +
      two(d.getUTCMinutes()) + ':' + two(d.getUTCSeconds()) + ' GMT';
  }

  /** 上次成功抓取的时刻（毫秒）；从未抓过返回 0 */
  private static async lastFetchedAt(): Promise<number> {
    const raw: string = await PrefStore.getText(KEY_CAMPUS_FETCHED_AT);
    const at: number = parseInt(raw, 10);
    return isNaN(at) ? 0 : at;
  }

  private static async savePrefs(c: CampusCalendar, urls: string[]): Promise<void> {
    await PrefStore.putText(KEY_CAMPUS_SECTIONS, c.sections.join('\n'));
    await PrefStore.putText(KEY_CAMPUS_IMAGES, c.images.join('\n'));
    await PrefStore.putText(KEY_CAMPUS_IMAGE_URLS, urls.join('\n'));
    await PrefStore.putText(KEY_CAMPUS_UPDATED, c.updated);
    await PrefStore.putText(KEY_CAMPUS_FETCHED_AT, Date.now().toString());
  }

  /** 清掉缓存（设置页用）。**不动用户填的地址** —— 那是配置，不是缓存。 */
  static async clearCache(): Promise<void> {
    CampusCalendarService.removeFiles();
    CampusCalendarService.mem = null;
    await PrefStore.putText(KEY_CAMPUS_SECTIONS, '');
    await PrefStore.putText(KEY_CAMPUS_IMAGES, '');
    await PrefStore.putText(KEY_CAMPUS_IMAGE_URLS, '');
    await PrefStore.putText(KEY_CAMPUS_UPDATED, '');
  }

  /**
   * 只清**校历附件**，保留作息（设置页把地址清空时调用）。
   *
   * 为什么清空地址必须连附件一起删：否则界面上会继续显示上一个地址
   * 抓来的校历 —— 用户刚亲手删掉了来源，应用却还在展示那份数据，
   * 而那份数据是「哪一年的、还准不准」都无从判断。作息不受影响，
   * 它来自课表页、与本地址无关。
   */
  static async clearAttachments(): Promise<void> {
    CampusCalendarService.removeFiles();
    CampusCalendarService.mem = null;
    await PrefStore.putText(KEY_CAMPUS_IMAGES, '');
    await PrefStore.putText(KEY_CAMPUS_IMAGE_URLS, '');
    await PrefStore.putText(KEY_CAMPUS_UPDATED, '');
  }

  /** 删掉缓存目录里的全部文件（目录本身留着，下次抓取直接写） */
  private static removeFiles(): void {
    const dir: string = CampusCalendarService.baseDir();
    if (dir.length === 0) {
      return;
    }
    try {
      if (!fileIo.accessSync(dir)) {
        return;
      }
      // rmdirSync 对非空目录会抛 13900032（Directory not empty），
      // 因此先逐个删文件再删目录 —— 否则「清除缓存」在有缓存时永远失败，
      // 而失败被吞掉，用户看到的是「点了没反应」。
      const names: string[] = fileIo.listFileSync(dir);
      for (let i = 0; i < names.length; i++) {
        fileIo.unlinkSync(dir + '/' + names[i]);
      }
      fileIo.rmdirSync(dir);
    } catch (e) {
      Logger.warn('campus cache clear failed');
    }
  }

  /**
   * 设置页「校历与作息表」的副标题：只说「能不能看」，不暴露数据来源与缓存细节。
   *
   * 刻意**不**显示「已获取最新版 / 显示上次缓存的版本 / 更新于 x」——
   * 那些是内部策略，用户看到只会多出「数据是不是过期了」的疑问。
   * 唯一值得外显的是「学校官网更新到哪一版」这个**官方信息**。
   */
  static async hint(c: CampusCalendar): Promise<string> {
    if ((await CampusCalendarService.pageUrl()).length === 0) {
      return '选择要显示的校历';
    }
    if (c.updated.length === 0) {
      return '查看已获取的校历';
    }
    return '官网 ' + c.updated + ' 版';
  }

  // ==================== 小工具 ====================

  private static filePath(name: string): string {
    const dir: string = CampusCalendarService.ensureDir();
    if (dir.length === 0) {
      return '';
    }
    return dir + '/' + name;
  }

  private static split(raw: string): string[] {
    const out: string[] = [];
    if (raw.trim().length === 0) {
      return out;
    }
    const parts: string[] = raw.split('\n');
    for (let i = 0; i < parts.length; i++) {
      const t: string = parts[i].trim();
      if (t.length > 0) {
        out.push(t);
      }
    }
    return out;
  }

  private static exists(p: string): boolean {
    try {
      return fileIo.accessSync(p);
    } catch (e) {
      return false;
    }
  }

  private static sizeOf(p: string): number {
    try {
      const st: fileIo.Stat = fileIo.statSync(p);
      return st.size;
    } catch (e) {
      return 0;
    }
  }

  /** 只保留磁盘上确实存在的附件路径 */
  private static existingFiles(paths: string[]): string[] {
    const out: string[] = [];
    for (let i = 0; i < paths.length; i++) {
      if (CampusCalendarService.exists(paths[i])) {
        out.push(paths[i]);
      }
    }
    return out;
  }

  private static errText(e: Object): string {
    const err: Error = e as Error;
    return (err !== undefined && err.message !== undefined && err.message.length > 0)
      ? err.message : '校验未通过';
  }

  // ==================== 纯解析逻辑（转发到 parser，便于与 Flutter 端同名对照）====================

  /**
   * 从课表页解析节次作息 —— 本校**唯一的**权威来源。
   *
   * 实现在 [CampusCalendarParser.parseSectionTimesFromTimetable]：
   * 那里不依赖任何 @kit，可被 testdata/run-tests.mjs 直接编译运行。
   */
  static parseSectionTimesFromTimetable(html: string): string[][] {
    return CampusCalendarParser.parseSectionTimesFromTimetable(html);
  }

  /**
   * 从 HTML 里取可下载的**校历附件**地址。
   *
   * 实现在 [CampusCalendarParser.parseAttachmentUrls]（严格判据的理由见那里）。
   */
  static parseAttachmentUrls(html: string, pageUrl: string): string[] {
    return CampusCalendarParser.parseAttachmentUrls(html, pageUrl);
  }

  /**
   * 若用户**没有自定义过**作息，就用从课表页解析到的时刻刷新本地作息。
   *
   * 只在 `SectionTimeStore.isDefault()` 为真时写入 —— 用户手动调过的时间
   * 是用户意图，不能被一次联网静默覆盖。用 `saveOfficial` 而不是用户保存：
   * 这是**教务课表页**的值，不能置位「已自定义」标记 ——
   * 否则同步一次就再也不跟随了。返回是否发生了更新。
   */
  static async applyOfficialSectionsIfDefault(sections: string[][]): Promise<boolean> {
    const rows: string[][] = CampusCalendarParser.mapToGridRows(sections);
    if (rows.length !== 5) {
      return false;
    }
    await SectionTimeStore.load();
    if (!SectionTimeStore.isDefault()) {
      return false;
    }
    let changed: boolean = false;
    for (let i = 0; i < 5; i++) {
      if (OFFICIAL_SECTIONS[i].start !== rows[i][0] || OFFICIAL_SECTIONS[i].end !== rows[i][1]) {
        changed = true;
        break;
      }
    }
    if (!changed) {
      return false;
    }
    const official: OfficialSection[] = OFFICIAL_SECTIONS;
    const list: SectionTime[] = [];
    for (let i = 0; i < 5; i++) {
      list.push(new SectionTime(i, official[i].label, rows[i][0], rows[i][1]));
    }
    await SectionTimeStore.saveOfficial(list);
    Logger.info('sections updated from timetable page');
    return true;
  }

  /** 作息是否为用户自定义（设置页据此显示「恢复官方作息」入口） */
  static sectionTimesCustomized(): boolean {
    return !SectionTimeStore.isDefault();
  }
}
