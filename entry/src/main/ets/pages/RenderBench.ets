import { pdfService, pdfViewManager } from '@kit.PDFKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { router, display } from '@kit.ArkUI';

const TAG: string = 'PdfDemo';

@Entry
@Component
struct RenderBench {
  @State pixelMap?: image.PixelMap = undefined;
  @State status: string = '渲染调试台：加载文档后测试各档位';
  @State pageIdx: number = 0;
  @State docName: string = 'demo.pdf';
  private pdfDocument: pdfService.PdfDocument = new pdfService.PdfDocument();
  private loaded: boolean = false;
  private prevPm?: image.PixelMap = undefined;

  private getCtx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private log(line: string): void {
    this.status = line;
    hilog.info(0x0000, TAG, '%{public}s', line);
  }

  private async ensureCopied(name: string): Promise<number> {
    const dst: string = this.getCtx().filesDir + '/' + name;
    const t0 = Date.now();
    const buf: Uint8Array = await this.getCtx().resourceManager.getRawFileContent(name);
    const file = fs.openSync(dst, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, buf.buffer);
    fs.closeSync(file);
    return Date.now() - t0;
  }

  private loadDoc(): void {
    this.ensureCopied(this.docName).then((copyMs: number) => {
      this.pdfDocument = new pdfService.PdfDocument();
      const t1 = Date.now();
      const result: pdfService.ParseResult =
        this.pdfDocument.loadDocument(this.getCtx().filesDir + '/' + this.docName);
      const loadMs = Date.now() - t1;
      this.loaded = result === pdfService.ParseResult.PARSE_SUCCESS;
      this.pageIdx = 0;
      const pages: number = this.loaded ? this.pdfDocument.getPageCount() : -1;
      this.log(`TEST|act=load|doc=${this.docName}|result=${result}|pages=${pages}|loadMs=${loadMs}|copyMs=${copyMs}`);
    });
  }

  private show(pm: image.PixelMap): void {
    const old: image.PixelMap | undefined = this.prevPm;
    this.prevPm = pm;
    this.pixelMap = pm;
    if (old !== undefined) {
      setTimeout(() => {
        old.release();
      }, 2000);
    }
  }

  private renderDefault(): void {
    if (!this.loaded) {
      return;
    }
    const t0 = Date.now();
    const page: pdfService.PdfPage = this.pdfDocument.getPage(this.pageIdx);
    const pm: image.PixelMap = page.getPagePixelMap();
    const ms = Date.now() - t0;
    pm.getImageInfo().then((info: image.ImageInfo) => {
      const wPt: number = page.getWidth();
      const hPt: number = page.getHeight();
      this.show(pm);
      this.log(`TEST|act=default|doc=${this.docName}|page=${this.pageIdx}` +
        `|srcPt=${wPt}x${hPt}|out=${info.size.width}x${info.size.height}|ms=${ms}`);
    });
  }

  private renderScale(scale: number): void {
    if (!this.loaded) {
      return;
    }
    const t0 = Date.now();
    const page: pdfService.PdfPage = this.pdfDocument.getPage(this.pageIdx);
    const wPt: number = page.getWidth();
    const hPt: number = page.getHeight();
    const matrix: pdfService.PdfMatrix = new pdfService.PdfMatrix();
    matrix.x = 0;
    matrix.y = 0;
    matrix.width = wPt;
    matrix.height = hPt;
    matrix.rotate = 0;
    const pm: image.PixelMap = page.getAreaPixelMap(matrix,
      Math.floor(wPt * scale), Math.floor(hPt * scale), false, false);
    const ms = Date.now() - t0;
    pm.getImageInfo().then((info: image.ImageInfo) => {
      this.show(pm);
      this.log(`TEST|act=area${scale}x|doc=${this.docName}|page=${this.pageIdx}` +
        `|srcPt=${wPt}x${hPt}|out=${info.size.width}x${info.size.height}|ms=${ms}`);
    });
  }

