import AppLinksPlugin from '../plugins/AppLinksPlugin';
import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import ConnectivityPlugin from '../plugins/ConnectivityPlugin';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import { RuntimePlugin } from '../runtime/RuntimePlugin';
import FilesMediaPlugin from '../plugins/FilesMediaPlugin';

export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    flutterEngine.getPlugins()?.add(new AppLinksPlugin())
    super.configureFlutterEngine(flutterEngine)
    flutterEngine.getPlugins()?.add(new ConnectivityPlugin())
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    flutterEngine.getPlugins()?.add(new RuntimePlugin())
    flutterEngine.getPlugins()?.add(new FilesMediaPlugin())
  }
}
