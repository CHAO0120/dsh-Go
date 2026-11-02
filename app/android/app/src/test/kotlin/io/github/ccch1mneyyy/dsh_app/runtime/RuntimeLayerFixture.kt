package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File

/** Small extracted assets only; preparation, activation and recovery stay in production code. */
internal fun writeRuntimeLayerFixture(layers: RuntimeLayers, next: RuntimeLayerSet) {
    for (name in layers.changed(next)) {
        val staged = layers.staged(name)
        val payload = when (name) {
            "base" -> "bin/new"
            "dsh" -> "opt/dsh/package.txt"
            else -> "opt/dsh-go/bridge.txt"
        }
        File(staged, payload).apply { parentFile.mkdirs(); writeText(next.layer(name)) }
        if (name == "base") {
            listOf("root", "opt", "etc/dsh-app").forEach { File(staged, it).mkdirs() }
        }
    }
    layers.stagedIdentity().writeText(next.identity)
}