  // 探针C1：源区域=下半页（PDF y 轴从底部算），画布=区域点尺寸原大
  private probeCropHalf(): void {
    if (!this.loaded) {
      return;
    }
    const page: pdfService.PdfPage = this.pdfDocument.getPage(this.pageIdx);
    const wPt: number = page.getWidth();
    const hPt: number = page.getHeight();
    const matrix: pdfService.PdfMatrix = new pdfService.PdfMatrix();
    matrix.x = 0;
    matrix.y = 0;
    matrix.width = wPt;
    matrix.height = Math.floor(hPt / 2);
    matrix.rotate = 0;
    const pm: image.PixelMap = page.getAreaPixelMap(matrix, wPt, Math.floor(hPt / 2), false, false);
    pm.getImageInfo().then((info: image.ImageInfo) => {
      this.show(pm);
      this.log(`TEST|act=cropHalf|doc=${this.docName}|page=${this.pageIdx}` +
        `|matrix=${matrix.width}x${matrix.height}|out=${info.size.width}x${info.size.height}`);
    });
  }

  // 探针C2：源区域=左下1/4页，画布=区域的2倍
  private probeQuarter(): void {
    if (!this.loaded) {
      return;
    }
    const page: pdfService.PdfPage = this.pdfDocument.getPage(this.pageIdx);
    const wPt: number = page.getWidth();
    const hPt: number = page.getHeight();
    const matrix: pdfService.PdfMatrix = new pdfService.PdfMatrix();
    matrix.x = 0;
    matrix.y = 0;
    matrix.width = Math.floor(wPt / 2);
    matrix.height = Math.floor(hPt / 2);
    matrix.rotate = 0;
    const pm: image.PixelMap = page.getAreaPixelMap(matrix, wPt, hPt, false, false);
    pm.getImageInfo().then((info: image.ImageInfo) => {
      this.show(pm);
      this.log(`TEST|act=quarter2x|doc=${this.docName}|page=${this.pageIdx}` +
        `|matrix=${matrix.width}x${matrix.height}|out=${info.size.width}x${info.size.height}`);
    });
  }

  // 探针C3：matrix 尺寸=画布尺寸=2倍点尺寸
  private probeMatrixEq(): void {
    if (!this.loaded) {
      return;
    }
    const page: pdfService.PdfPage = this.pdfDocument.getPage(this.pageIdx);
    const wPt: number = page.getWidth();
    const hPt: number = page.getHeight();
    const matrix: pdfService.PdfMatrix = new pdfService.PdfMatrix();
    matrix.x = 0;
    matrix.y = 0;
    matrix.width = Math.floor(wPt * 2);
    matrix.height = Math.floor(hPt * 2);
    matrix.rotate = 0;
    const pm: image.PixelMap = page.getAreaPixelMap(matrix,
      Math.floor(wPt * 2), Math.floor(hPt * 2), false, false);
    pm.getImageInfo().then((info: image.ImageInfo) => {
      this.show(pm);
      this.log(`TEST|act=matrixEq2x|doc=${this.docName}|page=${this.pageIdx}` +
        `|matrix=${matrix.width}x${matrix.height}|out=${info.size.width}x${info.size.height}`);
    });
  }

  // 探针P：从 Books 子目录加载 demo2 并立即 3x 渲染（判别“子目录路径导致文字版退化”假说）
  private probeBooksPath(): void {
    const path = this.getCtx().filesDir + '/Books/demo2.pdf';
    const doc = new pdfService.PdfDocument();
    const r = doc.loadDocument(path);
    if (r !== pdfService.ParseResult.PARSE_SUCCESS) {
      this.log(`TEST|act=booksPath|load=fail|${r}`);
      return;
    }
    this.pdfDocument = doc;
    this.loaded = true;
    this.pageIdx = 0;
    this.docName = 'Books/demo2.pdf';
    this.renderScale(3);
  }

  // 探针D：先调 display.getDefaultDisplaySync 再渲染（判别“屏宽查询毒化渲染”）
  private probeDisplayQuery(): void {
    const w = display.getDefaultDisplaySync().width;
    this.log(`TEST|act=dispQuery|screenW=${w}`);
    this.renderScale(3);
  }

