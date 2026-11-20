# N5 — Banked-income design note: per-Brainrot accrual vs player-level share

**Status: DESIGN NOTE ONLY — current behaviour is UNCHANGED. No economy
code or amount was modified. Nothing in this note takes effect without
explicit user approval.**

## 1. What the live code actually does (verified in source)

### The live income tick is player-level only

- `src/server/Services/BaseService.luau:1644-1645` (inside `BaseService.Init`'s
  passive income tick): every `Config.IncomeTickSeconds` (1s) it computes
  `rate = BaseService.GetIncomePerSec(player)` and banks it into the
  **player-level** field:
  `data.BankedIncome = math.min(banked + rate * dt, bankedCapFor(player))`.
- `BaseService.GetIncomePerSec` (`BaseService.luau:546-583`) sums a
  per-Brainrot rate for each placed Brainrot (`singleIncome`, `:410` — level /
  glitched / mutation via `Economy.IncomePerSecond`), then applies
  **whole-base** multipliers (base IncomeMultiplier, tide, event, rebirth,
  synergy, companion income via EconomyService). The per-Brainrot rates are
  computed on the fly and **never stored per Brainrot**.
- Claiming is player-level too: `BaseService.CollectIncome` (`:1319-1324`)
  floors `data.BankedIncome`, zeroes it, and pays it via
  `DataService.AddCoins`. There is no per-Brainrot claim.
- The player-level field defaults to 0 in new data
  (`DataService.luau:58,121`); the tick's cap is progression-scaled
  (`bankedCapFor`, `BaseService.luau:491-497`).

### Per-placed `BankedIncome` is never accrued by any live code path

The only writes to a per-instance `BankedIncome` in live code are copies,
not accrual:

| Location | What it does |
|---|---|
| `RaidService.luau:1361` | Steal snapshot copies `placed.BankedIncome` from the victim's placed record (the value being stolen *from*). |
| `RaidService.luau:1096` (R1 delivery) | `owned.BankedIncome = banked - paidShare` — writes the **remainder** onto the thief's owned record after the immediate reward is paid. |
| `BaseService.luau:1173` (`PlaceBrainrot`) | Copies `owned.BankedIncome` into the new placed record. |
| `BaseService.luau:994,1291-1292` | Preserve / mirror the field when (re)building placed records — no accrual. |
| `RaidService.luau:369` | Return-to-victim restore copies the snapshot's `BankedIncome` back. |

**Consequence:** in live play today, a placed Brainrot's `BankedIncome` is
0 unless that instance previously went through an R1 delivery (delivery
remainder → place → placed copy). The steal snapshot therefore usually
carries `BankedIncome = 0`, and the "500 → 250/250" split exists today
only in test fixtures (e.g. the theft harness seeds `BankedIncome = 500`
on the victim's placed target).

### The steal reward formula (the thing both options must stay consistent with)

- `src/shared/Economy.luau:222-229` — `Economy.StealRewardShare(characterId, bankedIncome)`:
  `math.floor(banked * Config.StealRewardMultiplier)` (multiplier 0.5,
  `Config.luau:162`); 0 when the character is unknown.
- `Economy.luau:234-239` — `Economy.StealReward` = `StealRewardShare + def.IncomePerSec * 10`
  (flat rarity bonus on top of the halved banked share).
- `RaidService.ConfirmDelivery` (`RaidService.luau:1080-1096,1113`): floors the
  snapshot banked, pays `StealReward` in coins, and writes
  `banked - paidShare` onto the delivered owned record — so the thief can
  never collect the same banked income twice. Failed delivery writes nothing
  and pays nothing.

## 2. Option (A) — Accrue banked income separately per placed Brainrot

### How it would work mechanically

- The income tick (`BaseService.luau:1644-1645`) would stop banking one
  whole-base sum into `data.BankedIncome` and instead add each placed
  Brainrot's `singleIncome * dt` (before or after the whole-base
  multipliers — a decision in itself) into that placed record's
  `BankedIncome`, and into the matching owned record so the value survives
  store/return flows. `GetIncomePerSec` would stay as the *rate* display.
- `CollectIncome` would need a per-Brainrot claim path (collect one
  Brainrot, collect all) instead of the single player-level zero-and-pay.
  The banked cap would need a per-Brainrot equivalent (or the player-level
  cap would stop meaning anything).
- The steal path would finally have real data to work with: the snapshot
  at `RaidService.luau:1361` already reads `placed.BankedIncome`, and
  `ConfirmDelivery` already splits it via `StealRewardShare`. No steal
  formula change is needed — but the R1 remainder write (`:1096`) and the
  place-copy (`BaseService.luau:1173`) become load-bearing in live play
  rather than fixture-only.
