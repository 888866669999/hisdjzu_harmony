# hi山建 · 鸿蒙客户端

山东建筑大学强智教务系统的 HarmonyOS 原生客户端（Stage 模型 + ArkTS/ArkUI）。
适配手机、平板与折叠屏。

> 本应用为个人学习用途的第三方客户端，仅用于查询**本人**教务数据。
> 使用前请确认遵守学校信息安全规定。

## 上手先看这里

| 你想做什么 | 去哪里 |
| --- | --- |
| 装到自己的手机上 | 见 [构建与运行](#三构建与运行) —— 需要一个未签名包 + 你自己的华为证书 |
| 看看这个应用长什么样 | 「零、验证状态」有完整的功能清单与验证结论 |
| 找接口是怎么实现的 | 「一、重要前提」起 —— 接口、加密、会话都逐条核对过 |
| 遇到问题想自查 | 「七、已知限制」列了**所有已知不工作的地方**，多数是系统能力限制而非 bug |
| 想跑测试 | `node testdata/run-tests.mjs`（离线，不需要登录） |

本仓库**不含**发布用的构建产物（HAP 走 Releases 页附件）。发布包是**未签名**的 ——
签名必须绑定你自己的开发者证书与设备，别人的证书签出来的包你装不上，
而把私钥放进公开仓库是严重的安全事故。签名步骤见构建章节。

本仓库已做过开源前清洗：不含任何真实个人信息（`testdata/fixtures/` 是重新脱敏过的
真实页面样本，姓名/学号均为示例值）。若你要自己抓取测试语料，
注意 `testdata/raw/` 与 `screenshots/` 会含真实姓名与学号 ——
`.gitignore` 已把**整个 `testdata/`** 与 `screenshots/` 排除（不是逐个列举子目录，
早先只写 `/testdata/raw` 时 `fixtures/` 漏在外面），切勿提交。

---

## 零、验证状态

> **测试环境**：以真机 **MatePad 11.5 S（API 24）** 为主，模拟器（API 20 平板
> 2560×1600）为辅。两者签名互斥：真机需华为签名，模拟器需 OpenHarmony 签名，
> 见「三、构建与运行」。

已在 **HUAWEI MatePad 11.5 S（真机，API 24，2800×1840）** 与
**API 20 平板模拟器** 完成端到端验证：

| 项 | 结果 |
|---|---|
| 一键构建 + 签名 | 通过，签名校验 `Verify success` |
| 登录（真实账号 + 验证码） | 通过，先取 `/jsxsd/` 建立作用域会话；`ticket` 重定向后会话就绪 |
| 课表 | 13 个课程格 / 14 条安排（一格两段换教室），5 个大节行完整渲染 |
| 课表单双周过滤 | 通过，单/双周课按周次正确显隐 |
| 成绩 | 夹具 23 门 / 48 学分；平均绩点由 `(分数−50)÷10` **简单平均**算出（页面「绩点」列整列为 0，不读它） |
| 个人信息 | 通过，「毕业生信息核对」页（夹具片段：8 字段 / 1 分组；证件类字段按敏感词剔除，不展示不缓存） |
| 平板分栏布局 | 左导航 + 右内容正常 |
| 手机两步登录 + 键盘避让 | 通过，输入框不被键盘遮挡 |
| 记住账号密码（系统密钥库） | 通过，重启后自动回填 |
| 登录态持久化 | 通过，杀进程重启后无需重新登录 |
| 课表本地编辑 + 持久化 | 通过，改课程名/教室后重启仍保留 |
| 无成绩学期空态 | 通过，筛选栏保留，可继续切换学期 |
| 下拉选中态与持久化 | 通过，标记跟随当前项，选择被记住 |
| 当前周自动定位 | 通过，按开学日期与系统时间推算，6 小时对齐 |
| 培养方案明细 | 通过，课程设置总表按「课程体系」分组（夹具片段：18 门 / 2 体系 / 16.5 学分 / 188.5 学时；服务端塞在 HTML 注释里的重复表被剥离） |
| **培养方案 × 修读情况（合并页）** | 通过，两组数据按归一后的体系名对齐成一张卡片列表：门数/学分、应修/已修/在修、进度条、「设置要求学分」；展开分「培养方案课程」与「修读记录」两段（修读明细按需拉取详情页）。一边失败只给非阻塞提示，另一边照常显示 |
| 修读情况数据源（无独立页） | 通过，「课程体系 → 要求/已修/正修读学分」解析正确（夹具 11 个体系 + 「总计」22.0 / 21.0），作为**合并页的第二组输入**使用；本校**没有课程明细**（每行的「详情」是另一个页面，展开分组时才去抓）。独立页与 `elective` 路由已删除 |
| **官方校历 + 作息表** | 通过，课表页顶栏可查看教学周历与日常教学时刻表；作息自动从**课表页**同步；校历附件（PDF）由用户填写公告页地址后抓取，离线退回缓存 |
| **作息时间按官方值** | 通过，5 个大节 07:50 / 09:40 / 13:40 / 15:30 / 18:40 起；内置旧值（08:00 起）由迁移逻辑丢弃 |
| **开学日期自动对齐教学周历** | 通过，用户没手动设过时自动取第 1 周周一（2026-09-07），手动设过的永不被覆盖 |
| **上课提醒（应用内通道）** | 通过，日志确认 `class notified:`，双通道自动降级 |
| **桌面「今日课程」卡片** | 通过，可添加至桌面并正确渲染日期与空态；改课表后由 `CardPusher` 主动推送更新 |
| **空教室查询** | 通过，实测该校区 231 间教室；空闲按**周次 + 星期 + 大节**逐格判定 |
| **培养方案（闪退已修复）** | 通过，进入培养页不再闪退；合并页两个来源各自独立加载，一边失败不影响另一边 |
| **健壮性回归** | 通过，7 个页面逐一切换均无崩溃 |
| **只看课表不打扰** | 通过，会话失效时启动仍纯离线渲染课表，无网络请求、无弹窗 |
| **按需重新登录** | 通过，有凭据只需补验证码；无凭据弹出完整账号密码表单 |
| **失效会话端到端** | 通过，把本地会话改成无效值后重启：课表照常离线渲染且无弹窗；点空教室才弹居中验证码框，补验证码后登录成功、原请求自动续跑 |
| **空教室星期高亮** | 通过，今天用蓝色描边、选中项用蓝色填充，切换星期不再残留蓝色 |
| **课表空白格无加号** | 通过，空白格与整行无课的节次（本校 2026-2027-1 夹具里是**第一大节整行**）均无任何占位符，点空白格仍可添加 |
| **验证码识别（实机实测）** | 通过，端上训练模型（ddddocr）**11/12 ≈ 92%**；系统通用 OCR 仅作兜底，42%（5/12） |
| 解析器回归测试 | **657 条断言全通过** |

### 实机与模拟器验证中发现并修复的真实缺陷

1. **会话建立失败**：HarmonyOS `http` 的 `res.cookies` 返回的是 **Netscape cookie 文件格式**
   （TAB 分隔，`#HttpOnly_域名 \t FALSE \t / \t … \t JSESSIONID \t 值`），
   按 `name=value` 解析会把整串当成一个 cookie 名，导致 `JSESSIONID` 从未进入 `Cookie` 头。
2. **登录被判定为失败**：登录成功后服务端不直接返回页面，而是以 **404 + `Location: /jsxsd/xk/LoginToXk?method=jwxt&ticket=…`** 下发一张 **`ticket`**；必须再访问该地址才能换成学生端会话。因此「非 200 即失败」的判据在这里是错的，登录成功恰恰依赖这个 404 + `Location`。
3. **门户首页被误判为登录页**（移植源侧实测，判据仍沿用）：`xsMain.jsp` 内含供管理员切换的
   `loginForm1`（字段名是小写 `useraccount`），原来的不区分大小写匹配把它当成登录页，
   导致登录成功后仍报错。改为「必须有密码输入框 + 验证码或 encoded 字段」双重判据。
   实测本端的登录页与未登录时的 `xsMain.htmlx` 都满足该判据，而被踢回登录页时
   正文确实是登录页，判定正确。
4. **课表同一门课重复渲染**：课程格内 `kbcontent1`（简略）与 `kbcontent`（详细）
   **各含全部课程**，原来按整个单元格切分短横线，导致每门课被拆成两份。
   改为先选定一层，再在该层内切分。
5. **成绩行错位**：某行「序号」与「学分」都是 `2`，渲染成两个完全相同的 `<td>2</td>`；
   原来用 `indexOf` 给单元格排序，相同字符串返回同一位置导致顺序错乱。
   改为从左到右单次扫描。同时改为**按表头文本定位列**，不再依赖固定列序。
6. **手机端键盘遮挡输入框**：登录表单原为居中 Scroll，键盘弹出时内容无法让位，
   输入框被顶出屏幕。改用 `KeyboardAvoidMode.RESIZE` + 可滚动布局。
7. **课表多门课格子被裁切**：行高写死 92vp，一格两门课时内容溢出被裁。
   改为按每行内容估算高度（取该行 7 天中最高的一格），卡片按课程名散列配色。
8. **保存后界面不刷新**：`ForEach` 的 key 未随内容变化，ArkUI 复用旧组件树。
   给每门课加内容版本号 `rev`，编辑后自增使 key 变化，强制重绘。
9. **「已修改」一键清除所有本地修改**：原设计点一下就把本地编辑全删掉，容易误触。
   改为二次确认，并明确告知会重新从教务系统获取。
10. **同一时段无法追加课程**：原来只有 chip 行在「多门课」时才显示，
    单门课的格子没有添加入口；且 × 与切换选中项共用一个点击区域，点 × 无法删除。
    改为 chip 行常显、+ 常驻、× 独立可点；删除到空时补一条空草稿保证表单可用。
11. **没有成绩的学期整页空白**：筛选栏原来挂在 `records.length > 0` 条件下，
    导致切到无成绩的学期后连学期下拉都消失，用户无法切回。
    改为筛选栏始终显示，空数据走空态提示。
12. **PDF「上一页」按钮永久置灰**：`@Builder` 的参数是**按值传递**的，
    按值传参的 Builder 只在首次构建时求值，之后状态变化不会重算。
    原来把判断结果 `this.pageIndex > 0` 当作参数传给 `toolButton(...)`，
    首次构建时 `pageIndex` 还是 0，于是按钮被永久冻结成灰色；
    而页码文本直接写在 Row 里所以能正常更新，形成「数字在变、按钮不动」的假象。
    改为按钮全部内联、直接引用 `this.*` 以获得响应式更新。
13. **真机安装被拒（`fail to verify pkcs7 file`）**：OpenHarmony 的调试证书
    （`OpenHarmony.p12` 链）只能用于模拟器，华为真机不认；自签 profile 还缺
    `app-identifier`、`issuer` 也不是 `app_gallery`。真机必须用**华为签发**的
    debug profile。本工程已由 DevEco「自动签名」生成 `default_hisdjzu_*.p7b`
    （含本机 UDID 授权），因此真机包要用 `hvigorw assembleHap` 构建
    （它会自动读取 `build-profile.json5` 的 signingConfigs 完成华为签名）。
14. **模拟器安装被拒（`9568332 install sign info inconsistent`）**：与第 13 条相反，
    模拟器只认 OpenHarmony 证书链。自签时还有两个坑：
    (a) Profile 里内嵌的 `development-certificate` 必须与 `app.cer` 的**叶子证书
    完全一致**，而 SDK 模板里内嵌的是另一张，直接用会导致签名信息不一致；
    (b) 模拟器上可能残留用另一套证书装过的同名应用，必须先 `uninstall` 再 `install`，
    否则 `-r` 覆盖也会因签名不一致失败。见 `signing/emu-sign-install.sh`。
15. **内置作息时间与学校官方不符**：早先内置的默认值是「08:00 / 10:00 / 14:00 / 16:00 / 19:00 起」
    这套参考时间，而本校课表页行首格给出的官方时刻是 **5 个大节：
    07:50-09:25 / 09:40-12:05 / 13:40-15:15 / 15:30-17:05 / 18:40-21:05**
    （节次命名也从「第一、二节」变成「第一大节」）。由于作息决定上课提醒的触发时刻，
    这套错值会让所有提醒整体偏移。已改为官方值，并加了「旧值自动丢弃」的迁移逻辑
    （只丢弃与旧默认值完全相同的落盘值，真正的用户自定义不受影响）。
16. **硬编码校历换学年就静默过期**：早先 `AcademicCalendar` 里手抄了一份校历数据
    （开学日、总周数），设置页还配了「官方校历一键采用」。它的失效方式很危险 ——
    换学年后日期就是错的，而界面上完全看不出来，用户会照着过期日期安排行程。
    已整份删除，改由教务系统「教学周历」（第 N 周 ←→ 周一日期对照表）**实时**提供：
    开学日期在用户没手动设过时自动补全（2026-2027-1 取到 2026-09-07），
    当前周、周次选择器上限、末周日期全部由它推导（本校本学期 22 周）。
17. **验证码路径少了 `/jsxsd` 前缀，症状是「验证码永远错误」**：
    只请求 `/verifycode.servlet` 也能拿到 cookie，但那个 cookie 的作用域是 `Path=/`；
    而登录接口在 `/jsxsd/xk/LoginToXk` 下，浏览器按路径匹配发送 Cookie 时不会带上它 ——
    服务端每次都判定「会话与验证码对不上」。界面只显示「验证码错误」，
    完全看不出是路径作用域的问题。已改为：先 GET 一次 `/jsxsd/` 登录页建立 `/jsxsd`
    作用域的会话，再取 `/jsxsd/verifycode.servlet`（见 `QzApi.fetchCaptcha`）。
18. **跨周时单双周判断错误**：上课提醒的 7 天窗口若跨到下一周，
    原来整段窗口都用「今天」的周次做单双周过滤，会把下周（单周）的课漏掉。
    改为**逐日各自算周次**，并加了回归测试锁住。
19. **实况窗（灵动岛）在本机不可用 —— 参数与权益两回事**：`startLiveView` 最初返回 401，
    用参数矩阵在真机上逐项试出真实的必填项：
    (a) `primary.clickAction` 必填，且 `actionFlags` 必须含 `CONSTANT_FLAG`
    （只给 `UPDATE_PRESENT_FLAG` 时语义是「替换既有 agent」，无既有 agent 就无效）；
    (b) `primary.layoutData` 必填，且 `layoutType` 不能是 `LAYOUT_TYPE_DEFAULT(-1)`，
    必须是真实模板且补齐该模板的必填字段；
    (c) `capsule.backgroundColor` 必填。
    补齐后参数校验**全部通过**，错误变为 `1003500005`（未开通实况窗权益）——
    这是账号与签名层面的事，需 AGC 按场景申请并由华为签发正式证书，
    调试证书无法获得。因此本应用**已移除实况窗**，改用普通高级提醒。
20. **空教室查询不能依赖服务端的周次筛选**（做该功能时实测发现，影响正确性）：
    `kbxx` 教室查询的 `zc`/`zc2` 参数有三个问题：
    (a) 课程类占用会被过滤，但「被借用」记录**完全无视周次**——
    第 2 周的借用记录在任何一周都会出现；
    (b) 按周筛选后，**该周没有任何占用记录的教室会被整行丢掉**
    （实测：不筛 231 间，筛第 4 周只剩 196 间，筛第 10 周 225 间）——
    而这恰恰是「找空教室」最需要的那批教室；
    (c) 传单个节次组合时表头是 8 列，传跨组合时会膨胀成 5 组 × 7 天 = 36 列。
    因此改为：**查询不传周次**，拿回完整教室表与全学期占用文本，
    再由客户端按单元格里的周次说明逐格判断（`model/ClassroomModels.ets`）。
    这样语义统一，也不会漏掉真正空闲的教室。
21. **重新登录弹窗漏恢复密码，导致「验证码怎么输都登不上」**：
    重写重新登录弹窗时，`start()` 只从密钥库恢复了账号、漏了密码，
    于是提交时密码为空。服务端返回的原文是
    `用户名或密码为空!`（靠新增的日志才看到），
    而界面上只表现为「验证码不对」，极难定位。
    已修：恢复密码；并在提交前加前置校验 —— 账号或密码缺失时直接提示、
    并把表单切到对应步骤，而不是把空值发给服务端。
    教训：**这类"输入被静默丢掉"的问题，必须靠服务端原始报错来定位**，
    所以 `QzApi` 现在会把登录被拒时的服务端原文打进日志。
22. **课表缓存按账号命名，账号丢失就找不到缓存**：
    课表缓存文件是 `timetable/<账号>_<学期>.json`，找到它需要先知道账号。
    但账号此前只写在 `AppStorage`（内存）里，`PrefStore.saveAccount()`
    虽然定义了却**从未被调用**（死代码），冷启动后账号即丢失。
    结果是：明明本地有课表，却因为拼不出文件名而判定"无缓存"，
    转而去请求服务器 —— 会话恰好失效时就会弹登录框，
    完全违背"只看课表不该被打扰"。
    已修：(a) 登录成功后把账号落盘；(b) `TimetableStore.findAccountForSemester()`
    按学期扫描缓存目录反查账号；(c) 连学期都没记住时用 `cachedSemesters()`
    从目录里列出，目标是**只要本地有课表就一定读得到**。
23. **并发查密钥库导致主线程卡死（appfreeze THREAD_BLOCK_6S）**：
    启动阶段 `Index.restore()` 与 `verifySessionInBackground()` 会
    同时调用 `CredentialStore`，两路并发打同一个 AssetStore 接口时应用无响应。
    已按 `PrefStore.init` 同样的思路修：**共享同一个 Promise** 让并发调用只发一次查询，
    并把结果缓存在内存里（凭据只由本应用的 save/clear 改动，改时主动失效）。

#### 移植到本校时新发现并修掉的缺陷（与移植源的数据形态直接相关）

24. **登录流程照搬移植源（握手 + 按位插字符），登录永远失败**：移植源是
    `POST /Logon.do?method=logon&flag=sess` 拿 `scode#sxh` 再按位插字符；
    本端走的是另一个入口 `/jsxsd/xk/LoginToXk`，它**没有握手**，
    `encoded` 就是 `Base64(账号) + '%%%' + Base64(密码)`。
    照搬的结果是服务端回一句通用的「用户名或密码错误」，看不出是编码方式错了。
    表单字段还必须与页面逐字对齐：隐藏字段 `loginMethod=LoginToXk` 不能少，
    `userPassword` 要原样提交（留空会被回「账号或密码不能为空」—— 实测踩过）。
25. **成绩页「绩点」列整列是 0**（学校没录入）：直接读它会让每科显示 0 绩点、
    平均 0.000 —— 看着完全正常、数字却全错。已改为由分数自算 `(分数 − 50) ÷ 10`
    （60 分 = 1.0、90 分 = 4.0），汇总取**各科简单平均**（**不是**学分加权，
    与 Flutter 端同一口径）；「优秀/良好」这类非数字成绩跳过、不参与平均。
    同时把列定位改为按表头文本（本校 16 列，且列序与移植源不同），找不到的列返回 −1
    而不是退回位置下标 —— 退回下标会把「辅修」显示成「考试」。
26. **培养方案页把整张课程表在 HTML 注释里重复了一遍**：不剥注释会多读 7 条假课程，
    分组名还会冒出「32」「8」这类学时数字（`HtmlLite` 现在统一剥注释）。
    另外本校课程表是 **15 列**（比移植源多「完成情况 / 课程性质 / 课程属性」），
    按固定偏移读会把课程名读成「素质拓展必修课」（同一串重复 13 遍）。
    已改为列位置一律从**两行表头**推导、数据行从右往左读（左侧列数因 rowspan 不固定）。
27. **空教室：服务端教学楼联动端点被整体关闭**：`jsjy_processAjax` 无论怎么组合请求头
    （裸请求 / `X-Requested-With` / jQuery 的 JSON `Accept` / 带发起页 `Referer` / 去掉 `Origin`），
    一律返回 736 字节的「提示：非法访问！」。楼栋筛选因此改在**客户端**从教室名推导
    （`博文馆407` → `博文馆`）。另外移植源的 `jszt=8`（完全空闲）不能沿用 ——
    那等于让服务端去筛，实测全校区只剩 1 间；现在查询不传周次、不传状态，
    取回全学期占用后由客户端按 `bySection[day][section]` 逐格判定（移植源是「只按天」，
    节次筛选形同虚设）。
28. **课表加了课，桌面卡片不变**：主应用写完快照不等于卡片会刷新 —— 已经渲染着的卡片
    只认 `formProvider.updateForm(formId, data)`，而改造前全仓库**没有任何一处**
    从主应用调用它（唯一的调用在 `FormExtensionAbility.onUpdateForm`，
    由平台的周期刷新触发，本应用 `updateDuration=1`，最短约 30 分钟且是批量调度）。
    已新增 `FormIdRegistry`（formId 落盘）与 `CardPusher`（动态 import 推送），
    课表加载/编辑、进入前后台时主动推。
29. **会话 cookie 明文躺在 preferences 里**：`JSESSIONID` 是「持有即可用」的凭据，
    而实测 `hdc shell cat .../preferences/sdjzu_jw_pref` 能直接打印出原文；
    当时备份开关还是开的，整个沙箱会进系统备份。已把会话 cookie 迁到**系统密钥库**
    （Asset Store，`DEVICE_FIRST_UNLOCKED`，见 `SessionCookieStore`），
    preferences 里的旧明文读到即迁移、随即抹除，并把 `allowToBackupRestore` 关掉。
30. **课表换了学校就整页解析不出来**：本校表 id 是 `#timetable`（移植源是 `#kbtable`），
    写死单一 id 的表现是「暂无数据」而不是报错；周次写法也复杂得多 ——
    `2,4,6,8(周)`（隔周）、`1-8,13-16(周)`（分段）、`3(周)[06-07节]`（尾巴带节次），
    旧实现只认 `a-b` 或把节次数字吞进周次，结果是「课表漏课 / 课在错误周次出现」。
    教室写作 `博文馆511[媒159]`：方括号里是校内编码（媒 = 多媒体），不是校区，必须丢掉；
    而课名里的数字（「碳中和与碳循环（能创25）」）绝不能被当成教室（宁可没教室，不能给错教室）。

#### 下拉列表选中态与持久化

`Select` 组件不会自动跟随 `.value()` 显示选中标记，必须显式传 `.selected(index)`。
原实现写死 `.selected(0)`（成绩页）或未传（课表学期），
表现为「蓝色选中标记永远停在第一项」。已改为按当前值计算索引。

后来成绩页与课表页的**学期**选择整个换成了自绘滚轮
（`SemesterPickerContent`）：真机上 `Select` 展开的列表**被窗口底边截断且不能滚动**
（教务返回 40+ 个学期，只画到第 9 项，更早的学期既看不到也点不到），
且浮层材质/圆角/关闭方式都不由我们控制。空教室页的四个筛选器仍是 `Select`，
那里选项少、且必须显式 `.selected(...)`（同样的选中态问题）。

同时把各页面的选择写入 preferences，下次进入沿用上次选择：
课表周次（`last_timetable_week`）、成绩学期（`last_score_semester`）。

#### 登录态持久化（切后台/杀进程后无需重新登录）

这一项踩过一个很隐蔽的**异步初始化竞态**，值得记录：

```
EntryAbility.onCreate  → PrefStore.init() 开始（await 中）
        ↓ 约 200ms 后
onWindowStageCreate    → Index.restoreSession() → PrefStore.loadCookie()
                         此时初始化尚未完成 → 读到空值 → 判定未登录 → 跳登录页
```

根因是 `init()` 里用「正在初始化」的**布尔标志**做重入保护：
并发的第二个调用者看到标志为真就**直接返回而不等待**，
于是 `store` 仍为 `null`，读 cookie 得到空串。
改为共享同一个 **Promise**，后到的调用者会 await 同一次初始化。

同时修正了会话校验策略，避免其它情况误踢用户：

- **乐观恢复**：只要有已保存的 cookie 就立刻进入主界面，不等服务器校验；
- **退到后台时把内存中的会话写回本地**，因为服务器可能在交互中轮换过 JSESSIONID。

#### 会话失效的处理：按需重新登录，课表浏览永不打扰

这是本轮的重点设计。会话过期了该怎么办，取决于**用户此刻是否真的需要联网**。

**后台校验不再踢人。** `verifySessionInBackground()` 无论会话是否失效、
有没有保存凭据，都**不退出登录、不弹窗**，只记一条日志。原因是课表可以纯离线渲染：
用户如果只是想看课表，就不该被打扰。

**失效的后果推迟到真正需要联网的那一刻。** 只有当请求真的被服务端打回登录页时
（`QzApi.ensureAuthed` 检测到返回的是登录页），才置
`AS_REAUTH_PENDING` 标记，由 `Index` 在**当前页面之上**弹出居中弹窗
（`ReAuthDialog`），页面与浏览位置都保持不变。弹窗分两种形态：

| 情况 | 弹窗形态 | 用户要做的事 |
|---|---|---|
| 密钥库里**有**账号密码 | 只需验证码；先自动尝试无感登录 | 设备能识别时**无感**，否则输 4 位验证码 |
| 密钥库里**没有**账号密码 | 完整登录表单（账号 → 密码与验证码**同框**） | 登录，可勾选「记住账号密码」以便下次无感 |

**优先无感续期。** 有凭据时先探测端上推理能力（`SystemCapability.AI.MindSporeLite`），
支持就动态 `import()` 加载 `CaptchaModel`（**不静态导入**，避免重演 PDF 那个
"缺失 HMS 导出导致模块加载期硬崩"的坑），模型不可用时再降级到系统 OCR
（`canIUse('SystemCapability.AI.OCR.TextRecognition')` + 动态 `import()` `OcrProbe`），
成功即静默登录；都不支持或识别失败则降级为手动输入。
识别细节与**实测识别率（端上模型 11/12，通用 OCR 5/12）**见
「验证码识别」一节 —— 它不是万能的，仍会失败，所以必须保留重试与手动退路。

**失败重试。** 交互路径最多自动提交 3 次（只在「验证码类失败」时换图重试，
凭据错则立即停止，避免拿错密码反复 POST 触发锁定）；失败后弹窗显示的是
**OCR 所用的同一张图**并预填识别结果，用户只需改错的那一位，
也可以点「重新尝试自动识别」或直接手输。

**启动时的静默续期只试 1 次**（不重试）：那属于「用户没在等」的场景，
多打请求只会平白增加风险（周期性自动登录的方案 —— 会话保活 —— 已从应用中移除，
见「已知限制」与第十节 P1-5）。

**页面不重复报错。** 会话失效时页面会跳过错误态
（`AppError.isAuthExpired(e) ? '' : msg`），否则弹窗背后会露出
「登录状态已失效 + 重试」，与弹窗形成两条互相冲突的提示。

> 为什么不用 OCR 之外的"自动登录"：验证码正是用来区分人和脚本的。
> 服务端也没有开放任何免验证码的接口，因此**能做到的上限就是
> "识别成功则无感、失败则降级手动"**，无法保证 100% 免输入
> （OCR 对扭曲字符与易混字符如 `1/l`、`0/O` 的识别不可能总是正确）。

#### 培养方案页：已删除 PDF 附件链路（本校没有附件）

早先培养方案页带「下载附件 + 交给系统阅读器」的入口（`PdfStore` 复用
`HttpClient` 把 `/ewebeditor/uploadfile/xxx.pdf` 拉到沙箱、校验大小与 `%PDF`
魔数，再转文件共享 URI 交给系统打开；缓存按「账号 + 路径」散列命名）。
**实测本校的培养方案页里 `uploadfile` / `.pdf` / `附件` 均不出现** ——
那是上一所学校的功能，整套链路（`data/PdfStore.ets`、`PlanDetail.pdfPath`、
`PlanParser.parsePdfPath`、PlanPage 的 PDF 卡片与 `fileUri`/`DocumentViewPicker`
保存代码）已在合并改版时整块删除。Flutter 端（Android）同步删除。

（**校历附件是另一个功能**：用户填写的公告页里挂的 PDF，由
`CampusCalendarService` 逐跳校验后下载、`CalendarSheet` 交给外部应用打开 ——
那条链路保留。）

**为什么当初还删掉了内嵌预览（走过的弯路）**

早期实现有两个阶段，都放弃了：

1. 用 `@kit.PDFKit` 的 `PdfView` + `pdfViewManager`。SDK 类型声明里有这些名字，
   所以**能编译通过**；但缺 HMS PDF 服务的设备上（如 OpenHarmony 模拟器），
   `@hms:officeservice.PdfView` 模块并不提供 `pdfViewManager` 这个具名导出，
   模块图加载阶段直接抛错：

```
Reason: SyntaxError
the requested module '@hms:officeservice.PdfView' does not provide an export
name 'pdfViewManager' which imported by '&entry/src/main/ets/components/PdfViewer&'
```

   这类错误发生在**模块求值时，try/catch 拦不住**，还会把引用它的 PlanPage
   一起打崩 —— 表现是「一进培养方案就闪退」，且只在**缺该能力的设备**上出现。

2. 改成只依赖 `pdfService`、自绘 `PdfViewer`（逐页 `getPagePixelMap` 渲染成位图 +
   缩放 + 翻页 + 全屏，近 600 行）。它确实能跑，但代价与收益不成比例：
   依赖特定设备的 `SystemCapability.OfficeService.PDFService.Core`、
   位图要驻留内存（几百页的方案在低内存设备上会被系统杀掉）、
   而且做出来的体验（搜索、跳页、批注都没有）远不如系统阅读器。

`PdfViewer.ets` 先被删除，最后连同上面那套「下载 + 交付」代码一起删除。

#### 通选课修读情况（已并入培养方案页）

移植源（山财）那边**确实留空了「要求学分（大于等于）」列**（学校未录入），
若据此判断达标，会把「已修 8 学分」误判成「未达标」。
因此界面在该列为空时显示「学校未设置要求」，且不画进度条，只展示已修/在修学分。

**本校（山建）这一列是有值的**（夹具：首行 38 / 已修 14.0 / 正修读 9.5，
末行「总计」159.0 / 22.0 / 21.0），但那条「空值不当达标」的逻辑仍然保留 ——
判据只认「读到的值是否为空」，不假设哪所学校有值。

另外两条与移植源不同的产品行为：

- 本校页面是**单表**（`课程体系(属性) | 毕业要求学分 | 已修学分 | 正修读学分 | 毕业还需学分 | 详情`），
  **没有课程明细**（每行「详情」指向另一个页面，本应用在**展开某个体系时**
  按需去抓，放进合并卡片的「修读记录」小节）—— 主页本身只有「体系 → 要求/已修」一层。
- 列位置按**表头文字**定位（两校列数与列名都不同），写死列号会把
  「已修学分」显示成「毕业还需学分」—— 数字看着正常、结论完全相反。
- 汇总行本校写「总计」而非「总学分 / 合计」，它不是课程体系，单独取汇总值。

#### 与培养方案的合并（按课程体系）

两页的「课程体系」列都带装饰，直接比对必然不匹配：
培养方案侧是 `素质拓展必修课` + `<br>` + `(应修 10 / 已修 6.5)`（解析出两行），
修读侧是 `学科基础必修课(必修)`。因此加 `systemMergeKey()`：**取首行、去掉一层
尾部括号**（半角/全角都认，整串都是括号内容时保留原样），归一后按**严格相等**
配对 —— 不做模糊匹配（匹配错了会把两个不同体系的数据并到一起，比不匹配更糟）。
被剥掉的方案侧注记由 `planNoteOf()` 单独取出、单独显示（那是真实的应修/已修数字）。

`mergePlanAndElective()` 的三条规则：培养方案顺序为准；修读侧多出的体系追加在后
（**两边都不丢**）；同一归一名的分组只配第一个，其余不吞不并。
要求学分的**存储键仍用修读侧的原始名**（`学科基础必修课(必修)`）——
换成归一名会让用户已录的值全部失配（要重录一遍）。

页面结构：一个体系一张卡片（门数/学分、应修/已修/在修、学校给的 `(应修…)` 注记、
进度条、「设置要求学分」），展开后分「培养方案课程」与「修读记录」两段。
两个来源（培养方案页、修读情况页）**各自走缓存、各自报错**：一边失败只在列表
顶部给一条非阻塞提示，另一边照常渲染。

#### 当前周自动定位

- 设置页可配置「开学日期（第 1 周周一）」，日期选择器选择，存储于 preferences；
  若用户填的是非周一日期，会**自动归入该日期所在周的周一**，避免周次偏移。
- 进入应用/切换页面时与系统时间对齐一次；**每 6 小时才真正重算**
  （记录上次对齐时间戳，未超时直接复用），跨周后自动跟上。
- 课表页进入时自动定位到当前周；若用户上次选的正是当前周则沿用其选择。
- 未配置开学日期时提示「未设置开学日期，无法自动定位当前周」，并引导去设置页。
- 周次推算封装在 `common/WeekCalc.ets`（纯函数，不依赖任何系统 API），
  表头日期也由它精确计算，跨月/跨年不会出错。

---

## 一、重要前提：这个实例没有开放 JSON 接口

网上多数强智教务教程假设存在 `/app.do?method=…` 形式的 JSON 接口。
**经实测，`xjwgl.sdjzu.edu.cn` 上该入口返回「出错页面」，并未启用。**

本系统真实形态是经典的 `jsxsd` 服务端渲染页面，因此本客户端的数据获取方式是
**结构化 HTML 解析**（ArkTS 无 DOM，故自研了 `HtmlLite` 解析层）。

如果直接照搬网上教程的 `/app.do` 接口，会全部失败。

### 本校（山建）与移植源（山财）的关键差异

本工程是从山东财经大学的同款客户端移植来的。两校都用强智教务，但**页面形态差得很多**，
下面这些差异在代码注释与测试里都有逐条对照；移植时凡是照搬移植源的地方，几乎都失败过一次。

| 维度 | 移植源（山财） | 本校（山建） |
|---|---|---|
| 登录 | `POST /Logon.do?method=logon&flag=sess` 先握手拿 `scode#sxh`，再按位插字符 | 走 `/jsxsd/xk/LoginToXk`（**该入口无握手**）：`encoded = Base64(账号)%%%Base64(密码)` |
| 验证码 | `/verifycode.servlet` | `/jsxsd/verifycode.servlet`（**必须带 `/jsxsd` 前缀**，否则 Cookie 作用域不对） |
| 学生端首页 | `xsMain.jsp` | `/jsxsd/framework/xsMain.htmlx` |
| 课表表 id | `#kbtable` | `#timetable` |
| 节次 | 「第一、二节」等 2 小节一行（08:30 起） | 「第一大节」～「第五大节」，行首格自带时刻（07:50-09:25 …） |
| 课间 | 官网作息表给了 3 段课间 | 课表页**不给课间**，`OFFICIAL_BREAKS` 为空（大节之间的空档已含在起止时刻里） |
| 周次写法 | 以 `1-18(周)` 为主 | 逗号列表（隔周 `2,4,6,8` / 分段 `1-8,13-16`）+ 节次尾巴 `[03-04节]` |
| 教室写法 | `7-120(章丘)` | `博文馆511[媒159]`（方括号内是校内编码，不是校区） |
| 开学日 / 周数 | 2026-08-24 起共 21 周 | 2026-09-07 起共 **22 周**（由教学周历实时给出，不再硬编码） |
| 个人信息 | 「学籍卡片」`/jsxsd/grxx/xsxx`，表 `#xjkpTable` | 「毕业生信息核对」`/jsxsd/bygl/bysxx`，表**没有 id** |
| 成绩 | 列数 / 列序不同 | 16 列；「绩点」列**整列为 0**，由 `(分数−50)÷10` 自算、简单平均 |
| 培养方案 | 只有「类别」一列 | 15 列（多 完成情况 / 课程性质 / 课程属性），HTML 注释里还有一份重复整表 |
| 通选课 | 类别表 + 课程明细两张表 | 单表（**没有课程明细**），汇总行写「总计」 |
| 空教室 | `GET /jsxsd/kbcx/kbxx_classroom_ifr`，`#kbtable` 单行表头 8 列 | `POST /jsxsd/kbxx/jsjy_query2`，三行表头 36 列；教学楼联动端点返回「非法访问」 |
| 作息来源 | 学校官网有作息时刻表 | 教务处**没有**作息表（只发校历 PDF），作息来自**课表页行首格** |
| 校历 | 官网固定校历页（图片） | 教务处按年发公告、挂 **PDF 附件**，地址每年变 → 由用户填写 |

### 登录链路（与移植源不同：没有握手）

```
1) GET  /jsxsd/                                ->  建立**作用域为 /jsxsd** 的会话
2) GET  /jsxsd/verifycode.servlet              ->  验证码图（与登录同一会话）
3) POST /jsxsd/xk/LoginToXk                    ->  404 + Location: /jsxsd/xk/LoginToXk?method=jwxt&ticket=…
   （表单：loginMethod=LoginToXk / userAccount / userPassword / RANDOMCODE / encoded）
4) GET  <上一步的 Location>                     ->  会话就绪（学生端首页）
```

移植源用的那套握手至今仍挂在**根路径的旧门户**上（实测
`GET /` 的表单里还有 `Logon.do?method=logon&flag=sess` 与 `sxh` 插字符脚本），
但它属于另一个入口 —— 本应用走的是 `/jsxsd/` 的教学一体化平台，**没有握手**。
照搬旧门户那套会得到服务端一句通用的「用户名或密码错误」，看不出是流程错了
（详见「已知限制」第 2 条）。

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

### 登录加密算法（已逐字核对）

页面 JS 的真实逻辑：

```js
var code = encodeInp(userAccount) + '%%%' + encodeInp(userPassword);
userPassword.value = pwd;
```

`encodeInp` 就是标准 Base64（浏览器控制台验证过：
`encodeInp('12345678') === 'MTIzNDU2Nzg=' === btoa('12345678')`）。因此：

1. `encoded = Base64(账号) + '%%%' + Base64(密码)`，分隔符 `%%%` 是原文、不参与编码；
2. **没有握手**：不存在 `scode#sxh`，也不做按位插字符（那是移植源的算法）；
3. 页面**同时**提交原始 `userPassword`，本实现保持一致（留空会被回
   「账号或密码不能为空」—— 实测踩过）。

实现见 `crypto/QzEncoder.ets`。移植时曾直接照搬移植源的按位插字符算法，登录永远失败，
且报错只有服务端那句通用的「用户名或密码错误」。

### 会话

会话 cookie 是 `HttpOnly` 的 `JSESSIONID`，页面 JS 读不到（实测 `document.cookie` 为空），
因此必须从响应 `cookies`/`Set-Cookie` 取出，并在后续请求手动回填 `Cookie` 头。
实现见 `CookieJar.ets`；**落盘不走 preferences，而是走系统密钥库**
（`SessionCookieStore`，理由见第六节与缺陷第 29 条）。

### 课表页面结构

`#timetable`（移植源是 `#kbtable`；两个 id 都试，写死单一 id 会「暂无数据」而不是报错）：
第 0 行是 `星期一…星期日`；第 1–5 行是 **5 个大节**，**行首格自带起止时刻**：

```
第一大节 (01,02小节)      07:50-09:25
第二大节 (03,04,05小节)   09:40-12:05
第三大节 (06,07小节)      13:40-15:15
第四大节 (08,09小节)      15:30-17:05
第五大节 (10,11,12小节)   18:40-21:05
```

末行为备注（`#bz_td`），列出「教学安排中未排课表课程」。每个课程格内是两层同内容的
div（`kbcontent1` 简略 / `kbcontent` 详细），字段用带语义的 `<font title="…">` 承载：

```html
<font title="老师">陈曦王敏周彤</font>
<font title="周次(节次)">2,4,6,8,10,12,14,16(周)[03-04-05节]</font>
<font title="教室">博文馆511[媒159]</font>
```

- 同一格可含多门课，以**连续短横线**分隔；周次有 `(周)`、`(单周)`、`(双周)` 三种，
  且常见**逗号列表**（`2,4,6,8` 隔周、`1-8,13-16` 分段）与**节次尾巴**（`[03-04节]`）——
  取周次前必须先把 `(周)` 之后的内容切掉，否则节次数字会被当成周次。
- 方括号里是学校内部的教室编码（`媒159` = 多媒体，数字与容量相同），不是校区 —— 丢弃；
  校区只在 `楼名+房号(校区)` 形态里出现。课名里的数字
  （「碳中和与碳循环（能创25）」）绝不能被当成教室。
- 解析时**优先用 `title` 属性**（稳定），文本行启发式仅作兜底以兼容其他强智版本。

---

## 二、工程结构

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

## 三、构建与运行

### 环境

- DevEco Studio 26.0.0.461（下文以 `$DEVECO` 代指其安装目录）
- SDK：API 26（`$DEVECO/sdk/default`）
- `hvigorw` 6.26.1、`ohpm`、`hdc` 已在 PATH
- 兼容范围：`compatibleSdkVersion` 设为 `6.0.0(20)`，因此可在 API 20 及以上的
  设备/模拟器安装。已移除废弃的 `getContext()`（改用 `ContextHolder` 注入上下文；
  卡片进程另注入 `FormExtensionContext`）。

> **首次构建前**：把 `build-profile.json5.example` 复制成
> `build-profile.json5`，并按其中的说明填好签名素材
> （用 DevEco 的「Automatically generate signature」最省事）。
> 真实的 `build-profile.json5` 不入库 —— 它含本机绝对路径与签名口令。

### 只构建

```bash
hvigorw assembleHap --no-daemon
```
产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`

### 构建给真机用（华为签名，推荐）

```bash
hvigorw assembleHap --no-daemon
```

产物 `entry/build/default/outputs/default/entry-default-signed.hap` 已由 DevEco 的
**自动签名**（华为 debug profile，含本机 UDID 授权）签好，可直接安装：

```bash
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
```

> 真机必须用华为签发的 profile。OpenHarmony 自签链装不上去，
> 会报 `fail to verify pkcs7 file`。

### 构建未签名包（发布 / 给别人用）

HAP 不能像 APK 那样「未签名也能装」，但**分发时应该给未签名包** ——
签名必须绑定你自己的证书与设备，别人的证书签出来的包别人装不上，
而把私钥放进开源仓库是严重的安全事故。

为此 `build-profile.json5` 里并列了两个 product：

| product | 带签名配置 | 用途 | 产物 |
|---|---|---|---|
| `default` | 是（本机华为证书） | 本机装真机 | `entry-default-signed.hap` |
| `release` | **否** | 发布 / 给他人自行签名 | `entry-default-unsigned.hap` |

```bash
hvigorw assembleHap --mode module -p product=release -p buildMode=release --no-daemon
```

产物：`entry/build/release/outputs/default/entry-default-unsigned.hap`

> 为什么不做成 buildMode 开关：hvigor 把签名配置挂在 **product** 上
> （`signingConfig`），没有「按 buildMode 决定签不签」的选项；
> 而删掉 `default` 的 signingConfig 又会让本机没法再装真机。

拿到未签名包后自行签名（以 SDK 自带的 OpenHarmony 链为例，
真机请换成你自己的华为证书）：

```bash
java -jar "$DEVECO/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar" \
  sign-app -keyAlias <别名> -signAlg SHA256withECDSA -mode localSign \
  -appCertFile <你的.cer> -profileFile <你的.p7b> \
  -inFile entry-default-unsigned.hap -keystoreFile <你的.p12> \
  -outFile hisdjzu-signed.hap -keyPwd <口令> -keystorePwd <口令>
```

（这条流程实测可用 —— 签名成功；只是 OpenHarmony 链签出的包在华为真机上
会报 `9568257 fail to verify pkcs7 file`，真机需用华为证书重新签。）

release 产物整理进 `release/`（含 `README.txt` 与 `SHA256SUMS.txt`），
该目录**不入库**（见 `.gitignore` 里的说明）：二进制走 GitHub Releases 附件，
放仓库里是永久的历史负担，且容易与 Releases 页那份额外的版本混淆。

### 构建并签名（模拟器用）

真机与模拟器**必须用不同的证书**：

| 目标 | 证书 | 命令 |
|---|---|---|
| 真机（华为） | DevEco 自动签名的华为 debug profile | `hvigorw assembleHap` 后安装 `entry-default-signed.hap` |
| 模拟器（OpenHarmony） | SDK 内置 `OpenHarmony.p12` 链 | `bash signing/emu-sign-install.sh` |

模拟器脚本做六步（原因见脚本内注释）：构建、取设备 UDID、生成 app 证书链、
生成 profile 签名证书、生成并签名调试 Profile、签名并安装。

```bash
OPENHARMONY_KEYSTORE_PWD=<OpenHarmony.p12 的口令> \
  bash signing/emu-sign-install.sh 127.0.0.1:5555
```

> 口令由调用方通过环境变量传入，不写在脚本或任何文件里。
> `OpenHarmony.p12` 随 SDK 公开分发、口令也是公开值，脚本仍要求显式传入 ——
> 免得仓库里出现「看起来像密钥的硬编码串」，被误认为泄露。

第 5 步的关键是把 **app.cer 的叶子证书**写进 `development-certificate`
（`signing/make-emu-profile.mjs`），并绑定设备 UDID；SDK 模板里内嵌的是
另一张证书，直接用会报 9568332。第 6 步会**先卸载再安装** ——
残留的旧证书应用会让 `-r` 覆盖失败。

产物写在 `build/emu/`，**不覆盖** `entry-default-signed.hap` ——
后者是华为签名的真机包，被覆盖后往真机安装会静默失败。

签名用的根 CA / 子 CA 直接用仓库里的 `signing/oh-root-ca.cer`
与 `oh-sub-ca.cer`（SDK 内那两份的副本），不必每次从密钥库导出。

启动模拟器（需先在 DevEco 的 Device Manager 里下载 API 20 镜像）：

```bash
"$DEVECO/tools/emulator/Emulator.exe" -license accept
"$DEVECO/tools/emulator/Emulator.exe" -start Huawei_Tablet
"$DEVECO/tools/emulator/Emulator.exe" -list        # 查看已有实例
```

`signing/emu-sign-install.sh` 里的 `$DEVECO` 同样按 `DEVECO_HOME`
环境变量解析；没设时用脚本内置的默认值。

### 安装到设备

```bash
hdc install entry/build/default/outputs/default/entry-default-signed.hap
```

### 运行解析器测试

```bash
node testdata/run-tests.mjs
```

该脚本把 `entry/src/main/ets` 下的纯逻辑源码复制为 `.ts`，
用 SDK 内置的 TypeScript 编译后在 Node 中直接执行，并对
`testdata/fixtures/` 里**真实抓取的页面**跑断言（当前 **657 条全通过，0 失败**）。
`hvigor` 本身没有可用的无设备测试任务，所以用这种方式做回归。
覆盖范围：登录加密（Base64 + `%%%`）、Cookie（含 Netscape 格式）、HTML 解析（含注释剥除）、
课表/成绩/个人信息/周历/培养方案/通选课/教室课表等页面解析器、课表编辑模型、
周次推算（含跨月与跨年）、**官方作息**（5 个大节、无课间）、**课表页作息解析**
（大节时刻、全角/波浪线归一化、行数不足时拒绝映射、星期表头不误收）、
**校历附件解析**（CMS 下载接口 / `/__local/` 附件区 / `.pdf` 三类判据、
logo 与导航被排除、相对路径绝对化、发布时间），
**通选课按表头定位列**（要求/已修/正修读不错位、汇总行「总计」）、
**培养方案 × 修读情况合并**（体系名归一化 `systemMergeKey` 的四种装饰、
注记提取 `planNoteOf`、一边有一边没有都不丢、重名只配第一个、
要求学分留空时不画进度条、详情页 8 列按表头定位）、
**上课提醒排期**（逐日周次 + 单双周 + 提前量）、
**桌面卡片快照**、**课表 → 日历事件的重复规则**（单双周起点对齐；模块保留、纯计算单测）、
**空教室**（周次说明解析、单双周、空闲判定、教学楼筛选与排序、36 列映射）、
**出站请求安全**（`UrlGuard` 拒绝环回/私有/保留地址）、
**错误处理**（`AppError.describe` 对原生错误/普通对象/null 的健壮性，
含「旧写法会抛异常」的反证用例）、
**验证码识别结果清洗**（含 7 个实测验证码样本的原样还原）、
**验证码预处理与投票**（墨迹分数 / Otsu / 裁边 / 去噪 / 包围盒剔除）。

对引入 `@kit` 的数据层模块（如 `CardSnapshotStore`、`CourseScheduleMath`
所依赖的 `SectionTimeStore`），测试用轻量桩替换依赖，只测逻辑本身。

## 四、登录页设计

采用**两步渐进式**输入，降低单屏信息量：

1. 账号 → 2. 密码与验证码（**同框**：一个圆角容器装两行、共用背景边框，一次提交）

- 输入框统一为「长圆角胶囊」样式，**不带前置图标**
- 第 2 步的验证码行 = 输入框 + 图片，两者总宽与上方密码框完全一致
- **点击验证码图片自动刷新**（新图会重新自动识别）
- 进入第 2 步才取验证码：验证码与会话绑定，早取会因会话轮换而失效
- 「记住账号密码」复选框在验证码下方，**默认不勾选**
- 勾选后账号与密码写入**系统密钥库**（`@kit.AssetStoreKit`，属性
  `DEVICE_FIRST_UNLOCKED`），并非明文 preferences；取消勾选或退出登录会删除
- 未勾选时不保存密码；仅勾选状态下重启应用会自动回填
- 所有出现图形验证码的地方都**自动识别并填入**输入框（见第八节「自动填验证码」）

> 登录页只在「从未登录过 / 主动退出登录 / 没有可用凭据」时出现。
> 会话过期**不会**把用户送回这里，而是弹出居中弹窗按需补验证码
> （见「零、验证状态」里「会话失效的处理」小节），这样浏览课表不会被登录页打断。

键盘避让：登录页所在页面设置 `KeyboardAvoidMode.RESIZE`，
让键盘压缩可视区而不是整体上移，避免输入框被顶出屏幕。

## 五、响应式设计

`WindowService` 监听 `windowSizeChange`，把窗口宽度写入 AppStorage，
页面用 `@StorageProp` 订阅：

| 断点 | 宽度 | 布局 |
|---|---|---|
| sm | < 600vp | 内容 + 底部标签栏（课表/成绩/我的/设置） |
| md | 600–840vp | 左侧导航 + 右侧内容主从分栏 |
| lg | ≥ 840vp | 同 md，内容区更宽 |

折叠屏展开/折叠时窗口宽度变化会实时切换布局。

`module.json5` 的 `deviceTypes` 为 `phone` / `tablet` / `2in1`。

## 六、安全与隐私

- **密码默认不落盘**：常规情况下只在内存中使用；仅当用户显式勾选
  「记住账号密码」时才写入系统密钥库（非明文文件）。
- **会话 cookie 也不落 preferences**：`JSESSIONID` 是「持有即可用」的凭据，
  已迁到系统密钥库（`SessionCookieStore`，`DEVICE_FIRST_UNLOCKED`）；
  preferences 里的旧明文读到即迁移并抹除。备份开关 `allowToBackupRestore`
  也已关掉（此前整个沙箱会进系统备份）。
  （密钥库极少数情况下不可用时会**降级**写回 preferences 并打警告日志 ——
  「能登录」优先于「加密」，此时旧明文仍会被清掉。）
- 偏好设置存在 preferences（明文，但不含凭据）；
- **不打印敏感信息**：日志不输出姓名、学号、成绩、密码；会话 cookie 只打
  摘要（`CookieJar.toLogSummary`），重定向日志中的 `ticket` 已做遮蔽。
- **证件类字段不展示、不缓存**：个人信息页的「证件类型 / 证件号」等按
  关键词在**解析层**剔除（缓存存的是原文，只有在这里丢掉才能两边都干净）。
- **个人数据本地留存**：`testdata/raw/` 与 `screenshots/` 含真实姓名/学号
  （本次移植后的工作副本里 `testdata/raw/` 已不存在），
  仅供本地核对，已被 `.gitignore` 排除，请勿提交或外传。
  `testdata/fixtures/` 是脱敏后的版本，可安全作为测试资产。
- **用户填写的校历地址按不可信输入处理**：过 `UrlGuard`（拒绝环回/私有/保留地址）
  并逐跳校验重定向，且**不复用**教务系统的 HttpClient（那个客户端的 CookieJar
  不带域名作用域、请求头还硬编码教务 Origin/Referer，拿它访问任意站点等于把
  JSESSIONID 发出去）。
- **低频访问**：不做批量抓取或高频重放。

## 六点五、玻璃材质

鸿蒙端**用系统沉浸材质**（`@ohos.arkui.uiMaterial` 的 `ImmersiveMaterial`，
含 5 档厚度、光照、交互光效），Flutter 端用第三方玻璃包 —— 两端观感同源，
但鸿蒙端不再引入任何第三方玻璃库。

**曾经的方案与为什么换掉**：早先用
[`com.hm.appleui.hw`](https://ohpm.openharmony.cn/#/cn/detail/com.hm.appleui.hw)
（`XComponent` + 原生 EGL / OpenGL ES 3.0 实时折射）。它能做出真·液态玻璃，
但**只随包提供 arm64-v8a 的原生库**（`libliquidglass.so`）：HAP 装不上
x86_64 模拟器（`install parse native so failed`），只能在
`entry/build-profile.json5` 里写死 `abiFilters: ["arm64-v8a"]`，另外维护一份
API 一致的占位包给模拟器验证布局。该依赖已整体移除，`abiFilters` 也随之删除 ——
现在四个 ABI 通用，真机与模拟器装的是同一个 HAP。

**两条路径（`theme/GlassKit.ets`）**：

| 路径 | 条件 | 实现 |
|---|---|---|
| 系统沉浸材质 | 设备 API ≥ 26 且能力探测通过 | dock 用 `THIN` + 8% 白，浮层面板用 `REGULAR` + 30% 白（`systemMaterial`） |
| 磨砂降级 | 其余情况（含本机 API 24） | `backgroundEffect` 磨砂 + 高光细边 + 投影 |

降级是**强制**的：`@ohos.arkui.uiMaterial` 模块与 `systemMaterial` 属性都是
`@since 26`，老设备上模块不存在、静态导入会在模块加载期抛错（try/catch 拦不住），
因此探测走「`apiAvailable('26.0.0')` → `await import()` → 能力函数」，
与 `OcrProbe` / `CaptchaModel` 同一条已验证的路子。材质构造单独放在
`theme/MaterialProbe.ets`（ArkTS 不允许在 interface 里写构造签名），
只有确认可用后才会被动态加载。

落地范围是「背后有内容可透出」的浮层：手机端底部 dock、页面内浮层
（`GlassOverlay` 的 `GLASS` 材质，默认 —— 课程编辑 / 周次与日期滚轮 /
提前量选项 / 体系要求学分编辑 / 重新验证）。**侧栏与顶栏仍用 `backgroundEffect`
磨砂**：它们背后是页面底色、没有内容穿过，模糊出来是纯色，挂材质只是多一层合成。
内容密集的浮层（校历月历 + 作息表、课表页的学期选择、节次作息编辑、
校历来源编辑）用 **`PanelMaterial.SYSTEM` 不透明面板**：半透明底会把密集小字
与下层内容叠在一起，怎么调都读不清，与系统弹窗一致的不透明面板才清楚。

**导航项与 Flutter 端对齐为 4 项**（课表/成绩/培养/我的）：「通选」（修读情况）
**已并入培养方案页**（按课程体系对齐展示，一边与另一边各自独立加载），
`ElectivePage` 与 `content()` 里的 `elective` 路由都已删除（与 Flutter 端
`kNavItems` / 页面删除的处理一致）；「空教室」仍只在课表页顶栏。

完整调研（API 细节、建议用法、与 Flutter 端的能力差异对比）见
[docs/harmony-liquid-glass.md](docs/harmony-liquid-glass.md)。

---

## 六点六、平板课表文字溢出（尺寸单位 bug）

**症状**：平板上课程卡内的文字被挤到溢出。

**根因**：`windowSizeChange` 回调给出的宽度是 **px**，而 ArkUI 布局用的是
**vp**。`WindowService` 早期直接把 px 写进 AppStorage，等于在 2x 屏上把
窗口宽度**报成两倍**。后果是连锁的：

1. `fitsOneScreen()` 用这个被夸大的宽度判断，得出「一屏放得下 7 列」；
2. 于是放弃横向滚动，把 7 列硬塞进一个实际很窄的窗口；
3. 每列过窄 → 卡片里的文字被挤到溢出。

**为什么只在平板上暴露**：手机屏密度与窗口宽度恰好使误判不明显；
平板（大屏 + 高密度）把误差放大到足以翻转 `fitsOneScreen()` 的结论。

**修法**（两处，缺一不可）：

1. `WindowService.pxToVp()`：全局唯一的 px→vp 换算，
   `currentWidth()` 与 `windowSizeChange` 回调都过它；
2. `SchedulePage` 改为读**实测窗口宽度**（`@StorageProp(AS_WINDOW_WIDTH)`），
   不再用「SM=360 / MD=700 / LG=1000」这三个**假定值** —— 断点只说明是哪一档，
   同档内宽度差很多，按定值猜必然出错。

顺带把卡片「每行几个字」的估算也从「窄/宽二分」改为按真实列宽与字号推算，
让估算与实际渲染一致（估算偏少会让卡片高度不足，同样表现为文字溢出）。

**一句话教训**：**凡是参与布局计算的尺寸，单位必须统一、且必须来自实测。**
断点/设备类型只能决定「用哪套版式」，不能用来**推断具体尺寸**。

---

## 六点七、提前提醒时间改了不生效（跨通道不一致）——该缺陷已随功能移除，教训保留

**症状（移植源那版）**：在设置里改「提前提醒」分钟数，系统日历里的提醒时间不变。

**根因**：提醒有**两条通道**，它们各自记住自己的参数：

| 通道 | 参数存放位置 | 改设置时是否自动跟随 |
|---|---|---|
| 应用内 / 代理提醒 | 每次重排都读最新配置 | ✅ 会跟随 |
| **系统日历** | 日程写入时把提前量**固化**在事件里 | ❌ 不会 |

设置页判断「是否需要重建日历」靠的是**课表指纹**（写日历时的依据有没有变）。
而那个指纹**只哈希了课表内容，没算提前分钟数**：
用户只改提前量、没动课表 → 指纹不变 → 永远不提示重建 → 日历里一直是旧提前量。

**当时的修法**（两处，缺一不可）：

1. `CalendarSyncService.timetableFingerprint()` 把**提前分钟数**也并入指纹；
2. `SettingsPage.applyAdvance()` 改完设置后主动调一次
   `notifyTimetableChanged()`，让「建议重建」提示及时出现
   （原先只有课表页改动时才触发比对）。

**现状**：系统日历同步整组已随「对齐 Flutter 端」移除，
`CalendarSyncService` 与它的指纹机制都不在了；剩下的两条通道
（代理提醒 / 应用内定时器）共用同一套排期计算，每次重排都读最新配置。
`SettingsPage.applyAdvance()` 保留了「改完即重排提醒」的动作
（`republishIfEnabled()`）——这正是当时第 2 条修法的直接延续：
**改了会影响触发时刻的设置，必须主动重排，不能等下一次课表变化。**

**教训（与具体功能无关，仍然成立）**：同一份用户设置被多条通道各自缓存时，
「改了设置」未必等于「所有通道都生效了」——
要么让各通道都能读到最新值，要么把该设置纳入「是否需要重建」的判定依据。

---

## 六点八、底部 dock 图标没对齐（Path 坐标不缩放）

**症状**：底部导航栏每个图标相对自己的文字**系统性偏移**（实测约 12–17px），
看起来像「图标没对齐」。

**排查过程（连踩三坑，都经真机/模拟器截图确认）**：

1. `Path().width(24).height(24).scale(iconSize/24)`
   —— `Path` 的 width/height 是组件尺寸，**不缩放 path 坐标**，
   24 单位的图形被小容器裁剪成碎片。
2. `Shape(){Path()}.viewPort({0,0,24,24}).width(22).height(22)`
   —— 以为 `viewPort` 等价 SVG 的 `viewBox`。实测**它不缩放 Path 坐标**：
   坐标为 24 的图形永远画成约 24px 大，而 22vp 的框在 3x 屏上是 66px，
   于是「小图标位于大框左上角」→ 相对文字偏移。
3. 自己按尺寸重写 path 的数值
   —— 看似可行，但 path 里相邻数值会写成 `-1.99.9` 这种形式，
   数值扫描稍有疏忽就把两个数粘成一个（实测粘了），
   属于容易写出**静默错误**的做法。

**最终修法**：改用 **svg 资源 + `Image().fillColor()`**
（`resources/base/media/*.svg`，与 Flutter 端 `Icons.*_outlined` 同源）。
缩放交给 Image 统一处理，没有任何坐标系换算；`fillColor` 仍能着色。
实测偏移从「均匀 22px」降到 **0 / ±1px**。

**教训**：ArkUI 的 `viewPort` 不是 SVG 的 `viewBox`；
凡是需要「坐标系 → 组件尺寸」的映射，宁可换用成熟的资源渲染路径
（svg + Image），也不要自己手写坐标变换。

---

## 七、已知限制

1. **明文 HTTP**：站点是 `http://`，链路未加密。HarmonyOS 默认允许明文访问
   （`networkSecurity.isCleartextPermitted()` 默认返回 true），故无需额外配置，
   但传输内容在网络上不可信，请避免在不可信网络下使用。
   （服务端未提供 HTTPS 入口，客户端无法修复这一点。）
2. **两套登录入口，本应用只用其中一套**：
   - 根路径的**旧门户**（`/Logon.do?method=logon&flag=sess` 拿 `scode#sxh`
     再按位插字符）—— 移植源用的那套，实测至今仍挂在服务器上；
   - `/jsxsd/` 下的**教学一体化平台**（`/jsxsd/xk/LoginToXk`，
     `encoded = Base64(账号)%%%Base64(密码)`）—— 本应用走这套。

   两者的表单字段与编码算法都不同，混用会以一句通用的「用户名或密码错误」告终
   （移植时就踩过）。登录成功后 `LoginToXk` 以
   `404 + Location: …?ticket=…` 下发票据，必须再请求一次该地址才能换成
   学生端会话（见第一节「登录链路」）。
3. **作息时间的唯一权威来源是教务课表页**：每个节次行的行首格自带起止时刻
   （`第一大节 (01,02小节) 07:50-09:25`），教务处官网只发校历 PDF、没有作息表。
   内置值在 `AcademicCalendar.OFFICIAL_SECTIONS`（`Constants.SECTIONS` 与之
   保持一致，有测试锁住），只作冷启动兜底；联网取回课表时顺手解析并覆盖
   （仅当用户没手动改过）。用户可在设置里按实际情况调整，调整后不再被覆盖，
   「恢复官方作息」可交还给自动同步。
4. **课表按周查询是「服务端筛一次 + 客户端再筛一次」**：用户在周次滚轮里选了
   具体第 N 周时，`zc=N` 会真的提交给服务端（服务端先筛一遍）；
   但客户端拿回课程后仍按本地的周次区间与单双周再过滤一次
   （`isActiveInWeek`）。两条语义必须都保留：前者决定「这一周服务端认为有哪些课」，
   后者决定「同一格里的多门课按各自规则取舍」。
   注意 `auto`（跟随本周）与空串（全部）是**本地语义、绝不提交** ——
   把 `auto` 当 `zc` 传上去，未登录时会被登录页短路（离线怎么测都「正常」），
   会话有效时服务端会返回 404 空响应，表现为点多少次重试都打不开课表。
5. **校历地址由用户填写**（见 `CampusCalendarService` + 设置页「校历来源」）：
   本校教务处是**按年份发公告**（「山东建筑大学 2026 年校历」），地址里带
   内容 id（`/jwc/info/1024/3232.htm` 这类），**每年都不一样**；公告挂的是
   **PDF 附件**，不是图片。因此：
   1. 应用**不内置任何校历网址** —— 内置一个「当前年份」的地址，换年就静默
      失效，而界面上完全看不出来，属于最危险的那类失败；
   2. 设置页给一个输入框 + 一个「教务处信息公开列表」的直达入口，用户自己
      找到当年那篇、把地址粘进来；应用只负责抓取、缓存、解析；
   3. 附件解析**严格限定三类特征**（CMS 下载接口 / `/__local/` 附件区 /
      `.pdf` 链接）—— 放宽到「任意图片」会把站点 logo 当成校历；
   4. 抓不到就沿用上次成功缓存的附件（落在沙箱 `files/campus/`），从未成功过
      就只显示教学周历与作息表、不显示附件 ——「取不到就不显示」比
      「显示一份可能过期的校历」安全；
   5. 用户填的地址与页面里解析出的地址都属**不可信输入**：过 `UrlGuard`
      （拒绝环回/私有/保留地址）并**逐跳**校验重定向，且刻意不复用教务系统的
      HttpClient（那个客户端的 CookieJar 不带域名作用域、还硬编码教务
      Origin/Referer，用它访问任意站点等于把会话 JSESSIONID 发出去）。
   作息若解析出的行数**少于课表的 5 行**，会**拒绝映射**并继续用本地值 ——
   宁可提醒时间旧一点，也不能按错位的时间算上课提醒。
6. **代理提醒被华为管控**：本机实测 `publishReminder` 返回 `1700002`（配额为 0）——
   这是系统对第三方应用的限制，不是代码问题。应用已做双通道自动降级：
   首选系统代理提醒，失败则改用「应用内定时器 + 普通通知」（需应用存活）。
   实际走哪条通道可由 `ClassNotifier.channel()` 读出（日志/排查用）；
   设置页显示的是「已排定 N 条」与通知权限状态，两者都是向系统查询的真实值。
   （移植源那份「同步到系统日历」的兜底方案已随鸿蒙端对齐 Flutter 时移除，
   因此本机没有「应用不运行也能提醒」的可靠手段 —— 详见第八节。）
7. **实况窗（灵动岛）在本机不可用**：参数已全部试对，卡在
   `1003500005`（未开通实况窗权益）。该权益需在 AGC 按场景申请并由华为签发正式证书，
   调试证书无法获得，因此**该功能已从应用中移除**。
8. **模拟器需要单独的签名**：见「三、构建与运行」。真机包和模拟器包不能混用。

## 八、已实现：提醒、桌面卡片与验证码识别

### 上课提醒（双通道）

`ClassNotifier` 先探测系统代理提醒是否可用，不可用则自动降级：

| 通道 | 机制 | 是否需要应用存活 |
|---|---|---|
| 1. 系统代理提醒 | `reminderAgentManager.publishReminder` | 否（系统托管） |
| 2. 应用内定时器 | 10 秒粒度检查 + `notificationManager.publish` | 是 |

排期算法在 `model/ReminderPlan.ets`（纯计算、有单测）：
只看未来 7 天，**逐日各自计算周次**，再按 `isActiveInWeek` 过滤单双周与周次区间。
提前量、节次作息、教室/教师信息都会拼进通知内容。

设置页可配置：开关、提前分钟数；未授权通知时给出「去系统设置开启通知」的入口。

> **历史：** 移植源那版客户端还有「同步到系统日历」与「登录状态保活」两套机制。
> 移植到鸿蒙端并对齐 Flutter 端时已整组移除：系统日历同步（`CalendarSyncService`）
> 需要 `READ_CALENDAR`/`WRITE_CALENDAR` 运行时权限与专属日历账户
> （现 `module.json5` 只声明 INTERNET / GET_NETWORK_INFO / PUBLISH_AGENT_REMINDER），
> 保活（`SessionKeepAlive`）在 HarmonyOS 退后台即挂起、定时器不可靠，
> 两者在 Flutter 端都没有对应实现，留着会让两端行为分叉。
> 它们背后的服务代码（连同 `common/AccountScopeHooks` 钩子登记处）也一并删除，
> 不留死代码；`model/CourseScheduleMath.ets` 的重复规则计算保留了下来，
> 仍由离线测试覆盖（`buildEvent` 的单双周起点对齐）。

### 桌面卡片（`TodayCourseFormAbility` + `widget/pages/TodayCourseCard.ets`）

卡片只做渲染，数据来自主应用写好的**快照**（`CardSnapshotStore`）：
卡片可能随时被系统要求刷新，而渲染时间短、不适合联网与解析 HTML。
主应用在「课表加载/编辑、进入前后台」时刷新快照，卡片读到 `今天没有课` 也是真实结论。

- 支持 `2*2` / `2*4` / `4*4` 三种尺寸（`form_today_course.json` 的
  `supportDimensions`），按尺寸决定显示几行（`maxRows` 由主应用按实际尺寸注入）
- 卡片与主应用分别打包，因此卡片页**不 import 主应用模块**，只按字段名约定读 JSON
- `FormExtensionAbility.onAddForm` 必须**同步**返回绑定数据，
  故 `PrefStore.readTextSync` 用 preferences 的同步接口读同一份存储
- 快照存的是**整周载荷**（含每门课的周次区间、单双周与节次起止），
  卡片自己按当前时间算「今天」—— 跨天自愈，`done` 与「下一节」随时间变化，
  不必等主应用打开
- **改了课表要主动推**：已渲染的卡片不会自己读 preferences，
  只有 `formProvider.updateForm(formId, data)` 能把新数据送过去。
  `CardPusher` 负责这件事（动态 import `@kit.FormKit`，避免缺 HMS 导出时
  在模块加载期硬崩），`FormIdRegistry` 把 formId 落盘供其使用

### 验证码识别（`CaptchaModel` 主路径 + `OcrProbe` 兜底）

#### 先说结论与实测数字

| 方案 | 完全正确率 | 说明 |
|---|---|---|
| 系统通用 OCR，原图直投 | 14–20% | 最初实现 |
| 系统通用 OCR + 多尺度 + 一致性投票 | **42%（5/12）** | 优化后的上限，仍经常失败 |
| **端上训练模型（ddddocr，`CaptchaModel`）** | **11/12 ≈ 92%** | 现在的主路径 |

因此识别优先级是 **端上模型 → 系统通用 OCR**：后者只在设备不支持端上推理
（`SystemCapability.AI.MindSporeLite`）或模型加载失败时兜底。
模型是 ddddocr 的 ONNX 经 converter_lite 转成 MindSpore Lite 的 `.ms`
（约 27MB，随包内置，不联网）；字符表 `CaptchaCharset` 是它 `CHARSET_BETA` 里
ASCII 字母数字的**稀疏映射**（索引是模型输出的绝对值，不能压缩重排）。

> **坐标系陷阱（务必注意）**：同源的两版客户端用**不同模型、不同字符表**：
>
> | 版本 | 模型 | 字符表 |
> |---|---|---|
> | 鸿蒙 | `common.onnx`（浮点，转成 `.ms`） | `CHARSET_BETA` |
> | Android | `common_old.onnx`（量化，ONNX 直载） | `CHARSET_OLD` |
>
> 两者都是 8210 类、输出形状一致，**配错不会报任何错**，只会让识别率变成 0%。
> Android 版就踩过这个坑。识别率异常时第一件事就是核对这张表：
> 把日志里的原始 `indices` 拿到两套表里各查一次，哪套能解出字母数字就是对的。

#### 通用 OCR 那一版为什么提升有限（保住的历史教训）

最初的假设是「**二值化 + 放大** 能大幅提升识别率」——把验证码转成黑白、
去掉彩色与噪声，听起来完全合理。**真机扫描直接推翻了它**：

| 变体 | 某次扫描的单独正确率 |
|---|---|
| `raw+x2`（原图放大 2 倍） | **43%** ← 最好 |
| `raw+x4` | 29% |
| `raw+x6` | 29% |
| `gray+x4`（灰度） | 29% |
| `raw+x1`（不放大） | 14% |
| `bin+x4`（二值化） | **0%** ← 最差 |
| `seg+x4`（逐字符切分） | **0%** |

两条反直觉的结论：

1. **二值化反而有害**。识别引擎是按自然图像（平滑灰阶）训练的；
   硬二值化 + 最近邻放大产生的锯齿边缘会误导它 —— 实测 `zu79` 被读成
   `Zu779`（凭空多一个 7）、`vzpz` 被读成 `vzdz`。而**什么都不做、只放大**的原图
   反而读对了 `zu79`。
2. **逐字符切分完全无效**。把字符一个个切出来单独识别，引擎输出全空——
   它需要「凑成词」的上下文，单字喂进去就直接放弃。这同时解释了另一个现象：
   读整条时它常只读出一部分（`qj3n`→`3n`、`9dvp`→`p`），因为它试图把
   4 个字符归并成更短的「词」，而验证码恰恰不是词。

**教训**：图像预处理对 OCR 的效果高度依赖引擎的训练分布，不能靠直觉；
必须先用带真值的语料做对照测量，再决定参数。这条教测量先行的方法最终把项目
推向了「换模型」而不是继续调参数 —— 差距是量级性的（42% → 92%）。

#### 现在的实现

- **`CaptchaModel`**（主路径）：模型输入是灰度、高 64、宽 160、白底右补白；
  CTC 贪心解码（合并连续重复、丢 blank）后查字符表。**不做易混字符纠正**
  （1↔l、0↔O 由服务端判定，擅自替换只会在原本正确时引入错误）。
  经动态 `import()` 加载，避免缺 `SystemCapability.AI.MindSporeLite` 的设备
  在模块求值期抛错。
- **`CaptchaPrep`**（通用 OCR 兜底路径的预处理，纯像素运算、可离线单测）
  - 墨迹分数用 `255 - min(R,G,B)` 而不是灰度：验证码每个字符颜色不同
    （深绿/黑/棕/青紫，低饱和），灰度会把蓝紫色压到接近背景而丢字；
    min 通道只要够暗就判定有笔画，实测蓝色字符 (40,80,160) 灰度为 79（含混）、
    墨迹分数 215（明确）。
  - **Otsu 自适应二值化**：背景并非纯白（实测纯白仅约 83%），固定阈值会漏字；
    Otsu 按直方图自寻分割点，实测阈值落在 92–106。
  - **两步裁边**：先按列/行密度裁掉四周留白，再裁掉黑边框线。
    必须分两步 —— 真实截图里黑框**不贴图像边缘**（实测竖边在 x=11..13），
    只做「从边缘按密度找边框」会立刻停下、边框根本裁不掉。
  - 去孤立噪点（清 JPEG 噪点与 1px 划痕）；**默认不做膨胀**，实测会让字符粘连。
- **`OcrProbe`**：同一张图跑 3 个不同放大倍数（×2/×4/×6），
  各自识别后取候选，交给投票。多变体只烧端上 CPU，**不额外请求验证码、
  不额外提交登录**，因此不增加服务器负担或账号锁定风险。
- **`CaptchaVote`**：本 SDK 的 OCR **没有置信度**，无法「取分数最高」，
  因此用**一致性投票**代替——两个不同尺度独立给出同一结果，
  其可信度远高于任一单次。同时用 word 级包围盒剔除边框被识别成的长条伪 token
  （否则 `substring(0,4)` 会把真字符挤掉）。

#### 自动填验证码（含首次登录）

所有出现图形验证码的地方都**自动识别并填入输入框**：

| 场景 | 行为 |
|---|---|
| 首次登录 | 输入账号后进入第二步，自动取图识别并填入；失败则提示手输 |
| 会话失效后重登 | 同上；有凭据时密码已回填，用户可能只需点「继续」 |
| 静默续期 | 后台识别并直接提交，成功则完全无感 |

三者共用 `ReAuthService.solveCaptcha()`，统一走「端上模型 → 系统通用 OCR」。

是「填入」而非「静默提交」：识别率约九成，剩下一成必须让用户能看见并改正。
另外**图与填入文本必须是同一张**（`CaptchaSolve` 同时返回两者）。

密码与验证码**同框**（两步式：账号 → 密码与验证码），
一个圆角容器装两行、共用背景边框，一次提交。

#### 限次重试（`ReAuthService.autoLoginWithRetry`）

交互路径（用户点开功能触发弹窗）最多提交 **3 次**登录；识别失败或服务端明确回
「验证码」错时**换一张图**再试。两条关键约束：

- **只对验证码类失败重试**。为此给 `QzApi.LoginResult` 加了机器可读的
  `LoginFailKind`，不再靠比对界面文案判断。若把账号/密码错也当成可重试，
  就会拿错误凭据反复 POST，有把账号打到临时锁定的实际风险。
- **静默路径不重试**（固定 1 次），启动续期这类「用户没在等」的场景不该多打请求。

> 历史上会话保活（`SessionKeepAlive`）也会自动 OCR 登录，加了重试后意味着
> 每 5 分钟一次取验证码 + POST 登录，一天近 300 次请求。该功能已整体移除，
> 这条约束的受益方现在是启动静默续期与「用户点开需要联网的功能」两条路径；
> 无论哪条，**都不做周期性自动登录**。

#### 顺带修掉的一个「看起来像 OCR 不行」的 bug

`ReAuthDialog` 原先在识别失败时**预填 OCR 文本 + 另取一张新图**，
预填内容与所见图必然不一致，用户直接提交必然失败。现在
`AutoLoginOutcome.captchaImage` 把 OCR 用的**同一张**图带回来，
图文一致，用户只需改错的那一位。

#### 可测量的入口

`OcrProbe.sweep()` 仍保留：一次跑完所有候选变体、给出**各自单独**的正确率 ——
上面那张「通用 OCR 为什么提升有限」的表就是它的输出，
「哪个预处理更好」由数据回答而不是靠猜。

> **历史：** 早期有一版把「识别率评测 / 变体选型扫描」做进设置页（`OcrEval`），
> 语料放 `resources/rawfile/ocr_eval/`、支持从沙箱 `files/ocr_eval/` 覆盖。
> 改成端上模型后该测试入口与内置语料已整体移除，只在本仓库的
> `tools/ocr_eval/` 留了一份备份（`OcrEval.ets.bak`）；需要重新做选型时，
> 可以直接在测试脚本里对 `OcrProbe.sweep()` 跑断言，不必把 UI 装回来。

### 空教室查询（`ClassroomPage` + `ClassroomParser` + `ClassroomModels`）

数据源是教务系统的教室查询页（筛选器 `GET /jsxsd/kbxx/jsjy_query`，
结果 `POST /jsxsd/kbxx/jsjy_query2`），不是独立的空教室接口
（系统菜单里没有该项）。选择「学期 + 校区 + 教学楼 + 节次 + 周次 + 星期」，
列出该时段的空闲教室。

**交互：改动筛选条件后重新查询，没有「查询」按钮。**

- 进入页面即自动查一次（选项加载完成后）
- 改动**学期 / 校区 / 节次**会立即重新请求（这三项进缓存 key）；
  换**周次 / 星期 / 教学楼**是**纯本地过滤，不发请求** —— 服务端返回的
  本来就是整个学期的全周占用，这几项只是「读哪一列、取哪批教室」的选择
- 数据的新鲜期是 2 分钟（`TTL_CLASSROOM_USAGE`），超过后再改条件才会真的联网；
  教室占用是实时变化的（借用记录随时被编辑），所以这条 TTL 刻意很短
- 星期行同时就是「本周空闲速览」：每天空闲几间标在当天下面，点哪天切到哪天
  —— 早先这两者画成了两行一模一样的周一…周日，看起来像 bug，现已合并
- 空闲教室按教学楼分组展示，并提示该时段有多少间在上课或已被借用
- 默认落在「当前教学周 + 今天」；默认校区取下拉**第一项**（＝学校排的主校区），
  不硬编码校名
- 教学楼候选**由查询结果推导**（从教室名 `信息楼211`、`博文馆101` 取楼名去重）：
  服务端的楼栋联动端点 `/jsxsd/kbxx/jsjy_processAjax` 在本校**整体关闭**，
  任何请求头组合都返回「提示：非法访问！」

**并发保护**：自动查询会在连续改动时并发发出多个请求，慢的那个可能后回来。
因此用递增序号标记每次请求，回来时若序号已过期就**丢弃响应**，
避免把新结果覆盖成旧结果。

**核心决策**：查询**不把周次交给服务端**。服务端的周次参数既漏过滤借用记录，
又会丢掉该周无占用记录的教室（真正空闲的那批），因此改为取回全学期占用文本后
在客户端逐格判断，见上面第 20 条缺陷说明。
「改条件才重新请求」与此不矛盾：**请求拿全量、客户端按周筛**。
结果页表结构是**三行表头 + 数据行**：行 0 是功能区/教室名/查询，
行 1 是星期（8 格，星期列 `colspan=5`），**行 2 才是节次编号**
（36 格 = 1 个教室名 + 7 天 × 5 大节），数据行同样是 36 格。
列映射必须读行 2 的节次编号，不能按行 1 的格号去映射 ——
那样会把周三到周日整段读错（而全空的教室在错表里看起来完全正常）。

单元格里两种周次写法都已覆盖：
课程 `(3-18周)`、`(5-18双周)`、`(1-2,4-8,10周)`；借用 `被借用( 第(2周)(01-04节)周,王超,学生活动 )`。
拿不到周次说明时**保守视为占用**，避免把有课的教室报成空闲。
空闲判定按 **`bySection[day][section]`** 逐格做：选「第一大节」只排除该节有课的教室，
而不是「整天没课」的教室（后者的口径下节次筛选形同虚设）。

### 路线图（尚未实现）

一键评教、成绩趋势与绩点分析、多账号切换、跨设备同步。

## 九、健壮性审查（本轮修复的隐患）

对全工程做了一轮针对性审查，重点找「换设备/换数据才暴露」和「静默失效」类问题。
除上面的 PDF 崩溃外，还修了以下几处 —— 每一条都写明了**为什么原写法有问题**。

### 1. catch 块里再抛异常，把页面打崩（影响 7 个页面）

原写法在所有页面里都是：

```ts
catch (e) {
  const err: AppError = e as AppError;   // as 只是类型断言，不做运行时检查
  this.errorText = err.toUserText();     // 非 AppError 时这里是 undefined
}
```

`as` 不做运行时校验。一旦抛出的是原生错误（TypeError / SyntaxError，
或底层 HMS 抛出的普通对象），`err.toUserText` 就是 `undefined`，
调用它会**在 catch 里再抛一次**，变成未处理的 Promise 异常 —— 白屏甚至崩溃。
更麻烦的是这类路径平时跑不到，只有异常类型恰好「不对」时才触发。

修法：新增 `AppError.describe(e)`，显式判别类型，任何抛出物都能得到可显示字符串；
原生错误直接回显其 message（更利于定位）。单测里专门加了
「旧写法确实会抛异常」的反证用例，锁住这个行为。

### 2. 关闭提醒后仍会弹通知（定时器没被停掉）

`ReminderService.cancelAll()` 原来只调 `reminderAgentManager.cancelAllReminders()`，
那是**系统代理提醒**通道；而应用内通道是 `ClassNotifier` 用 `setInterval`
自己检查到点后发通知的，系统接口停不掉它。
于是「关掉上课提醒」之后，应用内定时器仍在跑，依然会弹通知。

修法：`cancelAll()` 先 `ClassNotifier.stopInAppChannel()` 再取消系统提醒，两条通道一起清。

### 3. 退出登录后仍用上个账号的课表提醒

退出登录只清了会话，没有停掉后台提醒；定时器继续跑，会拿上一个账号的课表弹通知。
修法：退出时先 `ReminderService.cancelAll()` 再清会话。

> 移植源那版还刻意**不删**已写入系统日历的日程（那是用户主动开启、由系统日历
> 托管的条目）。系统日历同步在本端已整组移除，这条注意事项也随之下线。

### 4. 缓存策略：课表本地优先，其余按 TTL 走三层缓存

页面在切换标签时会被销毁重建（`Index` 用 if/else 换页），
各页 `aboutToAppear` 里的 `load()` 都会重新请求。

**结论性设计**：

- **课表必须本地优先**（按「账号 + 学期」落成 `timetable/<账号>_<学期>.json`）：
  用户可以在本地编辑课程，必须优先读本地，否则改动会被服务器数据覆盖；
  而且用户常常只是看一眼课表，纯本地渲染才能做到"不打扰"（见第 10 条）。
- **其余页面走 `PageCache` 的三层缓存**（内存 → 磁盘 → 网络）**并按新鲜期决定是否联网**：
  缓存存的是**服务器原文**（解析器是唯一真相，避免「模型加字段、序列化器忘了同步」
  这类静默错误），新鲜期与 Flutter 端逐项对齐 ——
  成绩 / 空教室占用 2 分钟，通选课 10 分钟，培养方案 / 个人信息 / 校历 / 学期列表
  6 小时。判据是「数据多久变一次 vs 重复请求的代价」，宁可偏短。

> 中途确实试过「所有页面一律实时取」，代价是每切一次标签就打一个请求；
> 现在改为「TTL 之内直接用缓存，超过就联网」，时效性由 2 分钟档的数据兜住。

### 5. 切换账号时数据串号

`AppState` 里的成绩/个人信息等字段都是 `static`，进程内跨账号共享。
原实现退出登录只清会话、不清这些字段，于是「A 退出 → B 登录」后
B 会看到 A 的成绩与个人信息。

修法：新增 `AppState.clearUserCaches()`，在 `logout()`、`forceLogout()`
以及「检测到换了账号」时统一清空。
注意**只清内存、不删课表文件** —— 课表按账号分文件保存，
所以换回原账号时会自动读回本地缓存，用户的课表修改完好保留
（这正是「切账号再换回来，课表修改还在」这条需求的实现方式）。

### 6. PDF 写入失败时泄漏文件句柄

（PDF 附件链路已随合并改版删除，但这条教训留在了同类代码里。）
早先 `PdfStore.download()` 里 `openSync` 之后若 `writeSync` 抛错，`closeSync`
不会执行，fd 一直泄漏；反复重试可能耗尽句柄。
修法：`try/finally` 保证关闭，并在写失败时删掉半个文件，避免它被下次当成有效缓存。
现在 `TimetableStore.save` / `PageCache.writeText` 等所有写文件处都沿用同一写法。

### 7. 已发通知记录无界增长

`ClassNotifier.fired` 里的 key 含日期，只增不减（应用长期开着会一直涨）。
排期窗口只有 7 天，保留最近 200 条足够去重。修法：超出后裁掉最早的。

### 8. 一处误导性文案

PDF 卡片副标题只要「下载完成」就显示「已在本页直接阅读」，
即使设备根本不支持内嵌渲染。修法：区分「已下载」与「已渲染」两种状态，
不支持时明确显示「已下载，本机不支持内嵌渲染」，并在失败处标出缺失的 syscap。

（后来内嵌渲染整体删掉了，这条文案也随之简化成「已下载，可交给其它应用打开」——
状态再也不会有「下载成功但渲染失败」这种中间态。）

### 9. 空闲教室列表重复计算

`ClassroomPage.freeRooms()` 在 build 里被调用 4 次（数量、空态、分组、统计），
每次都遍历并按教室号排序 200+ 条。修法：按 (周次, 星期, 节次, 教学楼, 结果)
记忆化 —— 节次与楼栋是**本地**过滤条件，必须一起进缓存键，
否则切换它们时列表不会重算、显示的还是上一次条件的结果。

### 尚未处理（已知、评估后决定不做）

- **页面销毁后异步回调写状态**：切标签时旧页面的请求可能还在飞，
  回来后会写入已销毁组件。实测快速切换未触发崩溃（ArkUI 对已销毁组件的
  @State 赋值会被忽略），且改造需要在每个页面加生命周期标志、
  收益有限，故暂不处理，仅在此记录。
- **非 BusinessError 的异常在提醒路径只读 `err.code`**：
  读不到的属性会得到 `undefined` 而非抛错，属于安全写法，无需改动。

## 十、第二轮全量审查（按优先级逐条修复）

上一节是围绕 PDF 崩溃展开的针对性排查。这一轮把整个工程按「数据流」重读了一遍，
专门找**只有在换账号、换数据、换设备时才暴露**，以及**静默返回错误结果**的问题。
下面按修复优先级列出，每条都标明原来的写法为什么错。

### P0 · 会串数据或产生错误结果

**P0-1　退出登录没有清理账号作用域状态（跨账号串号）**
`logout()` / `forceLogout()` 只清了会话，桌面卡片快照、当前账号、
上次停留的学期/周次/成绩学期、以及「待重新登录」标记全部残留。
后果是 A 登出、B 登录后，桌面卡片仍显示 A 的课程，课表选择器停在 A 的学期。
修法：新增 `AppState.clearAccountScopedState()`，两条登出路径统一调用，
并顺带 `ClassNotifier.stopInAppChannel()` 停掉应用内提醒通道——
否则 B 会收到 A 课表的上课提醒。

**P0-2　课表缓存的账号归属靠「猜」**
`TimetableStore.findAccountForSemester()` 原先直接取缓存目录里的第一个账号。
多账号共存时这等于**把 A 的课表当 B 的返回**，而且是静默的。
修法：只有当缓存里**恰好只有一个账号**时才用它；有多个（或零个）就返回空串，
由调用方回退到网络请求。宁可多一次请求，也不能用错数据。

**P0-3　CookieJar 并发写入坏掉名值对**
原来用 `names[]` / `values[]` 两条平行数组，`absorbOne()` 分别 push。
两个响应并发到达时，两次 push 会交错，产生 `NAME=undefined` 这种条目，
后续请求带着坏 Cookie 发出，表现为「随机掉登录」。
修法：改用 `Map<string,string>`。同时把 `Set-Cookie` 按 `;` 切分，
保留同一响应里的多个 cookie，并跳过 `Path`/`Expires`/`HttpOnly`/`SameSite`
等属性（只在 `i > 0` 的位置判断，避免误伤值里以这些词开头的 cookie）。

### P1 · 静默错误 / 时效性问题

| # | 问题 | 原来的写法 | 修法 |
|---|---|---|---|
| P1-1 | 刷新后仍是旧课表 | 请求选项未设 `usingCache`，鸿蒙 http 默认可能命中本地缓存 | STRING 与 ARRAY_BUFFER 两条路径都显式 `usingCache: false` |
| P1-2 | 把 404 当成登录失效 | `ensureAuthed()` 见非 200 就判会话过期 | 改为 `checkResponse()`：仅 `status >= 400` **且无 `location` 头**时抛错——登录成功恰恰依赖 404 + Location ticket |
| P1-3 | 周历整片错位 | 把文档里所有 `MM月dd日` 按每 7 个一组切分；真实页面只给周六周日写完整日期 | 按行解析：行首 `td` 是周次，第一个带 `title` 属性的单元格是周一。为此给 `HtmlCell` 加了 `openTag` 与 `attr()` 以读取属性 |
| P1-4 | 跨年时当前周算错 | `currentWeek()` 比较 `MM-dd` 字符串，12 月→1 月必然错 | 比较真实日期（`Date.UTC` 毫秒） |
| P1-5 | 个人信息多出子表列名 | 表头行识别过宽，子表的列名被当成字段 | `isSectionTitleRow()`：单非空单元格、3–16 字、不含数字与冒号 → 判为节标题，跳过其后一行；`lastLabel()` 不再截断含括号的标签 |
| P1-6 | 非法日期被接受 | `WeekCalc.parse` 不校验日期是否存在（`2026-02-31` 可通过） | 经 `Date.UTC` 往返比对年/月/日 |
| P1-7 | 提醒 id 冲突 | 通知 id 可能重复，后一条覆盖前一条 | `nextNotifyId` 单调自增取模 1000000 |
| P1-8 | 改课表后提醒不更新 | 只在首次排布，之后不再重算 | `ClassNotifier.rebuildIfNeeded()`（24 小时节流、按键合并去重）+ `CardPusher` 主动推卡片 |

### P2 · 资源与并发

| # | 问题 | 修法 |
|---|---|---|
| P2-1 | PDF 缓存无上限增长 | `MAX_CACHE_BYTES = 50MB`，每次下载成功后 `prune()` 按 mtime 淘汰最旧；设置页显示占用并有清空入口 |
| P2-2 | 重复的并发操作 | 一律用 `inFlight` Promise 串行化、复用同一次执行：会话探测（`QzApi.probeInFlight`）、自动登录（`ReAuthService.autoLoginInFlight`）、密钥库读取（`CredentialStore.inFlight`） |

> 移植源那版还有一条「重复触发日历同步」的 P2 项（`CalendarSyncService.inFlight`）。
> 系统日历同步已整组移除，这项随之消失；串行化的写法在剩下几处继续沿用。

### 顺带修掉的三处「写了但没接线」

- `PrefStore.saveAccount()` 定义了很久却**从未被调用**。后果很隐蔽：冷启动时
  应用不知道当前账号，按账号缓存的课表看起来「不存在」，于是走网络请求，
  会话失效就弹登录框——这与「只看课表不打扰」直接冲突。现在 `onLoggedIn()` 里补上。
- `CredentialStore.generation`：异步读密钥库期间用户点了「清除」，
  回调仍会把旧凭据写回内存缓存。加世代号，写缓存前校验。
- 数据存储读取时补边界校验（`version`、行列范围），避免损坏的缓存文件
  被当成正常课表渲染。

### P0-4　启动时两处并发探测会话，导致「假失效」

这是做会话保活时顺带挖出来的一个**既存缺陷**，保活本身后来移除了，缺陷与修法仍在：
`AppState.verifySessionInBackground` 与 `Index.trySilentRenewal` 在启动时
**各探测一次会话**。两条请求带着**同一个 JSESSIONID** 并发打到服务器，
服务端一旦在响应中轮换会话，后到的那条就会被判为未登录 ——
于是 `isSessionAlive()` 出现假阴性，进而触发一次完全不必要的重新登录
（取验证码 + 提交登录），而这次登录又会再次轮换会话、干扰其它在途请求。

真机日志可以直接看到这个现象：同一个时间戳下连着两条 `session probe`。

修法分两层，都是「让并发调用共享同一次操作」：

- `QzApi.isSessionAlive()` 加 `probeInFlight`，并发调用复用同一个 Promise；
- `ReAuthService.tryAutoLogin()` 加 `autoLoginInFlight`，避免两处各自提交登录
  （共用会话会让两次登录**都**失败）。

修完后真机日志只剩一条探测。同时把探测逻辑抽成 `AppState.probeSession()`
返回 `SessionProbe`（区分「会话失效」与「网络失败」），
供启动校验与各处按需续期共用，避免多条路径各写一套判定、日后行为分叉。

### P1-5　周期性自动登录的风险（此约束仍生效）

移植源那版的会话保活（`SessionKeepAlive`）在探测到会话失效时会尝试 OCR 登录。
如果再加上「换图重试」，同一条保活循环就会每 5 分钟取一次验证码 + POST 登录，
一天接近 300 次 —— 既明显打扰服务器，也平白把账号往「临时锁定」的阈值上推，
而用户此刻未必在等结果。当时把保活改成「只探测、只记录、静默等待」，
顺带删掉了为它准备的 `AutoLoginOutcomeLite` 与相应测试桩。

保活模块后来整体移除，但**这条约束被继承下来并写进了 `ReAuthService` 的契约**：
只有交互路径（用户点开需要联网的功能）才允许 `autoLoginWithRetry`，
启动静默续期固定 1 次，**不存在周期性自动登录**。

### P1-6　识别失败时预填的验证码与显示的图片不是同一张

`ReAuthDialog.start()` 原先在自动识别失败后做两件事：把 OCR 文本填进输入框，
然后 `loadCaptcha()` **再拉一张新图**。结果预填内容与用户看到的图必然不一致，
直接提交必然失败 —— 而这会被用户理解为「OCR 识别不行」，掩盖了真实原因。

修法：`AutoLoginOutcome` 增加 `captchaImage`，把 OCR 用的**同一张**图的 dataUri
带回弹窗；图文一致后，用户只需改错的那一位字符。

### P1-7　无法区分「验证码错」与「账号密码错」，重试只能靠猜

要让重试安全（只重试验证码类失败），就必须能机器可读地判断失败类别。
原先只有一个界面文案字符串，靠它做判断的话，服务端措辞一变就会把
「密码错误」误判成可重试 —— 那就变成拿错误凭据反复 POST，是真实的锁定风险。

修法：`QzApi` 新增 `LoginFailKind` 枚举与 `LoginResult.kind`，
由 `classifyFail()` 按服务端原文**保守归类**：只把明确含「验证码」的归为可重试，
含「密码/账号/用户名」的归为凭据类并立即停止，其余归为不可重试。