  // 探针E：位图级真相诊断——直接读取 getAreaPixelMap 返回位图的像素，
  // 计算非白内容的包围盒（不受显示层/截图/背景色干扰）
  private probeBitmapTruth(): void {
    if (!this.loaded) {
      this.status = '请先加载文档';
      return;
    }
    const page: pdfService.PdfPage = this.pdfDocument.getPage(this.pageIdx);
    const wPt = page.getWidth();
    const hPt = page.getHeight();
    const k = 3;
    const W = Math.floor(wPt * k);
    const H = Math.floor(hPt * k);
    const matrix = new pdfService.PdfMatrix();
    matrix.x = 0;
    matrix.y = 0;
    matrix.width = wPt;
    matrix.height = hPt;
    matrix.rotate = 0;
    const pm = page.getAreaPixelMap(matrix, W, H, false, false);
    // 全图读出（BGRA），扫非白像素包围盒
    const buf = new ArrayBuffer(W * H * 4);
    pm.readPixelsSync({
      pixels: buf,
      offset: 0,
      stride: W * 4,
      region: { size: { width: W, height: H }, x: 0, y: 0 }
    } as image.PositionArea);
    pm.release();
    const b = new Uint8Array(buf);
    let minX = W, minY = H, maxX = -1, maxY = -1, darkCount = 0;
    for (let y = 0; y < H; y++) {
      const row = y * W * 4;
      for (let x = 0; x < W; x++) {
        const i = row + x * 4;
        const mx = Math.max(b[i], b[i + 1], b[i + 2]);
        if (mx < 200) {
          darkCount++;
          if (x < minX) { minX = x; }
          if (x > maxX) { maxX = x; }
          if (y < minY) { minY = y; }
          if (y > maxY) { maxY = y; }
        }
      }
    }
    this.status = `BITMAP|W=${W},H=${H}|内容bbox=(${minX},${minY})-(${maxX},${maxY})` +
      `|宽占比=${maxX < 0 ? 0 : Math.round((maxX - minX + 1) * 100 / W)}%|暗像素=${(darkCount * 100 / (W * H)).toFixed(1)}%`;
    hilog.info(0x0000, TAG, '%{public}s', this.status);
  }

  // 探针F：渲染后延迟 600ms 再显示（检验“光栅异步完成”假说）
  private renderScaleDelayed(scale: number): void {
    if (!this.loaded) {
      return;
    }
    const page: pdfService.PdfPage = this.pdfDocument.getPage(this.pageIdx);
    const wPt = page.getWidth();
    const hPt = page.getHeight();
    const matrix: pdfService.PdfMatrix = new pdfService.PdfMatrix();
    matrix.x = 0;
    matrix.y = 0;
    matrix.width = wPt;
    matrix.height = hPt;
    matrix.rotate = 0;
    const pm: image.PixelMap = page.getAreaPixelMap(matrix,
      Math.floor(wPt * scale), Math.floor(hPt * scale), false, false);
    setTimeout(() => {
      this.show(pm);
      this.log(`TEST|act=delayedShow|scale=${scale}x`);
    }, 600);
  }

  // 探针G：加载从未打开过的新文件名（判别“按路径持久化的渲染缓存污染”）
  private probeFreshFile(): void {
    const path = this.getCtx().filesDir + '/fresh.pdf';
    const doc = new pdfService.PdfDocument();
    const r = doc.loadDocument(path);
    if (r !== pdfService.ParseResult.PARSE_SUCCESS) {
      this.log(`TEST|act=fresh|load=fail|${r}`);
      return;
    }
    const page = doc.getPage(0);
    const wPt = page.getWidth();
    const hPt = page.getHeight();
    const k = 3;
    const W = Math.floor(wPt * k);
    const H = Math.floor(hPt * k);
    const matrix = new pdfService.PdfMatrix();
    matrix.x = 0;
    matrix.y = 0;
    matrix.width = wPt;
    matrix.height = hPt;
    matrix.rotate = 0;
    const pm = page.getAreaPixelMap(matrix, W, H, false, false);
    const buf = new ArrayBuffer(W * H * 4);
    pm.readPixelsSync({
      pixels: buf,
      offset: 0,
      stride: W * 4,
      region: { size: { width: W, height: H }, x: 0, y: 0 }
    } as image.PositionArea);
    pm.release();
    doc.releaseDocument();
    const b = new Uint8Array(buf);
    let minX = W, minY = H, maxX = -1, maxY = -1;
    for (let y = 0; y < H; y++) {
      const row = y * W * 4;
      for (let x = 0; x < W; x++) {
        const i = row + x * 4;
        if (Math.max(b[i], b[i + 1], b[i + 2]) < 200) {
          if (x < minX) { minX = x; }
          if (x > maxX) { maxX = x; }
          if (y < minY) { minY = y; }
          if (y > maxY) { maxY = y; }
        }
      }
    }
    this.status = `FRESH|W=${W},H=${H}|bbox=(${minX},${minY})-(${maxX},${maxY})` +
      `|宽占比=${maxX < 0 ? 0 : Math.round((maxX - minX + 1) * 100 / W)}%`;
    hilog.info(0x0000, TAG, '%{public}s', this.status);
  }

