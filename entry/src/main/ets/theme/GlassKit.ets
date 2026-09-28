/*
 * GlassKit：全应用统一的「玻璃」工具集
 *
 * ===== 这一版换了实现，为什么 =====
 * 旧版用第三方库 com.hm.appleui.hw（XComponent + 原生 EGL 透镜）拿边缘折射，
 * 代价是它的原生库只有 **arm64-v8a**：HAP 装不上 x86_64 模拟器
 * （`install parse native so failed`），只能在 entry/build-profile.json5 里
 * 写死 abiFilters 只打 arm64，另外再做一份 API 一致的占位包给模拟器用。
 * 现在改用**系统沉浸材质**（@ohos.arkui.uiMaterial，@since 26）：
 *   · 不带任何第三方原生库 → 四个 ABI 同一份产物，模拟器与真机都能装；
 *   · 观感交给系统（厚度分档 + 光照 + 阴影 + 可选的交互反馈），不再自绘着色器；
 *   · 代价：**API 26 以下根本没有这套材质**，那条路必须能优雅降级（见下）。
 *
 * ===== 两条路径（按设备能力二选一）=====
 * 1. **材质路径**：`systemMaterial(new ImmersiveMaterial(...))`。
 *    dock 用 THIN（厚度最小 → 内容能透出来），浮层面板用 REGULAR
 *    （模糊够强，面板里的输入框 / 滚轮 / 按钮才压得住下层内容）。
 * 2. **降级路径**：`backgroundEffect` 磨砂（模糊 + 提饱和 + 极淡底色）
 *    + 一条高光细边 + 投影 —— 即「半透明表面 + 边框 + 阴影」。
 *    内容依旧从下面透出来，只是没有折射与厚度。本项目的主要验证机型
 *    （API 24）走的就是这条。
 *
 * ===== 能力探测为什么这么绕（必须遵守，否则老设备会崩）=====
 * 1. `systemMaterial` 属性本身是 @since 26：**老系统上不能调用它**，
 *    连 `systemMaterial(undefined)` 也不行（属性方法在旧运行时里不存在）。
 *    因此用到材质的组件一律用 if/else 分支把调用包起来 —— 条件为假时
 *    那一行**根本不执行**（见 Index.dockBar / GlassOverlay.glassPanel）。
 * 2. **不能静态 import** '@ohos.arkui.uiMaterial'：该模块在旧设备上不存在，
 *    静态导入会在**模块加载期**抛错，try/catch 拦不住，还会把引用它的页面
 *    一起带崩（本仓库 PDF 闪退就是这一类，详见 README）。所以本文件只在
 *    API ≥ 26 时才 `await import()`（见 ensureMaterial），静态部分只依赖
 *    设备信息模块与全局类型，完全不碰 uiMaterial。
 * 3. 探测全局只做一次并把结论缓存下来（probe）；组件在 aboutToAppear 里
 *    fire-and-forget 调用，回来后再置位 @State 触发一次重建切到材质路径。
 * 4. `uiMaterial.Material.empty` 的语义是「把组件上已有的材质关掉」，
 *    不是另一种降级外观，因此降级不靠它，而是靠上面第 2 条那套色/边/影。
 *
 * ===== 哪些地方用材质、哪些地方仍用磨砂 =====
 * · 手机端底部 dock、页面内浮层（GlassOverlay 的 PanelMaterial.GLASS）：
 *   它们浮在可滚动内容之上、内容从下面穿过 —— 材质的背景模糊/厚度才有意义。
 * · 侧栏 / 顶栏 / 输入框底衬：仍用本文件下面的 backgroundEffect 磨砂。
 *   它们背后没有内容穿过（侧栏背后是页面底色），挂材质只会多一层无谓合成。
 */
import deviceInfo from '@ohos.deviceInfo';
import { Logger } from '../common/Logger';
import { Theme } from './Theme';

