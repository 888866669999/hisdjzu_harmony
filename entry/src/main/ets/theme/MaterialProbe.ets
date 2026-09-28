/*
 * MaterialProbe：系统沉浸材质（uiMaterial）的**唯一**接触点
 *
 * ===== 为什么单独成文件、且只通过动态 import 加载 =====
 * `@ohos.arkui.uiMaterial` 模块与 `systemMaterial` 属性都是 @since 26：
 * 老设备上这个模块**根本不存在**，静态导入会在**模块加载期**抛错
 * （try/catch 拦不住，还会把引用它的页面一起带崩 —— 见 README 的 PDF 闪退一节）。
 * 因此本文件绝不静态导入任何页面，只提供「确认设备可用之后才加载」的实现，
 * 由 GlassKit 在 API 版本与能力探测都通过后 `await import()`。
 * 这与 OcrProbe / CaptchaModel 的处理方式完全一致（同一条踩过的坑）。
 *
 * ===== 为什么构造材质放在这里，而不是放在 GlassKit =====
 * ArkTS 不允许在 interface / type 别名里写**构造签名**
 * （arkts-no-ctor-signatures-iface），而 `new uiMaterial.ImmersiveMaterial(...)`
 * 必须让编译器看见真正的类。把构造收在本文件里，外部只需要 SDK 的全局类型
 * `SystemUiMaterial`，就不必在别处引用该命名空间，探测逻辑也因此能独立放在
 * GlassKit（那里用的是「自己声明的形状」，见其 loadMaterial）。
 */
import { uiMaterial } from '@kit.ArkUI';

export class MaterialProbe {
  /**
   * dock 的材质：THIN（厚度最小）+ 极淡底色。
   *
   * THIN 而不是 REGULAR：dock 的诉求是「内容从下面滚过时看得见被遮住的东西」，
   * 厚度越大越像一块实心板。底色由调用方给（GlassKit 里的 DOCK_TINT，约 8% 白），
   * 与降级路径的 backgroundColor 同值 —— 两条路径观感一致。
   */
  static dockMaterial(tint: ResourceColor): SystemUiMaterial {
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.THIN,
      materialColor: tint,
      applyShadow: true,
      // 不做按下形变/光感反馈：dock 整体被拉伸很难看，且这里无法实测
      interactive: false
    });
  }

  /**
   * 浮层面板的材质：REGULAR（模糊够强）+ 30% 白底色。
   *
   * 面板里有输入框、滚轮、按钮与说明文字，必须压得住下层内容；
   * 底色与降级路径的 panelEffect().color 同值（GlassKit 里的 PANEL_TINT）。
   */
  static panelMaterial(tint: ResourceColor): SystemUiMaterial {
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.REGULAR,
      materialColor: tint,
      applyShadow: true,
      interactive: false
    });
  }
}
