import Foundation

@main
struct PetOverlayContract {
  static var checks = 0
  static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    precondition(condition(), name)
    checks += 1
  }

  static func main() throws {
    guard CommandLine.arguments.count == 2 else { fatalError("Pass app/assets/pets") }
    let assets = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    var policy = PetOverlayPolicy()
    check(!policy.enabled && !policy.alwaysShow && !policy.hasDemand, "default off")
    check(policy.begin(id: 3, sessionID: "fixture", line: "Maps"), "authenticated owner begin")
    check(!policy.hasDemand, "task cannot enable the feature")
    policy.enabled = true
    check(policy.hasDemand, "enabled active task has demand")
    check(!policy.end(id: 2) && policy.task?.id == 3, "stale end cannot end current task")
    check(policy.requestPause() == 3 && policy.paused, "system pause locks exact owner")
    check(policy.requestPause() == nil, "pause callback is delivered once")
    check(!policy.confirmResume(id: 2) && policy.paused, "stale resume cannot unlock current task")
    check(!policy.mayConfirmStop(id: 2) && policy.mayConfirmStop(id: 3), "stop confirmation is owner bound")
    check(policy.confirmResume(id: 3) && !policy.paused, "explicit current-owner resume")
    policy.update(id: 2, line: "stale", progress: 0.8)
    check(policy.task?.line == "Maps", "stale progress is ignored")
    check(policy.end(id: 3) && !policy.hasDemand, "task end is immediate, without Android grace period")
    check(!policy.begin(id: 3, sessionID: "fixture", line: nil), "ended task cannot be revived by stale begin")
    policy.alwaysShow = true
    check(policy.hasDemand, "separately chosen alwaysShow survives end")
    policy.snoozed = true
    check(!policy.hasDemand, "system close suppresses automatic restart")
    check(!PetOverlayState.safeAssetComponent("../deepy-whale"), "pack path cannot escape assets")
    let ignored = PetOverlayState(["state": "invented", "packId": "none", "active": true,
      "foreground": false, "bubble": ["id": "one", "text": "Approved title", "untilMs": 5000,
        "ask": ["text": "do not render private request"], "detail": "do not render reply"]])
    check(ignored.state == "idle" && ignored.packID == nil, "unknown mood and no-pet semantics")
    check(ignored.visibleBubble(at: 4000) == "Approved title", "only reduced bubble title is rendered")
    check(ignored.visibleBubble(at: 5000) == nil, "bubble expires without another Dart push")
    let quiet = PetOverlayState(["quiet": true, "bubble": ["id": "q", "text": "quiet", "untilMs": 10000]])
    check(quiet.visibleBubble(at: 0) == nil, "quiet suppresses title")

    let repeated = PetOverlayAnimation(name: "fixture", sheet: "fixture.png", frameWidth: 4,
      frameHeight: 3, columns: 2, box: PetOverlayBox(x: 1, y: 2, width: 4, height: 3),
      frames: [PetOverlayFrame(cell: 0, milliseconds: 40), PetOverlayFrame(cell: 0, milliseconds: 60),
        PetOverlayFrame(cell: 3, milliseconds: 90)], loops: true)
    check(repeated.frameIndex(at: 39) == 0 && repeated.frameIndex(at: 40) == 1,
      "unequal per-frame durations are not flattened")
    check(repeated.nextChange(after: 0) == 100 && repeated.nextChange(after: 80) == 20,
      "repeated cells preserve timing without redraw")
    check(repeated.sourceRect(cell: 3) == PetOverlayBox(x: 4, y: 3, width: 4, height: 3), "row-major grid")
    check(repeated.frameIndex(at: 190) == 0, "loop boundary wraps exactly")
    let oneShot = PetOverlayAnimation(name: "once", sheet: "fixture.png", frameWidth: 4,
      frameHeight: 3, columns: 2, box: repeated.box, frames: repeated.frames, loops: false)
    check(oneShot.frameIndex(at: 10000) == 2 && oneShot.nextChange(after: 190) == nil,
      "one-shot holds final frame with no timer")

    for id in ["deepy-whale", "whale-girl"] {
      let bytes = try Data(contentsOf: assets.appendingPathComponent(id + "/pack.json"))
      let pack = try PetOverlayPack(data: bytes, expectedID: id)
      check(pack.primary(state: "working", tier: 1).name == "typing", id + " working tier one")
      check(pack.primary(state: "working", tier: 3).name == "building", id + " working tier three")
      check(pack.primary(state: "juggling", tier: 2).name == "conducting", id + " subagent tier")
      check(pack.primary(state: "unknown", tier: 0).name == "idle", id + " fallback matches Dart")
      for density in [1.0, 2.0, 2.75, 3.0] {
        let s = pack.artScale(size: .small, deviceScale: density)
        let m = pack.artScale(size: .medium, deviceScale: density)
        let l = pack.artScale(size: .large, deviceScale: density)
        check(s.rounded() == s && m >= s + 1 && l >= m + 1, id + " distinct physical-pixel sizes")
      }
      for animation in pack.animations.values {
        var at = 0
        for (index, frame) in animation.frames.enumerated() {
          check(animation.frameIndex(at: at) == index, id + " " + animation.name + " boundary")
          check(animation.frameIndex(at: at + frame.milliseconds - 1) == index,
            id + " " + animation.name + " end-exclusive timing")
          at += frame.milliseconds
        }
      }
      let active = PetOverlayState(["packId": id, "state": "working", "tier": 1])
      var clock = PetOverlayFrameClock()
      let first = clock.frame(pack: pack, state: active, now: 1000, random: { 0.9 })
      clock.setPaused(true, now: 1020)
      let frozen = clock.frame(pack: pack, state: active, now: 9000, random: { 0.9 })
      check(first.index == frozen.index, id + " hiding freezes frame clock")
      clock.setPaused(false, now: 9000)
      let resumed = clock.frame(pack: pack, state: active, now: 9000, random: { 0.9 })
      check(resumed.index == frozen.index, id + " resume does not skip hidden time")
      let still = PetOverlayState(["packId": id, "state": "working", "tier": 1, "reduceMotion": true])
      let frame = clock.frame(pack: pack, state: still, now: 10000, random: { 0.9 })
      check(frame.index == 0 && frame.nextMilliseconds == nil, id + " reduced motion has no timer")
      var calm = PetOverlayFrameClock()
      let sleeping = PetOverlayState(["packId": id, "state": "sleeping"])
      _ = calm.frame(pack: pack, state: sleeping, now: 0, random: { 0 })
      let sleepAction = calm.frame(pack: pack, state: sleeping, now: 8000, random: { 0 })
      check(sleepAction.animation.name == "sleeping", id + " sleeping never invents a waking mood")
      var corrupt = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
      corrupt["scale"] = true
      do {
        _ = try PetOverlayPack(data: JSONSerialization.data(withJSONObject: corrupt), expectedID: id)
        fatalError("boolean scale accepted")
      } catch is PetOverlayPackFailure { checks += 1 }
    }
    print("PASS: \(checks) production Swift policy/pack/frame assertions; no AVKit/device claims")
  }
}
