import { common } from '@kit.AbilityKit';
import { router, window } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { scanCore, generateBarcode } from '@kit.ScanKit';
import { BookInfo } from '../model/BookInfo';
import { paletteOf, fontScaleOf, THEME_LIST, FONT_SCALES, FONT_NAMES, ThemePalette } from '../model/AppTheme';
import { LibraryManager } from '../service/LibraryManager';
import { SettingsStore } from '../service/SettingsStore';
import { TransferServer } from '../service/TransferServer';

interface ReceivedItem {
  name: string;
  size: number;
}

// 书架首页：顶栏 + 内容区（书架/传书/设置三 tab 丝滑横滑切换）+ 底部导航栏。
// 传书内嵌为 tab 内容（服务器随 tab 进出启停）；长按书卡弹中央编辑弹窗
// （改名+删除二合一）；顶栏搜索弹窗按关键词过滤书架。
@Entry
@Component
struct Index {
  @State books: BookInfo[] = [];
  @State importing: boolean = false;
  @State tab: number = 0;              // 0=书架 1=传书 2=设置
  @State tabDir: number = 1;           // 切换方向（内容滑入滑出用）
  @State menuBook?: BookInfo = undefined;
  @State etTitle: string = '';
  @State confirmDel: boolean = false;
  @State editY: number = 560;          // 编辑弹窗初始位（屏外下方）
  @State searchOpen: boolean = false;  // 搜索弹窗
  @State searchText: string = '';      // 弹窗输入中的关键词
  @State shelfFilter: string = '';     // 已生效的书名过滤词
  @State searchOp: number = 0;         // 搜索弹窗淡入淡出（0→1）
  // WiFi 传书（内嵌为 tab 内容区）
  @State trRunning: boolean = false;
  @State trErr: string = '';
  @State trIp: string = '0.0.0.0';
  @State qrPm?: image.PixelMap = undefined;   // 传书地址二维码
  @State received: ReceivedItem[] = [];
  private editOpenT: number = 0;
  private pressBook?: BookInfo = undefined;
  private pressT0: number = 0;
  private pressX: number = 0;
  private pressY: number = 0;
  private pressing: boolean = false;
  private lpFired: boolean = false;
  private lpTimer: number = -1;
  @StorageProp('themeIdx') themeIdx: number = 0;
  @StorageProp('fontIdx') fontIdx: number = 1;
  @StorageProp('fitWidthExp') fitWidthExp: boolean = false;
  @StorageProp('sortIdx') sortIdx: number = 0;
  @StorageProp('dualPageExp') dualPageExp: boolean = false;
  @StorageProp('tapTurn') tapTurn: boolean = true;
  @State devOpen: boolean = false;   // 开发者选项折叠，默认收起防误触
  @StorageLink('shelfDirty') @Watch('onShelfDirty') shelfDirty: number = 0;

  private getCtx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private fs(base: number): number {
    return Math.round(base * fontScaleOf(this.fontIdx));
  }

  private reload(): void {
    this.books = LibraryManager.scan(this.getCtx());
  }

  /** 扫描 + 对未抽取元数据/封面的书启动串行抽取（避免大文档互相拖慢） */
  private refresh(): void {
    this.reload();
    const pending: BookInfo[] = this.books.filter((b: BookInfo) => !b.enriched);
    const next = (): void => {
      const b = pending.shift();
      if (b === undefined) {
        return;
      }
      LibraryManager.enrichBook(this.getCtx(), b.fileName, () => {
        this.reload();
        next();
      });
    };
    next();
  }

  aboutToAppear(): void {
    this.refresh();
  }

  onPageShow(): void {
    this.refresh();
    // 全屏 + 上下黑边与阅读页一致，转场前后黑边连续，消除退出弹跳
    window.getLastWindow(this.getCtx()).then((w: window.Window) => {
      w.setWindowLayoutFullScreen(true);
    });
  }

  // 阅读页写进度/传书落盘时经 AppStorage 触发；走 refresh（含元数据/封面抽取）
  onShelfDirty(): void {
    this.refresh();
  }

  /** 离开书架页（进阅读页等）时停掉传书服务器 */
  onPageHide(): void {
    this.stopTransfer();
  }

  private openBook(b: BookInfo): void {
    router.pushUrl({ url: 'pages/ReaderPage', params: { fileName: b.fileName } });
  }

  private importDemo(): void {
    this.importing = true;
    LibraryManager.importDemoBooks(this.getCtx()).then(() => {
      this.importing = false;
      this.refresh();
    });
  }