  // 把 rawfile 的 fresh.pdf 复制进沙箱（新文件名，系统从未加载过）
  private copyFresh(): void {
    this.getCtx().resourceManager.getRawFileContent('fresh.pdf').then((buf: Uint8Array) => {
      const file = fs.openSync(this.getCtx().filesDir + '/fresh.pdf',
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, buf.buffer);
      fs.closeSync(file);
      this.status = 'fresh.pdf 已复制，请点“新文件真相”';
    });
  }

  // 探针H：matrix.width = 页宽-1（验证“matrix==页宽时缩放静默失效”边界条件）
  private probeMinusOne(): void {
    if (!this.loaded) {
      return;
    }
    const page: pdfService.PdfPage = this.pdfDocument.getPage(this.pageIdx);
    const wPt = page.getWidth();
    const hPt = page.getHeight();
    const k = 3;
    const W = Math.floor(wPt * k);
    const H = Math.floor(hPt * k);
    const matrix = new pdfService.PdfMatrix();
    matrix.x = 0;
    matrix.y = 0;
    matrix.width = wPt - 1; // 关键：比页宽小 1
    matrix.height = hPt;
    matrix.rotate = 0;
    const pm = page.getAreaPixelMap(matrix, W, H, false, false);
    const buf = new ArrayBuffer(W * H * 4);
    pm.readPixelsSync({
      pixels: buf,
      offset: 0,
      stride: W * 4,
      region: { size: { width: W, height: H }, x: 0, y: 0 }
    } as image.PositionArea);
    pm.release();
    const b = new Uint8Array(buf);
    let minX = W, minY = H, maxX = -1, maxY = -1;
    for (let y = 0; y < H; y++) {
      const row = y * W * 4;
      for (let x = 0; x < W; x++) {
        const i = row + x * 4;
        if (Math.max(b[i], b[i + 1], b[i + 2]) < 200) {
          if (x < minX) { minX = x; }
          if (x > maxX) { maxX = x; }
          if (y < minY) { minY = y; }
          if (y > maxY) { maxY = y; }
        }
      }
    }
    this.status = `MINUS1|W=${W},H=${H}|bbox=(${minX},${minY})-(${maxX},${maxY})` +
      `|宽占比=${maxX < 0 ? 0 : Math.round((maxX - minX + 1) * 100 / W)}%`;
    hilog.info(0x0000, TAG, '%{public}s', this.status);
  }

  // 通用：渲染→读像素→返回“内容bbox/画布”描述
  private measurePm(pm: image.PixelMap, tag: string): void {
    const W = 1785;
    const H = 2526;
    const buf = new ArrayBuffer(W * H * 4);
    pm.readPixelsSync({
      pixels: buf,
      offset: 0,
      stride: W * 4,
      region: { size: { width: W, height: H }, x: 0, y: 0 }
    } as image.PositionArea);
    pm.release();
    const b = new Uint8Array(buf);
    let minX = W, minY = H, maxX = -1, maxY = -1;
    for (let y = 0; y < H; y++) {
      const row = y * W * 4;
      for (let x = 0; x < W; x++) {
        const i = row + x * 4;
        if (Math.max(b[i], b[i + 1], b[i + 2]) < 200) {
          if (x < minX) { minX = x; }
          if (x > maxX) { maxX = x; }
          if (y < minY) { minY = y; }
          if (y > maxY) { maxY = y; }
        }
      }
    }
    const wPct = maxX < 0 ? 0 : Math.round((maxX - minX + 1) * 100 / W);
    this.log(`SCAN|${tag}|bbox=(${minX},${minY})-(${maxX},${maxY})|宽占比=${wPct}%`);
  }

