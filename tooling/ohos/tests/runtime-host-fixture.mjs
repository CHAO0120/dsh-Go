export const native = {
  state: { phase: 'idle', consumed: false, baseUrl: null, token: null, exitCode: null, errorCode: null, errorMessage: null },
  events: [], starts: [], stops: 0, afterDrain: null,
  reset() {
    this.state = { phase: 'idle', consumed: false, baseUrl: null, token: null, exitCode: null, errorCode: null, errorMessage: null };
    this.events = []; this.starts = []; this.stops = 0; this.afterDrain = null;
  },
};
export function getState() { return { ...native.state }; }
export function drainEvents() {
  const batch = native.events.splice(0);
  native.afterDrain?.();
  return batch;
}
export function start(options) {
  if (native.state.consumed) throw new Error('one shot');
  native.starts.push(options);
  native.state.phase = 'starting'; native.state.consumed = true;
}
export function stop() { native.stops++; native.state.phase = 'stopping'; }

export const connection = {
  NetCap: { NET_CAPABILITY_NOT_METERED: 11 },
  async getDefaultNet() { return { netId: 1 }; },
  async getNetCapabilities() { return { networkCap: [11] }; },
};

export class MethodCall {
  constructor(method, args) { this.method = method; this.args = args; }
  argument(key) { return this.args?.get(key) ?? null; }
}
export class MethodChannel {
  constructor(messenger, name) { this.messenger = messenger; this.name = name; }
  setMethodCallHandler(handler) { this.handler = handler; }
}
export class EventChannel {
  constructor(messenger, name) { this.messenger = messenger; this.name = name; }
  setStreamHandler(handler) { this.handler = handler; }
}
