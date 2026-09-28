# hi山建 · 鸿蒙客户端

山东建筑大学强智教务系统的 HarmonyOS 原生客户端（Stage 模型 + ArkTS/ArkUI）。
适配手机、平板与折叠屏。

> 本应用为个人学习用途的第三方客户端，仅用于查询**本人**教务数据。
> 使用前请确认遵守学校信息安全规定。


### 已核实的接口清单

| 能力 | 端点 | 方式 | 关键参数 / 说明 |
|---|---|---|---|
| 登录页（建立 `/jsxsd` 会话） | `/jsxsd/` | GET | 取验证码前必须先走这一步，否则 Cookie 作用域不对 |
| 登录 | `/jsxsd/xk/LoginToXk` | POST | `loginMethod` `userAccount` `userPassword` `RANDOMCODE` `encoded` |
| 换取会话 | `/jsxsd/xk/LoginToXk?method=jwxt&ticket=<…>` | GET | 登录响应 `Location` 给出 |
| 验证码 | `/jsxsd/verifycode.servlet` | GET | 会话绑定，返回 `image/jpeg` |
| 学生端首页（会话探测） | `/jsxsd/framework/xsMain.htmlx` | GET | 被踢回登录页时返回登录页 |
| 课程表 | `/jsxsd/xskb/xskb_list.do` | GET/POST | `xnxq01id`（如 `2026-2027-1`）`zc`（**只提交纯数字**；`auto`/空是本地语义） |
| 成绩 | `/jsxsd/kscj/cjcx_list?kksj=<学期>` | GET | 学期写法如 `2025-2026 第一学期` |
| 成绩筛选页 | `/jsxsd/kscj/cjcx_query` | GET | 学期下拉来源（与列表页不是同一地址） |
| 个人信息 | `/jsxsd/bygl/bysxx` | GET | 「毕业生信息核对」，非毕业年级同样可访问 |
| 教学周历 | `/jsxsd/jxzl/jxzl_query` | GET | 周次↔日期对照；学期列表也来自这里 |
| 培养方案明细 | `/jsxsd/pyfa/topyfamx` | GET | `#dataList` 说明 + `#mxh` 课程设置总表（本校没有 PDF 附件） |
| 修读情况（原通选课） | `/jsxsd/xxwcqk/xxwcqkOnkctxBy.do` | GET | 「学习完成情况查看」单表（无课程明细）；与培养方案在**同一页**按课程体系对齐展示 |
| 体系修读明细 | `/jsxsd/xxwcqk/xxwcqkOnkctxByxq.do` | GET | `kctxmc=<体系裸名>`，8 列课程表；展开分组时按需拉取 |
| 空教室筛选器 | `/jsxsd/kbxx/jsjy_query` | GET | 校区 / 学期选项来源 |
| 空教室查询 | `/jsxsd/kbxx/jsjy_query2` | POST | 参数见 `QzApi.getClassroomUsageHtml`；**不传周次** |
| 教学楼联动（不可用） | `/jsxsd/kbxx/jsjy_processAjax` | GET | 本校一律返回「提示：非法访问！」，楼栋改由客户端推导 |



## 工程结构