- Display: `GetBase` (`BaseService.luau:603`) already surfaces
  per-placed `BankedIncome`, so the client could show per-Brainrot banks
  with no new snapshot field.

### Economic impact

- **Who gains:** thieves, directly. Today a steal's banked share is
  normally 0 (see §1); under (A) every placed Brainrot carries a real,
  growing bank, so `StealReward` pays its halved share plus the flat
  `IncomePerSec * 10` on essentially every successful steal. Stealing
  becomes the highest-yield income activity whenever a victim has been
  offline / uncollected for a while.
- **Who loses:** victims lose half the bank of exactly the Brainrot
  stolen (plus the Brainrot itself until/unless returned) — a much
  sharper, more legible loss than today's "your whole unclaimed bank is
  untouched by a steal". High-income Brainrots become priority targets.
- **Inflation:** mildly inflationary in aggregate — the same banked coins
  are now reachable through two paths (owner collects, or thief steals
  half + the remainder stays on the delivered copy and can later be
  collected by the thief). The `banked - paidShare` remainder prevents
  double-counting the *same* coins, but the flat `IncomePerSec * 10`
  bonus is new coins minted per steal, and its frequency rises with the
  number of steals.
- **Interaction with the 500 → 250/250 split:** the split becomes the
  normal case instead of a fixture-only case. `StealRewardShare` is
  already the single computation for both the payment and the remainder,
  so the split stays exact — but the *volume* through it grows
  enormously, and any rounding edge (flooring, unknown-character → share
  0 with full remainder retained) now matters in live play instead of
  only in tests.

### Risks

- **Per-Brainrot cap / overflow design is new work.** A player-level cap
  (`bankedCapFor`) no longer bounds anything if banks are per Brainrot;
  without a per-Brainrot cap, a Brainrot left placed for days accrues an
  unbounded steal target. With one, the cap value is a fresh balance call.
- **Multiplier attribution is ambiguous.** `GetIncomePerSec` applies
  whole-base multipliers (tide, event, synergy, companion) after summing
  per-Brainrot rates. Under (A) those multipliers must be either baked
  into each Brainrot's accrual (then a tide doubling mid-bank retroactively
  changes nothing banked before it — fine, but the code must attribute
  consistently) or applied at claim time (then the stored bank is a
  pre-multiplier base and the claim math must reproduce the multipliers
  that applied while it accrued — much harder to get exactly right).
- **More mutable state, more desync surface.** Every placed record now
  carries a ticking number that must stay in sync between `Base.Placed`
  and `OwnedInstances` across place / store / steal / return / delivery /
  save-load. The Phase 1 repairs (P0-3, P1-14/R1) were precisely about
  those two copies drifting; (A) adds a continuously-changing field to
  that same fragile mirror.
- **Exploit surface:** a thief who steals, gets the Brainrot returned
  (failed delivery), and re-steals could farm the flat `IncomePerSec * 10`
  bonus repeatedly if the bank is not consumed correctly on a failed
  steal — today the bank is 0 so the bonus is the only payout and the
  exposure is small; under (A) each cycle also re-exposes the (restored)
  bank. The return path restores the snapshot bank (`RaidService.luau:369`),
  which is correct for the victim but means the bank is stealable again
  immediately.

## 3. Option (B) — Take the configured share from player-level unclaimed `data.BankedIncome`

### How it would work mechanically

- The income tick and `CollectIncome` do not change at all: income keeps
  accruing into player-level `data.BankedIncome` exactly as today.
- Only the steal path changes: `StealBrainrot`'s snapshot
  (`RaidService.luau:1347-1361`) would take its `BankedIncome` from the
  **victim's player-level** `data.BankedIncome` (or a defined slice of
  it) instead of from `placed.BankedIncome`, and `ConfirmDelivery` would
  **deduct the paid share from the victim's `data.BankedIncome`** at
  delivery time (or at steal time — a timing decision: deduct at steal
  and refund on return, or deduct only on successful delivery).
- The remainder semantics need redefining: under (B) there is no
  per-Brainrot bank to hold a remainder, so the `owned.BankedIncome =
  banked - paidShare` write (`RaidService.luau:1096`) would either go
  away or be replaced by "the victim keeps the undeducted balance in
  `data.BankedIncome`". The 500 → 250/250 split becomes "victim's
  unclaimed bank drops by 250; thief is paid 250 (+ flat bonus); the
  other 250 stays in the victim's bank for them to collect".
- `StealReward` / `StealRewardShare` (`Economy.luau:222-239`) can stay
  byte-identical — they take a `bankedIncome` number and do not care
  where it came from. Only the caller passes a different number.

### Economic impact

- **Who gains:** thieves again, but from a *shared* pool: a steal pays
  half of the victim's whole unclaimed bank (if the share is taken from
  the full `data.BankedIncome`), regardless of which Brainrot was stolen.
  A victim with a large unclaimed bank is a lucrative target even if the
  stolen Brainrot itself is a low earner.
