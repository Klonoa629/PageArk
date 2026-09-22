import { pdfService } from '@kit.PDFKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { BookInfo } from '../model/BookInfo';

const JUNK_TITLE: RegExp = /microsoft|word|acrobat|latex|calibre|unknown|admin|user|owner|creator|writer/i;

/**
 * 书库管理：books.json 索引 + Books/ 目录 + covers/ 封面缓存。
 * 扫描目录时不打开任何 PDF（瞬时）；元数据/封面抽取按需异步做。
 */
export class LibraryManager {
  static booksDir(ctx: common.Context): string {
    return ctx.filesDir + '/Books';
  }

  static coverPath(ctx: common.Context, fileName: string): string {
    // 封面缓存按渲染公式版本命名，公式修正后旧坏图自动失效重建
    return ctx.filesDir + '/covers/' + fileName + '.v2.jpg';
  }

  private static indexPath(ctx: common.Context): string {
    return ctx.filesDir + '/books.json';
  }

  private static loadIndex(ctx: common.Context): BookInfo[] {
    try {
      const p = LibraryManager.indexPath(ctx);
      if (!fs.accessSync(p)) {
        return [];
      }
      return JSON.parse(fs.readTextSync(p)) as BookInfo[];
    } catch (e) {
      return [];
    }
  }

  private static saveIndex(ctx: common.Context, list: BookInfo[]): void {
    const file = fs.openSync(LibraryManager.indexPath(ctx),
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, JSON.stringify(list));
    fs.closeSync(file);
  }

  private static ensureDirs(ctx: common.Context): void {
    if (!fs.accessSync(LibraryManager.booksDir(ctx))) {
      fs.mkdirSync(LibraryManager.booksDir(ctx));
    }
    if (!fs.accessSync(ctx.filesDir + '/covers')) {
      fs.mkdirSync(ctx.filesDir + '/covers');
    }
  }

  /** 目录与索引对账后返回书列表（最近阅读优先），不打开 PDF */
  static scan(ctx: common.Context): BookInfo[] {
    LibraryManager.ensureDirs(ctx);
    const names: string[] = fs.listFileSync(LibraryManager.booksDir(ctx))
      .filter((n: string) => n.toLowerCase().endsWith('.pdf'));
    const index: BookInfo[] = LibraryManager.loadIndex(ctx);
    const kept: BookInfo[] = index.filter((b: BookInfo) => names.indexOf(b.fileName) >= 0);
    const keptNames: string[] = kept.map((b: BookInfo) => b.fileName);
    for (const n of names) {
      if (keptNames.indexOf(n) < 0) {
        const st = fs.statSync(LibraryManager.booksDir(ctx) + '/' + n);
        const b: BookInfo = {
          fileName: n,
          title: n.replace(/\.pdf$/i, ''),
          size: st.size,
          pageCount: 0, page: 0, lastOpen: 0,
          importedAt: Date.now(), enriched: false,
          bookmarks: [],
          hasCover: fs.accessSync(LibraryManager.coverPath(ctx, n))
        };
        kept.push(b);
      }
    }
    for (const b of kept) {
      if (b.bookmarks === undefined) {
        b.bookmarks = [];
      }
      b.hasCover = fs.accessSync(LibraryManager.coverPath(ctx, b.fileName));
      // 封面缓存缺失（如渲染公式修正后升版本）时强制重新抽取
      if (!b.hasCover) {
        b.enriched = false;
      }
    }
    kept.sort((a: BookInfo, c: BookInfo) => {
      if (a.lastOpen !== c.lastOpen) {
        return c.lastOpen - a.lastOpen;
      }
      return c.importedAt - a.importedAt;
    });
    LibraryManager.saveIndex(ctx, kept);
    return kept;
  }

  static getBook(ctx: common.Context, fileName: string): BookInfo | undefined {
    const list = LibraryManager.loadIndex(ctx);
    for (const b of list) {
      if (b.fileName === fileName) {
        return b;
      }
    }
    return undefined;
  }