  // 生效过滤+排序后的书架列表（搜索确认后按书名关键词过滤）
  private filteredBooks(): BookInfo[] {
    const q: string = this.shelfFilter.trim().toLowerCase();
    const list: BookInfo[] =
      q === '' ? this.books.slice() : this.books.filter((b: BookInfo) => b.title.toLowerCase().includes(q));
    if (this.sortIdx === 1) {
      list.sort((a: BookInfo, c: BookInfo) => a.title.localeCompare(c.title, 'zh'));
    } else if (this.sortIdx === 2) {
      // 进度排序：未读（无页数信息）沉底
      list.sort((a: BookInfo, c: BookInfo) => {
        const pa = a.pageCount > 0 ? a.page / a.pageCount : -1;
        const pc = c.pageCount > 0 ? c.page / c.pageCount : -1;
        return pc - pa;
      });
    }
    // sortIdx 0：scan 返回的已是最近打开顺序
    return list;
  }

  // 最近读过的书（继续阅读卡数据源；与排序方式无关）
  private lastReadBook(): BookInfo | undefined {
    let hit: BookInfo | undefined = undefined;
    for (const b of this.books) {
      if (b.lastOpen > 0 && (hit === undefined || b.lastOpen > hit.lastOpen)) {
        hit = b;
      }
    }
    return hit;
  }

  // ============ 底部导航切换（丝滑滑动 + 淡入淡出） ============

