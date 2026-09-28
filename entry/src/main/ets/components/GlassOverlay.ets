/*
 * GlassOverlay：页面内浮层外壳（默认玻璃，可切系统默认材质）
 *
 * 两种材质由 [PanelMaterial] 选择：玻璃 = 系统沉浸材质（设备不支持时退化为
 * 磨砂背板）+ 挖空遮罩；系统 = 整屏遮罩 + 不透明面板。选型的依据是**内容的密度**
 * （密集文字在半透明底上会与下层内容叠在一起糊成一片，见 PanelMaterial 的说明）。
 * 下面描述的是玻璃路径（默认）的层级。
 *
 * ===== 为什么单独做一个组件 =====
 * 应用里有 5 个「页面内浮层」（课程编辑、校历与作息表、节次作息编辑、
 * 提前提醒、重新验证）。它们原先都是「半透明遮罩 + 不透明面板」，
 * 观感与 dock 的玻璃割裂。逐个改会有 5 份几乎一样的布局代码，
 * 以后调参要改 5 遍 —— 因此收口到这一个组件。
 *
 * ===== 玻璃路径的层级（顺序仍然关键）=====
 * ```
 * Stack（页面根）
 *   ├─ 页面内容（Scroll/Column…）      ← 兄弟 1：被透出的对象
 *   └─ GlassOverlay                   ← 兄弟 2：浮层容器
 *        └─ Stack
 *             ├─ 遮罩四条（挖空面板）    ← 先画，压暗面板之外
 *             └─ 玻璃面板 + 内容        ← 后画，浮在遮罩之上
 * ```
 * 两条约束来自「面板的底是半透明的、取的是自己背后的画面」：
 *   1. **遮罩不能铺在面板背后**：铺满整块遮罩时玻璃截到的是那块纯色，
 *      通透感全无（详见 [GlassKit.scrimRects] 的说明）。因此遮罩拆成四条挖空。
 *   2. **浮层容器必须是页面内容的后序兄弟**：这样它才叠在内容之上；
 *      若塞进页面内容内部，浮层会被内容的裁剪/滚动带着走。
 *
 * ===== 面板的底：材质 vs 磨砂 =====
 * 设备有系统沉浸材质（API ≥ 26）时直接用 `systemMaterial`（REGULAR 档 + 30% 白）：
 * 系统负责模糊、厚度、阴影，面板里的文字与输入框能压住下层内容。
 * 没有材质时退回 `panelEffect()` 磨砂 + 一条高光细边 + 投影 —— 同级观感，
 * 只是少了厚度与光照。两条路径的判定见 [GlassKit.materialReady]。
 */
import { GlassKit, PanelMaterial, ScrimRect } from '../theme/GlassKit';
import { Theme } from '../theme/Theme';

@Component
export struct GlassOverlay {
  /** 面板内容。由调用方通过尾随闭包传入。 */
  @BuilderParam content: () => void;

  /** 面板宽度占可用宽度的比例（会再受 maxPanelWidth 与边缘余量约束） */
  panelWidthRatio: number = 0.92;
  /** 面板高度占可用高度的比例 */
  panelHeightRatio: number = 0.72;

  /**
   * 面板的**精确高度**（vp）。>0 时优先于 [panelHeightRatio]。
   *
   * ===== 为什么需要它（比例不够用）=====
   * 比例是按「可用高度」算的，而浮层内容的高度往往是**固定 vp**（若干行按钮、
   * 固定高度的输入框）。两者不匹配时：内容比面板高就被裁掉（实测「提前提醒」
   * 的选择列表只露出 3 项、后两项被切），比面板矮则面板里空一大截。
   * 内容高度已知的浮层直接给 vp，跨设备都准。
   */
  panelHeightVp: number = 0;

