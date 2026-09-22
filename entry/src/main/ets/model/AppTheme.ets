export interface ThemePalette {
  name: string;
  bg: string;      // 页面背景
  card: string;    // 卡片/条目底色
  text: string;    // 主文字色
  sub: string;     // 次要文字色
}

// 主题色档（意象命名）。索引即持久化的 themeIdx，增删色档不可调换顺序
export const THEME_LIST: ThemePalette[] = [
  { name: '霜白', bg: '#FFFFFF', card: '#F1F3F5', text: '#1A1A1A', sub: '#666666' },
  { name: '纸黄', bg: '#F5F0E1', card: '#EDE5CE', text: '#3B3325', sub: '#85795C' },
  { name: '豆沙绿', bg: '#C7EDCC', card: '#B5E1BB', text: '#243524', sub: '#4F6B52' },
  { name: '丁香紫', bg: '#E9E2F6', card: '#DBD0F0', text: '#2C2340', sub: '#6E638C' },
  { name: '暮灰', bg: '#3A3D42', card: '#474B51', text: '#E6E7E9', sub: '#A8ABB1' },
  { name: '墨黑', bg: '#000000', card: '#17181B', text: '#EDEDED', sub: '#8E9094' }
];

export const FONT_SCALES: number[] = [0.85, 1.0, 1.2, 1.4];
export const FONT_NAMES: string[] = ['小', '标准', '大', '特大'];

export function paletteOf(idx: number): ThemePalette {
  if (idx < 0 || idx >= THEME_LIST.length) {
    return THEME_LIST[0];
  }
  return THEME_LIST[idx];
}

export function fontScaleOf(idx: number): number {
  if (idx < 0 || idx >= FONT_SCALES.length) {
    return 1.0;
  }
  return FONT_SCALES[idx];
}
