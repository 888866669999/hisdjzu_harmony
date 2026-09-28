# 鸿蒙端「液态玻璃」调研结论与方案

> 调研依据：直接读本机 SDK 的 `.d.ts` 声明（最权威），
> 并核对了真机设备的 API 等级。不是从文档/博客推测的。
>
> **2026-09-27 更新（现行方案）**：改用**系统沉浸材质**
> （`@ohos.arkui.uiMaterial`，API ≥ 26，见第 2 节），不可用时退化为
> `backgroundEffect` 磨砂 —— 两条路径都不带第三方原生库，四个 ABI 通用，
> x86_64 模拟器可直接安装。第三方库 `com.hm.appleui.hw` 的实践
> （第 6 节）已移除，保留作历史记录：其中的布局约束仍是理解 dock / 浮层
> 结构的钥匙。第 7 节已按新方案更新。
>
> **2026-09-18 更新（历史）**：本文件原先的结论是「真·液态玻璃在本机不可用」。
> 该结论当时被第三方库推翻 —— 但它只提供 arm64-v8a 的原生库，
> 代价是应用装不上模拟器，最终被换回系统材质方案。

---

## 1. 系统原生能力的三个档位

| 档位 | 能力 | 需要的 API | 本机可用 | 观感 |
|---|---|---|---|---|
| **A. 原生 Immersive Material** | 系统级玻璃材质（含光照、交互反馈、5 档厚度） | **API 26** | ❌ **设备仅 API 24** | 与 iOS 26 最接近 |
| **B. 模糊材质** | 背景模糊 + 饱和度 + 亮度 + 灰度噪声 | API 11–14 | ✅ 可用 | 磨砂玻璃，外观接近 A 的静态部分 |
| **C. 前后景模糊样式** | 系统预设 13 档 `BlurStyle` | API 9–12 | ✅ 可用 | 与系统风格一致，参数最少 |

**关键事实**：鸿蒙在 **API 26 才引入系统级的液态玻璃 API**
（`@ohos.arkui.uiMaterial`，2025–2026 年的新能力），
而本机设备（SLG-W60，HarmonyOS 6.1.0）**API 等级是 24** ——
所以 A 档在这台机器上**编译能过、运行无效**（`@since 26.0.0`）。

---

## 2. A 档：API 26 的原生 Immersive Material（未来可升级）

SDK 里的 `@ohos.arkui.uiMaterial.d.ts` 提供了完整的玻璃材质体系：

```ts
// 5 档厚度：ULTRA_THIN / THIN / REGULAR / THICK / ULTRA_THICK
class ImmersiveMaterial extends Material {
  constructor(options?: ImmersiveOptions);
}
interface ImmersiveOptions {
  style?: ImmersiveStyle;          // 厚度档位
  materialColor?: ResourceColor;   // 材质叠加色
  colorInvert?: boolean;           // 子树上颜色随背景自动反转（THIN/ULTRA_THIN 生效）
  applyShadow?: boolean;           // 是否带材质阴影（默认 true）
  interactive?: boolean;           // 是否响应交互
  lightEffect?: LightEffectOptions | null;  // 手势光效反馈（这就是「动态」的来源）
}
```

应用方式：`CommonMethod.systemMaterial(material)` ——
**挂在 `CommonMethod` 上，意味着任意组件都能用**（不只是弹窗）：

```ts
Column() { /* ... */ }
  .systemMaterial(new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.REGULAR,
    interactive: true,
    lightEffect: { color: Color.White },
  }))
```

还支持查询/批量开关（`getMaterialInfo()`、`MaterialState.ENABLE/DISABLE`），
以及给 `bindSheet` / `bindPopup` / `bindMenu` 指定 `systemMaterial`。

**升级条件**：`compatibleSdkVersion` 提到 26 且目标设备的 API ≥ 26。
当前项目 `targetSdkVersion` 已是 `26.0.0`，但 `compatibleSdkVersion` 是
`6.0.0(20)`、设备是 24 —— 需要设备升级才能真正跑起来。