  /** 面板的**精确宽度**（vp）。>0 时优先于 [panelWidthRatio]。 */
  panelWidthVp: number = 0;
  /** 面板最大宽度（vp）：平板上避免拉成一整条 */
  maxPanelWidth: number = 560;
  /** 面板最大高度（vp） */
  maxPanelHeight: number = 900;

  /** 关闭回调（点遮罩区域触发） */
  onDismiss: () => void = () => {};

  /**
   * 面板材质（见 [PanelMaterial]）。
   *
   * SYSTEM 时**不渲染玻璃**，改为不透明面板 + 整屏遮罩。校历那样密集的
   * 月历网格与说明文字在半透明底上会被下层内容干扰（玻璃再厚也只是模糊，
   * 不会把文字变清楚），系统面板下才清楚 —— 这是用户对校历的明确要求。
   */
  material: PanelMaterial = PanelMaterial.GLASS;

  /**
   * 是否为本层预留底部 dock 的让位。
   *
   * 默认 true：浮层铺满整个页面区域，底部确实与 dock 重合。
   * 但**嵌套**在另一个已避开 dock 的面板里的浮层（校历里再弹学期滚轮）
   * 必须置 false —— 它所在的区域本来就在 dock 之上，再扣一次会让滚轮
   * 无谓地上移与压扁。
   */
  avoidDock: boolean = true;

  /** 浮层可用区域的实测尺寸（vp） */
  @State areaW: number = 0;
  @State areaH: number = 0;

  /**
   * 系统沉浸材质是否已就绪（探测是异步的，见 GlassKit.ensureMaterial）。
   *
   * 它是 @State 而不是每次 build 现查：探测在 aboutToAppear 发起，回来时
   * 赋值触发一次重建，面板从磨砂切换到材质。在此之前用降级外观（不会闪白：
   * 磨砂本来就有底色与投影）。
   */
  @State materialOn: boolean = false;

  /**
   * 边缘余量（vp）。
   *
   * 旧版是 34vp，为的是给 AppleUI 透镜的画布外扩留空间（不足 30vp 时玻璃
   * **静默不渲染**）。换成系统材质后这条约束不存在了，这里只作为「浮层不贴边」
   * 的观感余量，与页面内边距同值。
   */
  private static readonly EDGE_MARGIN: number = Theme.PAGE_PAD;

  /**
   * 面板与底部 dock 之间额外留出的空隙（vp）。
   * 贴在一起会让面板看着像 dock 的一部分，留一条缝才像两块独立的浮层。
   */
  private static readonly DOCK_GAP: number = 12;

  /** 极矮窗口下面板的最小高度（vp）：可用区被挤光时不再继续压扁面板 */
  private static readonly MIN_PANEL_H: number = 240;

  aboutToAppear(): void {
    // 探测一次系统材质（全局缓存，后续实例同步拿到结论）。不 await：
    // 首帧先按降级外观渲染，可用时再切过去。
    this.materialOn = GlassKit.materialReady();
    GlassKit.ensureMaterial().then((ok: boolean) => {
      this.materialOn = ok;
    });
  }

  /** 面板宽度（vp）：精确值优先，其次比例，最后受上限与边缘余量约束 */
  private panelW(): number {
    const avail: number = Math.max(1, this.areaW - GlassOverlay.EDGE_MARGIN * 2);
    const want: number = this.panelWidthVp > 0
      ? this.panelWidthVp
      : Math.min(this.areaW * this.panelWidthRatio, this.maxPanelWidth);
    return Math.max(1, Math.min(want, avail));
  }

  /** 可用区的上边界（vp）：只留观感余量 */
  private safeTop(): number {
    return GlassOverlay.EDGE_MARGIN;
  }

