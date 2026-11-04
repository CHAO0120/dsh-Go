const unsupported = message => Object.assign(new Error(message), { code: 'ERR_IOS_PHONE_UNSUPPORTED' });
const invalid = message => Object.assign(new Error(message), { code: 'ERR_IOS_PHONE_ARGUMENTS' });
const text = (value, name, max = 8192) => {
  if (typeof value !== 'string' || value.length === 0 || Buffer.byteLength(value) > max || value.includes('\0')) {
    throw invalid(`${name} 必须是非空文字，且不能超过 ${max} 个 UTF-8 字节。`);
  }
  return value;
};
const optional = (value, name, max) => value === undefined ? undefined : text(value, name, max);
const number = value => {
  const result = text(value, 'number', 100);
  if (!/^[+\d ()-]+$/.test(result) || !/\d/.test(result)) throw invalid('号码只能含数字、+、空格、括号和连字符，不支持服务码。');
  return result;
};

// Catalog schemas remain byte-identical to Android. This is the smaller iOS execution set.
export function actionFor(name, args) {
  switch (name) {
    case 'open': {
      if (args.app !== undefined || args.background === true) throw unsupported('iOS 只能在前台打开网址，不提供枚举应用、按包名打开或后台屏。');
      const value = text(args.url, 'url', 2048);
      let url;
      try { url = new URL(value); } catch { throw invalid('url 不是有效网址。'); }
      if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password) {
        throw unsupported('iOS open 仅支持无内嵌凭据的 HTTP/HTTPS 链接；拨号、分享请使用对应 intent。');
      }
      return { kind: 'open', url: url.href };
    }
    case 'notify': return { kind: 'notify', title: text(args.title, 'title', 256), text: text(args.text, 'text') };
    case 'clipboard': {
      if (typeof args.set === 'string' && args.get !== true) {
        if (Buffer.byteLength(args.set) > 8192 || args.set.includes('\0')) throw invalid('剪贴板文字过长或含空字节。');
        return { kind: 'clipboard-set', text: args.set };
      }
      if (args.get === true && args.set === undefined) return { kind: 'clipboard-get' };
      throw invalid('clipboard 必须且只能指定 set 或 get:true。');
    }
    case 'intent': {
      switch (args.kind) {
        case 'calendar': return { kind: 'calendar', title: text(args.title, 'title', 256),
          begin: text(args.begin, 'begin', 100), end: optional(args.end, 'end', 100),
          allDay: args.all_day, location: optional(args.location, 'location', 1024),
          description: optional(args.description, 'description') };
        case 'dial': return { kind: 'dial', number: number(args.number) };
        case 'sms_draft': return { kind: 'sms-draft', number: args.number === undefined ? undefined : number(args.number), text: text(args.text, 'text') };
        case 'share': {
          if (args.app !== undefined) throw unsupported('iOS 分享由用户在系统分享面板选择目标，不能按 Android 应用名指定。');
          return { kind: 'share', text: text(args.text, 'text') };
        }
        case 'settings': {
          if (args.page !== 'home' || args.app !== undefined) throw unsupported('iOS 只支持 settings(page:"home") 打开 DSH Go 自身设置，不能打开其他系统设置页或其他 App 设置。');
          return { kind: 'settings' };
        }
        case 'navigate': {
          if (args.lat !== undefined || args.lng !== undefined) throw unsupported('目录中的坐标语义是 GCJ-02，不能直接作为 Apple Maps 坐标；iOS 请改用 destination 地址或地点名。');
          if (args.map !== undefined) throw unsupported('iOS 此实现使用 Apple Maps，不接受 Android 目录中的 amap/baidu 选择。');
          const mode = args.mode ?? 'drive';
          if (!['drive', 'walk', 'transit'].includes(mode)) throw unsupported('iOS 暂支持 drive、walk、transit；ride 暂不支持。');
          return { kind: 'navigate', destination: text(args.destination, 'destination', 1024), mode };
        }
        default: throw unsupported('iOS 此实现不提供系统闹钟或计时器；可使用 calendar 打开由用户保存的日程编辑器。');
      }
    }
    default: throw unsupported('iOS 公开 API 不允许此实现跨 App 读屏、截图、点击、输入、滚动或系统按键，也不能枚举已安装应用。请说明限制并让用户手动完成；handoff 不会提供或代替操作批准。');
  }
}