/** dock 材质底色：约 8% 白 —— 要的是「内容从下面透出来」，底色必须极淡 */
const DOCK_TINT: string = '#14FFFFFF';

/** 浮层面板材质底色：约 30% 白 —— 与 panelEffect() 同色，深浅色下观感一致 */
const PANEL_TINT: string = '#4DFFFFFF';
/**
 * 动态 import 到的 uiMaterial 模块形状。
 *
 * ===== 为什么不直接调 ui.isImmersiveMaterialSupported() =====
 * 这个函数只存在于 OpenHarmony SDK 26.0.0 的声明里；hvigor 实际编译用的是
 * DevEco 自带的那份 SDK（同为 API 26，但修订更早），它的
 * `@ohos.arkui.uiMaterial` **没有导出这个函数** —— 直接点出来编译不过。
 * 因此这里按「自己声明的形状」读取模块的 default：`Object` 兜住类型检查，
 * 探测函数声明为**可选**，运行时拿不到就退回「版本够即认为支持」
 * （材质不生效时系统只是不渲染滤镜，面板仍有 materialColor / backgroundColor
 * 兜底，不会出现没有底的一片）。
 */
interface UiMaterialApi {
  ImmersiveStyle: Object;
  ImmersiveMaterial: Object;
  isImmersiveMaterialSupported?: () => boolean;
}

interface UiMaterialModule {
  default?: UiMaterialApi;
}

/** 动态 import 到的材质构造模块形状（见 theme/MaterialProbe.ets） */
interface MaterialFactoryModule {
  MaterialProbe: MaterialFactoryApi;
}

interface MaterialFactoryApi {
  dockMaterial(tint: ResourceColor): SystemUiMaterial;
  panelMaterial(tint: ResourceColor): SystemUiMaterial;
}

/**
 * 浮层面板的材质。
 *
 * 两种都要有，因为内容性质不同（用户明确要求校历用系统默认）：
 *
 * 1. GLASS（默认）——半透明玻璃：材质可用时是系统沉浸材质，否则是磨砂背板。
 *    适合内容**稀疏**的浮层（几个按钮、一个滚轮、几个输入框）：
 *    能看见下层内容的轮廓，边缘还有一道接光细边。
 *
 * 2. SYSTEM——不透明面板（surface + 圆角 + 投影）+ 整屏压暗遮罩。
 *    适合内容**密集**的浮层（校历的月历网格、几十行的列表）：
 *    半透明底会把密集小字与下层内容叠在一起，怎么调都读不清；
 *    含大量文字的浮层用系统面板，是与系统弹窗一致的、也是唯一清楚的选择。
 */
export enum PanelMaterial {
  /** 玻璃：系统沉浸材质（不可用时退化为磨砂背板） */
  GLASS = 0,
  /** 系统默认：不透明表面 + 圆角 + 投影 */
  SYSTEM = 1
}

export class GlassKit {
  // ---------- 系统沉浸材质（API 26+，探测结论全局缓存） ----------

  /** 探测的 Promise：只创建一次，并发调用共享同一结论 */
  private static probe: Promise<boolean> | null = null;
  /** 探测结论：材质可用（= 两个材质对象都已建好） */
  private static ok: boolean = false;
  private static dockMat: SystemUiMaterial | undefined = undefined;
  private static panelMat: SystemUiMaterial | undefined = undefined;

  /**
   * 同步查询材质是否已就绪。
   *
   * build() 里只能用它（构建是同步的，没法 await）；真正的探测由
   * ensureMaterial 在 aboutToAppear 阶段发起。未就绪时一律走降级路径。
   */
  static materialReady(): boolean {
    return GlassKit.ok;
  }

  /**
   * 探测并加载系统材质（幂等）。
   *
   * 调用方（Index / GlassOverlay）在 aboutToAppear 里 fire-and-forget 调用，
   * 完成后置位 @State 触发重建 —— 因此**不能在这里等**：等不到就一直是
   * 降级外观，也比卡住首屏强。
   *
   * @returns 是否可用（false = 走降级路径，不抛异常）
   */
  static ensureMaterial(): Promise<boolean> {
    if (GlassKit.probe === null) {
      GlassKit.probe = GlassKit.loadMaterial();
    }
    return GlassKit.probe;
  }