---

## 3. B 档：现在就能做的方案（推荐）

SDK 提供 `backgroundEffect(BackgroundEffectOptions)`（@since 12），
参数足以做出玻璃质感：

```ts
.backgroundEffect({
  radius: 18,            // 模糊半径：玻璃的「磨砂」程度
  saturation: 1.5,       // 饱和度：透出的颜色不发灰
  brightness: 1.05,      // 亮度微提
  color: '#3DFFFFFF',    // 玻璃自身底色（极淡）
  adaptiveColor: AdaptiveColor.AVERAGE,  // 按背景自适应取色
  blurOptions: { grayscale: [20, 60] },  // 灰度区间：**做磨砂质感的关键**
  policy: BlurStyleActivePolicy.ALWAYS_ACTIVE,
})
```

另有更省事的 `backgroundBlurStyle(BlurStyle.X, options)`，
其中 `BlurStyle` 有 13 档：

- `Thin / Regular / Thick`（9+，应用内材质）
- `BACKGROUND_THIN / REGULAR / THICK / ULTRA_THICK`（3+，背景材质）
- **`COMPONENT_ULTRA_THIN / THIN / REGULAR / THICK / ULTRA_THICK`（8–12，组件材质）** ← 最接近 A 档的分档语义

### 建议用法（与 Flutter 端保持一致的信息层次）

| 位置 | 建议 | 理由 |
|---|---|---|
| 侧边 dock / 顶部栏 / 底部栏 | `COMPONENT_REGULAR` + 低透明度底色 | 与 Flutter 端同为「浮层」 |
| 弹窗（课程编辑 / 重新验证 / 校历） | `COMPONENT_THICK` + `backgroundEffect` 提饱和 | 弹窗上内容多，需要更强的实体感 |
| 设置页分组卡片 | `COMPONENT_THIN` | 卡片是次级层次，淡一些 |
| **课表网格内的课程卡** | **不做玻璃** | 与 Flutter 端同一决策：实心彩卡是内容载体，加玻璃既冲突又费 GPU |

### 需要注意的两点

1. **`backgroundEffect` 是「背景模糊」，不是「前景折射」。**
   它把组件**背后**的内容模糊后透出，但没有 A 档那种光线折射/边缘高光。
   想要高光可叠加 `border({ width: 1, color: '#33FFFFFF' })` 模拟玻璃边缘。
2. **性能**：华为官方对 `backgroundEffect` 也有性能提示 ——
   大面积、多层叠加会明显增加 GPU 负载。
   鸿蒙端应**比 Flutter 端更保守**（鸿蒙设备的 GPU 调度更紧），
   建议只用在导航栏与弹窗这两类小面积浮层上。

---

## 4. 落地步骤（若要做）

> 这一节是最初的规划，落地时基本照此推进：`GlassKit` 收口、dock 先行、
> 真机验证、能力兜底（第 4 条现在由 `GlassKit.ensureMaterial` 的
> 版本号 + 动态 import + 能力函数三级探测实现）。下列步骤保留，
> 用于说明推进顺序。

1. 在 `theme/Theme.ets` 旁新增 `theme/GlassKit.ets`，集中定义
   「一处参数、多处复用」的玻璃样式（与 Flutter 端 `glass_kit.dart` 对应）。
2. 从侧边 dock 与顶部栏开始（改动最小、最容易看出效果）。
3. **必须在真机上验证**：
   - 该设备 API 24 只支持 B 档，确认 `backgroundEffect` 生效；
   - 观察滚动/切页时是否掉帧；
   - 深色模式下降低模糊、提高底色不透明度（深色下模糊过强会发灰发浑）。
4. 加入 `canIUse('SystemCapability.ArkUI.ArkUI.Full')` 之类的兜底：
   低端或老设备上退化为纯色面板，**绝不因为玻璃而让界面显示不出来**。

---

## 5. 与 Flutter 端的能力对比（为何两端观感会有差异）

