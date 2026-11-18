# Flight 15 — first Starship tower catch

Commander → MISSIONS → **FLIGHT 15** (Landing). A crewed-cockpit telling of SpaceX
Starship Flight 15 (13–14 November 2026): tower launch from Starbase, Texas, 26
Starlink V3 satellites through the PEZ door, then the first ship catch at Mechazilla
on Pad 2. After you light the engines, the flight flies itself so everyone can watch.

## How to fly it

1. `./run.sh` from the repo (the launcher auto-pulls). Open **FLIGHT 15** and press START
   after the overhead checklist and harnesses.
2. **Pilot (launch only):** ENGINE ARM, IGNITION and full throttle at T−5. If the engines
   are not ready the clock holds, just like First Light.
3. After liftoff, sticks and triggers no longer fly the ship. You can still look around
   and switch **VIEW** (cockpit / chase). The chase view follows the action: staging,
   the booster’s divert and destruct, PEZ deploy, plasma, the flip and the catch.
4. Terrain pack: the next normal `./run.sh` (not `--offline` / `--no-install`) queues the
   **Starbase TX** area in the background and starts the game immediately. Open
   Commander → **AREAS**: you should see **Starbase TX** (`starbase`) go from queued to
   running (dem / imagery / osm / build, progress and MB downloaded), then pack ✓ when
   it is ready. This happens once; if you delete the area later it will not be re-added.
   The mission works without the pack (global Earth + the procedural Starbase). Headless
   tests and the agent box never download it.

## What Flight 15 really did

Sources:

- [SpaceX — Starship Flight 15](https://www.spacex.com/launches/starship-flight-15/)
- [Wikipedia — Starship flight 15](https://en.wikipedia.org/wiki/Starship_flight_15)
- [Space.com — booster abort / low fuel mass alarm](https://www.space.com/space-exploration/launches-spacecraft/spacex-says-starship-flight-15-booster-aborted-chopsticks-landing-catch-after-launch-due-to-guidance-issue-video)
- [Aviation Week — first ship tower catch](https://aviationweek.com/space/operations-safety/starship-flight-15-ends-first-ship-tower-catch)
- [Spaceflight Now — live coverage](https://spaceflightnow.com/2026/11/13/live-coverage-starship-flight-15-attempts-to-recover-full-vehicle-in-double-launch-pad-catch/)
- [Aerospace America — reentry path](https://aerospaceamerica.aiaa.org/spacex-achieves-first-starship-tower-catch/)

| | Real Flight 15 |
|---|---|
| Launch | 13 Nov 2026, 22:47:36 UTC (16:47:36 CST) from **Starbase OLP-2** |
| Vehicles | Super Heavy **Booster 22** (Block 3), **Ship 42** (Block 3) |
| Orbit | ~276 × 278 km, **30.5°** inclination (LEO); ~14 orbits, **22 h 32 m 32 s** |
| Payload | **26 Starlink V3** (Starlink Group 31-2), including 3 with cameras, through the PEZ bay. Deploy start T+35:01, complete T+1:17:40 |
| Booster | Planned tower catch. Boostback lit **32 of 33** engines, then **ended early due to a low fuel mass alarm**. GNC **aborted the catch** during coast (it “detected that the booster was not in the place that it was supposed to be to proceed with a catch”) and diverted to an **offshore landing location** in the **Gulf of Mexico**. Landing burn, engines cut off **while hovering over the Gulf**, then the **flight termination system** triggered. Destroyed a few feet above the water, ~6.5 min after liftoff. Not a catch, not over land. |
| Ship | Deorbit with a single sea-level Raptor (~10 s) at T+21:35:57. Entry T+22:10:46. Path: Pacific, across Baja / northern Mexico, **north of South Padre Island**, a **swoosh out over the Gulf**, then the pad. Landing burn T+22:32:16, flip T+22:32:18, 3→2 engines T+22:32:26, 2→1 T+22:32:33, catch T+22:32:34. First ship tower catch, fittings just below the forward flaps. |
| Ascent times | Liftoff, Max Q T+00:58, MECO T+02:19, hot-staging T+02:21, boostback T+02:26–03:02, ship cutoff T+08:09, insertion burn T+26:10–26:30 |

Kate Tice (14 Nov webcast): “Early indications are that the booster ended its boostback [burn] early due to a low fuel mass alarm.” Dan Huot later clarified that GNC itself was not at fault; it did its job by aborting an out-of-box catch.

## Real vs modeled

| Topic | In this mission |
|---|---|
| Crewed cockpit | **Modeled / requested.** Real Flight 15 was uncrewed. This is the one deliberate change Yves asked for. |
| Launch site, tower launch, hot staging | Real (OLP-2 / Pad 2, 25.99677 N, 97.15799 W). |
| Ascent azimuth ~107.5° | **Approximated** from the published Gulf / Yucatán hazard corridor, not official telemetry. |
| Orbit 30.5°, ~277 km, 26 V3 sats, PEZ deploy | Real counts and orbit class. Deploy spacing is **compressed** (~2 s apart in play, ~98 s on the real flight) so you can watch it. |
| 20+ hour coast | **Time-compressed** (auto warp / skip) with short return-check callouts. The kids do not wait 22 hours. |
| Booster low fuel mass alarm, GNC abort, offshore FTS | **Real sequence and wording.** Commander warnings use the public phrases (low fuel mass alarm; not in position for a catch; divert to the offshore landing location; landing-burn shutdown then FTS). |
| Exact FTS coordinates | **Modeled.** SpaceX did not publish a lat/lon. The designated spot used here is **26.02 N, 96.82 W**, about 34 km east of OLP-2 over the Gulf, away from the beach, South Padre and Brownsville. |
| Ship return path | **Modeled from public descriptions** (Pacific → Baja / northern Mexico → north of South Padre → Gulf swoosh → Pad 2). Not official telemetry. The “exact path” claim is only as good as those reports. Entry is **time-compressed** versus the real ~22 minutes from entry to catch. Final approach stays over the Gulf, not over the towns. |
| Flip and 3→2→1 landing burn, chopstick catch | Real sequence; timing is shortened to stay watchable. |
| Starbase buildings | **Recognisable procedural** set (two towers, tank farm, high bays, Starfactory / HQ, Highway 4, beach), not photoreal. Sharper ground needs the optional Starbase area pack. |
| Auto-flight after launch | **Game design** (Yves: a fully automated flight except for the launch). |

## Tests

```bash
XDG_DATA_HOME=$(mktemp -d) godot --headless --path game --audio-driver Dummy -- --flight15-test
```

The test lights the engines with the launch controls only, then sends no further flight input
and checks: event order, the real booster error and a Gulf water FTS away from shore and
towns, 26 PEZ deploys, flaps and plasma, flip, and a ship catch near the tower.

Headless tests do not prove the look of the plasma or the explosion on Yves’s Vulkan GPU.
