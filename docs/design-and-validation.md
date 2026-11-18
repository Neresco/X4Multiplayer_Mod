# In-game multiplayer design and validation

## Intended player experience

All player-facing multiplayer interaction belongs inside X4, including when a
graphical client hosts: server/address selection, requests, sync progress,
cancellation/errors/retry, player names and future host/admin controls. Background
transfer/network services may support the UI but must not impose a separate
launcher, picker, dashboard or terminal during ordinary play.

The host owns one engine-simulated universe and persistent outcomes. Joining
requests entry first, obtains server-owned authorization where required, syncs
a consistent compatible snapshot, validates/promotes it, loads it and only then
completes native readiness/admission. Workers never mutate game state; the actual
save load/native call happens on the UI lifecycle after the game validates its slot.

The companion native source documents the full
[decisions and tradeoffs](https://github.com/H3xx1st/X4Native_Linux/blob/codex/headless-host-and-join/docs/MULTIPLAYER_DESIGN.md),
[Docker environment/acquisition setup](https://github.com/H3xx1st/X4Native_Linux/blob/codex/headless-host-and-join/docs/HEADLESS_HOST.md)
and [evidence/remaining acceptance](https://github.com/H3xx1st/X4Native_Linux/blob/codex/headless-host-and-join/docs/VALIDATION.md).

## Implemented changes

- Shared Lua across the generic, Windows and Linux packages: saved server/manual
  address, local Player name, request/status and cancellation before loading.
- Reapply Host/Join entries on rebuild without duplicates and retain original
  Host handling. The legacy Join installer can arrive late; it now delegates to
  the controller instead of bypassing synchronization.
- Match response/request IDs, retire cancelled IDs, ignore stale/duplicate
  verification, refresh the save list and reject invalid/mismatched slots.
- Persist the display name in local UI data. Current JOIN tokens support 1-32
  ASCII letters/digits/underscore/hyphen. Names are not authenticated identity;
  changing/copying a name must not transfer ships, ownership or admin rights.
- Recognize native bridge capability and fail with an in-game error if missing.
  A new game process resets stale join intent; menu rebuilds retain its session.

## Evidence

The LuaJIT regression runs the real menu source with GUI/game boundaries stubbed.
It covers rebuild/idempotence, late legacy installation, request-before-sync,
stale/cancelled/duplicate replies, invalid saves, missing bridge and process reset.
The three platform source copies are byte-identical. Windows user acceptance
confirmed the picker opens, controls survive resizing, and verified snapshot sync/
load reaches the universe. Native Windows/Linux builds and coordinator integrity/
transport tests are covered in the companion contribution.

This did not establish a live connected world. An attempted authenticated forward
was denied by server policy, and a definitive readiness callback was lost during
UI re-discovery. A host-local transport probe received WELCOME, but that is not
client gameplay acceptance. No policy was weakened and no readiness timeout or
player-ID shortcut was used to turn the failure into a pass.

## Before release

Package and supervise the coordinator behind the in-game UI; deliver/replay real
second-pass readiness across rebuild; implement secure admission/identity/admin
queues and owner recovery; qualify cancel/disconnect, sector mappings and reconnect;
test interactive Linux behavior and host-owned gameplay/persistence outcomes.
Headless admin notifications/approvals belong in designated X4 clients while the
server retains role/decision authority. None of that is implemented by a cosmetic
admin field or a display name. Keep this contribution as a draft until dependencies
and real acceptance are complete.

AI assistance is being used for this work. We are keen to contribute further and
welcome review of the design, implementation and useful next development tasks.
