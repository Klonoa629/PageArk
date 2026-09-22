# PageArk

纯自用的鸿蒙（HarmonyOS NEXT）PDF 阅读器，MatePad 真机开发。ArkTS + ArkUI，基于 PDFKit 的 PdfView 组件。
操作系统版本：HarmonyOS 6.1.0.135 SP9（API 24）

## 功能

- 书架：缩略图网格、三档排序（最近打开/书名/进度）、继续阅读卡、书名搜索、长按改名/删除（二次确认）
- 阅读：整页适配白边补齐、单页分割；左右点击/横扫翻页，动画为 ghost PdfView 滑页（矢量无模糊）；捏合缩放、双击复位、缩小永不低于适配尺寸
- 目录大纲（PDF outline 递归抽取）、多书签（星标切换 + 列表跳页）
- 横屏双页：横屏时左右各一页拼对子整对翻页
- 裁切白边：书页横向铺满屏幕
- WiFi 传书：平板起 HTTP 服务，电脑浏览器/扫码上传 PDF，落盘自动出缩略图
- 外观：六档背景色（霜白/纸黄/豆沙绿/丁香紫/暮灰/墨黑）、四档界面字号
- 设置内开发者选项（渲染调试台、手势调试、导入测试书），默认折叠

## 工程结构

```
entry/src/main/ets/
├── pages/Index.ets        书架首页（书架/传书/设置三 tab）
├── pages/ReaderPage.ets   阅读页（滑页动画、缩放、目录、书签）
├── pages/RenderBench.ets  开发者：渲染诊断台
├── pages/PdfViewDemo.ets  开发者：PdfView 手势调试
├── service/LibraryManager.ets  书库索引/元数据/封面缓存
├── service/TransferServer.ets  WiFi 传书 HTTP 服务
├── service/SettingsStore.ets   设置持久化（Preferences + AppStorage）
└── model/                  BookInfo / AppTheme
```

## 构建

DevEco Studio 打开工程直接 Build Hap；或命令行：

```
hvigorw assembleHap --mode module -p product=default --no-daemon
```

注意：仅真机（MatePad 11.5"S）验证过，未做其他机型的适配测试。
