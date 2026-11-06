export const guestInstallRequiredMessage = 'ERR_IOS_GUEST_INSTALL_REQUIRED: 请先在设置中安装 Linux 环境，然后重新启动本机引擎。';
// Owner-side metadata store only. No channel/native imports, filesystem probes,
// command execution, or guest boot. Publishing is a trusted bootstrap operation;
// it must never be exposed as a model/config/HTTP mutation API.
const unknown = Object.freeze({
  v: 1, source: 'none', state: 'unavailable', installed: 'unknown',
  available: false, enforcement: 'unknown', python: 'unknown',
  hint: '可连接电脑执行；可选 Linux 环境须由 App 安装并确认可用。',
});
const oneOf = (v, choices) => choices.includes(v);
export function createGuestMetadataStore() {
  let cached = unknown;
  return Object.freeze({
    read: () => cached,
    // A JSON transport value cannot invoke arbitrary property getters while
    // normalizing it. A malformed/new unsupported report replaces stale ready.
    publishJSON(text) {
      cached = unknown;
      if (typeof text !== 'string' || text.length > 4096) return false;
      let value;
      try { value = JSON.parse(text); } catch { return false; }
      if (!value || value.v !== 1 ||
          !oneOf(value.source, ['ios-native-owner', 'linux-test']) ||
          !oneOf(value.state, ['disabled', 'ready', 'busy', 'faulted', 'unavailable']) ||
          !oneOf(value.installed, ['present', 'absent', 'unknown']) ||
          typeof value.available !== 'boolean' ||
          !oneOf(value.enforcement, ['none', 'partial', 'strong', 'unknown']) ||
          !oneOf(value.python, ['supported', 'unsupported', 'unknown'])) return false;
      const available = value.available && value.installed === 'present' &&
        ['ready', 'busy'].includes(value.state);
      cached = Object.freeze({
        v: 1, source: value.source, state: value.state,
        installed: value.installed, available,
        enforcement: value.enforcement === 'strong' ? 'unknown' : value.enforcement, python: value.python,
        // Test readiness is never presented as installed iSH capability.
        testOnly: value.source === 'linux-test',
        hint: value.source === 'linux-test' ? '仅 Linux 测试后端，不证明 iSH 或 Apple 能力。' : unknown.hint,
      });
      return true;
    },
    clear() { cached = unknown; },
  });
}
export function guestDescription(metadata) {
  if (!metadata || metadata.source === 'none') return '可选 Linux 执行环境当前不可用，安装状态未知。' + unknown.hint;
  if (metadata.testOnly) return '当前仅接入 Linux 测试后端，不代表 iSH 已安装或可用于设备。';
  if (!metadata.available) return '可选 Linux 执行环境当前不可用（' + metadata.state + '）。' + unknown.hint;
  return '可信原生 owner 的缓存报告：可选 Linux 执行环境可用；约束状态为 ' + metadata.enforcement + '。本查询没有启动或探测环境。';
}

// Apply transport/queue availability without booting or probing either one.
export function guestMetadataView(cached, hasTransport, queueState) {
  const store = createGuestMetadataStore();
  try { store.publishJSON(JSON.stringify(cached)); } catch {}
  const value = store.read();
  const state = !hasTransport ? 'unavailable' : ['faulted', 'closed'].includes(queueState) ? queueState : value.state;
  return Object.freeze({...value, state, available: value.available && hasTransport && !['faulted', 'closed'].includes(queueState)});
}
