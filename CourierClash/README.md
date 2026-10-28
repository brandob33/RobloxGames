# Steal the Package

(Code folder and module names still say `CourierClash`; only the player-facing name changed.)

Two teams, one package. Grab the package from the center of the field, carry
it into your team's drop zone to score, and tackle whoever is carrying it
for the other team. First team to 3 deliveries (or the most when the 3-minute
clock runs out) wins the round. Empty slots are filled with bots so it plays
fine with one person; real players always take priority, and
`FILL_WITH_BOTS = false` in Config turns bots off entirely.

| | |
| --- | --- |
| Teams | **Ember** (orange, west end) vs **Tide** (blue, east end), 10 couriers each |
| Pick up | Walk into the package. You get a 1 s speed burst and 2 s where you can't be tackled (force-field bubble), then carriers run slower (14 vs 18 studs/s) and can't sprint or slide |
| Sprint | Hold `Shift` (gamepad `L2`, touch: Sprint button toggles). 27 studs/s. Uses stamina. Not while carrying |
| Slide | `C` or `Ctrl` (gamepad `B`, touch: Slide button). A quick, flat, feet-first slide; tackles miss you mid-slide. Free, just a 1.6 s cooldown (shown on the HUD) |
| Juke | The slide key while carrying: a quick dash the way you're steering, 2.2 s cooldown. No tackle immunity, so time it |
| Score | Carry it into your own glowing drop zone |
| Tackle | `F`, gamepad `R1`, or the on-screen button. A committed, aimed dive: it only lands if your body reaches the carrier during the lunge. Miss and you're on the ground for 1 s. 2.5 s cooldown. Knocks the package loose and stuns the carrier for 1.25 s |
| Kickoff | At the start and after every delivery, everyone goes back to their spawn box behind a force-field gate for an 8 s countdown |
| Round | Lobby (20 s, set `LOBBY_SECONDS = 60` for release) → 3 min round (first to 3) → 8 s results → lobby |

All numbers live in [`src/shared/Config.luau`](src/shared/Config.luau).

## Coins and the shop

You earn coins for playing: 25 per delivery, 10 per landed tackle, 50 for a
round win and 15 for every round you finish. Coins, trails and upgrades are
saved between sessions. Open the shop with the **SHOP** button or **M**.
Buying works between games (lobby, results); equipping works anytime.

- **Trails** are cosmetic only.
- **Upgrades** are small and capped (3 levels each): Stamina Reserve
  (+5 max stamina per level) and Quick Breath (+8% stamina regen per
  level). They can only be bought with coins earned in-game.
- **Coin packs** (Robux) are optional. Create a Developer Product for each
  pack (Creator Dashboard → your experience → Monetization → Developer
  Products) and paste its ID into `COIN_PACKS` in
  [`src/shared/ShopCatalog.luau`](src/shared/ShopCatalog.luau). Packs with
  ID `0` are hidden.

Prices and items live in `ShopCatalog.luau`.

To test saving in Studio, publish the place and turn on **Game Settings →
Security → Enable Studio Access to API Services**. Without it, Studio gives
you a temporary profile and says coins won't be saved.

## Run it in Roblox Studio

