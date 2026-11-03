package io.github.ccch1mneyyy.dsh_app.runtime

import android.content.Context
import org.json.JSONObject

/**
 * Describes the Linux runtime bundled in this APK flavor
 * (assets/runtime/manifest.json, written by runtime/build-runtime.sh).
 */
data class RuntimeManifest(
    val runtimeVersion: String,
    val abi: String,
    val rootfsBytes: Long,
    val uncompressedBytes: Long,
    val layers: Map<String, Layer>,
    val runtimeIdentity: RuntimeIdentity,
    val dshVersion: String,
    val nodeVersion: String,
    /** proot argv template; placeholders are expanded by [LaunchSpec]. */
    val launchArgv: List<String>,
    val launchEnv: Map<String, String>,
    val raw: JSONObject,
) {
    data class Layer(
        val asset: String,
        val bytes: Long,
        val archiveSha256: String,
        val contentSha256: String,
        val uncompressedBytes: Long,
    )

    data class RuntimeIdentity(val asset: String, val bytes: Long, val sha256: String)

    internal val layerSet: RuntimeLayerSet
        get() = RuntimeLayerSet(runtimeVersion, abi,
            layers.getValue("base").contentSha256, layers.getValue("dsh").contentSha256,
            layers.getValue("go").contentSha256, runtimeIdentity.sha256)

    companion object {
        const val ASSET_DIR = "runtime"

        fun load(context: Context): RuntimeManifest {
            val text = context.assets.open("$ASSET_DIR/manifest.json").bufferedReader().use { it.readText() }
            val json = JSONObject(text)
            check(json.getInt("schema") == 2) { "unsupported bundled runtime manifest" }
            val layers = json.getJSONObject("layers")
            check(layers.getInt("schema") == 1) { "unsupported bundled runtime layers" }
            val identity = json.getJSONObject("runtimeIdentity")
            val launch = json.optJSONObject("launch") ?: JSONObject()
            val argvJson = launch.optJSONArray("argv")
            val argv = if (argvJson != null) List(argvJson.length()) { argvJson.getString(it) } else emptyList()
            val envJson = launch.optJSONObject("env") ?: JSONObject()
            val env = envJson.keys().asSequence().associateWith { envJson.getString(it) }
            return RuntimeManifest(
                runtimeVersion = json.getString("runtimeVersion"),
                abi = json.optString("abi"),
                rootfsBytes = json.optLong("rootfsBytes", -1L),
                uncompressedBytes = json.optLong("uncompressedBytes", -1L),
                layers = RuntimeLayers.NAMES.associateWith { name ->
                    val layer = layers.getJSONObject(name)
                    Layer(layer.getString("asset"), layer.getLong("bytes"),
                        layer.getString("archiveSha256"), layer.getString("contentSha256"),
                        layer.getLong("uncompressedBytes"))
                },
                runtimeIdentity = RuntimeIdentity(identity.getString("asset"),
                    identity.getLong("bytes"), identity.getString("sha256")),
                dshVersion = json.optString("dshVersion"),
                nodeVersion = json.optString("nodeVersion"),
                launchArgv = argv,
                launchEnv = env,
                raw = json,
            )
        }
    }
}
