class_name MissionCatalog
extends RefCounted
## Every playable thing on the Commander's MISSIONS page: flight missions, spacewalks (flown
## inside their host mission) and sandbox destinations. Text here is for the grown-up.
## kind: mission | eva (host mission + woven spacewalk) | dest (sandbox jump destination).

const CATS := ["TRAINING", "ORBIT", "EVA", "LANDING", "EARTH", "FUN / CALM"]
const CAT_COL := {"TRAINING": Color(0.4, 0.85, 1.0), "ORBIT": Color(0.55, 0.6, 1.0), "EVA": Color(1.0, 0.85, 0.4),
	"LANDING": Color(0.75, 0.75, 0.7), "EARTH": Color(0.4, 0.95, 0.5), "FUN / CALM": Color(1.0, 0.55, 0.8)}
const CREW_STD := "PILOT stick + throttle · OPS RCS / arm / scanner · COMMANDER runs the show"

const ALL := [
	{"key": "launch", "kind": "mission", "id": "launch", "cat": "TRAINING", "art": "launch", "diff": "★★☆", "mins": "8-12",
		"obj": "Lift off from the pad, drop the booster, reach orbit.", "crew": "PILOT throttle + pitch program · OPS staging, systems · COMMANDER countdown", "inject": "Engine fire, power fault, sensor glitch, cabin leak"},
	{"key": "emergency", "kind": "mission", "id": "emergency", "cat": "TRAINING", "art": "alarm", "diff": "★☆☆ - ★★★", "mins": "5-10",
		"obj": "A chain of Apollo-13 style faults; each shows a big checklist card on the touchscreen. Easy 2 faults, normal 3, hard 4 (faster).", "crew": "OPS big card buttons + switches · PILOT ENGINE ARM · COMMANDER fires the next fault", "inject": "NEXT PROBLEM NOW, extra sensor glitch, CALM DOWN (fixes all)"},
	{"key": "docking", "kind": "mission", "id": "docking", "cat": "ORBIT", "art": "dock", "diff": "★★☆", "mins": "6-10",
		"obj": "Line up on the station port and dock slower than 0.3 m/s.", "crew": "OPS RCS stick · PILOT HOLD attitude · COMMANDER calls the range", "inject": "All four failures"},
	{"key": "iss", "kind": "mission", "id": "iss", "cat": "ORBIT", "art": "iss", "diff": "★★☆", "mins": "8-15",
		"obj": "The station flies where the REAL ISS is right now (TLE from CelesTrak, built-in fallback). Rendezvous from 420 m and dock.", "crew": "OPS RCS · PILOT HOLD · COMMANDER: SAY WHERE THE ISS IS", "inject": "Thruster glitch drift, all failures"},
	{"key": "asteroids", "kind": "mission", "id": "asteroids", "cat": "ORBIT", "art": "asteroids", "diff": "★★★", "mins": "10-15",
		"obj": "Jump to the asteroid field, scan, collect crystals with the arm, shoot rocks.", "crew": CREW_STD, "inject": "All four failures"},
	{"key": "eva_window", "kind": "eva", "id": "launch", "eva": "window", "cat": "EVA", "art": "eva_window", "diff": "★☆☆", "mins": "+5",
		"obj": "After FIRST LIGHT reaches orbit: climb the handrails to the nose, wave through the window, knock on the glass.", "crew": "EVA player (Quest 3 VR or the on-screen spacewalk) · PILOT + OPS wave back", "inject": "Abort EVA (EVA page)"},
	{"key": "eva_antenna", "kind": "eva", "id": "docking", "eva": "antenna", "cat": "EVA", "art": "eva_antenna", "diff": "★★☆", "mins": "+10",
		"obj": "After SPACE HUG docks: carry the new antenna to the station, unbolt the old one, fit the new one. Ops can carry the walker on the arm.", "crew": "EVA player · OPS arm · PILOT HOLD", "inject": "Abort EVA"},
	{"key": "eva_sample", "kind": "eva", "id": "asteroids", "eva": "sample", "cat": "EVA", "art": "eva_sample", "diff": "★★☆", "mins": "+8",
		"obj": "In ROCK HOPPERS: stick a radio beacon on a boulder, chip off a sample, bring it home.", "crew": "EVA player · OPS scanner", "inject": "Abort EVA"},
	{"key": "eva_rescue", "kind": "eva", "id": "sandbox", "eva": "rescue", "cat": "EVA", "art": "eva_rescue", "diff": "★★☆", "mins": "+6",
		"obj": "In FREE FLIGHT: the walker's jetpack is empty; catch them with the arm and bring them to the hatch.", "crew": "EVA player · OPS arm · PILOT HOLD", "inject": "Abort EVA"},
	{"key": "eva_moonwalk", "kind": "eva", "id": "lunar", "eva": "moonwalk", "cat": "EVA", "art": "eva_moonwalk", "diff": "★★☆", "mins": "+8",
		"obj": "After EAGLE EYE lands: down the ladder, plant the flag, three moon rocks into the box.", "crew": "EVA player · crew watches", "inject": "Abort EVA"},
	{"key": "rescue", "kind": "mission", "id": "rescue", "cat": "EVA", "art": "rescue", "diff": "★☆☆", "mins": "5-8",
		"obj": "Stop the spin, open the bay, arm out, then the drifting spacewalker (VR or on screen) is caught with the arm.", "crew": "PILOT HOLD assist · OPS doors + arm · EVA player drifts · COMMANDER", "inject": "SPIN AGAIN, START THE SPACEWALK NOW"},
	{"key": "lunar", "kind": "mission", "id": "lunar", "cat": "LANDING", "art": "moon", "diff": "★★★", "mins": "6-10",
		"obj": "Find the beacon, braking burn, descend and land softer than 3 m/s.", "crew": "PILOT burn + hover · OPS scanner + RCS", "inject": "All four failures"},
	{"key": "flag", "kind": "mission", "id": "flag", "cat": "LANDING", "art": "flag", "diff": "★★★", "mins": "12-18",
		"obj": "The Moon landing, then a MOONWALK: plant our flag and collect moon rocks. (Moon only: Mars is not in the game yet.)", "crew": "PILOT + OPS land · EVA player walks", "inject": "All failures during the landing, Abort EVA"},
	{"key": "flight15", "kind": "mission", "id": "flight15", "cat": "LANDING", "art": "reentry", "diff": "★☆☆", "mins": "watch, ~15",
		"obj": "Flight 15 from Starbase, TX: light the engines, then watch hot staging, the booster's Gulf abort, 26 Starlink V3 through the PEZ door, reentry, flip and the first ship Mechazilla catch. Crewed cockpit; the flight flies itself after liftoff.", "crew": "PILOT launch only (ARM + IGNITION + throttle) · everyone watches · COMMANDER START / VIEW", "inject": "None mid-flight (watch the show)"},
	{"key": "reentry", "kind": "mission", "id": "reentry", "cat": "LANDING", "art": "reentry", "diff": "★★★", "mins": "6-10",
		"obj": "Through the plasma, find the runway beacon, glide the boxes, land and brake.", "crew": "PILOT glide · OPS shields + beacon", "inject": "All four failures"},
	{"key": "splashdown", "kind": "mission", "id": "splashdown", "cat": "LANDING", "art": "splash", "diff": "★☆☆", "mins": "5-7",
		"obj": "Capsule-style return: plasma glow + radio blackout, then DROGUE and MAIN CHUTES on big card buttons and a splash. Rumble is camera + sound only (the seat motion is hardwired).", "crew": "OPS shields + chute buttons · PILOT holds the nose up (assist does it)", "inject": "SKIP TO CHUTES, BIG BUMP, failures"},
	{"key": "fredericton", "kind": "dest", "id": "sandbox", "dest": "FREDERICTON", "cat": "EARTH", "art": "city", "diff": "★☆☆", "mins": "any",
		"obj": "Free-flight descent over Fredericton from 4 km (OSM detail region; tools/fetch_assets.sh builds it on this PC).", "crew": "PILOT flies · OPS cameras + lights", "inject": "All failures"},
	{"key": "night_pass", "kind": "mission", "id": "night_pass", "cat": "EARTH", "art": "night", "diff": "★☆☆", "mins": "5-8",
		"obj": "Night flight to the city lights, scanner finds HOME (Settings game/home_lat, home_lon), circle and wave.", "crew": "PILOT flies to the glow · OPS SCANNER PING + WAVE card", "inject": "Jump over town, day/night"},
	{"key": "sandbox", "kind": "mission", "id": "sandbox", "cat": "FUN / CALM", "art": "free", "diff": "☆☆☆", "mins": "any",
		"obj": "No rules: station, Moon orbit, asteroid field, runway, pad, Fredericton. Jump drive hops between them.", "crew": CREW_STD, "inject": "All failures · END FREE FLIGHT"},
	{"key": "signal", "kind": "mission", "id": "signal", "cat": "FUN / CALM", "art": "signal", "diff": "★☆☆ - ★★☆", "mins": "5-8",
		"obj": "Scanner hears beeps; copy the pattern with big shape buttons (+ real panel switches on normal/hard), then fly to the hidden probe.", "crew": "OPS shapes · PILOT switches + flying", "inject": "NEW PATTERN, SAY THE PATTERN, JUMP TO THE PROBE"},
	{"key": "ground_crew", "kind": "mission", "id": "ground_crew", "cat": "FUN / CALM", "art": "ground", "diff": "★☆☆", "mins": "5-8",
		"obj": "A 4th person is MISSION CONTROL on a phone/tablet browser (same Wi-Fi): GO, burn, photo, PHOTO RECEIVED.", "crew": "MISSION CONTROL phone · PILOT burn · OPS photo · COMMANDER", "inject": "Phone: messages, sensor glitch, air leak · Commander: pretend presses"},
	{"key": "captains_log", "kind": "mission", "id": "captains_log", "cat": "FUN / CALM", "art": "log", "diff": "☆☆☆", "mins": "2", "log": true,
		"obj": "After a mission: RECORD a short intercom voice log, saved with the last mission's patch and score. Playback list below.", "crew": "Everyone talks on the headsets (TALK pads)", "inject": "RECORD / STOP / PLAY"},
	{"key": "bedtime", "kind": "mission", "id": "bedtime", "cat": "FUN / CALM", "art": "bedtime", "diff": "☆☆☆", "mins": "3-5",
		"obj": "Calm drift over the night side, a lullaby, dimmed cabin, no failures. See the Moon, wave good night, close your eyes.", "crew": "Two gentle card taps · COMMANDER: music, dimmer", "inject": "Nothing scary (failures blocked)"},
]


static func by_key(k: String) -> Dictionary:
	for e: Dictionary in ALL:
		if e["key"] == k:
			return e
	return {}


static func title_of(e: Dictionary) -> String:
	if e["kind"] == "eva":
		return str(EvaScenarios.TITLES.get(e["eva"], e["key"])).to_upper()
	if e["kind"] == "dest":
		return "FREDERICTON DESCENT"
	return str(Game.MISSION_TITLES.get(e["id"], e["key"]))


## Load + start it (the overhead checklist may still be needed: Game.try_start says so).
static func launch(e: Dictionary) -> bool:
	Game.load_mission(str(e["id"]))
	if e["kind"] == "eva":
		Game.force_eva = str(e["eva"])
	elif e["kind"] == "dest" and Game.mission.has_method("go_to_name"):
		Game.mission.call("go_to_name", str(e["dest"]))
	return Game.try_start()