| 维度 | Flutter (`liquid_glass_widgets`) | 鸿蒙 B 档 (`backgroundEffect`) |
|---|---|---|
| 技术手段 | 自研 **fragment shader** | 系统合成器（Skia/RenderService） |
| 折射 / 色散 | ✅ 有（`refractiveIndex` / `chromaticAberration`） | ❌ 无 |
| 边缘高光 | ✅ 有（`fresnelStrength` / `lightAngle`） | ⚠️ 只能用 1px 边框模拟 |
| 手势光效 | ✅ 有（`isInteractive` / `glowIntensity`） | ❌ 无（A 档才有 `lightEffect`） |
| 模糊+饱和度 | ✅ 有 | ✅ 有 |
| 设备门槛 | Impeller（本机满足） | API 11+（本机满足） |

**结论（当时的判断，现已被后续方案取代）**：Flutter 端能做到「真·液态玻璃」
（有折射与高光），鸿蒙端靠系统原生能力在当前设备上只能做到「磨砂玻璃」
（模糊+饱和度）—— 当年因此引入了第三方库（第 6 节，已移除）。
现在的结论是：**折射/色散不值得用「锁死单一 ABI」去换**，
系统沉浸材质 + 磨砂降级已经足够（见第 7 节）。

---

## 6. 曾经的方案：`com.hm.appleui.hw`（**已移除**，保留作历史记录）

> **2026-09-27 更新：本方案已整体移除。** 改用**系统沉浸材质**
> （`uiMaterial.ImmersiveMaterial` + `systemMaterial`，API ≥ 26，
> 见第 2 节）—— 探测可用则挂材质，否则退化为 `backgroundEffect` 磨砂
> （半透明表面 + 高光细边 + 投影），两条路径都**不带任何第三方原生库**，
> 四个 ABI 通用，x86_64 模拟器可直接安装。落地位置与观感意图不变：
> 手机端 dock 与内容稀疏的页面内浮层。第 6 节以下内容保留，因为其中
> 「素材/透镜类方案的约束」仍然是理解这套布局（为什么 dock 是浮层、
> 为什么遮罩要挖空）的钥匙；第 7 节的建议已按新方案更新。

上述「等 API 26」的结论只适用于**系统原生**能力。第三方库方案当年在真机上
（API 24）也能做出真正的液态玻璃，代价如下表 —— **这也是它最终被换掉的原因**。

### 选型

| 项 | 值 |
|---|---|
| 包名 | `com.hm.appleui.hw` |
| 版本 | `^2.1.0` |
| `compatibleSdkVersion` | **20**（本机 API 24 可用，无需升级系统） |
| 原理 | `XComponent(TEXTURE)` + 原生 EGL / OpenGL ES 3.0，独立渲染线程 |
| 依赖 | `libliquidglass.so`（仅 `arm64-v8a`）← **移除的直接原因** |

安装：`ohpm install com.hm.appleui.hw`（依赖写入根 `oh-package.json5`）。

它实时截取**紧邻下层**的背景做透镜：中心区域保持纯透明可看穿，只在边缘做
径向折射、RGB 色散与切向正弦扭曲 —— 这正是与「磨砂玻璃」的本质区别。

### 两个必须知道的约束（都踩过）

**① 透镜四周必须留出 ≥ 30vp 的空隙。**

该库把画布向透镜四周各外扩 30vp（源码 `padVp`）以容纳边缘采样点，并按**画布**
而非透镜去截取背景。玻璃离父层边缘不足 30vp 时，外扩区越出父层边界，
截帧被判越界：

```
W AceComponentSnapshot: Snapshot reigon out of range.
E AppleUI: snapshot fail 401
```

**玻璃会完全不渲染**，只剩全透明 —— 不崩溃、不抛异常，界面看起来只是
「没有玻璃效果」，极难察觉。因此 `Index.ets` 里 dock 的左右边距与底部留白
都由 `DOCK_PAD = 30` 推出（`DOCK_MARGIN = 34`、`DOCK_BOTTOM = 36`）。

