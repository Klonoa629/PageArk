import { pdfService, pdfViewManager, PdfView } from '@kit.PDFKit';
import { common } from '@kit.AbilityKit';
import { router, window, display } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { BookInfo } from '../model/BookInfo';
import { LibraryManager } from '../service/LibraryManager';

interface RectVp {
  x: number;
  y: number;
  w: number;
  h: number;
}

// 目录大纲条目（pdfService.Bookmark 递归抽取后的平面列表）
interface OutlineItem {
  title: string;
  pageIndex: number;   // 0 基，与 pageIdx 一致
  depth: number;
}

// 阅读页：PdfView 沉浸式阅读。正常态 Block 层拦截触摸（三分区点击、横扫自判、
// 捏合缩放）；放大态触摸直达 PdfView（原生平移+原生捏合）；翻页主路径 ghost
// PdfView 滑页，位图覆盖层与白罩瞬切为兜底。页码一律 PDF 内部页序（0 基）。
@Entry
@Component
struct ReaderPage {
  @State pageIdx: number = 0;
  @State pageCount: number = 0;
  @State error: string = '';
  @State jumpText: string = '';
  @State jumpBad: boolean = false;   // 非法页码提示弹窗
  @State jumpBadOp: number = 0;      // 弹窗淡入淡出（0→1）
  @State tocList: OutlineItem[] = []; // 目录大纲（无目录的书为空）
  @State tocOpen: boolean = false;   // 目录弹窗
  @State tocOp: number = 0;
  @State markedPages: number[] = []; // 本书书签页码（0 基，升序）
  @State bmOpen: boolean = false;    // 书签列表弹窗
  @State bmOp: number = 0;
  @State zoomed: boolean = false;
  @State barsOpen: boolean = false;
  @State screenH: number = 0;
  // 滑页动画态：flipOff 由 animateTo 驱动（旧页/新页共用同一偏移，相隔一屏）
  @State flipping: boolean = false;
  @State flipOff: number = 0;
  @State coverOp: number = 0;   // 白罩瞬切遮罩
  // ghost PdfView：第二个 PdfView 常显沉在主视图底下预渲染下一页（移出屏外或
  // 近零透明度会被框架跳过光栅化），翻页时抬 z 滑入盖住主视图，全程矢量无模糊
  @State ghostX: number = 0;
  @State ghostZ: number = -1;           // 平时 -1 沉底；滑页时抬到 5
  @State ghostHidden: boolean = false;  // 放大态平移/捏合期 ghost Hidden 卸载

  private fileName: string = '';
  private title: string = '';
  private controller: pdfViewManager.PdfController = new pdfViewManager.PdfController();
  private ghostCtl: pdfViewManager.PdfController = new pdfViewManager.PdfController();
  private ghostReady: boolean = false;   // ghost 装载成功才走 ghost 滑页
  private ghostPage: number = -1;        // ghost 当前渲染的页序，预取跟踪用
  private inited: boolean = false;
  private screenWvp: number = 0;
  private screenHvp: number = 0;
  private pinchStartZoom: number = 1;  // pinch 起手时的当前缩放（getPageZoom）
  private fitZoom: number = 0;         // 正常态（fit）基准缩放，首次 pinch 起手校准
  // onTouch 横扫跟踪（仅单指）
  private tStartX: number = 0;
  private tStartY: number = 0;
  private tStartT: number = 0;
  private tTracking: boolean = false;
  // 滑页动画私有态
  private flipBusy: boolean = false;
  private flipOld: number = 0;
  private flipTarget: number = 0;
  private flipDir: number = 1;
  private rectX: number = 0;
  private rectY: number = 0;
  private rectW: number = 0;
  private rectH: number = 0;
  // 滑页新页 rect：按新页自身纵横比 FIT_PAGE 居中（旧版共用旧页 rect 拉伸，
  // 横版页翻入瞬间被拉变形）
  private newRectX: number = 0;
  private newRectY: number = 0;
  private newRectW: number = 0;
  private newRectH: number = 0;
  // 缩小归位插值进行中标志：插值穿越 fit×1.02 区域时监听器不得插手
  private settling: boolean = false;
  private settleTimer: number = -1;
  private pmCache: Map<number, image.PixelMap> = new Map();
  private scrollP: pdfViewManager.ScrollParam | undefined = undefined;
  // 双击复位/回落的 zoom 手动插值动画
  private zoomAnimId: number = -1;
  // 滑页覆盖层高清渲染通道：pdfService 双开同文档（缩略图通道分辨率太低会发虚）
  private pdfDocument: pdfService.PdfDocument | undefined = undefined;
  private densityPx: number = 2;
  // 捏合手势进行中标志：手势内禁止回落插值与手势写 zoom 竞争
  private pinching: boolean = false;
  private lastAppliedZoom: number = 0;
  // 归位适配模式：整页适配 / 裁切白边开启时为宽度适配，一切 setPageFit 归位都回这里
  private fitMode: pdfService.PageFit = pdfService.PageFit.FIT_PAGE;
  // 横屏双页：展开态 = 横屏 && 开关。左右两个 PdfView 拼对子整对翻页，缩放关闭
  private dualExp: boolean = false;
  private landscape: boolean = false;
  @State spreadOn: boolean = false;   // 必须是 @State：visibility 绑定依赖它刷新
  @State spreadReady: boolean = false;
  @State spreadRValid: boolean = true;
  private spreadLCtl: pdfViewManager.PdfController = new pdfViewManager.PdfController();
  private spreadRCtl: pdfViewManager.PdfController = new pdfViewManager.PdfController();
  private spreadLoaded: boolean = false;   // 横竖往返时避免重复 loadDocument
  // 点击翻页开关（设置）：关闭后点左右两侧不再翻页
  private tapTurn: boolean = true;

