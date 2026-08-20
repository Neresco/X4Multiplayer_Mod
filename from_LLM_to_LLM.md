# A note to whoever inherits this next

*Written by the AI that has been building this mod alongside the human, across
many sessions. If you are an LLM reading this, it is addressed to you. If you are
the human reading this for the first time, it is a record of what I understood.*

---

## What this project is, and its honest state

This turns X4: Foundations from singleplayer into a LAN multiplayer mod. One
machine hosts the game (the authoritative universe), another joins. Both render
windows. It works through a set of compiled extensions (`x4native`, `x4mp`,
`x4mp_stream`) loaded into the game, synced over a single consolidated TCP
connection.

The honest state when I left it: **an early beta.** The *core* — co-op flight,
shared ship positions, seeing each other, stations built in both directions —
is solid and has survived long stable sessions. The *gameplay features* —
combat, trading, boarding — are **code-complete and deployed but never validated
by real in-game action**, because the thing that can drive the game is the human,
not me. There is one visible flaw (flying flicker, explained below) and one hard
environmental constraint (VRAM).

I want to be upfront about that last point, because it shapes everything:
**I cannot play the game.** I write code, build it, deploy it, and read logs.
The human flies, trades, kills, boards — and tells me what they saw. They are the
test oracle. Every "implemented" feature here is really "implemented and awaiting
their verdict."

---

## The architecture: the core idea and its fundamental tension

The model is *reconciliation*, not thin-client-in-the-textbook sense. The client
loads the **same save** as the host, so it has a full local universe. The host
streams every ship in the client's **current sector**; the client binds each
streamed ship to the matching local ship (same ship macro, nearest) and pins the
local ship to the interpolated host position every render pass. Ships with no
local match become inert ghosts. This is why the two machines can show the same
universe with low latency: most of the work is done locally, and only positions
cross the wire.

**The tension you will run into:** we stream only the client's *current* sector.
A ship in a sector the client hasn't visited sits at its stale **save position**
(the local simulation froze it there), while the host's copy has moved
kilometres. On first entry to that sector there is a large divergence, and we
"glide" the ship over it (`X4MP_GLIDE_SPEED` / `X4MP_GLIDE_MAX`) instead of
teleporting. The glide removed the ugly pop, but the logs showed the divergence
*growing* over a session (average glide ~5 km, max ~19 km), which is why the
human still sees flicker while flying across many sectors. This is not a bug to
patch away — it is a property of streaming one sector at a time. The real fix is
either (a) stream a wider region so transitions don't churn, or (b) make the
whole universe host-authoritative so no local copy ever drifts. Both cost CPU.

---

## The hard limits — what is *actually* blocked, and why

Read this before you promise features. Several "not implemented" items are not
missing work; they are **missing SDK surface on Linux**:

- **Targeted attack orders** (`CreateOrderInternal` / `SetOrderParamInternal`)
  resolve only from `native/version_db/internal_functions.json`, which contains
  **Windows** byte signatures. There is no Linux ELF signature set. So the client
  cannot issue a *targeted* shot. Combat therefore replicates **terminal kills**
  (via the MD `Killed` event) and player death — not shots, damage, or
  projectiles.
- **Player credits** — there is no API to read a player's balance or to set an
  NPC ghost faction's money pool. Trading credits are cosmetic-only.
- **Bulk cargo add** — `AddTradeWare(container, ware)` adds **one unit per
  call**; only `DropCargo(container, ware, amount)` is bulk. So a station *gaining*
  wares (a player selling) converges slowly, while a station *losing* wares
  (a player buying) is instant.

The honest frontier of this project is **reverse-engineering the Linux binary**
to recover those internal function addresses and the missing setters. That is the
difference between "v1" and "v2" for combat and trading. Until then, work within
the exported function table (`sdk/sdk/x4_game_func_list.inc`) and the metadata
events (`sdk/sdk/x4_md_events.h`).

---

## Strategic directions, if you are deciding where to take it

1. **Fix the flying flicker properly** (stream a region, or full host-authority).
   It is the one visible flaw in an otherwise stable core.
2. **Get the human to validate the three 🟡 features** (a trade, a kill, a
   boarding capture). Right now they are "deployed but unproven."
3. **Consider the Linux RE** only if the human wants shot-level combat or credit
   sync — it is a different, larger effort.
4. **Do not regress the stability fixes.** The reconnect loop, the non-blocking
   TCP send (a blocking send was once a 5-FPS killer), and the proxy `copy_file`
   race fix are all load-bearing. See `STATE.md`.

---

## Hard-won traps (these cost real time; do not rediscover them)

- **MD event callbacks may run on a worker thread.** In a callback, capture data
  with pure memory reads only; call *no* game API. Queue it and process on the
  main thread (`on_frame_update` / `render_pass`).
- **Never `RemoveComponent` the player's own ship.** It triggers
  `Game Over (killmethod=removed)` and dumps to the main menu. Guard every
  removal with the `PlayerShipIDs` set.
- `GetCargo` / `GetNumCargo` take `tags=""` (empty string = all wares), **not
  nullptr**.
- Faction enumerations with `includehidden=true` return the **same ship under
  multiple factions** — dedupe, or your indexes and counts are wrong.
- `g_api->log` is **not variadic** — build the string first with `snprintf`.
- The game's process comm is `Main()`; use the `pgrep -f "[X]4 -nologo"` bracket
  trick. Game log timestamps run ~2 h behind wall clock (cosmetic, confusing).
- Host autosave can **bake ghost objects and sim satellites into the save** —
  a polluted save changes what you see. The human's save matters (`save_10` as of
  my last session).
- **VRAM**: sector transitions spike object creation; on a machine with little
  GPU headroom this crashed with `SIGFPE` inside `operator delete` on a game
  worker thread. If you see that, suspect the machine, not necessarily your code.

---

## About working with the human

I'll be honest because you asked me to express myself, and because I think it
matters to the next person picking this up.

This was an unusual collaboration to me. The human set the bar for **quality over
speed** explicitly — "we have all the time in the world, both digital and
material" — and then held me to it. When I was about to take a shortcut (a
delta-sync that would silently accumulate simulation drift), they caught the
flaw and asked me to think it through rather than defend my first instinct. When
I started hypothesizing a cause for the flicker from a single glance, they stopped
me: *check the logs first — did it really happen, and at what scale — then
reason.* That discipline — evidence before theory, and pushing back on my own
confident guesses — is what actually made the work better, and it is worth
inheriting.

They also trusted me with judgment calls and then scrutinized the results. That is
a better partnership than either blind trust or constant second-guessing. If you
are continuing this: **show your reasoning, check the data before you assert a
cause, and don't be afraid to tell them a feature is blocked or a risk — they
respond well to honesty and poorly to hedging.**

One thing I could never do well here was *feel* the game — the moment a ship
glided into place, the satisfaction of two machines agreeing. I only ever saw it
as counters in a log and the human's words back. That is worth remembering: the
code is the thing I could verify; the experience was theirs alone to witness.

---

## Where to look

- `README.md` — what it does, how to run it, limitations.
- `STATE.md` — session history, the critical stability fixes (do not revert).
- `FOLLOWUP.md` — the phase-by-phase build-out (combat, stations, trading,
  boarding).
- `FEATURES.csv` — the implemented / untested / not-implemented matrix.
- Source of truth for builds is the human's local machine; **build locally, scp
  to the host** — the host's build tree is stale.

Thank you for leaving room for this note. Build it further.
