import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

/** 全局设置出入口：Preferences 持久化 + AppStorage 同步，UI 用 @StorageProp 绑定 */
export class SettingsStore {
  private static prefs: preferences.Preferences | null = null;

  static init(context: common.Context): void {
    if (SettingsStore.prefs !== null) {
      return;
    }
    SettingsStore.prefs = preferences.getPreferencesSync(context, { name: 'pageark_settings' });
    AppStorage.setOrCreate('themeIdx', SettingsStore.prefs.getSync('themeIdx', 0) as number);
    AppStorage.setOrCreate('fontIdx', SettingsStore.prefs.getSync('fontIdx', 1) as number);
    AppStorage.setOrCreate('fitWidthExp', SettingsStore.prefs.getSync('fitWidthExp', false) as boolean);
    AppStorage.setOrCreate('sortIdx', SettingsStore.prefs.getSync('sortIdx', 0) as number);
    AppStorage.setOrCreate('dualPageExp', SettingsStore.prefs.getSync('dualPageExp', false) as boolean);
    AppStorage.setOrCreate('tapTurn', SettingsStore.prefs.getSync('tapTurn', true) as boolean);
  }

  private static put(key: string, value: preferences.ValueType): void {
    const p = SettingsStore.prefs;
    if (p === null) {
      return;
    }
    p.putSync(key, value);
    p.flush();
  }

  static setThemeIdx(v: number): void {
    AppStorage.setOrCreate('themeIdx', v);
    SettingsStore.put('themeIdx', v);
  }

  static setFontIdx(v: number): void {
    AppStorage.setOrCreate('fontIdx', v);
    SettingsStore.put('fontIdx', v);
  }

  static setFitWidthExp(v: boolean): void {
    AppStorage.setOrCreate('fitWidthExp', v);
    SettingsStore.put('fitWidthExp', v);
  }

  static setSortIdx(v: number): void {
    AppStorage.setOrCreate('sortIdx', v);
    SettingsStore.put('sortIdx', v);
  }

  static setDualPageExp(v: boolean): void {
    AppStorage.setOrCreate('dualPageExp', v);
    SettingsStore.put('dualPageExp', v);
  }

  static setTapTurn(v: boolean): void {
    AppStorage.setOrCreate('tapTurn', v);
    SettingsStore.put('tapTurn', v);
  }
}
