/*
 * CampusCalendarParser：解析**用户填写的校历公告页**与**教务课表页**
 * （**纯逻辑，无 @kit 依赖**）
 *
 * 为什么和 CampusCalendarService 分开：
 *   抓取与缓存要碰 @kit（NetworkKit / CoreFileKit），无法在 Node 里跑测试；
 *   而解析逻辑恰恰是最容易「学校改版后悄悄失效」的部分，必须能单测。
 *   因此把解析全部放这里（可被 testdata/run-tests.mjs 直接编译运行），
 *   CampusCalendarService 只负责取字节、落盘、读缓存。
 *
 * ===== 本校（山建）的两个页面各给什么 =====
 *   1. **校历公告页**：地址由用户填写（教务处按年份发公告，地址每年都变），
 *      正文挂的是 **PDF 附件链接**，没有可用的作息表 ——
 *      这里只从它取附件地址与发布时间，见 [parseAttachmentUrls] / [updated]；
 *   2. **课表页**（/jsxsd/xskb/xskb_list.do）：节次行的行首格自带时刻，形如
 *        `第一大节&nbsp;<br>(01,02小节)<br>07:50-09:25`
 *      这是校内**唯一**公开的作息来源，见 [parseSectionTimesFromTimetable]。
 */

/** 课表的 5 行（与 Constants.SECTIONS 一致；这里独立一份以免解析层依赖 UI 常量） */
const GRID_ROWS: number = 5;

export class CampusCalendarParser {
  // ==================== 课表页：节次作息 ====================

  /**
   * 从课表页解析节次作息 —— 本校**唯一的**权威来源。
   *
   * 课表的每个节次行首格（`<th>`）写作：
   *   `第一大节&nbsp;<br>(01,02小节)<br>07:50-09:25`
   * 从中取「节次名 + 起止时刻」，返回 `[label, start, end]` 列表。
   *
   * 为什么不从教务处官网取：本校教务处只发校历 PDF，不公开作息表；
   * 而课表页本来就要抓（课表数据也来自它），顺带解析没有额外请求。
   */
  static parseSectionTimesFromTimetable(html: string): string[][] {
    const out: string[][] = [];
    // 节次名与时刻都在行首格（th）里；限长 300 防止把整页当一个格吞掉
    const thRe: RegExp = /<th[^>]*>([\s\S]{0,300}?)<\/th>/gi;
    const timeRe: RegExp = /(\d{1,2}:\d{2})\s*[-—~～]\s*(\d{1,2}:\d{2})/;
    let m: RegExpExecArray | null = thRe.exec(html);
    while (m !== null) {
      const inner: string = m[1];
      // 只有「节次」格才有时刻；「星期几」格没有「节」字
      if (inner.indexOf('节') >= 0) {
        // 先做全角归一化再匹配：教务的富文本编辑器会把 `：`「－」这类
        // 全角字符混进时刻里，漏掉时整行静默变空 ——
        // 表现为「作息表突然少了几行」而没有任何报错
        const tm: RegExpMatchArray | null = CampusCalendarParser.normalizeWidth(inner).match(timeRe);
        if (tm !== null && tm.length >= 3) {
          const text: string = CampusCalendarParser.text(inner);
          // 节次名 = 「(…小节)」之前的那一段；全角括号也认
          let label: string = text;
          const paren: number = text.indexOf('(');
          if (paren > 0) {
            label = text.substring(0, paren);
          } else {
            const p2: number = text.indexOf('（');
            if (p2 > 0) {
              label = text.substring(0, p2);
            }
          }
          label = label.replace(/\s+/g, '');
          if (label.length > 0) {
            out.push([label, CampusCalendarParser.two(tm[1]), CampusCalendarParser.two(tm[2])]);
          }
        }
      }
      m = thRe.exec(html);
    }
    return out;
  }

  /**
   * 把解析出的作息归并成课表的 5 行（`GRID_ROWS`），返回 `[start, end]` 列表。
   *
   *   - 行数恰好等于 5 → 一一对应；
   *   - 多于 5 → 前 4 行一一对应，多出来的并进第 5 行（取首行起点、末行终点）；
   *   - 少于 5 → **不做映射**（返回空数组），宁可继续用本地值，
   *     也不要按错位的时间算提醒。
   */
  static mapToGridRows(sectionTimes: string[][]): string[][] {
    if (sectionTimes.length < GRID_ROWS) {
      return [];
    }
    if (sectionTimes.length === GRID_ROWS) {
      const same: string[][] = [];
      for (let i = 0; i < GRID_ROWS; i++) {
        same.push([sectionTimes[i][1], sectionTimes[i][2]]);
      }
      return same;
    }
    const out: string[][] = [];
    for (let i = 0; i < GRID_ROWS - 1; i++) {
      out.push([sectionTimes[i][1], sectionTimes[i][2]]);
    }
    out.push([
      sectionTimes[GRID_ROWS - 1][1],
      sectionTimes[sectionTimes.length - 1][2]
    ]);
    return out;
  }