  // 探针I：变体扫描——一次测完所有候选用法
  private probeVariants(): void {
    if (!this.loaded) {
      return;
    }
    const page: pdfService.PdfPage = this.pdfDocument.getPage(0);
    const wPt = page.getWidth();
    const hPt = page.getHeight();
    const W = 1785;
    const H = 2526;
    try {
      const m1 = new pdfService.PdfMatrix();
      m1.x = 0; m1.y = 0; m1.width = wPt; m1.height = hPt; m1.rotate = 0;
      const opt = new pdfService.PixelOptions();
      opt.isGray = false;
      opt.drawAnnotations = false;
      opt.isTransparent = false;
      const pm1 = page.getAreaPixelMapWithOptions(m1, W, H, opt);
      this.measurePm(pm1, 'WithOptions');
    } catch (e) {
      this.log(`SCAN|WithOptions|EXCEPTION`);
    }
    try {
      const m2 = new pdfService.PdfMatrix();
      m2.x = 0; m2.y = 0; m2.width = Math.floor(wPt / 2); m2.height = Math.floor(hPt / 2); m2.rotate = 0;
      const pm2 = page.getAreaPixelMap(m2, W, H, false, false);
      this.measurePm(pm2, '半页matrix');
    } catch (e) {
      this.log(`SCAN|半页matrix|EXCEPTION`);
    }
    try {
      const m3 = new pdfService.PdfMatrix();
      m3.x = 0; m3.y = 0; m3.width = wPt; m3.height = hPt; m3.rotate = 0;
      const pm3 = page.getCustomPagePixelMap(m3, false, false);
      pm3.getImageInfo().then((info: image.ImageInfo) => {
        hilog.info(0x0000, TAG, 'SCAN|Custom|size=%{public}dx%{public}d', info.size.width, info.size.height);
        pm3.release();
      });
    } catch (e) {
      this.log(`SCAN|Custom|EXCEPTION`);
    }
    // 尺寸轴翻转：画布按高对齐（1x 高 = 842 → 若按此得到正常说明坐标轴理解反了）
    try {
      const m4 = new pdfService.PdfMatrix();
      m4.x = 0; m4.y = 0; m4.width = wPt; m4.height = hPt; m4.rotate = 0;
      const pm4 = page.getAreaPixelMap(m4, 595 * 3, 842, false, false);
      const buf4 = new ArrayBuffer(595 * 3 * 842 * 4);
      pm4.readPixelsSync({
        pixels: buf4,
        offset: 0,
        stride: 595 * 3 * 4,
        region: { size: { width: 595 * 3, height: 842 }, x: 0, y: 0 }
      } as image.PositionArea);
      pm4.release();
      const b4 = new Uint8Array(buf4);
      let cnt = 0;
      for (let i = 0; i < b4.length; i += 4) {
        if (Math.max(b4[i], b4[i + 1], b4[i + 2]) < 200) { cnt++; }
      }
      hilog.info(0x0000, TAG, 'SCAN|宽3x高1x|暗像素=%{public}d%%', cnt / (595 * 3 * 842 / 100));
    } catch (e) {
      this.log(`SCAN|宽3x高1x|EXCEPTION`);
    }
  }

