# Debt Ledger Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each player's addon keeps a per-character tab of who they owe and who owes them across real rounds, detects gold trades as payments, and lets players settle once at the end.

**Architecture:** A new engine module `Core/Ledger.lua` (pure logic over `ns.db.ledger[me]`, entries summed per person) is fed by `Jackpot.Record` for rounds and by a new `Core/Trade.lua` watcher for trades. Small addon messages (`K` compare, `G` notice, `A` ack) go through the existing `Comm`. A new `UI/LedgerView.lua` screen opens from a header button.

**Tech Stack:** WoW Lua 5.1 addon (Forever client, interface 16001), existing `ns.Comm`, `ns.Util`, `ns.Theme`/`ns.Widgets`; tests with `tests/run.lua` + fake client `tests/wow.lua`; luacheck.

**Spec:** `docs/superpowers/specs/2026-11-26-debt-ledger-design.md`

## Global Constraints

- All in-game UI text in English. Names always through `U.Canonical`; `U.Me()` is "me".
- Amounts stored in **copper** (`L.COPPER = 10000` per gold). Stakes/transfers in `round.result.transfers` are whole gold.
- Sign: `+` = that person owes me, `−` = I owe them. Balance = sum of that person's entries.
- Practice rounds never touch the ledger. Rounds from before this version are not imported.
- A debt may only disappear through an entry: no wipe, no history clear, no trim that changes a balance.
- Unilateral changes only **against** the clicker's own interest (creditor: RECEIVED/FORGIVE; debtor: ADD DEBT). No "adopt partner's figure".
- A trade counts only if it is gold-only (no items either side) and the partner is `L.Known` (has any ledger entry).
- New WoW API globals go into `.luacheckrc` `read_globals`; new engine files go into the TOC **before** `Games\Jackpot.lua` (the tests load Core and Games files in TOC order).
- **No Lua on this machine.** `lua5.1 tests/run.lua` and `luacheck GoblinCasino` run only in CI ("Lint and tests"). Per the user's rule, nothing is pushed to `dev` before the user has tested in game. Each "run" step below means: run it in CI when the branch is pushed (see handoff), and read the result through the GitHub API.
- Commit messages in English, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Same round finished twice after /reload** → exactly one ledger entry (dedupe by `round.id` in the ledger itself, not only Record's last-6 check). Test in Task 2.
2. **Trade cancelled, or one side never clicks Accept** → no entry on either side. Test in Task 5.
3. **Trade with items plus gold** (buying a potion) → no entry on either side. Test in Task 5.
4. **RECEIVED while the payer is offline or out of the group** → the notice waits in the outbox and is applied exactly once when both are grouped again, even if it arrives twice. Test in Task 4.
5. **Trimming a long history with one person** → the balance before and after is identical. Test in Task 2.

---

### Task 1: In-game probe of trade events (gate)

**Files:**
- Create: `GoblinCasino/Core/Trade.lua` (temporary probe; Task 5 replaces its body)
- Modify: `GoblinCasino/GoblinCasino.toc` (add `Core\Trade.lua` after `Core\Rolls.lua`)
- Modify: `.luacheckrc` (read_globals: `GetPlayerTradeMoney`, `GetTargetTradeMoney`, `GetTradePlayerItemInfo`, `GetTradeTargetItemInfo`, `InitiateTrade`, `SetTradeMoney`, `ERR_TRADE_COMPLETE`, `LE_GAME_ERR_TRADE_COMPLETE`)

**Interfaces:**
- Produces: a written finding (in the task report and as a comment at the top of `Core/Trade.lua`): which event sequence marks a completed trade on Forever, whether `TRADE_ACCEPT_UPDATE` reports `(1, 1)` before completion, whether `UI_INFO_MESSAGE` carries `ERR_TRADE_COMPLETE`, whether `SetTradeMoney(copper)` fills the money box.

- [ ] **Step 1: Write the probe.** A frame registering `TRADE_SHOW`, `TRADE_MONEY_CHANGED`, `TRADE_PLAYER_ITEM_CHANGED`, `TRADE_TARGET_ITEM_CHANGED`, `TRADE_ACCEPT_UPDATE`, `TRADE_REQUEST_CANCEL`, `TRADE_CLOSED`, `UI_INFO_MESSAGE`, `PLAYER_MONEY`. Each event goes to `ns.Log.Add("trade", ...)` with its args, plus `UnitName("NPC")`, `GetPlayerTradeMoney()`, `GetTargetTradeMoney()`, `GetMoney()`, all in `pcall`. On `TRADE_SHOW`, if `ns.Trade.probeMoney` is set, `pcall(SetTradeMoney, ns.Trade.probeMoney)` and log the result. Slash `/casino tradetest N` sets `probeMoney = N * 10000` (in `Core/Init.lua`).
- [ ] **Step 2: Commit locally** (`Trade probe: log trade events to /casino log`). Do not push.
- [ ] **Step 3: User check in game.** Ask the user to `/reload`, then: (a) `/casino tradetest 1`, trade 1g between two characters and both accept; (b) open a trade and cancel it; (c) a trade with an item and 1g. Then `/casino log` → copy, or read `WTF/Account/*/SavedVariables/GoblinCasino.lua` (it's written on `/reload`/logout).
- [ ] **Step 4: Record the finding** as the top comment of `Core/Trade.lua`. **If no event (and no `GetMoney` delta after `TRADE_CLOSED`) reliably marks completion, stop and bring it to the user** (spec: auto-detection is dropped, RECEIVED only).

### Task 2: Ledger module

**Files:**
- Create: `GoblinCasino/Core/Ledger.lua`
- Modify: `GoblinCasino/GoblinCasino.toc` (add `Core\Ledger.lua` after `Core\Rolls.lua`, before `Core\Trade.lua`)
- Modify: `GoblinCasino/Core/Init.lua` (`DEFAULTS.ledger = {}`)
- Test: `tests/test_ledger.lua` (single client, like `test_logic.lua`)

**Interfaces:**
- Produces (`ns.Ledger`, local `L`):
  - `L.COPPER = 10000`, `L.MAX_ENTRIES = 100` (per person; older ones fold into one `carry` entry)
  - `L.Book() -> { entries = { [who] = {entry...} }, rounds = { [roundId] = true }, outbox = {}, seen = { [noticeId] = true } }` for `U.Me()`, created in `ns.db.ledger[me]`
  - entry: `{ t = time(), kind = "round"|"trade"|"received"|"forgive"|"adjust"|"carry", amount = copper, id = ?, game = ?, gave = ?, got = ? }`
  - `L.Balance(who) -> copper`, `L.Known(who) -> bool`, `L.Entries(who) -> array` (oldest first), `L.People() -> array of names` (everyone known, sorted: I owe first, then owes me, then zero; ties by name)
  - `L.AddRound(round) -> changes|nil` where `changes = { { who = name, amount = copper }, ... }`; nil for practice, already-seen `round.id`, or me not in `round.result.transfers`
  - `L.AddTrade(who, gave, got)` (copper; entry `amount = gave - got`)
  - `L.Received(who, copper) -> ok, err` (only if `Balance(who) > 0`; entry `-copper`; queues notice, Task 4)
  - `L.Forgive(who, copper) -> ok, err` (allowed if `Balance(who) > 0` or `L.reported[who]` > 0; own entry `-min(copper, max(0, Balance(who)))` only if that's non-zero; queues notice)
  - `L.AddDebt(who, copper) -> ok, err` (debtor's self-adjust; entry `-copper`, kind `adjust`)
  - `L.reported = { [who] = copper }` (session only: what the partner's addon says, from my point of view; Task 4 fills it)
  - `L.OnChange(fn)`; every mutation calls listeners with `pcall` (same pattern as `J.OnChange`)
  - Amount validation: `copper` must be an integer ≥ 1 → else `false, "Enter an amount."`

- [ ] **Step 1: Write failing tests** in `tests/test_ledger.lua` (build `round` tables by hand: `{ id = "r1", game = "wheel", practice = nil, result = { transfers = { { from = "Bika", to = "Grom", amount = 30 } } } }`, client name `Bika`):
  - `"round: loser's tab shows the debt"`: `AddRound` → `eq(L.Balance("Grom"), -300000)`
  - `"round: winner's tab shows what's owed"`: transfer Grom→Bika 30 → `eq(L.Balance("Grom"), 300000)`
  - `"round: sapper loser owes everyone"`: transfers Bika→Grom 10, Bika→Zix 10 → `-100000` each
  - `"practice rounds don't count"`: `practice = true` → `eq(L.AddRound(r), nil)`, `eq(L.Known("Grom"), false)`
  - `"the same round counts once"`: `AddRound` twice → balance `-300000`; also after `c:Reload()` and a third `AddRound` with the same id
  - `"rounds I didn't play don't count"`: transfer Zix→Grom → `eq(L.Known("Grom"), false)`
  - `"trade pays a debt, overpay flips it"`: debt −30g, `AddTrade("Grom", 200000, 0)` → `-100000`; `AddTrade("Grom", 200000, 0)` → `100000`
  - `"received only by the one who's owed"`: Grom owes me 30g → `check(L.Received("Grom", 300000))` → `0`; I owe Grom → `eq(select(1, L.Received("Grom", 1)), false)`
  - `"forgive works on a reported debt"`: balance 0, `L.reported.Grom = 300000` → `check(L.Forgive("Grom", 300000))`, `eq(L.Balance("Grom"), 0)` (no own entry); without `reported` → false
  - `"add debt is against yourself"`: `L.AddDebt("Grom", 50000)` → `-50000`
  - `"trimming keeps the balance"`: 250 alternating rounds/trades with Grom, compare balance with the sum computed independently; `check(#L.Entries("Grom") <= L.MAX_ENTRIES + 1)`; first entry kind `carry`
  - `"bad amounts are refused"`: `Received("Grom", 0)`, `-5`, `1.5` → false
- [ ] **Step 2: Run** `lua5.1 tests/run.lua ledger` → FAIL (`ns.Ledger` is nil). (CI, see constraints.)
- [ ] **Step 3: Implement `Core/Ledger.lua`** per Interfaces. Trimming: when a person's entries exceed `MAX_ENTRIES`, replace the oldest `n - MAX_ENTRIES + 1` with one `{ kind = "carry", amount = sum, t = oldest.t }` at index 1. `rounds` set: drop ids older than 500 rounds is not needed (strings are small); keep it.
- [ ] **Step 4: Run** `lua5.1 tests/run.lua` → all PASS; `luacheck GoblinCasino` clean.
- [ ] **Step 5: Commit** `Ledger: a per-character tab of who owes whom`.

### Task 3: Rounds write to the tab; end-of-round messages

**Files:**
- Modify: `GoblinCasino/Games/Jackpot.lua` (`Record`, ~line 193; the DONE prints in `Finish`, ~lines 470–485)
- Test: `tests/test_multiplayer.lua`

**Interfaces:**
- Consumes: `L.AddRound(round) -> changes|nil`, `L.Balance(who)`
- Produces: `round.tab = changes` (set on the round so `Finish` can print from it)

- [ ] **Step 1: Write failing test** in `test_multiplayer.lua`, inside the `for _, game in ipairs(GAMES)` loop: `game .. ": after a real round the players' tabs mirror each other"` — play a round with `Group(3)` (helpers already in the file); for every pair `a, b`: `eq(a.ns.Ledger.Balance(b.name), -b.ns.Ledger.Balance(a.name))`; sum over everyone of all balances is 0; the payer `check(c:Printed("You owe"))` (existing check keeps passing). Practice test in the same loop: `eq(#c.ns.Ledger.People(), 0)`.
- [ ] **Step 2: Run** `lua5.1 tests/run.lua tabs` → FAIL.
- [ ] **Step 3: Call `L.AddRound(round)` in `Record`** after the duplicate check (before the history write) and store `round.tab`. In `Finish`'s DONE block, for non-practice rounds where I have `round.tab`, replace the current "You owe … Open a trade to pay." / "… owes you" lines with one line per change: payer: `"You owe <Short> <gold> (on your tab: you owe <Short> <total> in total)."`; receiver: `"<Short> owes you <gold> (on your tab: <total> in total)."` (use `U.Gold`; copper → gold by `/ L.COPPER`, show silver only when not whole: implementer's choice of a small `L.FormatCopper(copper)` helper). Keep the winner/loser announcement line as is.
- [ ] **Step 4: Run** `lua5.1 tests/run.lua` → PASS.
- [ ] **Step 5: Commit** `Ledger: every real round goes on the players' tabs`.

### Task 4: Notices and compare messages

**Files:**
- Modify: `GoblinCasino/Core/Ledger.lua`
- Test: `tests/test_multiplayer.lua`

**Interfaces:**
- Consumes: `Comm.Send(...)`, `Comm.On(kind, fn)` (sender arrives canonical), `U.InGroup(name)`
- Produces:
  - `L.Compare(who)`: sends `"K", who, L.Balance(who), "1"` when in a group and `L.Known(who)`
  - `L.mismatch = { [who] = { mine = copper, theirs = copper } }` (session only; `theirs` from my point of view)
  - message `K^to^balance^wantReply`: if `to == me`: `theirs = -balance`; `L.reported[sender] = theirs`; if `theirs ~= L.Balance(sender)` set `L.mismatch[sender]` and print `"<Short>'s addon says <their view>, yours says <your view>. Check the rounds on your tab."`; else clear `L.mismatch[sender]`; if `wantReply == "1"` reply with `wantReply "0"`. Notify listeners.
  - message `G^to^id^kind^copper` (kind `received`|`forgive`): if `to == me` and `book.seen[id]` is nil: add entry kind `kind`, `amount = +copper`, mark seen, print `"<Short> confirmed your payment of <gold>."` / `"<Short> forgave you <gold>."`; always answer `A^sender^id`.
  - message `A^to^id`: if `to == me`, remove the outbox item with that id.
  - Outbox item: `{ id = U.Me() .. GetServerTime() .. math.random(1000, 9999), to = who, kind = ..., amount = copper }`; sent immediately if `U.InGroup(to)`; resent for every waiting item whose `to` is in the group on `GROUP_ROSTER_UPDATE` and `PLAYER_ENTERING_WORLD` (Ledger registers its own event frame).

- [ ] **Step 1: Write failing tests** (2-client `Group(2)`, names Bika and Hymel; put one round's worth of debt on the tabs by calling `L.AddRound` on both clients with the same hand-made round):
  - `"received reaches the payer"`: Hymel owes Bika 30g; Bika `Received("Hymel", 300000)`; `w:Run(2)` → both balances 0; Bika's outbox empty
  - `"received waits until the payer is back in the group"`: `cs[2].inGroup = false; w:RosterChanged()`, Bika `Received`, `w:Run(2)` → Hymel still −30g; `cs[2].inGroup = true; w:RosterChanged(); w:Run(2)` → 0; deliver the same `G` twice (`w.drop` nil, call `L.ResendOutbox()` manually before the ack arrives) → still 0
  - `"forgive fixes a round only the debtor saw"`: only Hymel's client records the round (−30g); Hymel `L.Compare("Bika")`, `w:Run(2)` → Bika's `L.reported.Hymel == 300000`, both have `L.mismatch`; Bika `Forgive("Hymel", 300000)`, `w:Run(2)` → Hymel 0, Bika 0
  - `"matching tabs report no mismatch"`: both record the round, `Compare` → `eq(next(L.mismatch), nil)` on both
- [ ] **Step 2: Run** `lua5.1 tests/run.lua received` → FAIL.
- [ ] **Step 3: Implement** per Interfaces; `L.ResendOutbox()` public (used by the events and the test).
- [ ] **Step 4: Run** `lua5.1 tests/run.lua` → PASS.
- [ ] **Step 5: Commit** `Ledger: confirmations reach the payer, tabs are compared`.

### Task 5: Trade watcher

**Files:**
- Modify: `GoblinCasino/Core/Trade.lua` (replace the probe, keep the finding comment)
- Modify: `tests/wow.lua` (fake trade)
- Test: `tests/test_multiplayer.lua`

**Interfaces:**
- Consumes: `L.Known`, `L.AddTrade`, `L.Compare`, `L.Balance`; Task 1's finding.
- Produces:
  - `ns.Trade.payWho, ns.Trade.payCopper`: set by the UI's TRADE button (Task 6); on `TRADE_SHOW` with partner == `payWho`, `pcall(SetTradeMoney, payCopper)` (only if Task 1 found it works), then clear.
  - State per trade: `{ who, gave, got, items, accepted }`; `gave/got` refreshed from `GetPlayerTradeMoney()/GetTargetTradeMoney()` on every trade event; `items` = any non-nil name from `GetTradePlayerItemInfo(i)`/`GetTradeTargetItemInfo(i)` for `i = 1..7`; `accepted` from `TRADE_ACCEPT_UPDATE(1, 1)`.
  - On completion (the signal from Task 1; default assumption: `UI_INFO_MESSAGE` with `ERR_TRADE_COMPLETE`): if `not items and (gave + got) > 0 and L.Known(who)` → `L.AddTrade(who, gave, got)` and print `"Paid <Short> <gold>. <state>"` / `"<Short> paid you <gold>. <state>"` where state is `"You're even."`, `"You still owe <gold>."` or `"<Short> still owes you <gold>."`. Then clear the state. On `TRADE_SHOW` with a known partner: `L.Compare(who)`.
  - `tests/wow.lua`: `World:Trade(a, b, aGives, bGives, opts)` (copper; `opts.items`, `opts.cancel`): sets each client's trade view (`c.trade = { with = other, mine = ..., theirs = ..., items = ... }`), adds env functions `GetPlayerTradeMoney`, `GetTargetTradeMoney`, `GetTradePlayerItemInfo`, `GetTradeTargetItemInfo`, `SetTradeMoney` (records `c.tradeMoneySet`), `UnitName("NPC")` → partner name, globals `ERR_TRADE_COMPLETE = "Trade complete."`, `LE_GAME_ERR_TRADE_COMPLETE`, and fires on both clients the event sequence Task 1 recorded (cancel: `TRADE_SHOW`, `TRADE_REQUEST_CANCEL`/`TRADE_CLOSED` without completion).

- [ ] **Step 1: Write failing tests** (`Group(2)`, a round puts Hymel −30g / Bika +30g):
  - `"trade pays the tab on both sides"`: `w:Trade(cs[2], cs[1], 300000, 0)`; `w:Run(1)` → both balances 0; Hymel `Printed("Paid Bika")`
  - `"part payment"`: 100000 → Hymel −200000, Bika +200000
  - `"a cancelled trade changes nothing"`: `{ cancel = true }` → −300000 / +300000
  - `"a trade with items changes nothing"`: `{ items = true }` → unchanged
  - `"gold to a stranger isn't on the tab"`: add a third client never in a round; trade 1g → `eq(L.Known(...), false)` on both
  - `"trade from the TRADE button fills in the gold"` (only if Task 1 confirmed `SetTradeMoney`): `ns.Trade.payWho = "Bika"; payCopper = 300000`, `w:Trade(...)` → `eq(cs[2].tradeMoneySet, 300000)`
- [ ] **Step 2: Run** `lua5.1 tests/run.lua trade` → FAIL.
- [ ] **Step 3: Implement** `Core/Trade.lua` per Interfaces; every API call in `pcall`.
- [ ] **Step 4: Run** `lua5.1 tests/run.lua` → PASS; luacheck clean.
- [ ] **Step 5: Commit** `Ledger: a gold trade pays the tab`.

### Task 6: The TAB screen

**Files:**
- Create: `GoblinCasino/UI/LedgerView.lua` (pattern: `UI/HistoryView.lua`, `ns.Widgets.List`)
- Modify: `GoblinCasino/UI/MainFrame.lua` (header button left of HISTORY at line ~218, `f.views.ledger`, `OnRoundOpened` doesn't pull away from `"ledger"` either: line ~654)
- Modify: `GoblinCasino/GoblinCasino.toc` (`UI\LedgerView.lua` after `UI\HistoryView.lua`)
- Modify: `.luacheckrc` if new globals

**Interfaces:**
- Consumes: `L.People`, `L.Balance`, `L.Entries`, `L.Received`, `L.Forgive`, `L.AddDebt`, `L.mismatch`, `L.reported`, `L.OnChange`, `ns.Trade.payWho/payCopper`, `ns.Widgets.UnitFor(name)`, `ns.Widgets.AmountBox`
- Produces: `ns.LedgerView.Create(parent, width, height)` returning a frame with `:Refresh()`

- [ ] **Step 1: Build the view.** Header button `"TAB"` (84×36, `T.DarkButton`), its label turning red while I owe anyone and green while only owed. Left list: one row per `L.People()` entry: name, `"you owe"`/`"owes you"`/`"even"`, amount (red/green/dim). Right: selected person's entries newest first (time `%H:%M` or `%d.%m %H:%M`, kind text `"Ogre's Wheel"`-style game title via `J.games[e.game].title` / `"Trade"` / `"Received"` / `"Forgiven"` / `"Added by you"` / `"Earlier"`, signed amount), a mismatch line when `L.mismatch[who]`, an amount box (gold, default = the whole debt) and buttons: `TRADE` (always; sets `ns.Trade.payWho/payCopper` when I owe, then `InitiateTrade(unit)`; no unit → print `"<Short> isn't in your group or nearby."`), `RECEIVED` (when `Balance > 0`), `FORGIVE` (when `Balance > 0` or `L.reported[who] > 0`), `ADD DEBT` (when `L.mismatch[who]` and their figure says I owe more). Errors from L calls → `ns.Print(err)`. Refresh on `L.OnChange` while visible.
- [ ] **Step 2: Commit** `Ledger: the TAB screen`.
- [ ] **Step 3: User check in game** (`/reload`): one real round in a party of two, TAB shows mirrored amounts on both; TRADE fills the gold (if supported); after the trade both show even and the entry "Trade"; RECEIVED/FORGIVE on a second round; cancelled trade and item trade change nothing. After the user confirms: push `dev`, read the CI result (luacheck + tests), fix anything red.
