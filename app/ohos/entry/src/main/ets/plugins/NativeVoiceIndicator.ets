import { NativeMediaKey } from './NativeMediaPolicy';

// Mainline UI integration boundary, not a Host-controlled visible=true flag.
// The application implementation must resolve show only after the current key's
// visible stop control is mounted. A click invokes stop; a lost/unmounted control
// also invokes stop. hide is idempotent after any show attempt (including a
// rejected show), and must affect only this exact key, not a newer owner.
export interface NativeVoiceIndicator {
  show(key: NativeMediaKey, stop: () => void): Promise<void>;
  hide(key: NativeMediaKey): Promise<void>;
}