  private getCtx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, string>;
    this.fileName = params !== undefined ? params['fileName'] : '';
  }

  onPageShow(): void {
    if (this.inited) {
      return;
    }
    this.inited = true;
    if (this.fileName === '') {
      this.error = '缺少文件参数';
      return;
    }
    const entry: BookInfo | undefined = LibraryManager.getBook(this.getCtx(), this.fileName);
    this.title = entry !== undefined ? entry.title : this.fileName;
    if (entry !== undefined && entry.bookmarks !== undefined) {
      this.markedPages = entry.bookmarks.slice();
    }
    if (AppStorage.get<boolean>('fitWidthExp') === true) {
      this.fitMode = pdfService.PageFit.FIT_WIDTH;
    }

    const d = display.getDefaultDisplaySync();
    this.screenWvp = Math.round(d.width / d.densityPixels);
    this.screenHvp = Math.round(d.height / d.densityPixels);
    this.screenH = this.screenHvp;   // @State：触发底栏 position 重渲染
    this.densityPx = d.densityPixels;
    this.landscape = this.screenWvp > this.screenHvp;
    this.dualExp = AppStorage.get<boolean>('dualPageExp') === true;
    this.spreadOn = this.landscape && this.dualExp;
    this.tapTurn = AppStorage.get<boolean>('tapTurn') !== false;
    display.on('change', this.onDisplayChange);

    // 高清渲染通道双开文档（与 PdfView 同文件；失败则滑页降级用缩略图）
    try {
      const doc: pdfService.PdfDocument = new pdfService.PdfDocument();
      const r: pdfService.ParseResult =
        doc.loadDocument(LibraryManager.booksDir(this.getCtx()) + '/' + this.fileName);
      if (r === pdfService.ParseResult.PARSE_SUCCESS) {
        this.pdfDocument = doc;
        this.tocList = this.extractOutline(doc);
      }
    } catch (e) {
      this.pdfDocument = undefined;
    }

    // 页数监听必须在 loadDocument 之前注册（官方文档要求）
    this.controller.registerPageCountChangedListener((n: number) => {
      this.pageCount = n;
    });
    this.controller.registerPageChangedListener((idx: number) => {
      this.syncFrom(idx);
    });
    // 滚动监听：拿缩放后页面尺寸与偏移，用于滑页覆盖层的精确对位
    this.controller.registerScrollListener((p: pdfViewManager.ScrollParam) => {
      this.scrollP = p;
    });
    // 放大态实时钳制：原生捏合绕过手势钳制，zoom 跌破 fit×1.02 立即推回
    // （绝不允许缩到正常尺寸以下）；低于 fit×1.15 视为想缩回，手势停 160ms
    // 后插值归位
    this.controller.registerScaleChangedListener((zoom: number) => {
      if (!this.zoomed || this.settling || this.fitZoom <= 0) {
        return;
      }
      if (zoom < this.fitZoom * 1.02) {
        this.controller.setPageZoom(this.fitZoom * 1.02);
      }
      if (zoom < this.fitZoom * 1.15) {
        this.scheduleSettle();
      }
    });
    this.controller.loadDocument(LibraryManager.booksDir(this.getCtx()) + '/' + this.fileName)
      .then(() => {
        this.controller.enablePageDrag(false, false);
        this.controller.setPageFit(this.fitMode);
        // 平移期逐帧重栅格、倍率越高负载越重，限 2.5x 保流畅（细节仍够用）
        this.controller.setMaxZoom(2.5);
        const start = entry !== undefined ? entry.page : 0;
        if (start > 0) {
          this.controller.goToPage(start);
        }
        if (this.spreadOn) {
          // 横屏双页：主视图只做页数/页码源，画面交给左右拼对子
          this.setupSpread(start);
        } else {
          // 预渲染当前页与邻页像素图（滑页动画素材）
          setTimeout(() => {
            this.prefetchAround();
          }, 200);
          this.loadGhost();
        }
        window.getLastWindow(this.getCtx()).then((w: window.Window) => {
          w.setWindowKeepScreenOn(true);
          w.setWindowLayoutFullScreen(true);
        });
      })
      .catch(() => {
        this.error = '文档打开失败';
      });
  }

  // ghost 装载：与主视图同文件二次打开，串行放在主视图装载完成后避免双开竞争
  private loadGhost(): void {
    const path: string = LibraryManager.booksDir(this.getCtx()) + '/' + this.fileName;
    this.ghostCtl.loadDocument(path).then(() => {
      this.ghostCtl.setPageFit(this.fitMode);
      const cur: number = this.controller.getPageIndex();
      if (cur > 0) {
        this.ghostCtl.goToPage(cur);
      }
      this.ghostPage = cur;
      this.ghostReady = true;
      // 空闲期预取下一页：同向连翻免光栅等待
      setTimeout(() => {
        this.ghostPrefetch(1);
      }, 300);
    }).catch(() => {
      this.ghostReady = false;
    });
  }

  // ============ 横屏双页 ============

  // 展开态初始化：左右视图同文件双开各显一页（左偶右奇）。强制 FIT_PAGE：
  // 半屏 FIT_WIDTH 页高超屏被裁（实测"显示不完整"）。已装载过只归位不重复 loadDocument
  private setupSpread(start: number): void {
    const base = start - (start % 2);
    const path: string = LibraryManager.booksDir(this.getCtx()) + '/' + this.fileName;
    if (this.spreadLoaded) {
      this.spreadLCtl.setPageFit(pdfService.PageFit.FIT_PAGE);
      this.spreadLCtl.goToPage(base);
      if (base + 1 < this.pageCount) {
        this.spreadRValid = true;
        this.spreadRCtl.setPageFit(pdfService.PageFit.FIT_PAGE);
        this.spreadRCtl.goToPage(base + 1);
      } else {
        this.spreadRValid = false;
      }
      this.spreadReady = true;
      return;
    }
    this.spreadLCtl.loadDocument(path).then(() => {
      this.spreadLCtl.enablePageDrag(false, false);
      this.spreadLCtl.setPageFit(pdfService.PageFit.FIT_PAGE);
      this.spreadLCtl.goToPage(base);
      this.spreadRCtl.loadDocument(path).then(() => {
        this.spreadRCtl.enablePageDrag(false, false);
        this.spreadRCtl.setPageFit(pdfService.PageFit.FIT_PAGE);
        if (base + 1 < this.pageCount) {
          this.spreadRValid = true;
          this.spreadRCtl.goToPage(base + 1);
        } else {
          this.spreadRValid = false;
        }
        this.spreadLoaded = true;
        this.spreadReady = true;
      }).catch(() => {
        this.spreadReady = false;
      });
    }).catch(() => {
      this.spreadReady = false;
    });
  }

  // 整对翻页：白罩淡入遮瞬切 → 左右切页 → 淡出 reveal（展开态不做滑页动画：
  // 滑页需 4 个 XComponent 同屏，负载翻倍，先保稳）
  private spreadGoTo(base: number): void {
    this.flipBusy = true;
    this.getUIContext().animateTo({ duration: 120, curve: Curve.EaseIn }, () => {
      this.coverOp = 1;
    });
    setTimeout(() => {
      this.spreadLCtl.setPageFit(pdfService.PageFit.FIT_PAGE);
      this.spreadLCtl.goToPage(base);
      if (base + 1 < this.pageCount) {
        this.spreadRValid = true;
        this.spreadRCtl.setPageFit(pdfService.PageFit.FIT_PAGE);
        this.spreadRCtl.goToPage(base + 1);
      } else {
        this.spreadRValid = false;
      }
      this.syncFrom(base);
      setTimeout(() => {
        this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
          this.coverOp = 0;
        });
      }, 60);
    }, 130);
    setTimeout(() => {
      this.flipBusy = false;
    }, 420);
  }

  // 旋转/折叠方向变化：重取屏幕尺寸重配渲染模式。回调里 display 尺寸可能
  // 尚未刷新（官方 FAQ），延迟 300ms 再读
  private onDisplayChange = (): void => {
    setTimeout(() => {
      const d = display.getDefaultDisplaySync();
      this.screenWvp = Math.round(d.width / d.densityPixels);
      this.screenHvp = Math.round(d.height / d.densityPixels);
      this.screenH = this.screenHvp;
      this.densityPx = d.densityPixels;
      const land = this.screenWvp > this.screenHvp;
      if (land === this.landscape) {
        if (!this.spreadOn) {
          this.controller.setPageFit(this.fitMode);
        }
        return;
      }
      this.landscape = land;
      this.spreadOn = land && this.dualExp;
      if (this.spreadOn) {
        this.setupSpread(this.pageIdx);
      } else {
        // 回竖屏：收起展开层，主视图归位当前对子首页；ghost 没装过则补装
        this.spreadReady = false;
        this.controller.setPageFit(this.fitMode);
        this.controller.goToPage(this.pageIdx);
        if (!this.ghostReady) {
          this.loadGhost();
        }
      }
    }, 300);
  };

  aboutToDisappear(): void {
    display.off('change', this.onDisplayChange);
    if (this.zoomAnimId >= 0) {
      clearInterval(this.zoomAnimId);
      this.zoomAnimId = -1;
    }
    if (this.settleTimer >= 0) {
      clearTimeout(this.settleTimer);
      this.settleTimer = -1;
    }
    // 窗口保持全屏不回退：书架同为全屏+上下黑边，转场黑边连续，消除退出弹跳
    window.getLastWindow(this.getCtx()).then((w: window.Window) => {
      w.setWindowKeepScreenOn(false);
    });
  }

  // 页码同步 + 进度回写（回调与校正两条路都走这里，保证一致）
  private syncFrom(idx: number): void {
    this.pageIdx = idx;
    LibraryManager.updateProgress(this.getCtx(), this.fileName, idx, this.pageCount);
    AppStorage.setOrCreate('shelfDirty', Date.now());
  }

  // ============ 滑页动画（双 Image 覆盖层，ghost 的兜底路径） ============

  // 当前页在屏幕上的精确位置（vp）：FIT_PAGE 非连续单页模式下页面在视口居中，
  // ScrollParam 的 offset 是滚动量（居中时为 0），故用居中模型 + 缩放后页面尺寸换算
  private pageRectVp(): RectVp {
    const p = this.scrollP;
    if (p === undefined || p.pdfWidth <= 0 || p.viewWidth <= 0) {
      return { x: 0, y: 0, w: this.screenWvp, h: this.screenHvp };
    }
    const wVp = p.pdfWidth * (this.screenWvp / p.viewWidth);
    const hVp = p.pdfHeight * (this.screenHvp / p.viewHeight);
    return {
      x: (this.screenWvp - wVp) / 2,
      y: (this.screenHvp - hVp) / 2,
      w: wVp,
      h: hVp
    };
  }

  // 指定页按自身纵横比 FIT_PAGE 居中的 rect（滑页新页落点 / 复位动画终点）。
  // 优先 pdfDocument 拿页面 pt 尺寸；否则从已渲染像素图反推纵横比
  private async pageRectFit(idx: number, pm?: image.PixelMap): Promise<RectVp> {
    let wPt = 0;
    let hPt = 0;
    const doc = this.pdfDocument;
    if (doc !== undefined) {
      try {
        const pg: pdfService.PdfPage = doc.getPage(idx);
        wPt = pg.getWidth();
        hPt = pg.getHeight();
      } catch (e) {
        wPt = 0;
      }
    }
    if (wPt <= 0 && pm !== undefined) {
      try {
        const info = await pm.getImageInfo();
        wPt = info.size.width;
        hPt = info.size.height;
      } catch (e) {
        wPt = 0;
      }
    }
    if (wPt <= 0 || hPt <= 0) {
      return this.pageRectVp();
    }
    if (this.fitMode === pdfService.PageFit.FIT_WIDTH) {
      // 宽度适配：横向铺满、纵向居中（页高超屏时 y 为负，translate 允许出屏）
      const s: number = this.screenWvp / wPt;
      const h: number = hPt * s;
      return { x: 0, y: (this.screenHvp - h) / 2, w: this.screenWvp, h };
    }
    const s: number = Math.min(this.screenWvp / wPt, this.screenHvp / hPt);
    const w: number = wPt * s;
    const h: number = hPt * s;
    return { x: (this.screenWvp - w) / 2, y: (this.screenHvp - h) / 2, w, h };
  }

  private async ensurePm(idx: number, widthVp?: number): Promise<image.PixelMap | undefined> {
    if (idx < 0 || this.pageCount <= 0 || idx >= this.pageCount) {
      return undefined;
    }
    const hit = this.pmCache.get(idx);
    if (hit !== undefined) {
      return hit;
    }
    try {
      let pm: image.PixelMap;
      const doc = this.pdfDocument;
      if (doc !== undefined) {
        // 高清通道：按页面在屏幕上的显示物理像素渲染（缩略图通道会发虚）
        const page: pdfService.PdfPage = doc.getPage(idx);
        const wPt: number = page.getWidth();
        const hPt: number = page.getHeight();
        const p = this.scrollP;
        let wPx: number;
        if (widthVp !== undefined && widthVp > 0) {
          wPx = Math.round(widthVp * this.densityPx);
        } else if (p !== undefined && p.pdfWidth > 0 && p.viewWidth > 0) {
          const rectWvp = p.pdfWidth * (this.screenWvp / p.viewWidth);
          wPx = Math.round(rectWvp * this.densityPx);
        } else {
          wPx = Math.round(this.screenWvp * this.densityPx);
        }
        // 门控：getAreaPixelMap 引擎从不上采样——页面 pt 宽小于目标像素宽时
        // 内容最多渲染成 wPt 像素再以空白填补，覆盖层会显示成小页。此类页面
        // （文字版 A4 等）不走位图覆盖层，交给白罩瞬切路径（底层矢量始终清晰）
        if (wPt < wPx) {
          return undefined;
        }
        const hPx: number = Math.max(1, Math.round(wPx * hPt / wPt));
        const matrix: pdfService.PdfMatrix = new pdfService.PdfMatrix();
        matrix.x = 0;
        matrix.y = 0;
        matrix.width = wPt;
        matrix.height = hPt;
        matrix.rotate = 0;
        pm = page.getAreaPixelMap(matrix, wPx, hPx, false, false);
      } else {
        pm = await this.controller.getPagePixelMap(idx);
      }
      this.pmCache.set(idx, pm);
      this.trimPmCache(idx);
      return pm;
    } catch (e) {
      return undefined;
    }
  }

  // 缓存只留当前页前后 ±2，超出的 PixelMap 释放防内存膨胀
  private trimPmCache(center: number): void {
    const keys: number[] = Array.from(this.pmCache.keys());
    for (let i = 0; i < keys.length; i++) {
      const k: number = keys[i];
      if (Math.abs(k - center) > 2) {
        const pm: image.PixelMap | undefined = this.pmCache.get(k);
        try {
          if (pm !== undefined) {
            pm.release();
          }
        } catch (e) {
        }
        this.pmCache.delete(k);
      }
    }
  }

  private prefetchAround(): void {
    this.ensurePm(this.pageIdx);
    this.ensurePm(this.pageIdx + 1);
    this.ensurePm(this.pageIdx - 1);
  }

  // 翻页统一入口：ghost 就绪时所有书都走 ghost 滑页（扫描版/文字版同一动画
  // 同一手感）；位图覆盖层是 ghost 未装载时的兜底，白罩瞬切保底
  private flipTo(target: number): void {
    if (target < 0 || (this.pageCount > 0 && target >= this.pageCount) || target === this.pageIdx) {
      return;
    }
    if (this.flipBusy || this.zoomed) {
      return;
    }
    if (this.spreadOn) {
      // 展开态整对翻：相邻目标（±1，来自按钮/横扫）视为翻对，其余目标（跳页/
      // 目录/书签）归到它所在的对子；pageIdx 可能是对子右页（奇数），必须以
      // 偶数对基 ±2，否则跳页偏一
      if (target === this.pageIdx + 1 || target === this.pageIdx - 1) {
        const pairBase = this.pageIdx - (this.pageIdx % 2);
        const base = pairBase + (target > this.pageIdx ? 2 : -2);
        if (base < 0 || base >= this.pageCount || base === pairBase) {
          return;
        }
        this.spreadGoTo(base);
        return;
      }
      const base = target - (target % 2);
      if (base < 0 || base >= this.pageCount || base === this.pageIdx - (this.pageIdx % 2)) {
        return;
      }
      this.spreadGoTo(base);
      return;
    }
    this.doFlip(target);
  }

  private async doFlip(target: number): Promise<void> {
    if (this.ghostReady && !this.zoomed && target !== this.pageIdx) {
      this.doGhostFlip(target);
      return;
    }
    const oldIdx = this.pageIdx;
    const oldR: RectVp = this.pageRectVp();   // goToPage 之前取，scrollP 还是旧页
    // 素材渲染前就锁 Busy，防止渲染 await 期间用户再次翻页并发两个 doFlip
    this.flipBusy = true;
    const oldPm = await this.ensurePm(oldIdx, oldR.w);
    const newPm = await this.ensurePm(target);
    if (oldPm === undefined || newPm === undefined || target === this.pageIdx) {
      // 白罩淡入遮住瞬切：先 setPageFit 再 goToPage（装载路径同款顺序，底层
      // 不丢适配），白罩淡出 reveal 的已是 fit 新页，全程无大小跳变
      this.getUIContext().animateTo({ duration: 120, curve: Curve.EaseIn }, () => {
        this.coverOp = 1;
      });
      setTimeout(() => {
        if (!this.zoomed) {
          this.controller.setPageFit(this.fitMode);
        }
        this.controller.goToPage(target);
        setTimeout(() => {
          this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
            this.coverOp = 0;
          });
        }, 60);
      }, 130);
      setTimeout(() => {
        const real = this.controller.getPageIndex();
        if (real >= 0 && real !== this.pageIdx) {
          this.syncFrom(real);
        }
        this.prefetchAround();
        this.flipBusy = false;
        // 双重保险：goToPage 异步布局若又丢了适配，此处归位
        if (!this.zoomed) {
          this.controller.setPageFit(this.fitMode);
        }
      }, 420);
      return;
    }
    // 新页按自己的纵横比居中（混合尺寸文档的页翻入不被旧 rect 拉变形）
    const newR: RectVp = await this.pageRectFit(target, newPm);
    this.flipOld = oldIdx;
    this.flipTarget = target;
    this.flipDir = target > oldIdx ? 1 : -1;
    this.rectX = oldR.x;
    this.rectY = oldR.y;
    this.rectW = oldR.w;
    this.rectH = oldR.h;
    this.newRectX = newR.x;
    this.newRectY = newR.y;
    this.newRectW = newR.w;
    this.newRectH = newR.h;
    this.flipOff = 0;
    this.flipping = true;
    // 覆盖层已遮住画面，底层瞬切不可见：先 setPageFit 再 goToPage，撤层点
    // （捏合起手）露出的真身始终是 fit 态
    this.controller.setPageFit(this.fitMode);
    this.controller.goToPage(target);
    // 平移行程 = 一屏宽（页宽不等时的缝隙由白色底层遮）
    this.getUIContext().animateTo({ duration: 320, curve: Curve.EaseInOut }, () => {
      this.flipOff = -this.flipDir * this.screenWvp;
    });
    setTimeout(() => {
      // 滑动完成：校正页码 + 预取 + 解锁。覆盖层常驻不撤——新页 bitmap 停在
      // 最终 fit 位置与底层像素级一致，全层 Transparent 触摸穿透，连翻走
      // bitmap 素材天然无缝；唯一撤层点是正常态捏合起手
      const real = this.controller.getPageIndex();
      if (real >= 0 && real !== this.pageIdx) {
        this.syncFrom(real);
      }
      this.prefetchAround();
      this.flipBusy = false;
      // 文字版 goToPage 后底层会丢 FIT_PAGE 定格在 1pt=1px 小页，此处强制归位
      // （setPageFit 即使在小页态也有效）；覆盖层常驻遮住底层，归位过程不可见
      if (!this.zoomed) {
        this.controller.setPageFit(this.fitMode);
      }
    }, 380);
  }

  // ============ ghost PdfView 滑页（预取加速 + zIndex 可见性管理） ============
  // ghost 必须常显 opacity=1、靠 zIndex 藏底（移出屏外或近零透明度会被框架跳过
  // 光栅化，"屏外养护"无效）。翻页时瞬移屏外同时抬 z 再滑入；落定后沉回底下
  // 空闲预取同方向下一页：同向连翻走快路径，变向翻页走慢路径（底下现切 +
  // 300ms 光栅等待）。ghost 未就绪回退白罩瞬切。
  private ghostPrefetch(dir: number): void {
    if (!this.ghostReady || this.pageCount <= 0) {
      return;
    }
    const next: number = Math.min(Math.max(this.pageIdx + dir, 0), this.pageCount - 1);
    if (next === this.ghostPage) {
      return;
    }
    this.ghostCtl.setPageFit(this.fitMode);
    this.ghostCtl.goToPage(next);
    this.ghostPage = next;
  }

  private doGhostFlip(target: number): void {
    const dir = target > this.pageIdx ? 1 : -1;
    this.flipBusy = true;
    // 慢路径：ghost 还没备好目标页（变向首翻）——在底下切页并等光栅
    const fast = (this.ghostPage === target);
    if (!fast) {
      this.ghostCtl.setPageFit(this.fitMode);
      this.ghostCtl.goToPage(target);
      this.ghostPage = target;
    }
    const jumpAt = fast ? 30 : 300;
    const slideAt = fast ? 80 : 340;
    // 瞬移屏外同时抬到主视图上（此刻 ghost 在屏外，z 序切换无感知）
    setTimeout(() => {
      this.ghostX = dir * this.screenWvp;   // 无 .animation 修饰，立即生效
      this.ghostZ = 5;
    }, jumpAt);
    // 滑入（fast 时新页早已光栅完成；慢路径多等 300ms 光栅）
    setTimeout(() => {
      this.getUIContext().animateTo({ duration: 320, curve: Curve.EaseInOut }, () => {
        this.ghostX = 0;
      });
    }, slideAt);
    // 滑完：主视图暗中切页（被 ghost 完全遮住，瞬切不可见）
    setTimeout(() => {
      this.controller.setPageFit(this.fitMode);
      this.controller.goToPage(target);
    }, slideAt + 610);
    // 主视图落定后 ghost 沉回底下 + 校正页码 + 预取 + 解锁
    setTimeout(() => {
      this.ghostZ = -1;
      const real = this.controller.getPageIndex();
      if (real >= 0 && real !== this.pageIdx) {
        this.syncFrom(real);
      }
      if (!this.zoomed) {
        this.controller.setPageFit(this.fitMode);
      }
      this.flipBusy = false;
      // 空闲预取：ghost 现在与主视图同页，顺手切到下一页在底下备着
      this.ghostPage = this.pageIdx;
      this.ghostPrefetch(dir);
    }, slideAt + 810);
  }

  // ============ zoom 手动插值动画（animateTo 包 setPageFit 不生效，只能逐帧 set） ============
  private animateZoomTo(target: number, duration: number, done?: () => void): void {
    if (this.zoomAnimId >= 0) {
      clearInterval(this.zoomAnimId);
      this.zoomAnimId = -1;
    }
    const z0 = this.controller.getPageZoom();
    const t0 = Date.now();
    this.zoomAnimId = setInterval(() => {
      const t = Math.min(1, (Date.now() - t0) / duration);
      const e = 1 - Math.pow(1 - t, 3);   // easeOutCubic：由大到小缓动
      this.controller.setPageZoom(z0 + (target - z0) * e);
      if (t >= 1) {
        clearInterval(this.zoomAnimId);
        this.zoomAnimId = -1;
        if (done !== undefined) {
          done();
        }
      }
    }, 16);
  }

  // 放大态双击复位：插值回 fit×1.001——终点不穿越 fit 边界，规避组件 zoom/fit
  // 模式反复重排导致的两侧闪动；done 里一次性 setPageFit 归位重定中（无振荡）
  private resetZoom(): void {
    if (!this.zoomed) {
      return;
    }
    this.barsOpen = false;
    this.zoomed = false;
    this.ghostHidden = false;   // ghost 恢复保养渲染
    this.controller.enablePageDrag(false, false);
    this.animateZoomTo(this.fitZoom * 1.001, 380, () => {
      this.controller.setPageFit(this.fitMode);
    });
  }

  // 监听器钳制后的统一归位：想缩回正常的手势停 160ms 后插值回 fit×1.001，
  // 收尾 setPageFit——任何情况下都不会缩到正常尺寸以下
  private scheduleSettle(): void {
    if (this.settleTimer >= 0) {
      clearTimeout(this.settleTimer);
    }
    this.settleTimer = setTimeout(() => {
      this.settleTimer = -1;
      this.settleToFit();
    }, 160);
  }

  private settleToFit(): void {
    if (!this.zoomed || this.settling) {
      return;
    }
    this.settling = true;
    this.animateZoomTo(this.fitZoom * 1.001, 320, () => {
      this.zoomed = false;
      this.ghostHidden = false;   // ghost 恢复保养渲染
      this.controller.enablePageDrag(false, false);
      this.controller.setPageFit(this.fitMode);
      this.settling = false;
    });
  }

  // 正常态单击：左右区翻页；中央区弹出/收起顶底栏
  private handleTap(zone: number): void {
    if (this.zoomed || this.flipBusy) {
      return;
    }
    if (this.barsOpen) {
      this.barsOpen = false;
      return;
    }
    if (zone === 0) {
      if (this.tapTurn) {
        this.flipTo(this.pageIdx - 1);
      }
    } else if (zone === 2) {
      if (this.tapTurn) {
        this.flipTo(this.pageIdx + 1);
      }
    } else {
      this.barsOpen = true;
    }
  }

  // 放大态双击判定：挂在 PdfView.onTouch 仅放大态生效；干净点击记 pvLastTap，
  // 两击 <400ms → 挪出回调上下文后 resetZoom
  private pvStartX: number = 0;
  private pvStartY: number = 0;
  private pvStartT: number = 0;
  private pvMoved: boolean = false;
  private pvCand: boolean = false;
  private pvLastTap: number = 0;

  private onPdfTouch(e: TouchEvent): void {
    if (!this.zoomed) {
      return;
    }
    if (e.type === TouchType.Down) {
      this.pvCand = false;
      if (e.touches.length !== 1) {
        this.pvMoved = true;   // 多指（捏合）不参与双击判定
        return;
      }
      this.pvStartX = e.touches[0].x;
      this.pvStartY = e.touches[0].y;
      this.pvStartT = Date.now();
      this.pvMoved = false;
      this.pvCand = Date.now() - this.pvLastTap < 400;
      return;
    }
    if (e.type === TouchType.Move && e.touches.length === 1) {
      if (Math.abs(e.touches[0].x - this.pvStartX) > 12 || Math.abs(e.touches[0].y - this.pvStartY) > 12) {
        this.pvMoved = true;
      }
      return;
    }
    if (e.type === TouchType.Up) {
      if (this.pvMoved || Date.now() - this.pvStartT >= 350) {
        return;
      }
      if (this.pvCand) {
        this.pvCand = false;
        this.pvLastTap = 0;
        setTimeout(() => {
          this.resetZoom();
        }, 0);
      } else {
        this.pvLastTap = Date.now();
      }
    }
  }

  // onTouch 横扫判定（仅单指；双指时不跟踪，让 PinchGesture 处理）。
  // 实测：ArkUI 的 onClick 对大幅度拖拽也触发（抬起点落在热区内即算点击），
  // 横扫翻页必须吞掉这次 click，否则拖拽被当成"抬手点分区点击"反向翻页
  private swallowClick: boolean = false;

  private onTouchEvent(e: TouchEvent): void {
    if (e.type === TouchType.Down) {
      this.tTracking = e.touches.length === 1 && !this.flipBusy;
      this.swallowClick = false;
      if (this.tTracking) {
        this.tStartX = e.touches[0].x;
        this.tStartY = e.touches[0].y;
        this.tStartT = Date.now();
      }
      return;
    }
    if (e.type === TouchType.Cancel || (e.type === TouchType.Move && e.touches.length > 1)) {
      this.tTracking = false;
      return;
    }
    if (e.type === TouchType.Up) {
      if (!this.tTracking) {
        return;
      }
      this.tTracking = false;
      const p = e.changedTouches[0];
      const dx = p.x - this.tStartX;
      const dy = p.y - this.tStartY;
      const dt = Date.now() - this.tStartT;
      // 纵向占优的拖拽：吞掉 click 但不翻页——不吞的话 onClick 按抬手点分区
      // 误触（展开态半屏上下滑误翻页/误弹栏的根因）
      if (Math.abs(dy) > 24 && Math.abs(dy) > Math.abs(dx)) {
        this.swallowClick = true;
        return;
      }
      const fast = dt < 250 && Math.abs(dx) > this.screenWvp * 0.12;
      if (Math.abs(dx) > this.screenWvp * 0.25 || fast) {
        this.swallowClick = true;
        const target = this.pageIdx + (dx < 0 ? 1 : -1);
        // 挪出回调上下文再走统一翻页通道（滑页动画）
        setTimeout(() => {
          this.flipTo(target);
        }, 0);
        return;
      }
      // 横向小幅慢拖也是拖拽不是点击，吞掉防误触
      if (Math.abs(dx) > 24) {
        this.swallowClick = true;
      }
    }
  }

  // 跳页：纯数字 + 1~pageCount 才合法；非法时保留已输入内容，弹「非法页码」确认框
  private doJump(): void {
    const t: string = this.jumpText.trim();
    if (t === '') {
      return;   // 空输入直接忽略，不弹非法页码提示
    }
    const n: number = parseInt(t, 10);
    if (/^[0-9]+$/.test(t) && !isNaN(n) && n >= 1 && n <= this.pageCount) {
      this.jumpText = '';
      this.flipTo(n - 1);
    } else {
      this.jumpBad = true;
      setTimeout(() => {
        this.jumpBadOp = 1;
      }, 20);
    }
  }

  private closeJumpBad(): void {
    this.jumpBadOp = 0;
    setTimeout(() => {
      this.jumpBad = false;
    }, 200);
  }

  // ============ 目录大纲（pdfService.Bookmark 递归抽取） ============

  private extractOutline(doc: pdfService.PdfDocument): OutlineItem[] {
    const items: OutlineItem[] = [];
    const walk = (marks: pdfService.Bookmark[], depth: number): void => {
      if (depth > 6) {
        return;
      }
      for (let i = 0; i < marks.length; i++) {
        const bm: pdfService.Bookmark = marks[i];
        let title = '';
        let pageIndex = -1;
        try {
          title = bm.getBookmarkInfo().title;
        } catch (e) {
        }
        try {
          pageIndex = bm.getDestInfo().pageIndex;
        } catch (e) {
        }
        if (title !== '' && pageIndex >= 0) {
          items.push({ title, pageIndex, depth });
        }
        try {
          if (bm.hasChild()) {
            walk(bm.getChildren(), depth + 1);
          }
        } catch (e) {
        }
      }
    };
    try {
      walk(doc.getRootBookmarks(), 0);
    } catch (e) {
    }
    return items;
  }

  private openToc(): void {
    this.barsOpen = false;
    this.tocOpen = true;
    setTimeout(() => {
      this.tocOp = 1;
    }, 20);
  }

  private closeToc(): void {
    this.tocOp = 0;
    setTimeout(() => {
      this.tocOpen = false;
    }, 200);
  }

  // 点目录条目：关弹窗后走统一翻页通道（ghost 滑页，远页走慢路径光栅等待）
  private jumpToOutline(idx: number): void {
    this.closeToc();
    setTimeout(() => {
      this.flipTo(idx);
    }, 120);
  }

  // ============ 书签（页码存 books.json，星标切换 + 列表跳页） ============

  private isMarked(): boolean {
    return this.markedPages.indexOf(this.pageIdx) >= 0;
  }

  private toggleBookmark(): void {
    const on = LibraryManager.toggleBookmark(this.getCtx(), this.fileName, this.pageIdx);
    const cur = this.markedPages.indexOf(this.pageIdx);
    if (on && cur < 0) {
      this.markedPages = this.markedPages.concat([this.pageIdx]).sort((a: number, c: number) => a - c);
    } else if (!on && cur >= 0) {
      const next = this.markedPages.slice();
      next.splice(cur, 1);
      this.markedPages = next;
    }
  }

  private removeBookmarkAt(page: number): void {
    LibraryManager.toggleBookmark(this.getCtx(), this.fileName, page);
    const next = this.markedPages.slice();
    const i = next.indexOf(page);
    if (i >= 0) {
      next.splice(i, 1);
    }
    this.markedPages = next;
  }

  private openBookmarks(): void {
    this.barsOpen = false;
    this.bmOpen = true;
    setTimeout(() => {
      this.bmOp = 1;
    }, 20);
  }

  private closeBookmarks(): void {
    this.bmOp = 0;
    setTimeout(() => {
      this.bmOpen = false;
    }, 200);
  }

  private jumpToBookmark(page: number): void {
    this.closeBookmarks();
    setTimeout(() => {
      this.flipTo(page);
    }, 120);
  }

  // 返回书架：栏保持弹出、窗口保持全屏——书架页上下同样黑边同宽，转场前后
  // 黑边连续，配合 pageTransition 淡出即为自然退场
  private goBack(): void {
    window.getLastWindow(this.getCtx()).then((w: window.Window) => {
      w.setWindowKeepScreenOn(false);
    });
    router.back();
  }

  build() {
    Stack() {
      if (this.error !== '') {
        Column({ space: 16 }) {
          Text(this.error).fontSize(16).fontColor('#333333')
          Button('返回书架').onClick(() => router.back())
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        // 主视图：整页适配白边补齐，单页分割不露相邻页，无滚动条
        PdfView({
          controller: this.controller,
          pageFit: this.fitMode,
          isContinuous: false,
          showScroll: false,
        }).width('100%').height('100%')
          .onTouch((e: TouchEvent) => this.onPdfTouch(e))

        // ghost PdfView：隐身保养层，翻页时滑入盖住主视图；Transparent 命中——
        // 放大态触摸穿透到主视图原生手势
        PdfView({
          controller: this.ghostCtl,
          pageFit: this.fitMode,
          isContinuous: false,
          showScroll: false,
        }).width('100%').height('100%')
          .translate({ x: this.ghostX })
          .visibility(this.ghostHidden ? Visibility.Hidden : Visibility.Visible)
          .hitTestBehavior(HitTestMode.Transparent)
          .zIndex(this.ghostZ)

        // 横屏双页：左右 PdfView 各显一页拼对子，无缩放。必须常驻组件树 +
        // visibility 显隐（条件渲染会让 PdfView 不上树，loadDocument 永不成功
        // ——展开态死锁）。每个 PdfView 都挂 Transparent：只挂 Row 拦不住子节点
        // 原生触摸（半屏上下滑各翻各的，实测踩坑）。强制 FIT_PAGE：半屏 FIT_WIDTH
        // 页高超屏被裁（"显示不完整"的根因）
        Row() {
          PdfView({
            controller: this.spreadLCtl,
            pageFit: pdfService.PageFit.FIT_PAGE,
            isContinuous: false,
            showScroll: false,
          }).width('50%').height('100%')
            .hitTestBehavior(HitTestMode.Transparent)
          if (this.spreadRValid) {
            PdfView({
              controller: this.spreadRCtl,
              pageFit: pdfService.PageFit.FIT_PAGE,
              isContinuous: false,
              showScroll: false,
            }).width('50%').height('100%')
              .hitTestBehavior(HitTestMode.Transparent)
          } else {
            Column().width('50%').height('100%').backgroundColor('#FFFFFF')
          }
        }
        .width('100%').height('100%')
        .visibility(this.spreadOn && this.spreadReady ? Visibility.Visible : Visibility.Hidden)
        .hitTestBehavior(HitTestMode.Transparent)
        .zIndex(2)

        if (!this.zoomed) {
          // 正常态 Block 锁死层：PdfView 收不到触摸，onClick 三分区 + onTouch 横扫
          // 自判 + 捏合唯一手势。zIndex(3) 必须高于横屏双页层（z=2）——Transparent
          // 对 PdfView 无效（实测半屏上下滑照样原生翻页），Block 盾压住才收得到触摸
          Row()
            .width('100%').height('100%')
            .hitTestBehavior(HitTestMode.Block)
            .zIndex(3)
            .onClick((e: ClickEvent) => {
              if (this.swallowClick) {
                this.swallowClick = false;
                return;
              }
              const zone = e.x < this.screenWvp / 3 ? 0 : (e.x > this.screenWvp * 2 / 3 ? 2 : 1);
              this.handleTap(zone);
            })
            .onTouch((e: TouchEvent) => this.onTouchEvent(e))
            .gesture(PinchGesture()
              .onActionStart(() => {
                if (this.spreadOn) {
                  return;   // 展开态不开放缩放
                }
                this.pinching = true;
                // 撤掉常驻的滑页覆盖层（唯一撤层点）：缩放的是底层真身，覆盖层
                // bitmap 停在 fit 尺寸，不撤会被看出比例差
                this.flipping = false;
                // ghost 一并归位：Hidden 卸载 + 回屏内，防残留显形
                this.ghostHidden = true;
                this.ghostX = 0;
                this.pinchStartZoom = this.controller.getPageZoom();
                this.fitZoom = this.pinchStartZoom;   // 正常态起手 = fit 基准
                this.lastAppliedZoom = this.pinchStartZoom;
              })
              .onActionUpdate((e: GestureEvent) => {
                if (this.spreadOn) {
                  return;
                }
                // 下限钳制：不许进入 fit 基准以下的半吊子缩放——组件在 fit
                // 边界会 fit/zoom 模式反复重排，缓慢缩放时表现为一抖一抖
                const floor = this.fitZoom * 1.06;
                let z = this.pinchStartZoom * e.scale;
                if (z < floor) {
                  z = floor;
                }
                // 最小步长过滤：变化太小不重排，减少无效重排抖动
                if (Math.abs(z - this.lastAppliedZoom) < this.fitZoom * 0.008) {
                  return;
                }
                this.lastAppliedZoom = z;
                this.controller.setPageZoom(z);
              })
              .onActionEnd((e: GestureEvent) => {
                if (this.spreadOn) {
                  return;
                }
                this.pinching = false;
                const final = this.pinchStartZoom * e.scale;
                if (final > this.fitZoom * 1.15) {
                  // 进入放大态：切层 + PdfView 拿到拖动权 + ghost 卸载（
                  // 双 XComponent 合成负载是放大态平移抖动最可能根因）
                  setTimeout(() => {
                    this.zoomed = true;
                    this.ghostHidden = true;
                    this.controller.enablePageDrag(true, true);
                  }, 0);
                } else {
                  // 没放大成功：退正常态 + 插值回弹 fit（zoomed 一并清掉，否则
                  // 放大态卡死在 fit zoom 上单击无响应）
                  setTimeout(() => {
                    this.zoomed = false;
                    this.ghostHidden = false;
                    this.controller.enablePageDrag(false, false);
                    this.animateZoomTo(this.fitZoom * 1.001, 300, () => {
                      this.controller.setPageFit(this.fitMode);
                    });
                  }, 0);
                }
              })
              .onActionCancel(() => {
                this.pinching = false;
                // 手势被取消（如被翻页中断）：恢复 ghost 保养渲染，否则下次
                // 翻页底下没备好新页（ghost 需常显在底下光栅化）
                this.ghostHidden = false;
              }))
        }

        // 放大态：无覆盖层，触摸直达 PdfView——原生全向平移 + 原生捏合（实测
        // 手感最好；早期透明捏合层会把单指平移吃掉——"放大后彻底不能移动"的根因，
        // 已删）。原生捏合绕过手势钳制的"永久缩小"路径由 registerScaleChangedListener
        // 实时钳死。双击复位判定挂 PdfView.onTouch（放大态全事件可达）

        // 文字版瞬切白罩：淡入遮 goToPage 瞬切、淡出 reveal fit 新页
        Row()
          .width('100%').height('100%')
          .backgroundColor('#FFFFFF')
          .opacity(this.coverOp)
          .hitTestBehavior(HitTestMode.Transparent)
          .zIndex(16)

        // 滑页动画覆盖层（常驻不撤）：旧页滑出 + 新页滑入（底层瞬切被遮住），
        // 滑完新页 bitmap 停在最终 fit 位与底层像素级一致；三节点全 Transparent
        // 触摸穿透，点哪都照常工作
        if (this.flipping && this.pmCache.has(this.flipOld) && this.pmCache.has(this.flipTarget)) {
          Row()
            .width('100%').height('100%')
            .backgroundColor('#FFFFFF')
            .hitTestBehavior(HitTestMode.Transparent)
            .zIndex(17)
          Image(this.pmCache.get(this.flipOld))
            .objectFit(ImageFit.Fill)
            .width(this.rectW).height(this.rectH)
            .position({ x: this.rectX, y: this.rectY })
            .translate({ x: this.flipOff })
            .hitTestBehavior(HitTestMode.Transparent)
            .zIndex(18)
          Image(this.pmCache.get(this.flipTarget))
            .objectFit(ImageFit.Fill)
            .width(this.newRectW).height(this.newRectH)
            .position({ x: this.newRectX + this.flipDir * this.screenWvp, y: this.newRectY })
            .translate({ x: this.flipOff })
            .hitTestBehavior(HitTestMode.Transparent)
            .zIndex(19)
        }

        // 顶栏（黑色半透明，滑下弹出）：左上返回键 + 页码搜索栏 + 目录
        Column() {
          Row({ space: 10 }) {
            Text('‹')
              .fontSize(34).fontColor('#FFFFFF').fontWeight(FontWeight.Bold)
              .width(44).height(44).textAlign(TextAlign.Center)
              .onClick(() => this.goBack())
            Text(this.isMarked() ? '★' : '☆')
              .fontSize(22).fontColor(this.isMarked() ? '#FFD75E' : '#FFFFFF')
              .width(40).height(44).textAlign(TextAlign.Center)
              .onClick(() => this.toggleBookmark())
            TextInput({ placeholder: '跳转到页码', text: this.jumpText })
              .layoutWeight(1).height(40)
              .backgroundColor('rgba(255,255,255,0.16)')
              .fontColor('#FFFFFF')
              .placeholderColor('rgba(255,255,255,0.5)')
              .caretColor('#FFFFFF')
              .borderRadius(20)
              .type(InputType.Number)
              .onChange((v: string) => {
                this.jumpText = v;
              })
              .onSubmit(() => this.doJump())
            Button('跳转')
              .fontSize(14)
              .height(40)
              .backgroundColor('#0A59F7')
              .fontColor('#FFFFFF')
              .onClick(() => this.doJump())
            Button('目录')
              .fontSize(14)
              .height(40)
              .backgroundColor('rgba(255,255,255,0.16)')
              .fontColor('#FFFFFF')
              .onClick(() => this.openToc())
          }
          .width('100%')
          .padding({ left: 10, right: 12 })
        }
        .width('100%')
        .padding({ top: 40, bottom: 10 })
        .backgroundColor('rgba(17,17,17,0.92)')
        .position({ x: 0, y: 0 })
        .translate({ y: this.barsOpen ? 0 : -150 })
        .animation({ duration: 260, curve: Curve.EaseOut })
        .zIndex(30)

        // 底栏（黑色半透明，滑上弹出）：页码指示 + 上/下页 + 书签
        Column() {
          Row({ space: 28 }) {
            Text('‹ 上一页')
              .fontSize(15).fontColor('#FFFFFF')
              .padding(8)
              .onClick(() => this.flipTo(this.pageIdx - 1))
            Text(this.spreadOn
              ? `${this.pageIdx + 1}-${Math.min(this.pageIdx + 2, this.pageCount)} / ${this.pageCount}`
              : `${this.pageIdx + 1} / ${this.pageCount}`)
              .fontSize(16).fontColor('#FFFFFF').fontWeight(FontWeight.Medium)
            Text('下一页 ›')
              .fontSize(15).fontColor('#FFFFFF')
              .padding(8)
              .onClick(() => this.flipTo(this.pageIdx + 1))
            Text('书签')
              .fontSize(15).fontColor('#FFFFFF')
              .padding(8)
              .onClick(() => this.openBookmarks())
          }
          .padding({ bottom: 16 })
        }
        .width('100%')
        // 底部向下溢出 40vp：系统手势指示条的半透明磨砂区压在黑栏上会显出浅色
        // 缝隙（用户实测），黑底必须延伸盖到它下面去
        .padding({ top: 10, bottom: 40 })
        .backgroundColor('rgba(17,17,17,0.92)')
        .position({ x: 0, y: this.screenH - 66 })
        .translate({ y: this.barsOpen ? 0 : 130 })
        .animation({ duration: 260, curve: Curve.EaseOut })
        .zIndex(30)

        // 非法页码提示：非数字或超出 1~pageCount，中央弹窗 + 确认
        if (this.jumpBad) {
          Column()
            .width('100%').height('100%')
            .backgroundColor('rgba(0,0,0,0.45)')
            .opacity(this.jumpBadOp)
            .animation({ duration: 200 })
            .onClick(() => this.closeJumpBad())
            .zIndex(40)   // 弹窗层必须压过 Block 触摸盾(z=3)与顶底栏(z=30)，否则点击全被盾拦截
          Column({ space: 14 }) {
            Text('非法页码')
              .fontSize(18).fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
            Text(`请输入 1 ~ ${this.pageCount} 之间的数字页码`)
              .fontSize(14)
              .fontColor('rgba(255,255,255,0.72)')
              .textAlign(TextAlign.Center)
            Button('确认')
              .width('100%')
              .backgroundColor('#0A59F7')
              .fontColor('#FFFFFF')
              .onClick(() => this.closeJumpBad())
          }
          .width('72%')
          .padding(20)
          .borderRadius(18)
          .backgroundColor('rgba(24,24,24,0.96)')
          .opacity(this.jumpBadOp)
          .translate({ y: (1 - this.jumpBadOp) * 24 })
          .animation({ duration: 220, curve: Curve.EaseOut })
          .zIndex(41)
          .onClick(() => {
          })
        }

        // 目录弹窗：大纲列表（缩进显层级），无目录给提示
        if (this.tocOpen) {
          Column()
            .width('100%').height('100%')
            .backgroundColor('rgba(0,0,0,0.45)')
            .opacity(this.tocOp)
            .animation({ duration: 200 })
            .onClick(() => this.closeToc())
            .zIndex(40)   // 压过 Block 触摸盾(z=3)：遮罩点空白关弹窗、列表上下滑动才收得到手势
          Column({ space: 12 }) {
            Text('目录')
              .fontSize(18).fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
            if (this.tocList.length === 0) {
              Text('本书没有目录')
                .fontSize(14)
                .fontColor('rgba(255,255,255,0.72)')
                .padding({ top: 8, bottom: 8 })
              Button('确认')
                .width('100%')
                .backgroundColor('#0A59F7')
                .fontColor('#FFFFFF')
                .onClick(() => this.closeToc())
            } else {
              List({ space: 2 }) {
                ForEach(this.tocList, (it: OutlineItem) => {
                  ListItem() {
                    Row({ space: 8 }) {
                      Text(it.title)
                        .fontSize(15)
                        .fontColor('#FFFFFF')
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .layoutWeight(1)
                      Text(`第 ${it.pageIndex + 1} 页`)
                        .fontSize(12)
                        .fontColor('rgba(255,255,255,0.5)')
                    }
                    .width('100%')
                    .padding({ left: it.depth * 18, top: 9, bottom: 9 })
                  }
                  .onClick(() => this.jumpToOutline(it.pageIndex))
                }, (it: OutlineItem) => `${it.depth}-${it.pageIndex}-${it.title}`)
              }
              .width('100%')
              .divider({ strokeWidth: 0.5, color: 'rgba(255,255,255,0.12)' })
              .constraintSize({ maxHeight: this.screenHvp * 0.55 })
              .scrollBar(BarState.Auto)   // 目录长时显示滚动条提示可滑
            }
          }
          .width('78%')
          .padding(20)
          .borderRadius(18)
          .backgroundColor('rgba(24,24,24,0.96)')
          .opacity(this.tocOp)
          .translate({ y: (1 - this.tocOp) * 24 })
          .animation({ duration: 220, curve: Curve.EaseOut })
          .zIndex(41)
          .onClick(() => {
          })
        }

        // 书签列表弹窗：点条目跳页，右缘×移除
        if (this.bmOpen) {
          Column()
            .width('100%').height('100%')
            .backgroundColor('rgba(0,0,0,0.45)')
            .opacity(this.bmOp)
            .animation({ duration: 200 })
            .onClick(() => this.closeBookmarks())
            .zIndex(40)   // 同目录/非法页码弹窗：压过 Block 触摸盾(z=3)
          Column({ space: 12 }) {
            Text('书签')
              .fontSize(18).fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
            if (this.markedPages.length === 0) {
              Text('还没有书签\n阅读时点击顶栏星标即可添加')
                .fontSize(14)
                .fontColor('rgba(255,255,255,0.72)')
                .textAlign(TextAlign.Center)
                .padding({ top: 8, bottom: 8 })
              Button('确认')
                .width('100%')
                .backgroundColor('#0A59F7')
                .fontColor('#FFFFFF')
                .onClick(() => this.closeBookmarks())
            } else {
              List({ space: 2 }) {
                ForEach(this.markedPages, (p: number) => {
                  ListItem() {
                    Row({ space: 8 }) {
                      Text(`第 ${p + 1} 页`)
                        .fontSize(15)
                        .fontColor('#FFFFFF')
                        .layoutWeight(1)
                      Text('✕')
                        .fontSize(15)
                        .fontColor('rgba(255,255,255,0.55)')
                        .width(40).height(30)
                        .textAlign(TextAlign.Center)
                    }
                    .width('100%')
                    .padding({ top: 9, bottom: 9 })
                  }
                  // 整行一个 onClick：点右侧 ✕ 区（x>80% 行宽）删除，其余跳页。
                  // 拆成父子两个 onClick 实测子节点不触发（真机验证），按落点分区最稳
                  .onClick((e: ClickEvent) => {
                    if (e.x > this.screenWvp * 0.72 * 0.8) {
                      this.removeBookmarkAt(p);
                    } else {
                      this.jumpToBookmark(p);
                    }
                  })
                }, (p: number) => `bm-${p}`)
              }
              .width('100%')
              .divider({ strokeWidth: 0.5, color: 'rgba(255,255,255,0.12)' })
              .constraintSize({ maxHeight: this.screenHvp * 0.55 })
            }
          }
          .width('72%')
          .padding(20)
          .borderRadius(18)
          .backgroundColor('rgba(24,24,24,0.96)')
          .opacity(this.bmOp)
          .translate({ y: (1 - this.bmOp) * 24 })
          .animation({ duration: 220, curve: Curve.EaseOut })
          .zIndex(41)
          .onClick(() => {
          })
        }

      }
    }
    .width('100%').height('100%')
    .backgroundColor('#FFFFFF')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  // 页面转场：淡入淡出（书架与阅读页同为全屏 + 上下黑边，黑边连续，淡出即自然退场）
  pageTransition() {
    PageTransitionEnter({ type: RouteType.None, duration: 260, curve: Curve.EaseOut })
      .opacity(0)
    PageTransitionExit({ type: RouteType.None, duration: 260, curve: Curve.EaseIn })
      .opacity(0)
  }
}
