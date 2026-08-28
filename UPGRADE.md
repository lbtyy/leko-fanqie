# 升级指引（leko-plus）

本页面向从 **fanqie.koplugin** 或 **Leko Reader 0.15.49** 升级到 **leko-plus 0.15.49-plus** 的用户。

## 从 Leko Reader 0.15.49（基座）

leko-plus 是 Leko Reader 的真超集；菜单、书架、阅读器交互路径完全不变。

操作步骤：
1. 安装 leko-plus 0.15.49-plus.zip；解压后得到 `leko.koplugin/`。
2. 把整个 `leko.koplugin` 覆盖复制到 `koreader/plugins/leko.koplugin/`。
3. 完全退出并重启 KOReader（仅回到文件列表不会重新加载插件）。
4. 历史数据：`koreader/data/leko/` 子树全部保留；新版本号在 main.lua / _meta.lua / Version.lua 三处同步。
5. 不开启番茄源时与 Leko Reader 行为完全一致：所有菜单条目"+番茄"扩展点为隐藏。
6. 跨书源搜索 / 换源 / 导出 / 缓存 / 排版 等所有能力 100% 保留。

## 从 fanqie.koplugin 升级

番茄的核心价值点（扫码登录 + 番茄书架 + 段评 + 云端进度同步）已经全部并入 leko-plus，不需要保留独立 fanqie.koplugin 插件。

操作步骤：
1. 安装 leko-plus 0.15.49-plus.zip。
2. **首次启动时自动后台迁移**（阶段⑤ T11 实施，调度延时 2 秒，不阻塞主流程）：
   - 读取 `koreader/data/settings/fanqie.lua`
   - 把 Cookie 数组 + 同步开关 + 聚合源服务器地址转入 `koreader/data/leko/providers/fanqie/`
   - 迁移完毕写入 sentinel 文件（`data/leko/providers/fanqie/migration_state.lua`）
   - 老 `fanqie.koplugin` 插件目录仍在时弹一次"功能已并入 leko-plus"提示，可手动从 KOReader 插件列表移除
3. **章节缓存（旧 data/fanqie/cache/）不迁移**——番茄章节缓存统一走 leko Storage 全书缓存，第一次读章节时会自动按需拉取。
4. 迁移可重试：删除 `data/leko/providers/fanqie/migration_state.lua` 后再次重启。
5. 迁移可跳过：在 App:init 之前手动写入 sentinel state=skipped。

## 常见问题

**Q：升级后会丢登录吗？**
不会。Cookie 数组从 settings/fanqie.lua 迁移到 data/leko/providers/fanqie/account.lua，免重新扫码。

**Q：leko-plus 默认会发起番茄请求吗？**
不会。ProviderRegistry:get() 在 FanqieCompliance 未确认时返回 nil，番茄域名请求在代码路径上不可达。首次开启番茄源时弹出免责声明（个人学习研究用途、用户自担风险）。

**Q：能不能保留两套插件（leko-plus + fanqie.koplugin）？**
不建议：fanqie.koplugin 仍会读写 settings/fanqie.lua，可能与 leko-plus 迁移产生写写竞争。强烈建议从 KOReader 插件目录移除老 fanqie.koplugin。

**Q：版本号显示什么？**
`0.15.49-plus`（在 leko 上游版本号后加 -plus 后缀，方便后续 rebase 上游时滚动跟踪）。

**Q：怎么构建多平台 .so？**
见 `native/bridge/` 下四个脚本：build-kindle-armv7.sh / build-kobo-armv7.sh / build-linux-x86_64.sh / build-windows-x86_64.sh；ABI 验证跑 verify-multiplatform-abi.sh。
