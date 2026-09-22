export interface BookInfo {
  fileName: string;    // Books/ 下的文件名，唯一键
  title: string;       // 显示名：metadata 优先，文件名兜底
  size: number;        // 字节
  pageCount: number;   // 总页数（首次打开/导入时回填）
  page: number;        // 阅读进度页码（0 基）
  lastOpen: number;    // 上次打开时间戳 ms，0=从未
  importedAt: number;  // 导入时间戳 ms
  enriched: boolean;   // 元数据+封面是否已抽取
  hasCover: boolean;   // 封面缓存文件是否存在
  bookmarks?: number[]; // 书签页码（0 基，升序）；旧索引可能缺省
}
