# RemoteXPC object and HTTP/2 resource budgets (ADD08)

This increment extends the control-message limits in
`README-REMOTEXPC-BOUNDS.md`. It keeps the idevice commit, archive checksum,
dependency versions and lock unchanged. All upstream edits remain in
`idevice-rsd-xctest.patch`; run `prepare_upstream.py` to reconstruct the source.

## Object parsing and plist conversion

Each `XPCObject::decode` and `to_plist` operation has its own cumulative budget:

| Resource | Limit |
| --- | --- |
| Object depth, root counted as 1 | 64 |
| Objects, including containers and Null values | 65,536 |
| String, dictionary key and Data bytes | 16 MiB |

The same counter follows sibling branches. Container declarations are checked
before iteration, and do not cause a capacity reservation for untrusted counts.
String terminators, padding and remaining input are checked before copying.
The earlier 16 MiB wire-body limit and String/Data remaining-length checks stay
in effect.

`XPCObject::to_plist` now returns `Result<plist::Value, IdeviceError>`. Both pinned
RemoteXPC call sites propagate that result. Conversion also limits objects
constructed by program code, including dictionary keys; UUID text and the keys
and scalar generated for a FileTransfer dictionary consume the output budget.
Every error from `recv`, `recv_root` or `recv_any` clears the partial control
buffers and closes the owned HTTP/2 transport.

## HTTP/2 buffering and flow control

| Resource | Limit |
| --- | --- |
| Inbound frame payload | 16 KiB |
| Raw frame reassembly buffer | 32,777 bytes |
| Queued DATA per stream | 1 MiB |
| Queued DATA across all streams | 4 MiB |
| Tracked streams | 128 |
| Queued DATA frames per stream / total | 1,024 / 4,096 |
| Pending serialized output | One frame, at most 16 KiB + 9 bytes |

DATA accounting includes its pad-length byte and padding, and excludes the
nine-byte frame header. The frame length is rejected from the header before
waiting for its body. The 16 KiB frame limit matches the HTTP/2 default: this
client does not advertise a larger SETTINGS_MAX_FRAME_SIZE. Empty DATA still
consumes a queued-frame slot.

Connection and stream receive windows start separately at 65,535 bytes. The
existing RemoteXPC handshake still raises the stream initial window to 1 MiB
with SETTINGS and raises the connection window to 1 MiB with a separate
WINDOW_UPDATE. Arrival debits both windows. An unconsumed stream receives no
replacement credit merely because DATA was enqueued.

Removing DATA from the queue accumulates credit for the next operation. There
is no await between popping the payload and returning it to the caller. Credit
is moved into a single persistent output frame, whose write offset survives a
cancelled future. Local granted credit increases only after that whole frame
has been written. Retrying a partial write or a pending flush neither duplicates
WINDOW_UPDATE nor adds its credit twice. ACK, HEADERS and DATA use the same
pending-frame writer so subsequent output cannot split an unfinished frame.

The peer's send-window changes are also checked for 31-bit overflow. A legal
SETTINGS shrink can make a send window negative; empty DATA/END_STREAM still
costs no flow-control credit. Protocol/resource errors close the owned transport
immediately, clear local queues and leave the client in a sticky failed state.
They do not retry or act on another native owner.

## Stream lifecycle and practical limits

END_STREAM marks the remote half closed. Queued final DATA remains readable;
new DATA and further stream credit are disallowed. Once both halves have ended
and queued DATA is consumed, the stream entry is removed. The existing expected
RST for a completed outbound file stream removes its entry and returns only
connection credit for discarded queued bytes. Other active resets remain fatal.

Two parity-specific watermarks retain closed-ID information without an expanding
tombstone set. Existing lower-numbered streams remain live; retired IDs cannot
be recreated. Late WINDOW_UPDATE/RST for retired streams is ignored. Half-closed
or unread streams remain subject to the same caps. There is no timer-based
assumption that the peer has acknowledged closure, and no invented idle expiry.

These are local operational limits, not measured Apple protocol maxima or an
exact RSS ceiling. Vector/map spare capacity, object overhead, input and output
coexisting, caller-held data and lower-layer transport buffers have additional
cost. A peer that fills an unconsumed stream can stall at its window until the
caller consumes it or an existing outer deadline ends the operation. Legitimate
traffic exceeding a cap fails instead of growing memory. Device compatibility
at the chosen limits, Apple builds and real-device behavior remain **UNRUN**.

This change does not add general HTTP/2 support beyond the pinned RemoteXPC
frame/setting subset. It does not change the file-transfer wrapper arithmetic,
trusted outbound XPC encoder or `From<plist::Value>` recursion, and makes no
claim about caller-created arbitrarily deep values being safe to drop. The new
recursive fixtures stop at depth 65. No old crash, deep-stack, ASan or high-fd
probe is used.

## Pure synthetic verification

```sh
cargo test --locked --offline --lib xpc_resource_tests -- --test-threads=1
```

The test-only library module includes the exact reconstructed HTTP/2 and budget
files, while decoder/receive tests call the actual idevice dependency. Fixtures
cover depth 64/65, shared object/byte budgets, generated plist values, frame and
metadata caps, padding, independent windows, consumption-based credit, partial
write/flush cancellation, stream retirement and sticky transport failure. A
multi-frame control message also crosses the initial receive window and checks
returned credit before a plist-conversion budget error. All bytes use memory
transports; no socket, server, model, user record or device is used.

Protocol reference: [RFC 9113](https://www.rfc-editor.org/rfc/rfc9113.html),
sections 4.1–4.2, 5.1–5.2, 6.1 and 6.9. The resource cap values and failure policy
above are project choices.