  /** dock 的材质（THIN：厚度最小，中心尽量透） */
  static dockMaterial(): SystemUiMaterial | undefined {
    return GlassKit.dockMat;
  }

  /** 浮层面板的材质（REGULAR：模糊够强，面板里的文字才可读） */
  static panelMaterial(): SystemUiMaterial | undefined {
    return GlassKit.panelMat;
  }

  /**
   * 真正的探测：API 能力 → 动态加载模块 → 设备能力 → 建两个材质对象。
   *
   * 任何一步失败都返回 false（绝不抛），让调用方安静地走降级路径。
   */
  private static async loadMaterial(): Promise<boolean> {
    try {
      // 第一道门：运行时能力查询。低于 API 26 时系统里根本没有这个模块，
      // 连加载都不该试（动态 import 不存在的模块会抛错，虽然能 catch，
      // 但没必要去踩）。
      if (!GlassKit.materialApiReady()) {
        Logger.info('glass: system material off (api 26 unavailable, sdk ' +
          GlassKit.apiLevel().toString() + ')');
        return false;
      }

      // 动态 import：模块类型由自己声明的形状给出（见 UiMaterialModule）。
      // 这里只做**探测**：真正的材质构造在 MaterialProbe 里（ArkTS 不允许
      // 在 interface 里写构造签名，构造必须让编译器看见真正的类）。
      const mod: UiMaterialModule = await import('@ohos.arkui.uiMaterial');
      const ui: UiMaterialApi | undefined = mod.default;
      if (ui === undefined) {
        return false;
      }
      // 第二道门：设备能力。函数存在就照它判；老修订的 SDK 里没有这个导出，
      // 此时按「能力查询已通过即支持」处理（见 UiMaterialApi 的说明）。
      const supported: (() => boolean) | undefined = ui.isImmersiveMaterialSupported;
      if (supported !== undefined && !supported()) {
        Logger.info('glass: system material off (device unsupported)');
        return false;
      }
      // 能力已确认：加载构造模块并建两个材质（本模块静态依赖 uiMaterial，
      // 因此只在 API ≥ 26 的设备上会被加载到，见 MaterialProbe 的文件头）
      const factory: MaterialFactoryModule = await import('./MaterialProbe');
      const maker: MaterialFactoryApi = factory.MaterialProbe;
      GlassKit.dockMat = maker.dockMaterial(DOCK_TINT);
      GlassKit.panelMat = maker.panelMaterial(PANEL_TINT);
      GlassKit.ok = true;
      Logger.info('glass: system material on');
      return true;
    } catch (e) {
      // 模块加载/构造失败都落到磨砂路径：玻璃永远只是装饰，不能影响功能
      Logger.warn('glass: system material load failed, fallback to frosted');
      return false;
    }
  }

  /**
   * 设备是否具备 API 26 的能力。
   *
   * ===== 为什么用 apiAvailable 而不是比较 sdkApiVersion =====
   * 两者不是同一套编号：`sdkApiVersion` 给的是设备当前的 API 等级
   * （HarmonyOS 机型常见 20/24 这种数字），而 `uiMaterial` / `systemMaterial`
   * 的 @since 标的是 **26.0.0** 这个版本号。`apiAvailable('26.0.0')` 正是
   * 系统为这种跨版本判断提供的入口（也是编译器在 `systemMaterial` 那行
   * 警告里推荐的做法）：对 API 26+ 的字符串形式，它同时代表
   * OpenHarmony 与发行版两套版本号。
   *
   * 老系统上这个函数**本身不存在**，调用会抛 TypeError —— 与「不具备该能力」
   * 完全同义，因此 catch 里直接返回 false（不打印错误：这是预期路径）。
   */
  private static materialApiReady(): boolean {
    try {
      // 注意：这里的参数**必须是字面量**。ArkTS 编译器（11706013）是读
      // 实参的源码文本来判合法性的，写 `apiAvailable(MATERIAL_MIN_VERSION)`
      // 会直接报「必须是不大于 25 的十进制整数」—— 它认不出常量。
      return deviceInfo.apiAvailable('26.0.0');
    } catch (e) {
      // 老系统没有 apiAvailable：说明系统版本远低于 26，材质必然不可用
      return false;
    }
  }