1. Install the toolchain once with [Rokit](https://github.com/rojo-rbx/rokit):
   `rokit install` (in this folder). That gives you Rojo, Wally, Selene and StyLua.
2. Install the Rojo Studio plugin: `rojo plugin install`.
3. In Studio, create a new **Baseplate** place.
4. In this folder, run `rojo serve`. In Studio open the Rojo plugin and press **Connect**.
5. Press **Play**. The server builds the arena, teams and bots on startup;
   you don't need to place anything by hand.

To produce a place file instead: `rojo build -o CourierClash.rbxl`.

Set **Game Settings → Avatar → Avatar Type to R15**. Everyone gets the same
blocky body and default animations (players keep their own head, face and
clothes), so hitboxes are fair and the slide and dive poses look right.

When you publish, set **Max Players to 20** (Game Settings → Places → or the
place's Configure page) so both teams can be full of people; bots fill
whatever's left.

### Studio-only QA keys

While playtesting in Studio, hold **Shift** and press **1** (Ember +1),
**2** (Tide +1), **3** (end the round) or **4** (take the package). These do nothing in a published game (the
server only listens for them when `RunService:IsStudio()`).

## Structure

```text
src/
├── shared/                 → ReplicatedStorage.Shared
│   ├── Types.luau            payload + state types
│   ├── Config.luau           every tunable number
│   ├── Remotes.luau          the one list of remotes
│   ├── ShopCatalog.luau      trails, upgrades, coin packs and prices
│   └── Util/
│       ├── Signal.luau
│       ├── MatchLogic.luau   pure rules (teams, bots, winner)
│       └── MatchLogic.spec.luau
├── server/                 → ServerScriptService.Server
│   ├── init.server.luau      two-phase bootstrap
│   ├── Net.luau              creates remotes
│   ├── Util/RateLimit.luau
│   └── Systems/
│       ├── Arena.luau        builds the field, spawn boxes, gates, lobby
│       ├── Agents.luau       players + bots as one "Agent" type, teams, speed
│       ├── Parcel.luau       pickup, carry, tackle, delivery
│       ├── Movement.luau     server-side speed/teleport check for players
│       ├── Sprint.luau       stamina, sprint and slide rules
│       ├── Match.luau        round loop, scores, state broadcast
│       ├── Bots.luau         bot fill + AI
│       ├── Avatars.luau      same blocky R15 body for everyone
│       ├── PlayerData.luau   saved coins/items (DataStore, session lock)
│       ├── Shop.luau         coin rewards, shop purchases, Robux receipts
│       └── Cheats.luau       Studio-only QA
└── client/                 → StarterPlayerScripts.Client
    ├── init.client.luau
    ├── Net.luau
    └── Controllers/
        ├── HudController.luau     score bar, timer, banners, tackle button
        ├── TackleController.luau  input + cooldown
        ├── MovementController.luau sprint/slide/dive input, prediction, FOV
        ├── PoseController.luau    slide and dive body poses
        ├── ShopController.luau    coin counter + shop screen
        └── DevKeys.luau           Studio-only QA keys
```

## Security model

- The server decides pickups, tackles and deliveries from positions it sees;
  the client never reports them.
- The only gameplay remote, `Tackle`, takes no arguments. The server picks
  the target (the enemy carrier), checks range and cooldown, and rate-limits
  the remote.
- Players simulate their own characters, so a client can ignore WalkSpeed or
  teleport. `Movement.luau` checks every player's distance over a rolling
  1-second window against the speed they're allowed (carrying, stunned or
  running). A violation drops the package at the last plausible spot and
  blocks that player's pickups and tackles for 2 seconds, so speed and
  teleport hacks can't steal or run the package home.
- Sprint and slide are requested, not declared: the server owns stamina and
  cooldowns (`Sprint.luau`) and the Movement check uses the same speed limit,
  so a client can't sprint forever or slide off cooldown.
- Bots are simulated by the server (network owner `nil`).

## Checks

- Format: `stylua src`
- Lint: `selene src`
- Tests: `MatchLogic.spec.luau` is a [TestEZ](https://github.com/Roblox/testez)
  spec. Uncomment TestEZ in `wally.toml`, run `wally install`, then serve the
  test project (`rojo serve test.project.json`, which also maps
  `DevPackages`) and run this in the Studio command bar during Play:
  `require(game.ReplicatedStorage.DevPackages.TestEZ).TestBootstrap:run({ game.ReplicatedStorage.Shared.Util })`

## Not in this version

- No sounds or custom art. Everything
  is built from plain parts so there are no asset IDs to upload yet.
- Bots steer straight at their target and jump or sidestep when stuck;
  no pathfinding.