  // ==================== 校历公告页：附件与时间 ====================

  /**
   * 取可下载的**校历附件**地址（绝对化、去重、按出现顺序）。
   *
   * ===== 这里必须严格，否则会把站内装饰图当成校历 =====
   * 对着真实页面核过：一篇校历公告里除了附件，还有几十个导航链接和
   * 两三张站点 logo（`/images/logo_left.jpg`、`/__local/…png`）。
   * 早先的实现「凡 .jpg/.png 都要」，结果校历页显示成一堆 logo。
   *
   * 因此只认三类**附件特征**：
   *   1. 学校 CMS 的下载接口 —— `download.jsp?urltype=news.DownloadAttachUrl`
   *      或带 `wbfileid=`（教务处用的就是这个）；
   *   2. `/__local/` 下的附件（书院 CMS 把上传文件放这里，
   *      与 `/images/`、`/__local/…/logo` 这类站点资源不同）；
   *   3. 正文里指向 `.pdf` 的链接（很多学校直接给 PDF 地址）。
   *
   * 刻意**不**把「正文里的 .jpg」算进来：本站的校历是 PDF，
   * 而参考实现那边的图片走的是专用附件路径（`virtual_attach_file`），
   * 那个特征在下面单独识别 —— 放宽到「任意图片」只会误收 logo。
   */
  static parseAttachmentUrls(html: string, pageUrl: string): string[] {
    const out: string[] = [];

    // 附件几乎都以 <a href> 形式给出
    const aRe: RegExp = /<a[^>]*>/gi;
    let m: RegExpExecArray | null = aRe.exec(html);
    while (m !== null) {
      const tag: string = m[0];
      const href: string = CampusCalendarParser.attr(tag, 'href');
      if (href.length > 0 && CampusCalendarParser.isAttachmentUrl(href)) {
        CampusCalendarParser.addUrl(out, href, pageUrl);
      }
      m = aRe.exec(html);
    }

    // 参考实现那边的校历是图片、挂在专用附件路径上（`virtual_attach_file`），
    // 因此还要看 <img>，但**只认那一个特征**，不放宽到任意图片。
    const imgRe: RegExp = /<img[^>]*>/gi;
    m = imgRe.exec(html);
    while (m !== null) {
      const tag: string = m[0];
      // 优先取原图属性（CMS 里拼作 orisrc，少一个 g 的写法也认）
      let pick: string = CampusCalendarParser.attr(tag, 'origsrc');
      if (pick.length === 0) {
        pick = CampusCalendarParser.attr(tag, 'orisrc');
      }
      if (pick.length === 0) {
        pick = CampusCalendarParser.attr(tag, 'src');
      }
      if (pick.length > 0 && pick.indexOf('virtual_attach_file') >= 0) {
        CampusCalendarParser.addUrl(out, pick, pageUrl);
      }
      m = imgRe.exec(html);
    }

    return out;
  }

  /** 取页面上标注的时间：`更新时间：2026年9月` / `发布时间：2025年12月19日`；取不到返回空串 */
  static updated(html: string): string {
    const t: string = CampusCalendarParser.text(html);
    const m: RegExpMatchArray | null =
      t.match(/(?:更新|发布)时间[:：]\s*([0-9]{4}\s*年\s*[0-9]{1,2}\s*月)/);
    if (m !== null && m.length >= 2) {
      return m[1].replace(/\s+/g, '');
    }
    const m2: RegExpMatchArray | null =
      t.match(/([0-9]{4}\s*年\s*[0-9]{1,2}\s*月)\s*[0-9]{1,2}\s*日/);
    if (m2 !== null && m2.length >= 2) {
      return m2[1].replace(/\s+/g, '');
    }
    return '';
  }

  // ---------- HTML 小工具 ----------

  /**
   * 这个链接是「可下载的校历附件」吗？
   *
   * 判据见 [parseAttachmentUrls] 的说明：只认 CMS 下载接口、
   * `/__local/` 附件区、以及正文里的 `.pdf` 链接。
   */
  private static isAttachmentUrl(url: string): boolean {
    const u: string = url.toLowerCase();
    if (u.startsWith('javascript:') || u.startsWith('#')) {
      return false;
    }
    // 1) 学校 CMS 的下载接口（教务处）
    if (u.indexOf('downloadattachurl') >= 0 || u.indexOf('wbfileid=') >= 0) {
      return true;
    }
    if (u.indexOf('download.jsp') >= 0 && u.indexOf('urltype=news') >= 0) {
      return true;
    }
    // 2) 网站附件区（书院 CMS 把上传文件放 /__local/，站点图片在 /images/）
    if (u.indexOf('/__local/') >= 0 && u.indexOf('logo') < 0) {
      return true;
    }
    // 3) 正文里直接指向 PDF
    if (u.endsWith('.pdf')) {
      return true;
    }
    return false;
  }