  /**
   * 可用区的下边界（vp）：扣掉底部 dock 与一条空隙。
   *
   * 只有窄屏才有 dock（宽屏是左侧导航），因此扣减量取 `Theme.bottomInset()` ——
   * 它与各页面滚动内容用的让位是**同一个值**（由 Index 按断点写入：
   * 窄屏 = dock 高 + 下边距，宽屏 = 0），不必再判断一次断点。
   */
  private safeBottom(): number {
    const inset: number = this.avoidDock ? Theme.bottomInset() : 0;
    return this.areaH - Math.max(inset + GlassOverlay.DOCK_GAP, GlassOverlay.EDGE_MARGIN);
  }

  /**
   * 面板高度（vp）：精确值优先，其次比例，最后夹进可用区。
   *
   * ===== 为什么必须夹进可用区（真机 bug）=====
   * 早先只把高度夹进「窗口高度 − 2×余量」，而位置在「扣掉 dock 之后」的
   * 区域里居中 —— 两者用的边界不一致。比例 0.88 的浮层（课程编辑）在手机上
   * 比扣完 dock 的可用区还高，于是走了「放不下就退回居中」的分支，
   * 面板下沿落进 dock 的高度范围内：底部的「保存 / 取消」正好被玻璃压住
   * （用户反馈「底部的按键不会给 dock 让位」）。现在高度与位置共用同一对
   * 边界，面板永远放得进可用区（只有极矮的自由多窗例外，见 room）。
   */
  private panelH(): number {
    const avail: number = Math.max(1, this.safeBottom() - this.safeTop());
    // 自由多窗拖到极矮时可用区会被挤成一条：这时允许面板占满窗口高度
    // （底部暂时压在 dock 下），也好过塌成一条看不见的缝
    const room: number = Math.max(avail, Math.min(GlassOverlay.MIN_PANEL_H, this.areaH));
    const want: number = this.panelHeightVp > 0
      ? this.panelHeightVp
      : Math.min(this.areaH * this.panelHeightRatio, this.maxPanelHeight);
    return Math.max(1, Math.min(want, room));
  }

  /**
   * 面板中心的目标 y（vp）。
   *
   * ===== 为什么不能简单居中（竖屏真机问题）=====
   * 底部 dock 是**外壳层**画的浮层，层级在页面之上；而本浮层活在页面里，
   * 于是面板底部会被 dock 压住 —— 校历浮层的「关闭」按钮正好在最下沿，
   * 竖屏时与 dock 重合，点不到（用户实测反馈）。
   *
   * 做法：在 safeTop…safeBottom 之间居中（下边界已扣掉 dock）。
   * 面板若比这段可用区还高（极矮窗口），则**贴着上边界**放、超出部分沉到
   * dock 下面 —— 宁可底部被压一点，也不能把面板顶出屏幕上沿（那会让标题
   * 与整行按钮一起消失）。
   */
  private safeCenterY(): number {
    const top: number = this.safeTop();
    const bottom: number = Math.max(this.safeBottom(), top + this.panelH());
    return (top + bottom) / 2;
  }

  /** 遮罩四条（挖空面板）：中心与面板一致，否则洞与面板错位 */
  private scrims(): ScrimRect[] {
    return GlassKit.scrimRects(
      this.areaW, this.areaH, this.panelW(), this.panelH(), this.safeCenterY());
  }

  /** 圆角半径（vp）：面板圆角与 Theme.RADIUS 一致，避免同页方圆混用 */
  private panelRadius(): number {
    return Theme.RADIUS;
  }

  /**
   * 不透明面板（PanelMaterial.SYSTEM）：系统表面色 + 圆角 + 投影，内容叠在上面。
   * 投影让它在压暗的遮罩上仍有浮起感，不至于像贴在屏幕上的纸片。
   */
  @Builder
  solidPanel() {
    Stack() {
      this.content()
    }
    .width(this.panelW())
    .height(this.panelH())
    .borderRadius(this.panelRadius())
    .backgroundColor($r('app.color.surface'))
    // 0.5vp 细边：纯色面板在白底页面上容易与背景糊在一起（暗色主题下更明显）
    .border({ width: 0.5, color: $r('app.color.divider') })
    .shadow(GlassKit.FLOAT_SHADOW)
    .clip(true)
    .offset({ y: this.safeCenterY() - this.areaH / 2 })
  }