  /** 设备系统 API 等级（仅用于日志；取不到按 0 处理） */
  private static apiLevel(): number {
    try {
      const v: number = deviceInfo.sdkApiVersion;
      return v > 0 ? v : 0;
    } catch (e) {
      return 0;
    }
  }

  // ---------- 降级路径的观感（半透明表面 + 高光细边 + 投影） ----------

  /**
   * 底部 dock 的磨砂底（材质不可用时的替代）。
   *
   * radius 12：比顶栏的 barEffect（20）低一档 —— dock 要的是「还能看清被它
   * 压住的是什么」，糊太狠就成了一块毛玻璃板，与「内容从下面穿过」的诉求相反。
   * 底色只给约 12% 白：图标与文字的对比靠它们自己的颜色，不靠底色遮挡。
   */
  static dockEffect(): BackgroundEffectOptions {
    return {
      radius: 12,
      saturation: 1.2,
      brightness: 1.02,
      color: '#1FFFFFFF',
      adaptiveColor: AdaptiveColor.AVERAGE,
      blurOptions: { grayscale: [10, 36] }
    };
  }

  /**
   * 浮层面板 / 卡片容器的磨砂底（材质不可用时的替代，也是弹窗面板的既有观感）。
   *
   * radius 24：与 flutter 端 GlassQuality.standard 的观感对齐；
   * color 带 ~30% 白：磨砂面板需要一点底色才能与背景分层（纯模糊会「散」），
   * 这个值同时也是材质路径的 materialColor（PANEL_TINT），两条路径观感一致。
   */
  static panelEffect(): BackgroundEffectOptions {
    return {
      radius: 24,
      saturation: 1.35,
      brightness: 1.02,
      color: PANEL_TINT,
      adaptiveColor: AdaptiveColor.AVERAGE,
      blurOptions: { grayscale: [15, 45] }
    };
  }

  /** 输入框 / 选择器底衬：比面板薄一档（字段小，模糊过强会显得脏） */
  static fieldEffect(): BackgroundEffectOptions {
    return {
      radius: 16,
      saturation: 1.2,
      brightness: 1.02,
      color: '#40FFFFFF',
      adaptiveColor: AdaptiveColor.AVERAGE,
      blurOptions: { grayscale: [12, 40] }
    };
  }

  /** 顶栏 / 工具条：介于两者之间 */
  static barEffect(): BackgroundEffectOptions {
    return {
      radius: 20,
      saturation: 1.3,
      brightness: 1.02,
      color: '#47FFFFFF',
      adaptiveColor: AdaptiveColor.AVERAGE,
      blurOptions: { grayscale: [14, 42] }
    };
  }

  /**
   * 玻璃表面的高光细边（0.5vp 白，约 25%）。
   *
   * ===== 为什么要有这一笔 =====
   * 玻璃控件落在**不透明**面板上（系统材质浮层）时，模糊背后是一块纯色 ——
   * 观感几乎等于没做玻璃。这条极细的白边是玻璃边缘「接光」的那一道，
   * 暗色主题下也能显出来（与已被删除的 PDF 内嵌视窗用的是同一手法）。
   *
   * 用法：与 fieldEffect / panelEffect / dockEffect 一起用，不要单独用。
   */
  static readonly FIELD_EDGE: string = '#40FFFFFF';

