import { pdfService, pdfViewManager, PdfView } from '@kit.PDFKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'PdfDemo';

@Entry
@Component
struct PdfViewDemo {
  @State status: string = '未加载';
  private controller: pdfViewManager.PdfController = new pdfViewManager.PdfController();
  private loaded: boolean = false;

  private getCtx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private log(line: string): void {
    this.status = line;
    hilog.info(0x0000, TAG, '%{public}s', line);
  }

  private load(name: string): void {
    const path: string = this.getCtx().filesDir + '/' + name;
    if (!fs.accessSync(path)) {
      this.status = `沙箱里没有 ${name}，先回首页加载一次`;
      return;
    }
    if (this.loaded) {
      this.controller.releaseDocument();
      this.loaded = false;
    }
    const t0 = Date.now();
    // 页数监听必须在 loadDocument 之前注册（官方文档明确要求）
    this.controller.registerPageCountChangedListener((pageCount: number) => {
      this.loaded = true;
      this.log(`TEST|act=pvload|doc=${name}|pages=${pageCount}|ms=${Date.now() - t0}`);
    });
    this.controller.registerPageChangedListener((idx: number) => {
      hilog.info(0x0000, TAG, 'TEST|act=pvpage|page=%{public}d', idx);
    });
    this.controller.registerScaleChangedListener((zoom: number) => {
      hilog.info(0x0000, TAG, 'TEST|act=pvscale|zoom=%{public}f', zoom);
    });
    this.controller.loadDocument(path)
      .then((r: pdfService.ParseResult) => {
        hilog.info(0x0000, TAG, 'TEST|act=pvparse|result=%{public}d', r);
      })
      .catch((err: BusinessError) => {
        this.status = `加载失败：${JSON.stringify(err)}`;
      });
  }

  aboutToDisappear(): void {
    if (this.loaded) {
      this.controller.releaseDocument();
    }
  }

  build() {
    Column({ space: 8 }) {
      Text(this.status).fontSize(12).maxLines(3).fontColor(Color.White)
      Column() {
        PdfView({
          controller: this.controller,
          pageFit: pdfService.PageFit.FIT_WIDTH,
        }).width('100%').height('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .backgroundColor(Color.Black) // 试验点：PdfView 外围衬底显色
      Row({ space: 8 }) {
        Button('加载demo2').onClick(() => this.load('demo2.pdf'))
        Button('加载demo').onClick(() => this.load('demo.pdf'))
        Button('跳100页').onClick(() => {
          this.controller.goToPage(100);
        })
        Button('放大2x').onClick(() => {
          this.controller.setPageZoom(2);
        })
        Button('整页适配').onClick(() => {
          this.controller.setPageFit(pdfService.PageFit.FIT_PAGE);
        })
        Button('返回').onClick(() => router.back())
      }
    }
    .width('100%').height('100%').padding(8)
    .backgroundColor(Color.Black)
  }
}