  /**
   * 玻璃面板（PanelMaterial.GLASS）：面板内容 + 半透明底。
   *
   * 两条分支的**结构完全相同**（尺寸、圆角、位置、裁剪都一样），只有「底」不同：
   *   材质可用 → 系统沉浸材质（自带模糊/厚度/阴影，不再叠加底色与边框）；
   *   否则     → 磨砂背板 + 一条高光细边 + 投影。
   *
   * ===== 为什么要分支而不是「传一个空材质」=====
   * systemMaterial 属性本身是 @since 26，老系统上调用它（哪怕传 undefined）
   * 都可能直接出错。if 分支为假时那一行根本不执行，这是唯一安全的写法
   * （完整说明见 GlassKit 文件头）。
   */
  @Builder
  glassPanel() {
    if (this.materialOn) {
      Column() {
        this.content()
      }
      .width(this.panelW())
      .height(this.panelH())
      .borderRadius(this.panelRadius())
      .clip(true)
      .offset({ y: this.safeCenterY() - this.areaH / 2 })
      // 只给材质，**不叠背景色/边框**：SDK 明确建议 systemMaterial 不要与
      // 这几个属性同用（低算力设备上材质本身就是通过它们生效的）。
      // 面板 30% 白的底色由材质自己的 materialColor 提供（见 theme/MaterialProbe）
      .systemMaterial(GlassKit.panelMaterial())
    } else {
      Column() {
        this.content()
      }
      .width(this.panelW())
      .height(this.panelH())
      .borderRadius(this.panelRadius())
      .clip(true)
      .offset({ y: this.safeCenterY() - this.areaH / 2 })
      // 磨砂背板：把下层内容真正糊开并给一点底色（可读性靠它）
      .backgroundEffect(GlassKit.panelEffect())
      // 极细高光边：玻璃边缘「接光」的那一道，否则磨砂面板是一块没有轮廓的雾
      .border({ width: 0.5, color: GlassKit.FIELD_EDGE })
      .shadow(GlassKit.FLOAT_SHADOW)
    }
  }

  build() {
    Stack() {
      if (this.areaW > 0 && this.areaH > 0) {
        if (this.material === PanelMaterial.SYSTEM) {
          // 系统默认材质：一整块遮罩 + 居中不透明面板（面板不透明，不需要挖空）
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(GlassKit.SCRIM_COLOR)
            .onClick(() => {
              this.onDismiss();
            })
          this.solidPanel()
        } else {
          // 1) 遮罩四条：只压暗面板之外，面板背后留洞给玻璃（见 scrimRects 的说明）
          ForEach(this.scrims(), (r: ScrimRect) => {
            Column()
              .width(r.w)
              .height(r.h)
              .backgroundColor(GlassKit.SCRIM_COLOR)
              .position({ x: r.x, y: r.y })
              .onClick(() => {
                this.onDismiss();
              })
          }, (r: ScrimRect) => 'scrim-' + r.x.toString() + '-' + r.y.toString()
            + '-' + r.w.toString() + '-' + r.h.toString())

          // 2) 玻璃面板 + 内容：叠在遮罩之上（面板背后是未压暗的真实内容）
          this.glassPanel()
        }
      }
    }

    .width('100%')
    .height('100%')
    // 量出可用区域：面板尺寸、遮罩四条都要按它算
    .onAreaChange((_o: Area, now: Area) => {
      const w: number = Number(now.width);
      const h: number = Number(now.height);
      if (w > 0 && h > 0 && (Math.abs(w - this.areaW) > 0.5 || Math.abs(h - this.areaH) > 0.5)) {
        this.areaW = w;
        this.areaH = h;
      }
    })
  }
}
