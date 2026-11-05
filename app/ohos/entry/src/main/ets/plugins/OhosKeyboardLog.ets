// One hilog line per keyboard event, to read off a device what the eased inset in
// keyboard_motion.dart only guesses: the real curve and when the height is reported.
// The will and did events carry the rects, animated and the animation config; height and
// avoidArea are what the embedding hears. Geometry only. hilog's timestamps line them up.
import hilog from '@ohos.hilog';
import window from '@ohos.window';

function line(event: string, detail: string): void {
  hilog.info(0x3F00, 'DshKeyboard', '%{public}s %{public}s', event, detail);
}

export class OhosKeyboardLog {
  private target: window.Window | null = null;
  private willShow: (info: window.KeyboardInfo) => void = (info: window.KeyboardInfo): void => { line('willShow', JSON.stringify(info)); };
  private willHide: (info: window.KeyboardInfo) => void = (info: window.KeyboardInfo): void => { line('willHide', JSON.stringify(info)); };
  private didShow: (info: window.KeyboardInfo) => void = (info: window.KeyboardInfo): void => { line('didShow', JSON.stringify(info)); };
  private didHide: (info: window.KeyboardInfo) => void = (info: window.KeyboardInfo): void => { line('didHide', JSON.stringify(info)); };
  private height: (height: number) => void = (height: number): void => { line('height', String(height)); };
  private avoidArea: (data: window.AvoidAreaOptions) => void = (data: window.AvoidAreaOptions): void => {
    if (data.type === window.AvoidAreaType.TYPE_KEYBOARD) line('avoidArea', JSON.stringify(data.area));
  };

  attach(stage: window.WindowStage): void {
    this.detach();
    this.quietly('getMainWindow', (): void => {
      const target = stage.getMainWindowSync();
      this.target = target;
      this.quietly('keyboardWillShow', (): void => { target.on('keyboardWillShow', this.willShow); });
      this.quietly('keyboardWillHide', (): void => { target.on('keyboardWillHide', this.willHide); });
      this.quietly('keyboardDidShow', (): void => { target.on('keyboardDidShow', this.didShow); });
      this.quietly('keyboardDidHide', (): void => { target.on('keyboardDidHide', this.didHide); });
      this.quietly('keyboardHeightChange', (): void => { target.on('keyboardHeightChange', this.height); });
      this.quietly('avoidAreaChange', (): void => { target.on('avoidAreaChange', this.avoidArea); });
    });
  }

  detach(): void {
    const target = this.target;
    this.target = null;
    if (target === null) return;
    this.quietly('keyboardWillShow', (): void => { target.off('keyboardWillShow', this.willShow); });
    this.quietly('keyboardWillHide', (): void => { target.off('keyboardWillHide', this.willHide); });
    this.quietly('keyboardDidShow', (): void => { target.off('keyboardDidShow', this.didShow); });
    this.quietly('keyboardDidHide', (): void => { target.off('keyboardDidHide', this.didHide); });
    this.quietly('keyboardHeightChange', (): void => { target.off('keyboardHeightChange', this.height); });
    this.quietly('avoidAreaChange', (): void => { target.off('avoidAreaChange', this.avoidArea); });
  }

  // A device without one of these still gets the others, and the app never pays for a log.
  private quietly(what: string, action: () => void): void {
    try { action(); } catch (_) { hilog.warn(0x3F00, 'DshKeyboard', 'no %{public}s', what); }
  }
}
