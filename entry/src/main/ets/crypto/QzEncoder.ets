/*
 * 强智教务登录编码：encoded = Base64(账号) + '%%%' + Base64(密码)
 *
 * ===== 与参考实现（山财，本项目的移植源）截然不同 =====
 * 山财那套是「先握手拿 scode#sxh，再按位插字符」的算法，山建**完全不适用**：
 *   1. 山建**不需要会话握手** —— 没有 /Logon.do?flag=sess 这一步；
 *   2. 密码不提交明文，而是提交 Base64 后的 encoded（字段名 encoded）。
 *
 * 因此这里不能再沿用移植源那份 QzEncoder。实测校方登录页的 JS：
 *     var code = encodeInp(userAccount) + '%%%' + encodeInp(userPassword);
 * 而 encodeInp 就是标准 Base64（在浏览器控制台验证过：
 * encodeInp('12345678') === 'MTIzNDU2Nzg=' === btoa('12345678')）。
 *
 * 移植时曾直接照搬山财的按位插字符算法，结果登录永远失败，
 * 且报错是服务端那句通用的「用户名或密码错误」—— 看不出是编码方式错了。
 */
export class QzEncoder {
  /** Base64 字母表（与 btoa 一致） */
  private static readonly B64: string =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  /**
   * 把字符串编码成 Base64（按 UTF-8 取字节）。
   *
   * 账号密码都是 ASCII，但这里仍按完整 UTF-8 处理：万一学校将来允许
   * 非 ASCII 密码，不至于静默编出错误的串。
   */
  static base64(input: string): string {
    if (input.length === 0) {
      return '';
    }
    const bytes: number[] = [];
    for (let i = 0; i < input.length; i++) {
      const c: number = input.charCodeAt(i);
      if (c < 0x80) {
        bytes.push(c);
      } else if (c < 0x800) {
        bytes.push(0xc0 | (c >> 6));
        bytes.push(0x80 | (c & 0x3f));
      } else if (c >= 0xd800 && c <= 0xdbff) {
        // 代理对：合并成一个码点再编成 4 字节
        const c2: number = i + 1 < input.length ? input.charCodeAt(i + 1) : 0;
        const cp: number = 0x10000 + ((c - 0xd800) << 10) + (c2 - 0xdc00);
        bytes.push(0xf0 | (cp >> 18));
        bytes.push(0x80 | ((cp >> 12) & 0x3f));
        bytes.push(0x80 | ((cp >> 6) & 0x3f));
        bytes.push(0x80 | (cp & 0x3f));
        i++;
      } else {
        bytes.push(0xe0 | (c >> 12));
        bytes.push(0x80 | ((c >> 6) & 0x3f));
        bytes.push(0x80 | (c & 0x3f));
      }
    }

    let out: string = '';
    for (let i = 0; i < bytes.length; i += 3) {
      const b0: number = bytes[i];
      const b1: number = i + 1 < bytes.length ? bytes[i + 1] : 0;
      const b2: number = i + 2 < bytes.length ? bytes[i + 2] : 0;
      const n: number = (b0 << 16) | (b1 << 8) | b2;
      const rem: number = bytes.length - i;
      out += QzEncoder.B64.charAt((n >> 18) & 63);
      out += QzEncoder.B64.charAt((n >> 12) & 63);
      out += rem > 1 ? QzEncoder.B64.charAt((n >> 6) & 63) : '=';
      out += rem > 2 ? QzEncoder.B64.charAt(n & 63) : '=';
    }
    return out;
  }

  /**
   * 构造登录表单的 `encoded` 字段。
   *
   * 服务端把它按 `%%%` 切开再各自 Base64 解码，因此分隔符是原文的 `%%%`，
   * 不参与编码。
   */
  static buildEncoded(account: string, password: string): string {
    if (account.length === 0 || password.length === 0) {
      return '';
    }
    return QzEncoder.base64(account) + '%%%' + QzEncoder.base64(password);
  }
}