**② 玻璃必须与它要折射的内容层同处一个 Stack、且作为后序兄弟。**

该库从自身出发沿父链「向前找最近一个与自身可见区域重叠的兄弟层」，
中间多夹一层容器同样会导致截帧区域越界。

### 怎么确认玻璃真的在渲染

**不要只看截图** —— 「全透明」与「未渲染」外观完全一样。可靠办法是清空日志缓冲
后重跑，再数错误条数：

```bash
hdc shell "hilog -r"
hdc shell "aa force-stop com.sdjzu.hijianzhu"
hdc shell "aa start -b com.sdjzu.hijianzhu -a EntryAbility"
hdc shell "hilog -x" | grep -c "AppleUI.*snapshot fail"   # 期望 0
```

### 落地范围

两处：

1. **手机端（窄屏）底部 dock**：`Index.ets` 的 `dockGlass()`（玻璃）与
   `dockTabs()`（图标文字，叠于其上）。dock 是浮层，内容从玻璃下面滚过，
   所以各页面滚动内容需按 `Theme.bottomInset()` 补一段底部空白
   （值由 `Index` 按当前布局写入 `AppStorage`，平板无底部 dock 时为 0）。
2. **内容稀疏的页面内浮层**（`GlassOverlay` 的 `GLASS` 材质，默认）：
   课程编辑 / 周次与日期滚轮 / 提前量选项 / 体系要求学分编辑 / 重新验证弹窗。
   条件是浮层容器**本身**必须是页面内容层的后序兄弟，透镜上溯一层才能取到内容。

**不用的地方**（都实测过，不是保守起见）：

- **侧栏与顶栏**：背后没有可折射的兄弟层。补一层取样层也救不回来 ——
  真机日志显示截帧区域宽 424 而侧栏是 200vp，量纲对不上，SDK 判越界，
  连续 900+ 条 `snapshot fail 401`，玻璃一格都不画。这两处退回
  `backgroundEffect` 磨砂（`GlassKit.panelEffect()` / `barEffect()`）。
- **内容密集的浮层**（校历月历网格 + 作息表、课表页的学期选择、
  节次作息编辑表单、校历来源编辑）：AppleUI 的模糊是 16 点 Vogel 盘采样，
  密集小字会被复制成 16 份鬼影 —— 实测（14vp / 48vp 两档）都无法让这种内容
  变清楚。这些浮层用 `PanelMaterial.SYSTEM`（不透明 surface + 圆角 + 投影 +
  整屏压暗），与系统弹窗一致。
- **系统弹窗框架（CustomDialogController）自建的弹窗**：没有可用的前序兄弟。

---

## 7. 现在的方案与建议

- **手机端 dock 与内容稀疏的页面内浮层用系统沉浸材质**（`GlassKit` 的
  材质路径）：设备 API ≥ 26 且能力探测通过时挂 `systemMaterial`
  （dock 用 `THIN`、面板用 `REGULAR`），否则一律退化为磨砂
  （`backgroundEffect` + 高光细边 + 投影）。探测走
  「版本号 → `await import('@ohos.arkui.uiMaterial')` → 能力函数」，
  与 `OcrProbe` / `CaptchaModel` 同一条路 —— **绝不能静态导入**该模块。
- **侧栏、顶栏、输入框底衬仍用磨砂**：它们背后是页面底色、没有内容穿过，
  玻璃（无论材质还是磨砂）透出来的都是纯色，挂上去只是多一层合成。
- **内容密集的浮层用不透明面板**（`PanelMaterial.SYSTEM`）：校历月历、
  作息表、学期选择等，密集小字与下层内容叠在一起无法阅读。
- **不做**：课表网格与长列表不加玻璃（两端同一决策：彩卡是内容载体，
  加玻璃既冲突又有性能代价）。
- **不再引入任何第三方玻璃库**：第三方原生库（只提供 arm64-v8a 的 .so）
  会把应用锁死在单一 ABI，丢掉模拟器与部分设备的安装能力 ——
  这笔账不划算，观感上系统材质已经够用。
