/*
 * ProfileService：个人信息的唯一加载入口 + 姓名/学号的就绪保障
 *
 * ===== 为什么要有这个模块（真机 bug）=====
 * 姓名显示在**外壳**上（宽屏侧栏的标题下、内容页顶栏右侧），但它原先只有
 * `ProfilePage.applyProfile` 会往 AppStorage 里写 —— 于是冷启动后不点进
 * 「我的」，侧栏/顶栏就一直是空的（用户反馈「必须进我的才能加载出姓名」）。
 *
 * 修法不是「在 Index 里再写一遍同样的请求」，而是把加载器收口到这里：
 *   - `identity()`：给外壳用。先吃内存/磁盘缓存（**不联网**）立刻把姓名补上，
 *     缓存没有再触发一次联网，成功后再发布；
 *   - `loader()`：ProfilePage 用它取完整资料（同一份缓存 key 与 TTL）。
 * 两条路径共用同一个 PageDataLoader 定义，不会出现「一边改了 TTL、另一边还是旧值」。
 *
 * ===== 为什么外壳侧也愿意联网一次 =====
 * 冷启动时磁盘上通常有上一次的资料缓存（TTL 6 小时），绝大多数情况零请求。
 * 只有全新设备/首次登录才会真的发一次 —— 而那种情况下姓名本来就得联网才有。
 * 这一请求与「进我的页」时发的那次完全一样，不增加教务系统的负担。
 */
import { PageCache, PageDataLoader, PageLoadResult } from './PageCache';
import { ProfileParser } from '../parser/ProfileParser';
import { StudentProfile } from '../model/Models';
import {
  CACHE_PROFILE, TTL_PROFILE, AS_STUDENT_NAME, AS_STUDENT_ID, AS_PROFILE_LOADED_FOR
} from '../common/Constants';
import { AppState } from './AppState';
import { Logger } from '../common/Logger';

export class ProfileService {
  /** 同一个账号的身份预取正在进行中（见 prefetchOnce 的去重说明） */
  private static prefetchInFlight: Promise<void> | null = null;

  /**
   * 已经取到身份的账号（空串 = 还没取到过）。
   *
   * 用**账号**而不是布尔标记：退出登录/换账号后重置为「没取过」，
   * 下次登录必然重新预取 —— 否则换了账号姓名也永远不更新
   * （布尔量在换账号后仍是 true），或者同一账号重新登录后被判成
   * 「已取过」而外壳一直空着。
   *
   * 落在 AppStorage 而不是本类的静态字段里：登出清理必须把它一并清掉，
   * 而那是 AppState 的职责；AppState 反向引用本类会形成循环 import，
   * 因此共享值放 Constants 的键里，两边各自读写
   * （与 AS_REAUTH_PENDING 同一手法）。
   */
  static owner(): string {
    const v: string | undefined = AppStorage.get<string>(AS_PROFILE_LOADED_FOR);
    return v === undefined || v === null ? '' : v;
  }

  /** 记下「这个账号的身份已经取到过」 */
  static markLoaded(account: string): void {
    if (account.length > 0) {
      AppStorage.setOrCreate(AS_PROFILE_LOADED_FOR, account);
    }
  }

  /**
   * 清掉「已取到身份的账号」标记（登出/换账号时调用）。
   *
   * 真正的调用点是 AppState 的登出清理；这里保留一个同名入口，
   * 便于 ProfileService 自身与测试使用。
   */
  static reset(): void {
    AppStorage.setOrCreate(AS_PROFILE_LOADED_FOR, '');
  }

  /** 个人资料的加载器（与 ProfilePage 共用；key 随账号变化，故每次现取） */
  static loader(): PageDataLoader<StudentProfile> {
    return new PageDataLoader<StudentProfile>(
      PageCache.keyOf(AppState.account, CACHE_PROFILE),
      () => AppState.apiInstance().getProfileHtml(),
      (body: string) => ProfileParser.parse(body),
      TTL_PROFILE);
  }