  /**
   * 降级路径浮层的投影。
   *
   * 与不透明面板的那条投影同值：让 dock / 浮层在页面与压暗遮罩之上仍有
   * 浮起感，不至于像贴在屏幕上的一块纸片。材质路径由材质自带阴影，不用它。
   */
  static readonly FLOAT_SHADOW: ShadowOptions = {
    radius: 24,
    color: '#33000000',
    offsetX: 0,
    offsetY: 6
  };

  // ---------- 浮层遮罩 ----------

  /**
   * 浮层压暗遮罩的四个矩形（中间挖空给玻璃面板）。
   *
   * ===== 为什么不能铺一整块遮罩 =====
   * 玻璃面板取的是**自己背后**的画面（背景模糊 / 系统材质都如此）。若在面板
   * 与页面内容之间铺一整块半透明遮罩，玻璃截到的就是那块**纯色**，通透感全无
   * —— 面板会退化成一整块死板的深色矩形（这是旧版 AppleUI 时代实测的结论，
   * 换成系统材质后同样成立：材质的滤镜也只认真实内容）。
   *
   * 反过来把遮罩画在面板**之上**也不行：它会连面板一起压暗。
   *
   * 因此这里把遮罩拆成「面板四周的四条」——视觉上等于「整屏压暗、中间挖一个
   * 面板大小的洞」，而面板背后没有任何遮挡，玻璃透出的是真实的页面内容。
   * 附带的好处：玻璃里看到的是**未压暗**的内容，比 Flutter 端（玻璃叠在
   * 全屏遮罩之上、透出的是已压暗的画面）更通透。
   *
   * @param screenW 屏幕宽（vp）
   * @param screenH 屏幕高（vp）
   * @param panelW  面板宽（vp）
   * @param panelH  面板高（vp）
   * @param centerY 面板中心的 y（vp）。不传或 ≤0 时按屏幕垂直居中。
   *                浮层需要躲开底部 dock 时由调用方传入上移后的中心值
   *                （见 GlassOverlay 的 safeCenterY）。
   * @returns 四条遮罩矩形，顺序为 上/下/左/右；宽高为 0 的条可跳过渲染
   */
  static scrimRects(
    screenW: number,
    screenH: number,
    panelW: number,
    panelH: number,
    centerY?: number
  ): ScrimRect[] {
    const left: number = Math.max(0, (screenW - panelW) / 2);
    // 遮罩与面板必须用**同一个**中心值，否则挖出的洞会和面板错位，
    // 表现为「面板边缘压着一块暗角」。
    const cy: number = (centerY === undefined || centerY <= 0)
      ? screenH / 2 : centerY;
    const top: number = Math.max(0, cy - panelH / 2);
    const right: number = Math.max(0, screenW - left - panelW);
    const bottom: number = Math.max(0, screenH - top - panelH);
    const out: ScrimRect[] = [];
    if (top > 0) {
      out.push(new ScrimRect(0, 0, screenW, top));
    }
    if (bottom > 0) {
      out.push(new ScrimRect(0, top + panelH, screenW, bottom));
    }
    if (left > 0) {
      // 左右两条只覆盖面板所在的那一段高度，避免与上下条重叠画出双层暗度
      out.push(new ScrimRect(0, top, left, panelH));
    }
    if (right > 0) {
      out.push(new ScrimRect(left + panelW, top, right, panelH));
    }
    return out;
  }

  /** 浮层遮罩的颜色：与既有实现一致（#66000000 = 40% 黑） */
  static readonly SCRIM_COLOR: string = '#66000000';

  /** 浮层面板的统一内边距 */
  static readonly PANEL_PAD: number = Theme.GAP_L;
}

/** 遮罩矩形（vp） */
export class ScrimRect {
  x: number = 0;
  y: number = 0;
  w: number = 0;
  h: number = 0;

  constructor(x: number, y: number, w: number, h: number) {
    this.x = x;
    this.y = y;
    this.w = w;
    this.h = h;
  }
}