  /** 开发用：把 rawfile 里的测试书复制进书库 */
  static importDemoBooks(ctx: common.Context): Promise<string[]> {
    return new Promise<string[]>((resolve) => {
      const added: string[] = [];
      const names: string[] = ['demo.pdf', 'demo2.pdf', 'testbook.pdf'];
      let pending = names.length;
      const finishOne = (): void => {
        pending--;
        if (pending <= 0) {
          LibraryManager.scan(ctx);
          resolve(added);
        }
      };
      for (const n of names) {
        const dst = LibraryManager.booksDir(ctx) + '/' + n;
        if (fs.accessSync(dst)) {
          finishOne();
          continue;
        }
        ctx.resourceManager.getRawFileContent(n).then((buf: Uint8Array) => {
          const file = fs.openSync(dst, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
          fs.writeSync(file.fd, buf.buffer);
          fs.closeSync(file);
          added.push(n);
          finishOne();
        }).catch(() => finishOne());
      }
    });
  }

  static updateProgress(ctx: common.Context, fileName: string, page: number, pageCount: number): void {
    const list = LibraryManager.loadIndex(ctx);
    for (const b of list) {
      if (b.fileName === fileName) {
        b.page = page;
        b.lastOpen = Date.now();
        if (pageCount > 0) {
          b.pageCount = pageCount;
        }
        break;
      }
    }
    LibraryManager.saveIndex(ctx, list);
  }

  // 切换书签：已在则移除，不在则加入（保持升序）。返回切换后是否已标记
  static toggleBookmark(ctx: common.Context, fileName: string, page: number): boolean {
    const list = LibraryManager.loadIndex(ctx);
    for (const b of list) {
      if (b.fileName === fileName) {
        if (b.bookmarks === undefined) {
          b.bookmarks = [];
        }
        const i = b.bookmarks.indexOf(page);
        if (i >= 0) {
          b.bookmarks.splice(i, 1);
          LibraryManager.saveIndex(ctx, list);
          return false;
        }
        b.bookmarks.push(page);
        b.bookmarks.sort((a: number, c: number) => a - c);
        LibraryManager.saveIndex(ctx, list);
        return true;
      }
    }
    return false;
  }

  static editBook(ctx: common.Context, fileName: string, title: string): void {
    const list = LibraryManager.loadIndex(ctx);
    for (const b of list) {
      if (b.fileName === fileName) {
        if (title.trim().length > 0) {
          b.title = title.trim();
        }
        break;
      }
    }
    LibraryManager.saveIndex(ctx, list);
  }

  static deleteBook(ctx: common.Context, fileName: string): void {
    const list = LibraryManager.loadIndex(ctx).filter((b: BookInfo) => b.fileName !== fileName);
    LibraryManager.saveIndex(ctx, list);
    try {
      fs.unlinkSync(LibraryManager.booksDir(ctx) + '/' + fileName);
    } catch (e) {
    }
    try {
      fs.unlinkSync(LibraryManager.coverPath(ctx, fileName));
    } catch (e) {
    }
  }

  /** 异步抽取元数据（标题/页数）并生成封面缓存，完成后回调通知 UI 刷新 */
  static enrichBook(ctx: common.Context, fileName: string, onDone: () => void): void {
    LibraryManager.enrichAsync(ctx, fileName).then(() => onDone()).catch(() => onDone());
  }

  private static async enrichAsync(ctx: common.Context, fileName: string): Promise<void> {
    const path = LibraryManager.booksDir(ctx) + '/' + fileName;
    const doc = new pdfService.PdfDocument();
    const result = doc.loadDocument(path);
    const list = LibraryManager.loadIndex(ctx);
    const entry = list.find((b: BookInfo) => b.fileName === fileName);
    if (entry === undefined) {
      if (result === pdfService.ParseResult.PARSE_SUCCESS) {
        doc.releaseDocument();
      }
      return;
    }
    entry.enriched = true; // 失败也不再重试，避免每次扫描重复打开大文件
    if (result !== pdfService.ParseResult.PARSE_SUCCESS) {
      LibraryManager.saveIndex(ctx, list);
      return;
    }
    try {
      entry.pageCount = doc.getPageCount();
      const md: pdfService.Metadata = doc.getMetadata();
      if (entry.title === entry.fileName.replace(/\.pdf$/i, '')) {
        const t = md.title.trim();
        if (t.length > 1 && t.length < 80 && !JUNK_TITLE.test(t)) {
          entry.title = t;
        }
      }
      await LibraryManager.makeCover(ctx, doc, fileName);
      entry.hasCover = true;
    } catch (e) {
      // 单步失败不影响其他字段
    }
    LibraryManager.saveIndex(ctx, list);
    doc.releaseDocument();
  }

  private static async makeCover(ctx: common.Context, doc: pdfService.PdfDocument, fileName: string): Promise<void> {
    const page = doc.getPage(0);
    const wPt = page.getWidth();
    const hPt = page.getHeight();
    // 阶段一验证过的安全公式：画布必须是页宽的整数倍（k≥1），
    // 非整数倍率会触发渲染退化（内容按 1pt=1px 落在画布左上角）
    const k = Math.max(1, Math.round(400 / wPt));
    const W = Math.floor(wPt * k);
    const H = Math.floor(hPt * k);
    const matrix = new pdfService.PdfMatrix();
    matrix.x = 0;
    matrix.y = 0;
    matrix.width = wPt;
    matrix.height = hPt;
    matrix.rotate = 0;
    const pm: image.PixelMap = page.getAreaPixelMap(matrix, W, H, false, false);
    const packer = image.createImagePacker();
    const data: ArrayBuffer = await packer.packToData(pm, { format: 'image/jpeg', quality: 78 } as image.PackingOption);
    packer.release();
    pm.release();
    const file = fs.openSync(LibraryManager.coverPath(ctx, fileName),
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, data);
    fs.closeSync(file);
  }
}
