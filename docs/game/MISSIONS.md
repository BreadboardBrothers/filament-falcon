# Missions page (Commander screen)

**Commander → MISSIONS** is the first tab. It lists every mission, spacewalk and destination, grouped as Training, Orbit, EVA, Landing, Earth and Fun/Calm.

Select one to see:
- its patch and a diagram;
- the objective, crew roles, difficulty and duration;
- what the Commander can inject;
- the Commander buttons for that mission (these appear once it is loaded).

**START** loads the mission and starts it. The overhead checklist still applies where the mission needs it. Pressing START while a different mission is running asks for a second press.

The kids get a big **card** on the touchscreen with a few huge buttons. Everything else uses the stick, the throttle and a few switches. Dad sets the difficulty on TRAINING (easy / normal / hard) or uses the mission's Commander buttons.

| Mission | What happens |
|---|---|
| REAL ISS | The station sits where the real ISS is right now, on its 51.6° orbit plane. Run `./run.sh` to refresh the TLE from CelesTrak twice a day; if that fails, it uses the last file or the built-in elements. Rendezvous from 420 m, then dock. |
| CITY LIGHTS | Night flight to Fredericton. SCANNER PING finds HOME (set `home_lat` and `home_lon` in the `[game]` section of `falcon_settings.cfg`), then circle and wave. Uses the OSM region and the night lights from `tools/fetch_assets.sh`. |
| HOUSTON, A PROBLEM | A chain of Apollo-style faults: 2, 3 or 4 by difficulty. Each fault gets a checklist card. The Commander can fire the next one with NEXT PROBLEM NOW. |
| SPLASHDOWN | Plasma, radio blackout, then DROGUE and MAIN CHUTES card buttons, then a splash. The rumble is camera and sound only, because the seat motion is hardwired. |
| CATCH THE SPACEWALKER | Stop the spin, open the cargo doors and put the arm out. Then the CANADARM RESCUE spacewalk runs, in VR or on screen. |
| PLANT THE FLAG | The Moon landing, then the MOONWALK spacewalk: flag and rocks. |
| CAPTAIN'S LOG | RECORD / STOP. The intercom helper mixes the headset voices into `~/.local/share/filament-falcon/captains_log/*.wav`, saved with the last mission's patch and score. Play them back from the MISSIONS page. |
| ALIEN SIGNAL | SCANNER PING plays a pattern. Copy it with the shape buttons, plus real panel switches on normal and hard. Then fly to the probe. |
| GROUND CREW | A 4th person opens `http://<pc-ip>:8088` on a phone on the same Wi-Fi and acts as Mission Control: GO, messages, faults, PHOTO RECEIVED. Anyone on the home network can press the buttons. |
| FLIGHT 15 | Starship Flight 15 from Starbase, TX: light the engines, then watch the fully automatic flight — booster boostback, low fuel mass abort and Gulf FTS, 26 Starlink V3 through the PEZ door, entry, flip and the first ship Mechazilla catch. Optional Starbase area pack from Commander → AREAS. Details in [FLIGHT15.md](FLIGHT15.md). |
| BEDTIME CRUISE | Night side of Earth, a lullaby, a dimmed cabin, no failures, two gentle taps. |

The EVA entries fly their usual host mission, and the spacewalk is woven in at the end. SPACEWALK NOW starts it right away when the ship is somewhere it is allowed.

**Tests:**
- `-- --smoke-test`: starts and completes every mission, and checks the phone web page.
- `-- --ui-fit`: checks every page and every MISSIONS entry at 1920×1080 and 1280×720.
- `-- --iss`: prints where the ISS is now.
- `-- --flight15-test`: Flight 15 profile (launch input only, then unattended).