- **Who loses:** victims lose half their entire unclaimed bank on any
  successful steal — a much larger and less predictable loss than (A)'s
  per-Brainrot half. A victim who has not collected in a while can lose
  far more to one steal than the stolen Brainrot ever earned.
- **Inflation:** roughly neutral on the banked portion — the paid share
  is deducted from the victim's bank, so those coins move rather than
  duplicate (provided the deduction is implemented exactly once; see
  risks). The flat `IncomePerSec * 10` bonus is still newly minted per
  steal, same as today.
- **Interaction with the 500 → 250/250 split:** the split's *shape*
  survives (half paid, half retained) but its *meaning* changes: the
  retained 250 stays with the **victim**, not on the delivered copy.
  The R1 remainder write would be deleted, which simplifies the
  delivered-copy lifecycle — but it also removes the thief's ongoing
  claim on the stolen Brainrot's past earnings, which is arguably the
  point of stealing a high earner.

### Risks

- **The deduction must be exactly-once, across steal / return / delivery.**
  If the share is deducted at steal time, a failed steal (return) must
  refund it — the return path (`ReturnStolen`, `RaidService.luau:369`
  region) currently restores a per-Brainrot bank, and would need a
  matching player-level refund. If deducted only at delivery, the
  victim could collect their whole bank mid-theft (between steal and
  delivery) and the delivery-time deduction would then overdraw or
  silently pay from nothing. Either timing needs a hold / escrow on the
  victim's bank during transit, which is new state and a new failure mode.
- **Attribution / fairness problem.** The share is no longer tied to the
  stolen Brainrot: stealing a Common from a rich victim pays more than
  stealing a Secret from a poor one. That is a design decision, not a
  bug, but it changes what "steal the best Brainrot" means and will
  read as arbitrary to players unless the UI explains it.
- **A second thief / concurrent-collect race.** Two thieves stealing
  from the same victim, or a victim collecting while a theft is in
  transit, can both draw on the same `data.BankedIncome`. The current
  per-Brainrot snapshot is immune to this (each Brainrot's bank is
  disjoint); (B) needs locking or a transit hold on the victim's bank.
- **Cap interaction.** The banked cap (`bankedCapFor`) bounds what a
  victim can lose in one steal only indirectly; a capped bank is still
  a large single-steal payout, so steal profitability spikes at the cap.

## 4. Recommendation

**Neither option is recommended without further data — but if one must be
chosen, (A) is the better fit for this codebase, with a condition.**

Reasons:

1. **(A) is the architecture the steal path was already built for.**
   The snapshot (`RaidService.luau:1361`), the single share computation
   (`Economy.StealRewardShare`), the R1 remainder write (`:1096`), the
   place-copy (`BaseService.luau:1173`), and the return restore
   (`RaidService.luau:369`) all already assume a per-Brainrot bank. (A)
   makes those paths live instead of fixture-only; (B) rewrites their
   meaning and deletes the remainder write that R1 just fixed.
2. **(A) keeps theft losses attributable and bounded.** A victim loses
   half the bank of the Brainrot actually stolen — legible, predictable,
   and bounded by that Brainrot's earnings. (B) lets one steal take half
   of everything the victim has not collected, which is a far harsher
   and harder-to-explain loss, and it introduces a shared-pool race
   (victim collecting mid-theft, two thieves) that the current code has
   no mechanism for.
3. **(A)'s risks are implementation risks; (B)'s risks are design risks.**
   (A) needs a per-Brainrot cap decision, a multiplier-attribution
   decision, and care with the Placed/OwnedInstances mirror — all
   tractable engineering with tests (the Phase 1 suites already cover
   the mirror). (B) needs an escrow/hold on the victim's bank during
   transit and a fairness story for "steal a Common, take half a
   fortune" — those are product decisions, not code.

**Condition before implementing (A):** measure first. Today the steal
bank is 0 in live play, so nobody knows how often steals succeed, how
large unclaimed banks get, or what the flat `IncomePerSec * 10` bonus
already pays out. Before accruing per-Brainrot banks, collect: steal
success rate, median `data.BankedIncome` at steal time, and time since
last collect for victims. If steals are rare, (A) is a small, safe
improvement to theft rewards; if steals are frequent, (A) materially
raises thief income and the per-Brainrot cap + flat-bonus values should
be re-tuned first. Do not implement (A) on the fixture numbers alone —
the 500 → 250/250 split is a test value, not a balance target.

**Explicit restatement: current behaviour is UNCHANGED. The live tick
still banks into player-level `data.BankedIncome`; per-placed
`BankedIncome` still accrues nowhere; steal rewards still compute from
the (normally 0) placed bank. No code was changed for this note.**