  private switchTab(t: number): void {
    if (t === this.tab) {
      return;
    }
    this.tabDir = t > this.tab ? 1 : -1;
    // 传书服务器的生命周期跟随 tab：进入传书 tab 启动，离开即停
    if (t === 1) {
      this.startTransfer();
    } else {
      this.stopTransfer();
    }
    this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseInOut }, () => {
      this.tab = t;
    });
  }

  // ============ WiFi 传书（内嵌 tab，服务器随 tab 进出启停） ============

  private startTransfer(): void {
    if (this.trRunning) {
      return;
    }
    const ctx = this.getCtx();
    LibraryManager.scan(ctx); // 确保 Books/ 目录存在
    TransferServer.get().start(ctx, {
      onSaved: (fileName: string, size: number) => {
        this.received.unshift({ name: fileName, size: size });
        // 书架回前台时会 scan 对账；这里顺手把索引对上，并通知书架刷新
        LibraryManager.scan(ctx);
        AppStorage.setOrCreate<number>('shelfDirty', (AppStorage.get<number>('shelfDirty') ?? 0) + 1);
      },
      onError: (msg: string) => {
        this.trErr = msg;
      }
    }).then(() => {
      this.trRunning = true;
      this.trIp = TransferServer.get().deviceIp();
      this.makeQr();
    }).catch((e: Error) => {
      this.trRunning = false;
      this.trErr = `启动失败：${e.message}`;
    });
  }

  // 传书地址二维码：手机扫码直达上传页（生成失败则只显示文字地址）
  private makeQr(): void {
    try {
      const opts: generateBarcode.CreateOptions = {
        scanType: scanCore.ScanType.QR_CODE,
        width: 400,
        height: 400,
        margin: 2,
        level: generateBarcode.ErrorCorrectionLevel.LEVEL_M,
        backgroundColor: 0xFFFFFF,
        pixelMapColor: 0x1A1A1A
      };
      generateBarcode.createBarcode(`http://${this.trIp}:8080`, opts).then((pm: image.PixelMap) => {
        this.qrPm = pm;
      }).catch(() => {
        this.qrPm = undefined;
      });
    } catch (e) {
      this.qrPm = undefined;
    }
  }

  private stopTransfer(): void {
    TransferServer.get().stop();
    this.trRunning = false;
    this.qrPm = undefined;
  }

  private fmtSize(bytes: number): string {
    if (bytes >= 1024 * 1024) {
      return (bytes / 1024 / 1024).toFixed(1) + ' MB';
    }
    return Math.max(1, Math.round(bytes / 1024)) + ' KB';
  }

  @Builder
  ReceivedList() {
    List({ space: 10 }) {
      ForEach(this.received, (r: ReceivedItem) => {
        ListItem() {
          Row({ space: 10 }) {
            Text('✓').fontSize(this.fs(16)).fontColor('#3DAB5B')
            Column({ space: 2 }) {
              Text(r.name).fontSize(this.fs(14)).maxLines(1)
                .fontColor(paletteOf(this.themeIdx).text)
              Text(this.fmtSize(r.size)).fontSize(this.fs(11))
                .fontColor(paletteOf(this.themeIdx).sub)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
        }
        .width('100%')
        .padding(12)
        .borderRadius(12)
        .backgroundColor(paletteOf(this.themeIdx).card)
        .transition(TransitionEffect.translate({ y: 40 }).animation({ duration: 280 }))
      }, (r: ReceivedItem) => r.name + r.size)
    }
    .padding(14)
    .layoutWeight(1)
    .width('100%')
  }

  // WiFi 传书内容区（原 TransferPage 内容移植，顶栏由书架顶栏统一承担）
  @Builder
  TransferView() {
    Column({ space: 18 }) {
      // 地址卡片
      Column({ space: 10 }) {
        Text(this.trRunning ? '服务已启动' : '服务未启动')
          .fontSize(this.fs(15))
          .fontColor(this.trRunning ? '#3DAB5B' : '#D94848')
        if (this.trRunning) {
          Text('电脑与平板连同一 WiFi，浏览器打开：')
            .fontSize(this.fs(13))
            .fontColor(paletteOf(this.themeIdx).sub)
          Text(`http://${this.trIp}:8080`)
            .fontSize(this.fs(22))
            .fontWeight(FontWeight.Bold)
            .fontColor(paletteOf(this.themeIdx).text)
            .copyOption(CopyOptions.LocalDevice)
          if (this.qrPm !== undefined) {
            Image(this.qrPm)
              .width(190).height(190)
              .borderRadius(10)
              .backgroundColor('#FFFFFF')
              .padding(8)
          }
          Text('在打开的页面里选择 PDF 上传，传完书架自动出现新书')
            .fontSize(this.fs(12))
            .fontColor(paletteOf(this.themeIdx).sub)
            .textAlign(TextAlign.Center)
        }
        if (this.trErr.length > 0) {
          Text(this.trErr).fontSize(this.fs(12)).fontColor('#D94848')
        }
      }
      .width('92%')
      .padding(18)
      .borderRadius(14)
      .backgroundColor(paletteOf(this.themeIdx).card)
      .margin({ top: 16 })

      Text(`已接收 ${this.received.length} 本`)
        .fontSize(this.fs(13))
        .fontColor(paletteOf(this.themeIdx).sub)
        .alignSelf(ItemAlign.Start)
        .padding({ left: 16 })

      this.ReceivedList()
    }
    .width('100%').height('100%')
  }

  // ============ 搜索弹窗（中央淡入，确认/取消） ============

  private openSearch(): void {
    this.searchText = this.shelfFilter;   // 回填当前过滤词，便于修改
    this.searchOp = 0;
    this.searchOpen = true;
    setTimeout(() => {
      this.searchOp = 1;
    }, 20);
  }

  private closeSearch(): void {
    this.searchOp = 0;
    setTimeout(() => {
      this.searchOpen = false;
    }, 200);
  }

  private applySearch(): void {
    this.shelfFilter = this.searchText.trim();
    this.closeSearch();
  }

  // ============ 长按编辑弹窗（从下方滑到中央，改名+删除二合一） ============

  private startEdit(b: BookInfo): void {
    this.menuBook = b;
    this.etTitle = b.title;
    this.confirmDel = false;
    this.editOpenT = Date.now();   // 弹窗打开的注入长按抬起会穿透点到遮罩，需短时限流
    this.editY = 560;
    // 下一帧滑入中央
    setTimeout(() => {
      this.editY = 0;
    }, 20);
  }

  private closeEdit(): void {
    this.editY = 560;
    setTimeout(() => {
      this.menuBook = undefined;
      this.confirmDel = false;
    }, 240);
  }

  private saveEdit(): void {
    if (this.menuBook !== undefined) {
      LibraryManager.editBook(this.getCtx(), this.menuBook.fileName, this.etTitle);
    }
    this.closeEdit();
    this.reload();
  }

  private doDelete(): void {
    if (this.menuBook !== undefined) {
      LibraryManager.deleteBook(this.getCtx(), this.menuBook.fileName);
    }
    this.closeEdit();
    this.reload();
  }

  private coverUri(b: BookInfo): string {
    return 'file://' + LibraryManager.coverPath(this.getCtx(), b.fileName);
  }

  private progressLine(b: BookInfo): string {
    if (b.lastOpen === 0) {
      return '未读';
    }
    return b.pageCount > 0 ? `第 ${b.page + 1}/${b.pageCount} 页` : `第 ${b.page + 1} 页`;
  }

  private bookKey(b: BookInfo): string {
    // ForEach 差分渲染按 key 判断，进度变了 key 必须变，否则 UI 不刷新
    return `${b.fileName}|${b.title}|${b.page}|${b.pageCount}|${b.hasCover}|${b.enriched}|${b.lastOpen}`;
  }

  // ============ 继续阅读卡（书架顶部横卡，点击直开最近读过的书） ============

  @Builder
  ContinueCard(b: BookInfo) {
    Row({ space: 14 }) {
      Stack() {
        if (b.hasCover) {
          Image(this.coverUri(b))
            .width('100%').height('100%')
            .objectFit(ImageFit.Cover)
        } else {
          Column() {
            Text('PDF').fontSize(14).fontColor(paletteOf(this.themeIdx).sub)
          }
          .width('100%').height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor(paletteOf(this.themeIdx).bg)
        }
      }
      .width(52).height(72)
      .borderRadius(6)
      .clip(true)
      Column({ space: 6 }) {
        Text(b.title)
          .fontSize(this.fs(15))
          .fontColor(paletteOf(this.themeIdx).text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(`读至 ${this.progressLine(b)}`)
          .fontSize(this.fs(12))
          .fontColor(paletteOf(this.themeIdx).sub)
        Text('继续阅读 ›')
          .fontSize(this.fs(13))
          .fontColor('#4C6EF5')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(14)
    .borderRadius(14)
    .backgroundColor(paletteOf(this.themeIdx).card)
    .onClick(() => this.openBook(b))
  }

  // ============ 书架网格卡片 ============

  @Builder
  BookCard(b: BookInfo) {
    Column({ space: 8 }) {
      Stack() {
        if (b.hasCover) {
          Image(this.coverUri(b)).objectFit(ImageFit.Cover)
            .width('100%').height('100%')
        } else {
          Column() {
            Text('PDF').fontSize(this.fs(20)).fontColor(paletteOf(this.themeIdx).sub)
          }
          .width('100%').height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor(paletteOf(this.themeIdx).card)
        }
      }
      .width('100%')
      .aspectRatio(0.74)
      .borderRadius(10)
      .clip(true)
      .shadow({ radius: 10, color: 'rgba(0,0,0,0.16)', offsetY: 3 })

      // 书名/页码居中，一行放不下自动两行（不超缩略图宽），两行仍放不下省略号
      Text(b.title).fontSize(this.fs(13)).maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontColor(paletteOf(this.themeIdx).text)
        .width('100%')
        .textAlign(TextAlign.Center)
      Text(this.progressLine(b)).fontSize(this.fs(11))
        .fontColor(paletteOf(this.themeIdx).sub)
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .stateStyles({
      pressed: {
        .opacity(0.82)
      },
      normal: {
        .opacity(1)
      }
    })
    .animation({ duration: 140, curve: Curve.EaseOut })
  }

  // ============ 设置页内容（自 SettingsPage 移植，随底部导航切换） ============

  // 分组小标题
  @Builder
  SectionLabel(text: string) {
    Text(text)
      .fontSize(13)
      .fontColor(paletteOf(this.themeIdx).sub)
      .width('100%')
      .padding({ left: 6, top: 12, bottom: 2 })
  }

  // 设置行：左图标 + 标题（无控件，控件区由调用方在下方追加）
  @Builder
  SettingRow(icon: string, title: string) {
    Row({ space: 12 }) {
      SymbolGlyph($r(icon))
        .fontSize(19)
        .fontColor(['#4C6EF5'])
      Text(title).fontSize(15)
        .fontColor(paletteOf(this.themeIdx).text)
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 13, bottom: 13 })
  }

  // 开关行：图标 + 标题/副标题 + 右侧开关
  @Builder
  ToggleRow(icon: string, title: string, subtitle: string, isOn: boolean,
    onChange: (on: boolean) => void) {
    Row({ space: 12 }) {
      SymbolGlyph($r(icon))
        .fontSize(19)
        .fontColor(['#4C6EF5'])
      Column({ space: 3 }) {
        Text(title).fontSize(15)
          .fontColor(paletteOf(this.themeIdx).text)
        Text(subtitle).fontSize(11)
          .fontColor(paletteOf(this.themeIdx).sub)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .selectedColor('#4C6EF5')
        .onChange(onChange)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 13, bottom: 13 })
  }

  // 卡片内分隔线（缩进与标题文字对齐；sub 低透明度深浅色主题均可见）
  @Builder
  RowDivider() {
    Column()
      .width('100%')
      .height(0.6)
      .backgroundColor(paletteOf(this.themeIdx).sub)
      .opacity(0.25)
      .margin({ left: 47 })
  }

  // 开发者条目（展开后的跳转/操作行）
  @Builder
  DevEntry(label: string, enabled: boolean, onTap: () => void) {
    Row() {
      Text(label).fontSize(14)
        .fontColor(enabled ? paletteOf(this.themeIdx).text : paletteOf(this.themeIdx).sub)
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_forward'))
        .fontSize(13)
        .fontColor([paletteOf(this.themeIdx).sub])
    }
    .width('100%')
    .padding({ left: 47, right: 16, top: 12, bottom: 12 })
    .enabled(enabled)
    .onClick(onTap)
  }

  @Builder
  SettingsView() {
    Scroll() {
      Column({ space: 8 }) {
        // ===== 外观 =====
        this.SectionLabel('外观')
        Column() {
          this.SettingRow('sys.symbol.paintpalette', '系统背景色')
          Row({ space: 14 }) {
            ForEach(THEME_LIST, (t: ThemePalette, idx: number) => {
              Column({ space: 5 }) {
                Column()
                  .width(46).height(46).borderRadius(23)
                  .backgroundColor(t.bg)
                  .border({
                    width: this.themeIdx === idx ? 3 : 1,
                    color: this.themeIdx === idx ? '#4C6EF5' : paletteOf(this.themeIdx).sub
                  })
                Text(t.name).fontSize(11)
                  .fontColor(paletteOf(this.themeIdx).sub)
              }
              .onClick(() => SettingsStore.setThemeIdx(idx))
            }, (t: ThemePalette, idx: number) => idx.toString())
          }
          .width('100%')
          .padding({ left: 47, right: 16, top: 2, bottom: 14 })
          this.RowDivider()
          this.SettingRow('sys.symbol.textformat_size_square', '界面字号')
          Row({ space: 12 }) {
            ForEach(FONT_SCALES, (s: number, idx: number) => {
              Button(FONT_NAMES[idx])
                .fontSize(Math.round(16 * s))
                .backgroundColor(this.fontIdx === idx ? '#4C6EF5' : paletteOf(this.themeIdx).bg)
                .fontColor(this.fontIdx === idx ? '#FFFFFF' : paletteOf(this.themeIdx).text)
                .onClick(() => SettingsStore.setFontIdx(idx))
            }, (s: number, idx: number) => idx.toString())
          }
          .width('100%')
          .padding({ left: 47, right: 16, top: 2, bottom: 4 })
          Text('示例：书名 · 第 12/389 页')
            .fontSize(Math.round(13 * fontScaleOf(this.fontIdx)))
            .fontColor(paletteOf(this.themeIdx).sub)
            .width('100%')
            .padding({ left: 47, right: 16, top: 2, bottom: 14 })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .backgroundColor(paletteOf(this.themeIdx).card)
        .borderRadius(16)

        // ===== 阅读 =====
        this.SectionLabel('阅读')
        Column() {
          this.ToggleRow('sys.symbol.crop', '裁切白边', '书页横向铺满屏幕，白边移至页面上下',
            this.fitWidthExp, (on: boolean) => SettingsStore.setFitWidthExp(on))
          this.RowDivider()
          this.ToggleRow('sys.symbol.book_open_fill', '横屏双页', '横屏时左右各一页拼对子，竖屏不受影响',
            this.dualPageExp, (on: boolean) => SettingsStore.setDualPageExp(on))
          this.RowDivider()
          this.ToggleRow('sys.symbol.hand_tap', '点击翻页', '点击页面左右两侧翻到上/下一页',
            this.tapTurn, (on: boolean) => SettingsStore.setTapTurn(on))
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .backgroundColor(paletteOf(this.themeIdx).card)
        .borderRadius(16)

        // ===== 书架 =====
        this.SectionLabel('书架')
        Column() {
          this.SettingRow('sys.symbol.sort', '书架排序')
          Row({ space: 12 }) {
            ForEach(['最近打开', '书名', '进度'], (name: string, idx: number) => {
              Button(name)
                .fontSize(14)
                .backgroundColor(this.sortIdx === idx ? '#4C6EF5' : paletteOf(this.themeIdx).bg)
                .fontColor(this.sortIdx === idx ? '#FFFFFF' : paletteOf(this.themeIdx).text)
                .onClick(() => SettingsStore.setSortIdx(idx))
            }, (name: string, idx: number) => idx.toString())
          }
          .width('100%')
          .padding({ left: 47, right: 16, top: 2, bottom: 14 })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .backgroundColor(paletteOf(this.themeIdx).card)
        .borderRadius(16)

        // 开发者（默认折叠在「开发者选项」入口后，防误触）
        Column() {
          Row({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.wrench_and_screwdriver'))
              .fontSize(19)
              .fontColor(['#4C6EF5'])
            Text('开发者选项').fontSize(15)
              .fontColor(paletteOf(this.themeIdx).text)
              .layoutWeight(1)
            SymbolGlyph($r(this.devOpen ? 'sys.symbol.chevron_down' : 'sys.symbol.chevron_forward'))
              .fontSize(14)
              .fontColor([paletteOf(this.themeIdx).sub])
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 13, bottom: 13 })
          .onClick(() => {
            this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
              this.devOpen = !this.devOpen;
            });
          })
          if (this.devOpen) {
            Column() {
              this.RowDivider()
              this.DevEntry('渲染调试台', true, () => router.pushUrl({ url: 'pages/RenderBench' }))
              this.RowDivider()
              this.DevEntry('PdfView 手势调试', true, () => router.pushUrl({ url: 'pages/PdfViewDemo' }))
              this.RowDivider()
              this.DevEntry(this.importing ? '导入中…' : '导入测试书', !this.importing, () => this.importDemo())
            }
            .width('100%')
            .transition(TransitionEffect.OPACITY
              .combine(TransitionEffect.translate({ y: -10 })))
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .margin({ top: 12 })
        .backgroundColor(paletteOf(this.themeIdx).card)
        .borderRadius(16)

        Text('PageArk · v1.0.0')
          .fontSize(12).fontColor(paletteOf(this.themeIdx).sub)
          .margin({ top: 12 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 24 })
    }
    .scrollBar(BarState.Off)
  }

  // ============ 底部导航项 ============

  @Builder
  NavItem(idx: number, icon: string, label: string) {
    Column({ space: 3 }) {
      if (this.tab === idx) {
        Column()
          .width(22).height(3).borderRadius(2)
          .backgroundColor('#FFFFFF')
          .margin({ bottom: 2 })
          .opacity(this.tab === idx ? 1 : 0)
      } else {
        Column().width(22).height(3).margin({ bottom: 2 })
      }
      SymbolGlyph($r(icon))
        .fontSize(23)
        .fontColor(this.tab === idx ? ['#FFFFFF'] : ['rgba(255,255,255,0.42)'])
      Text(label)
        .fontSize(11)
        .fontColor(this.tab === idx ? '#FFFFFF' : 'rgba(255,255,255,0.42)')
    }
    .layoutWeight(1)
    .onClick(() => {
      // 三 tab 统一走内容区切换（传书不再 push 独立页面）
      this.switchTab(idx);
    })
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        // 顶栏（黑色，与阅读页同款黑边，盖住状态栏安全区）：标题 + 搜索图标
        Row() {
          Text('PageArk').fontSize(this.fs(22)).fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
          Blank()
          if (this.tab === 0) {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(22)
              .fontColor([this.shelfFilter.trim() !== '' ? '#7B9CFF' : '#FFFFFF'])
              .onClick(() => this.openSearch())
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 40, bottom: 14 })
        .backgroundColor('rgba(17,17,17,0.92)')

        // 内容区：书架 / 设置，丝滑横滑切换
        Stack() {
          if (this.tab === 0) {
            Column() {
              if (this.books.length === 0) {
                Column({ space: 14 }) {
                  Text('书架还是空的').fontSize(this.fs(16))
                    .fontColor(paletteOf(this.themeIdx).sub)
                  Button('导入书籍')
                    .onClick(() => this.switchTab(1))
                }
                .layoutWeight(1)
                .width('100%')
                .justifyContent(FlexAlign.Center)
              } else {
                // 继续阅读卡：仅无搜索条件且有阅读记录时显示
                if (this.shelfFilter.trim() === '' && this.lastReadBook() !== undefined) {
                  Row() {
                    this.ContinueCard(this.lastReadBook() as BookInfo)
                  }
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 12, bottom: 0 })
                }
                // 生效中的过滤条件 chip（可一键清除）
                if (this.shelfFilter.trim() !== '') {
                  Row({ space: 8 }) {
                    Text(`匹配「${this.shelfFilter.trim()}」`)
                      .fontSize(this.fs(12))
                      .fontColor(paletteOf(this.themeIdx).sub)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                    Text('清除')
                      .fontSize(this.fs(12))
                      .fontColor('#4C6EF5')
                      .padding(4)
                      .onClick(() => {
                        this.shelfFilter = '';
                      })
                  }
                  .width('100%')
                  .padding({ left: 16, right: 12, top: 10, bottom: 2 })
                }
                if (this.filteredBooks().length === 0) {
                  Column({ space: 12 }) {
                    Text(`没有找到匹配「${this.shelfFilter.trim()}」的书`)
                      .fontSize(this.fs(14))
                      .fontColor(paletteOf(this.themeIdx).sub)
                    Button('清除搜索条件')
                      .fontSize(this.fs(13))
                      .backgroundColor(paletteOf(this.themeIdx).card)
                      .fontColor(paletteOf(this.themeIdx).text)
                      .onClick(() => {
                        this.shelfFilter = '';
                      })
                  }
                  .layoutWeight(1)
                  .width('100%')
                  .justifyContent(FlexAlign.Center)
                } else {
                  Grid() {
                    ForEach(this.filteredBooks(), (b: BookInfo) => {
                      GridItem() {
                        this.BookCard(b)
                      }
                      .onTouch((e: TouchEvent) => {
                        if (e.type === TouchType.Down) {
                          this.pressBook = b;
                          this.pressT0 = Date.now();
                          this.pressX = e.touches[0].x;
                          this.pressY = e.touches[0].y;
                          this.pressing = true;
                          this.lpFired = false;
                          this.lpTimer = setTimeout(() => {
                            if (this.pressing && !this.lpFired && this.pressBook) {
                              this.lpFired = true;
                              this.startEdit(this.pressBook);
                            }
                          }, 550);
                        } else if (e.type === TouchType.Move) {
                          if (this.pressing && !this.lpFired) {
                            const dx = e.touches[0].x - this.pressX;
                            const dy = e.touches[0].y - this.pressY;
                            if (Math.sqrt(dx * dx + dy * dy) > 20) {
                              this.pressing = false;
                              if (this.lpTimer !== -1) {
                                clearTimeout(this.lpTimer);
                                this.lpTimer = -1;
                              }
                            }
                          }
                        } else if (e.type === TouchType.Up) {
                          if (this.lpTimer !== -1) {
                            clearTimeout(this.lpTimer);
                            this.lpTimer = -1;
                          }
                          const held = Date.now() - this.pressT0;
                          if (this.pressing && !this.lpFired && held < 550) {
                            this.openBook(b);
                          }
                          this.pressing = false;
                        } else if (e.type === TouchType.Cancel) {
                          this.pressing = false;
                          if (this.lpTimer !== -1) {
                            clearTimeout(this.lpTimer);
                            this.lpTimer = -1;
                          }
                        }
                      })
                    }, (b: BookInfo) => this.bookKey(b))
                  }
                  .columnsTemplate('1fr 1fr 1fr')
                  .columnsGap(14)
                  .rowsGap(20)
                  .padding(16)
                  .layoutWeight(1)
                  .width('100%')
                }
              }
            }
            .width('100%').height('100%')
            // 方向感知横滑：appear=+tabDir*90、disappear=-tabDir*90，两端同向
            // 才连贯（appear 符号写反会与旧页对向交叉，是"方向不一致"的元凶）
            .transition(TransitionEffect.asymmetric(
              TransitionEffect
                .translate({ x: this.tabDir * 90 })
                .combine(TransitionEffect.opacity(0)),
              TransitionEffect
                .translate({ x: -this.tabDir * 90 })
                .combine(TransitionEffect.opacity(0))))
          } else if (this.tab === 1) {
            // 传书 tab：内容区横滑换成 WiFi 传书
            Column() {
              this.TransferView()
            }
            .width('100%').height('100%')
            // 与书架块同款约定，disappear 写成 +tabDir*90 会反向交叉
            .transition(TransitionEffect.asymmetric(
              TransitionEffect
                .translate({ x: this.tabDir * 90 })
                .combine(TransitionEffect.opacity(0)),
              TransitionEffect
                .translate({ x: -this.tabDir * 90 })
                .combine(TransitionEffect.opacity(0))))
          } else {
            Column() {
              this.SettingsView()
            }
            .width('100%').height('100%')
            .transition(TransitionEffect.asymmetric(
              TransitionEffect
                .translate({ x: this.tabDir * 90 })
                .combine(TransitionEffect.opacity(0)),
              TransitionEffect
                .translate({ x: -this.tabDir * 90 })
                .combine(TransitionEffect.opacity(0))))
          }
        }
        .layoutWeight(1)
        .width('100%')

        // 底部黑色导航栏：书架 · 传书 · 设置（与阅读页底栏同宽同色的黑）
        Row() {
          this.NavItem(0, 'sys.symbol.house_fill', '书架')
          this.NavItem(1, 'sys.symbol.plus_square_on_square', '传书')
          this.NavItem(2, 'sys.symbol.gearshape', '设置')
        }
        .width('100%')
        .height(66)
        .backgroundColor('rgba(17,17,17,0.92)')
      }
      .width('100%').height('100%')
      .backgroundColor(paletteOf(this.themeIdx).bg)

      // ===== 长按编辑弹窗：下方滑入中央，改名 + 删除二合一 =====
      if (this.menuBook !== undefined) {
        Column()
          .width('100%').height('100%')
          .backgroundColor('rgba(0,0,0,0.45)')
          .opacity(this.editY === 0 ? 1 : 0)
          .animation({ duration: 240 })
          .onClick(() => {
            if (Date.now() - this.editOpenT > 400) {
              this.closeEdit();
            }
          })
        Column() {
          Column({ space: 14 }) {
            Text(`《${this.menuBook === undefined ? '' : this.menuBook.title}》`)
              .fontSize(this.fs(14)).maxLines(1)
              .fontColor(paletteOf(this.themeIdx).sub)

            if (this.confirmDel) {
              // 删除二次确认（同一弹窗内切换）
              Text(`确认删除《${this.menuBook === undefined ? '' : this.menuBook.title}》？`)
                .fontSize(this.fs(15))
                .fontColor('#D94848')
              Text('文件和阅读进度将一并删除，无法恢复。')
                .fontSize(this.fs(12))
                .fontColor(paletteOf(this.themeIdx).sub)
              Row({ space: 10 }) {
                Button('再想想')
                  .layoutWeight(1)
                  .backgroundColor(paletteOf(this.themeIdx).bg)
                  .fontColor(paletteOf(this.themeIdx).text)
                  .onClick(() => {
                    this.confirmDel = false;
                  })
                Button('确认删除')
                  .layoutWeight(1)
                  .backgroundColor('#D94848')
                  .fontColor('#FFFFFF')
                  .onClick(() => this.doDelete())
              }
              .width('100%')
            } else {
              TextInput({ text: this.etTitle, placeholder: '给这本书起个好听的名字' })
                .fontSize(this.fs(15))
                .fontColor(paletteOf(this.themeIdx).text)
                .placeholderColor(paletteOf(this.themeIdx).sub)
                .backgroundColor(paletteOf(this.themeIdx).bg)
                .padding(12)
                .onChange((v: string) => {
                  this.etTitle = v;
                })
              Button('删除这本书')
                .width('100%')
                .backgroundColor(Color.Transparent)
                .fontColor('#D94848')
                .border({ width: 1, color: '#D9484888' })
                .onClick(() => {
                  this.confirmDel = true;
                })
              Row({ space: 10 }) {
                Button('取消')
                  .layoutWeight(1)
                  .backgroundColor(paletteOf(this.themeIdx).bg)
                  .fontColor(paletteOf(this.themeIdx).text)
                  .onClick(() => this.closeEdit())
                Button('确认')
                  .layoutWeight(1)
                  .backgroundColor('#4C6EF5')
                  .fontColor('#FFFFFF')
                  .enabled(this.etTitle.trim().length > 0)
                  .onClick(() => this.saveEdit())
              }
              .width('100%')
            }
          }
          .width('84%')
          .padding(20)
          .borderRadius(18)
          .backgroundColor(paletteOf(this.themeIdx).card)
          .translate({ y: this.editY })
          .animation({ duration: 280, curve: Curve.EaseOut })
          .onClick(() => {
          })
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center)
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // ===== 搜索弹窗：中央淡入，输入 + 确认/取消 =====
      if (this.searchOpen) {
        Column()
          .width('100%').height('100%')
          .backgroundColor('rgba(0,0,0,0.45)')
          .opacity(this.searchOp)
          .animation({ duration: 200 })
          .onClick(() => this.closeSearch())
        Column() {
          Blank()
          Column({ space: 14 }) {
            Text('搜索书目').fontSize(this.fs(16)).fontWeight(FontWeight.Medium)
              .fontColor(paletteOf(this.themeIdx).text)
            TextInput({ placeholder: '输入书名关键词', text: this.searchText })
              .fontSize(this.fs(15))
              .fontColor(paletteOf(this.themeIdx).text)
              .placeholderColor(paletteOf(this.themeIdx).sub)
              .backgroundColor(paletteOf(this.themeIdx).bg)
              .padding(12)
              .onChange((v: string) => {
                this.searchText = v;
              })
              .onSubmit(() => this.applySearch())
            Row({ space: 10 }) {
              Button('取消')
                .layoutWeight(1)
                .backgroundColor(paletteOf(this.themeIdx).bg)
                .fontColor(paletteOf(this.themeIdx).text)
                .onClick(() => this.closeSearch())
              Button('确认')
                .layoutWeight(1)
                .backgroundColor('#4C6EF5')
                .fontColor('#FFFFFF')
                .onClick(() => this.applySearch())
            }
            .width('100%')
          }
          .width('84%')
          .padding(20)
          .borderRadius(18)
          .backgroundColor(paletteOf(this.themeIdx).card)
          .opacity(this.searchOp)
          .translate({ y: (1 - this.searchOp) * 24 })
          .animation({ duration: 220, curve: Curve.EaseOut })
          .onClick(() => {
          })
          Blank()
        }
        .width('100%').height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
      }
    }
    .width('100%').height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