  // 探针J：PdfController.getPagePixelMap（官方FAQ的缩略图通道，异步）位图真相
  private probeControllerPm(): void {
    const controller = new pdfViewManager.PdfController();
    controller.registerPageCountChangedListener((n: number) => {
      hilog.info(0x0000, TAG, 'SCAN|Ctrl|pages=%{public}d', n);
    });
    controller.loadDocument(this.getCtx().filesDir + '/' + this.docName).then(() => {
      controller.getPagePixelMap(0, true).then((pm: image.PixelMap) => {
        pm.getImageInfo().then((info: image.ImageInfo) => {
          hilog.info(0x0000, TAG, 'SCAN|CtrlPm|size=%{public}dx%{public}d', info.size.width, info.size.height);
          const W = info.size.width;
          const H = info.size.height;
          const buf = new ArrayBuffer(W * H * 4);
          pm.readPixelsSync({
            pixels: buf,
            offset: 0,
            stride: W * 4,
            region: { size: { width: W, height: H }, x: 0, y: 0 }
          } as image.PositionArea);
          const b = new Uint8Array(buf);
          let minX = W, minY = H, maxX = -1, maxY = -1;
          for (let y = 0; y < H; y++) {
            const row = y * W * 4;
            for (let x = 0; x < W; x++) {
              const i = row + x * 4;
              if (Math.max(b[i], b[i + 1], b[i + 2]) < 200) {
                if (x < minX) { minX = x; }
                if (x > maxX) { maxX = x; }
                if (y < minY) { minY = y; }
                if (y > maxY) { maxY = y; }
              }
            }
          }
          const wPct = maxX < 0 ? 0 : Math.round((maxX - minX + 1) * 100 / W);
          const hPct = maxY < 0 ? 0 : Math.round((maxY - minY + 1) * 100 / H);
          this.log(`SCAN|CtrlPm|size=${W}x${H}|bbox宽占比=${wPct}% 高占比=${hPct}%`);
          // 上屏显示，供截图+视觉终验
          this.show(pm);
        });
      }).catch((e: Error) => {
        this.log(`SCAN|CtrlPm|getPM失败|${e.message}`);
      });
    }).catch((e: Error) => {
      this.log(`SCAN|CtrlPm|load失败|${e.message}`);
    });
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        Button('← 返回')
          .fontSize(14)
          .onClick(() => router.back())
        Text(this.status).fontSize(12).maxLines(2).layoutWeight(1)
      }
      .width('100%')

      Image(this.pixelMap).objectFit(ImageFit.Contain)
        .layoutWeight(1).width('100%').backgroundColor(Color.Gray)
      Row({ space: 10 }) {
        Button('◀').onClick(() => {
          if (this.pageIdx > 0) {
            this.pageIdx--;
            this.renderScale(2);
          }
        })
        Button('加载文档').onClick(() => this.loadDoc())
        Button('▶').onClick(() => {
          if (this.pageIdx + 1 < this.pdfDocument.getPageCount()) {
            this.pageIdx++;
            this.renderScale(2);
          }
        })
      }
      Row({ space: 10 }) {
        Button('默认档').onClick(() => this.renderDefault())
        Button('1x').onClick(() => this.renderScale(1))
        Button('2x').onClick(() => this.renderScale(2))
        Button('3x').onClick(() => this.renderScale(3))
        Button('5x').onClick(() => this.renderScale(5))
      }
      Row({ space: 10 }) {
        Button('C1裁半页').onClick(() => this.probeCropHalf())
        Button('C2四分21').onClick(() => this.probeQuarter())
        Button('C3矩阵同').onClick(() => this.probeMatrixEq())
        Button('Books路径3x').onClick(() => this.probeBooksPath())
        Button('屏宽先询3x').onClick(() => this.probeDisplayQuery())
      }
      Row({ space: 10 }) {
        Button('位图真相').onClick(() => this.probeBitmapTruth())
        Button('延迟显示3x').onClick(() => this.renderScaleDelayed(3))
        Button('复制fresh').onClick(() => this.copyFresh())
        Button('新文件真相').onClick(() => this.probeFreshFile())
        Button('页宽减1真相').onClick(() => this.probeMinusOne())
        Button('变体扫描').onClick(() => this.probeVariants())
        Button('控制器位图').onClick(() => this.probeControllerPm())
      }
      Row({ space: 10 }) {
        Button('PdfView测试→').width('46%').onClick(() => router.pushUrl({ url: 'pages/PdfViewDemo' }))
      }
      Button('★从调试台打开阅读页(无参数)')
        .onClick(() => router.pushUrl({ url: 'pages/ReaderPage' }))
      Button(this.docName === 'demo.pdf' ? '切换到 demo2.pdf' : '切换到 demo.pdf')
        .onClick(() => {
          this.docName = this.docName === 'demo.pdf' ? 'demo2.pdf' : 'demo.pdf';
          this.loaded = false;
          this.status = `已切换到 ${this.docName}，请点“加载文档”`;
        })
    }
    .width('100%').height('100%').padding(10)
  }
}
