#include "../../../app/ohos/entry/src/main/cpp/lifecycle_state.h"
#include <cassert>
#include <cstdio>
static int64_t now=1000;
static int64_t clock_now() noexcept { return now; }
int main(){
 dsh::LifecycleState state(clock_now);DshHostLifecycleSnapshotV1 s{};
 assert(state.Snapshot(nullptr,sizeof(s))==-1);assert(state.Snapshot(&s,1)==-1);
 state.BeginEngine();auto a=state.BeginOwner(true);assert(a);
 assert(state.BeginGrant(a)==0);assert(state.Foreground(a,false));auto g=state.BeginGrant(a);assert(g);
 now+=500;assert(state.Activate(a,g,10000));state.Snapshot(&s,sizeof(s));assert(s.deadline_ms==11000&&s.drain_at_ms==5000&&s.phase==dsh::LifecycleState::Granted);
 assert(!state.Activate(a,g,180000));state.Snapshot(&s,sizeof(s));assert(s.deadline_ms==11000);
 assert(state.Foreground(a,false));state.Snapshot(&s,sizeof(s));assert(s.deadline_ms==11000&&s.phase==dsh::LifecycleState::Granted);
 assert(state.Drain(a,g));
 now=5000;state.Snapshot(&s,sizeof(s));assert(s.phase==dsh::LifecycleState::Draining);
 now=11000;state.Snapshot(&s,sizeof(s));assert(s.phase==dsh::LifecycleState::Expired);
 assert(state.Retire(a));state.Snapshot(&s,sizeof(s));assert(!s.available);
 auto b=state.BeginOwner(true);assert(b!=a);assert(!state.Retire(a));state.Snapshot(&s,sizeof(s));assert(s.available&&s.foreground);
 assert(state.Foreground(b,false));g=state.BeginGrant(b);assert(g);assert(state.Retire(b));assert(!state.Activate(b,g,180000));
 auto c=state.BeginOwner(false);g=state.BeginGrant(c);assert(g);now+=180000;assert(!state.Activate(c,g,180000));
 assert(state.Release(c,g));assert(state.Foreground(c,false));g=state.BeginGrant(c);assert(g);assert(!state.Activate(c,g,180001));assert(!state.Activate(c,g,0));
 state.Stop();assert(!state.Activate(c,g,10000));state.Snapshot(&s,sizeof(s));assert(!s.available);
 dsh::LifecycleState rollback(clock_now);rollback.BeginEngine();auto d=rollback.BeginOwner(false);g=rollback.BeginGrant(d);assert(g);now--;assert(!rollback.Activate(d,g,10000));rollback.Snapshot(&s,sizeof(s));assert(!s.available&&s.clock_failed);
 dsh::LifecycleState broken(clock_now);broken.BeginEngine();broken.BeginOwner(true);now=-1;broken.Snapshot(&s,sizeof(s));assert(!s.available&&s.clock_failed);
 now=9007199254740000LL;dsh::LifecycleState overflow(clock_now);overflow.BeginEngine();auto e=overflow.BeginOwner(false);g=overflow.BeginGrant(e);assert(g);assert(!overflow.Activate(e,g,180000));overflow.Snapshot(&s,sizeof(s));assert(s.clock_failed&&!s.available);
 puts("PASS native state: size, owner, fixed pre-API deadline, duplicate/late activation, drain/expire, retire, old owner, stop, invalid duration, rollback and clock failure");
}