  /** 绝对化后去重放入 out（`&amp;` 是 HTML 转义，URL 里必须是 `&`） */
  private static addUrl(out: string[], raw: string, pageUrl: string): void {
    const cleaned: string = raw.replace(/&amp;/g, '&').trim();
    if (cleaned.length === 0) {
      return;
    }
    const abs: string = CampusCalendarParser.absoluteUrl(cleaned, pageUrl);
    if (out.indexOf(abs) < 0) {
      out.push(abs);
    }
  }

  /** 去标签 + 解实体 + 压空白 */
  private static text(html: string): string {
    return html
      .replace(/<[^>]*>/g, ' ')
      .replace(/&nbsp;/g, ' ')
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/\s+/g, ' ')
      .trim();
  }

  /**
   * 取属性值（支持 `name="v"` 与 `name='v'`）。
   *
   * 用「前一字符不是标识符字符」保证 `src` **不会**匹配到 `orisrc=` 或
   * `data-src=` 的尾部 —— 学校 CMS 的属性顺序不保证，
   * 朴素的子串匹配会在属性顺序变化时取错值。
   */
  private static attr(tag: string, name: string): string {
    const re: RegExp = new RegExp(
      '(^|[^A-Za-z0-9_-])' + name + '\\s*=\\s*("([^"]*)"|\'([^\']*)\')', 'i');
    const m: RegExpMatchArray | null = tag.match(re);
    if (m === null || m.length < 5) {
      return '';
    }
    const dq: string = m[3];
    const sq: string = m[4];
    if (dq !== undefined && dq !== null) {
      return dq;
    }
    if (sq !== undefined && sq !== null) {
      return sq;
    }
    return '';
  }

  /** `7:50` → `07:50` */
  private static two(t: string): string {
    const i: number = t.indexOf(':');
    if (i <= 0) {
      return t;
    }
    return t.substring(0, i).length === 1 ? '0' + t : t;
  }

  /**
   * 全角 → 半角，并把各种「横线」统一成 `-`（只用于判定，不改变原文本）。
   *
   * 富文本编辑器里全角冒号/连字符/波浪线与全角数字很容易被误输入，
   * 一旦出现就会让整行解析为空 —— 而没有任何报错。
   */
  private static normalizeWidth(raw: string): string {
    let out: string = '';
    for (let i = 0; i < raw.length; i++) {
      const c: number = raw.charCodeAt(i);
      if (c === 0xFF1A) {
        out = out + ':';                                      // 全角冒号
      } else if (c >= 0xFF10 && c <= 0xFF19) {
        out = out + String.fromCharCode(c - 0xFF10 + 0x30);   // 全角数字
      } else if (c === 0x3000) {
        out = out + ' ';                                      // 全角空格
      } else if (c === 0xFF0D || c === 0x2013 || c === 0x2014 || c === 0x2015 ||
        c === 0xFF5E || c === 0x301C || c === 0x2212 || c === 0x7E ||
        c === 0x223C) {
        out = out + '-';                   // 各种横线/波浪线统一成连字符
      } else {
        out = out + raw.charAt(i);
      }
    }
    return out;
  }

  /**
   * 相对地址 → 绝对地址。
   *
   * 附件地址可能是绝对（`https://…`）、站内绝对路径（`/jwc/__local/…`）
   * 或相对当前页的路径（`../__local/…`）。CMS 三种都会出现，
   * 少处理一种的表现是「某些年份的公告取不到附件」——
   * 没有报错，只是那一年填进来的地址一直失败。
   */
  static absoluteUrl(url: string, pageUrl: string): string {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }
    const m: RegExpMatchArray | null = pageUrl.match(/^(https?:\/\/[^\/]+)([^?#]*)/);
    if (m === null || m.length < 2) {
      return url;
    }
    const origin: string = m[1];
    if (url.startsWith('/')) {
      return origin + url;
    }
    // 相对地址：以页面所在**目录**为基准，再逐段消掉 ./ 与 ../
    const path: string = (m.length >= 3 && m[2] !== undefined) ? m[2] : '/';
    const slash: number = path.lastIndexOf('/');
    const baseDir: string = slash >= 0 ? path.substring(0, slash + 1) : '/';
    return origin + CampusCalendarParser.normalizePath(baseDir + url);
  }

  /** 消掉路径里的 `.` 与 `..` 段（不依赖 URL 类，避免各版本行为差异） */
  private static normalizePath(path: string): string {
    const parts: string[] = path.split('/');
    const stack: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const seg: string = parts[i];
      if (seg === '.') {
        continue;
      }
      if (seg === '..') {
        if (stack.length > 0) {
          stack.pop();
        }
        continue;
      }
      stack.push(seg);
    }
    return stack.join('/');
  }
}