```
hisdjzu/
├── AppScope/                       应用级配置与资源
├── build-profile.json5             target 26.0.0 / compatible 6.0.0(20)（含本机签名，不入库）
├── build-profile.json5.example     模板：复制成上面那份即可构建（含 release product）
├── oh-package.json5
├── hvigorfile.ts
├── signing/                        签名素材与脚本
│   ├── emu-sign-install.sh         模拟器专用：构建 + 签名 + 安装 + 启动
│   ├── make-emu-profile.mjs        生成绑定叶子证书与 UDID 的调试 Profile
│   └── *.p12 / *.cer / *.p7b       证书素材（由脚本生成，可再生；整个目录默认不入库）
├── testdata/                       离线测试（可离线跑）
│   ├── run-tests.mjs               657 条断言，直接运行仓库里的纯逻辑代码
│   └── fixtures/                   已脱敏的真实页面样本
└── entry/src/main/
    ├── module.json5                deviceTypes: phone/tablet/2in1；权限与 form 扩展声明
    ├── resources/
    │   ├── base/profile/form_today_course.json   桌面卡片配置
    │   └── rawfile/captcha_crnn.ms               验证码识别模型（约 27MB，ddddocr 转 MindSpore Lite）
│                                             （曾内置两张校历图，已删 —— 换学年会静默过期）
    └── ets/
        ├── entryability/EntryAbility.ets
        ├── widget/
        │   ├── TodayCourseFormAbility.ets        FormExtensionAbility
        │   └── pages/TodayCourseCard.ets         卡片 UI（不依赖主应用模块）
        ├── common/                 Constants、Logger、Result、ContextHolder、WindowService、UrlGuard、
        │                           WeekCalc、AuthRecovery、TextMeasure
        ├── crypto/QzEncoder.ets   登录加密（Base64 + %%%）
        ├── network/                HttpClient、CookieJar、QzApi
        ├── parser/                 HtmlLite + 8 个页面解析器（课表/成绩/个人信息/周历/培养方案/通选课/教室/校历公告）
        ├── model/
        │   ├── Models.ets                      课程/成绩/个人信息/周历/培养方案/通选课
        │   ├── CaptchaPrep.ets                验证码预处理（纯计算，有单测）
        │   ├── CaptchaVote.ets                候选选择与一致性投票（纯计算，有单测）
        │   ├── CaptchaCharset.ets             ddddocr 字符表（8210 类稀疏映射）
        │   ├── ReminderPlan.ets                上课提醒排期（纯计算，有单测）
        │   ├── CourseScheduleMath.ets          日历重复规则（纯计算，有单测）
        │   └── ClassroomModels.ets             空教室：周次说明解析与空闲判定（纯计算，有单测）
        ├── data/
        │   ├── PrefStore / AppState / CredentialStore / TimetableStore
        │   ├── SessionCookieStore.ets          会话 cookie 加密落盘（系统密钥库）
        │   ├── AcademicCalendar.ets            官方作息（内置兜底）+ 教务处信息公开入口
        │   ├── SemesterCalendarService.ets     教学周历 → 学期信息（周数/开学日）
        │   ├── CampusCalendarService.ets       校历公告抓取（用户填地址）
        │   ├── SectionTimeStore.ets            节次作息（可配置，含旧值迁移）
        │   ├── ClassNotifier.ets               提醒双通道（代理提醒 → 应用内）
        │   ├── ReminderService.ets             提醒配置与发布编排
        │   ├── OcrProbe.ets                    验证码 OCR（动态 import，隔离 HMS 依赖）
        │   ├── CaptchaModel.ets                ddddocr 训练模型端上推理（MindSpore Lite）
        │   ├── ReAuthService.ets               无感续期 / 限次重试 / 重新验证编排
        │   ├── CardSnapshotStore.ets           桌面卡片数据快照（周级载荷）
        │   ├── CardPusher.ets                  主动更新已添加的卡片（动态 import formProvider）
        │   ├── FormIdRegistry.ets              已添加卡片的 formId 落盘
        │   ├── ElectiveRequirementStore.ets    通选课要求学分（用户自录，按账号分片）
        │   └── PageCache / ProfileService / AvatarStore
        ├── theme/Theme.ets
        ├── theme/GlassKit.ets                  玻璃参数与材质选型（系统沉浸材质 / 磨砂降级）
        ├── theme/MaterialProbe.ets             系统沉浸材质的构造（动态 import，隔离 uiMaterial 依赖）
        ├── components/GlassOverlay.ets         页面内浮层外壳（玻璃 / 系统两种材质）
        ├── components/SemesterPickerDialog.ets 学期滚轮（成绩页与课表页共用）
        ├── components/SemesterMonthGrid.ets    自绘月历
        ├── components/CalendarSheet.ets        校历与作息表
        ├── components/ReAuthDialog.ets         会话失效后的按需重新验证弹窗
        ├── components/StateViews.ets
        └── pages/                  Index(外壳)、Login、Schedule、Score、Plan、Profile、Settings、Classroom
```