  /**
   * 把姓名/学号发布到 AppStorage（外壳读它显示）。
   *
   * 空值不覆盖已有值：一次「只回了一半」的响应不该把已经显示出来的姓名抹掉。
   */
  static publish(p: StudentProfile): void {
    if (p.name.length > 0) {
      AppStorage.setOrCreate(AS_STUDENT_NAME, p.name);
    }
    if (p.studentId.length > 0) {
      AppStorage.setOrCreate(AS_STUDENT_ID, p.studentId);
    }
  }

  /**
   * 确保外壳能拿到姓名：缓存优先，必要时联网。
   *
   * 调用点：登录成功后、以及冷启动恢复会话后（见 Index.restore）。
   * **绝不抛异常** —— 它是外壳的装饰性数据，不能因为取不到姓名就影响启动。
   *
   * 同一个账号已经取到过姓名就直接返回：外壳上已经显示着了，
   * 不必每次启动都白打一次请求。判断依据是「哪个账号取到过」而不是
   * 布尔量（见 owner 的说明）。
   *
   * @param allowNetwork false 时只读缓存（用于「先让界面出字」的第一步）
   */
  static async ensureIdentity(allowNetwork: boolean = true): Promise<void> {
    const acct: string = AppState.account;
    if (acct.length === 0) {
      return;
    }
    // 同一个账号已经取到姓名：不用再取一遍
    const shown: string | undefined = AppStorage.get<string>(AS_STUDENT_NAME);
    if (ProfileService.owner() === acct &&
      shown !== undefined && shown !== null && shown.length > 0) {
      return;
    }
    const loader: PageDataLoader<StudentProfile> = ProfileService.loader();

    // 1) 内存缓存：同步拿到，界面立刻有字
    const mem: StudentProfile | null = loader.peek();
    if (mem !== null) {
      ProfileService.publish(mem);
      ProfileService.markLoaded(acct);
      return;
    }

    // 2) 磁盘缓存：不联网
    try {
      const disk: StudentProfile | null = await loader.loadCached();
      if (disk !== null) {
        ProfileService.publish(disk);
        ProfileService.markLoaded(acct);
        return;
      }
    } catch (e) {
      Logger.warn('profile disk cache read failed');
    }

    if (!allowNetwork) {
      return;
    }

    // 3) 真的没有缓存 → 联网一次（等价于「进我的页」那一次请求）
    try {
      const r: PageLoadResult<StudentProfile> = await loader.load(false);
      ProfileService.publish(r.data);
      // 成功才记标记：失败要留给下一次触发（启动补取/进我的页）再试，
      // 记上的话外壳会一直空着，而缓存里其实根本没有数据。
      ProfileService.markLoaded(acct);
    } catch (e) {
      // 会话失效不在这里处理：外壳没有弹窗的资格，交给「我的」页在
      // 用户主动进入时按 ReAuthService 的既有流程处理。
      Logger.warn('profile identity prefetch failed');
    }
  }

  /**
   * 启动期/登录后的一次性预取。
   *
   * 「同一个账号已经取过就不用再取」这条判断在 [ensureIdentity] 里
   * （它还要看姓名是否真的显示着）—— 这里只负责**并发去重**：
   * 「登录成功后」与「冷启动恢复会话后」两条路径在同一次启动里都可能触发，
   * 去重后只发一次真实请求（与 ReAuthService.autoLoginInFlight 同一手法）。
   */
  static async prefetchOnce(): Promise<void> {
    if (AppState.account.length === 0) {
      return;
    }
    if (ProfileService.prefetchInFlight !== null) {
      return await ProfileService.prefetchInFlight;
    }
    ProfileService.prefetchInFlight = ProfileService.ensureIdentity(true);
    try {
      await ProfileService.prefetchInFlight;
    } finally {
      ProfileService.prefetchInFlight = null;
    }
  }
}
