class_name WorldView
extends Node3D
## Renders the universe around the Falcon with a floating origin: the ship's centre is
## always (0,0,0) and everything else is placed at its BigVec offset each frame. Inertial
## axes are kept, so the star sky never moves.

var env: Environment
var sky_mat: ShaderMaterial
var sun: DirectionalLight3D
var earthshine: DirectionalLight3D
var ship: ShipModel
var earth_node: Node3D
var earth_mat: ShaderMaterial
var cloud_mat: ShaderMaterial
var atmo_mat: ShaderMaterial
var moon_node: Node3D
var moon_mat: ShaderMaterial
var earth_lod: PlanetLOD
var moon_lod: PlanetLOD
var moon_scale := 1.0
var _pack_tex := {}            # area pack id -> Texture2D (Sentinel-2 imagery)
var _pack_loading := {}
var _pack_tasks: Array[int] = []
var ent_nodes := {}            # entity id -> Node3D
var tunnel: MeshInstance3D
var tunnel_mat: ShaderMaterial
var fx_nodes: Array = []       # [{node, pos: BigVec, t}]
var rig_xform := Transform3D.IDENTITY
var day_factor := 0.0
var in_shadow := false
var _t := 0.0
var _blinkers: Array = []
var _last_mission_obj: Object = null

const EYE := Vector3(0, 1.05, -5.3)
## Cameras use far = 1e6 m (larger ratios break Godot's frustum culling). Bodies whose visible
## disc would reach past that are drawn in "scaled space": shrunk about the camera by s and
## moved to s * distance, which keeps exactly the same angular size and shading.
## The VR client lowers these (XR combined-frustum culling breaks at huge far/near ratios).
var FAR_SAFE := 9.0e5
var ATMO_PROXY_R := 8.0e5
var atmo_node: MeshInstance3D
var earth_scale := 1.0
var eva_view: EvaView
var region: RegionView


func _ready() -> void:
	add_to_group("world")
	_build_environment()
	_build_bodies()
	_apply_nasa_textures()
	_scan_regions()
	_set_region(_fixed_region_dir())
	ship = ShipModel.new()
	ship.name = "Falcon"
	add_child(ship)
	# The Falcon's own model lives on render layer 11 so the cockpit windows can hide it
	# (the eye point sits inside the hull); chase / console cameras still see it.
	get_tree().node_added.connect(func(n: Node) -> void:
		if ship and ship.is_ancestor_of(n):
			_tag_one(n))
	_tag_ship.call_deferred(ship)
	# the spacewalk (rails, props, astronaut) is NOT under the ship so the windows still see it
	eva_view = EvaView.new()
	add_child(eva_view)
	tunnel_mat = ProcGen.shader_mat("res://shaders/glow_fx.gdshader", {"color": Color(0.45, 0.35, 1.0), "mode": 3, "intensity": 0.0})
	tunnel = ProcGen.mesh_node(ProcGen.cyl(40.0, 40.0, 6000.0, 48), tunnel_mat)
	tunnel.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	tunnel.visible = false
	add_child(tunnel)
	Game.mission_loaded.connect(_on_mission_loaded)
	Game.game_event.connect(_on_game_event)
	Settings.changed.connect(func(_s: String) -> void: apply_quality())
	_on_mission_loaded()
	apply_quality()


const SHIP_LAYER := 1 << 10


func _tag_one(n: Node) -> void:
	# hull meshes only: effects you should see out of the window (plume, laser, beam,
	# plasma sheath), lights and particles stay on the default layer
	if n is MeshInstance3D and (ship.plume == null or not ship.plume.is_ancestor_of(n)) and n != ship.laser and n != ship.beam and n != ship.plasma:
		(n as MeshInstance3D).layers = SHIP_LAYER


func _tag_ship(n: Node) -> void:
	_tag_one(n)
	for c in n.get_children():
		_tag_ship(c)


func _build_environment() -> void:
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = load("res://shaders/space_sky.gdshader")
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	sky.process_mode = Sky.PROCESS_MODE_REALTIME
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.05, 0.06, 0.08)
	env.ambient_light_energy = 1.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.0
	env.tonemap_white = 6.0
	env.glow_enabled = true
	env.glow_intensity = 0.7
	env.glow_bloom = 0.06
	env.glow_hdr_threshold = 1.1
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.set_glow_level(0, 0.0)
	env.set_glow_level(2, 1.0)
	env.set_glow_level(4, 0.8)
	env.set_glow_level(6, 0.5)
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.1
	env.adjustment_contrast = 1.05
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.light_energy = 2.2
	sun.light_color = Color(1.0, 0.97, 0.92)
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 900.0
	sun.shadow_bias = 0.05
	sun.shadow_blur = 1.5
	add_child(sun)
	earthshine = DirectionalLight3D.new()
	earthshine.light_energy = 0.0
	earthshine.light_color = Color(0.45, 0.6, 1.0)
	earthshine.shadow_enabled = false
	earthshine.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	add_child(earthshine)


func _quality_segments() -> int:
	return [192, 320, 448, 640][Settings.quality_index()]


func _build_bodies() -> void:
	var e: CelestialBody = Game.earth
	earth_node = Node3D.new()
	earth_node.name = "Earth"
	add_child(earth_node)
	var seg := _quality_segments()
	var air := {"planet_r_km": e.radius / 1000.0, "atmo_r_km": e.radius / 1000.0 + 90.0}
	earth_mat = ProcGen.shader_mat("res://shaders/planet.gdshader", {"site_a": Game.pad_dir, "site_b": Game.runway_dir, "lod": true}.merged(air))
	# Real-size ground: cube-sphere quadtree LOD (same heights as the physics), camera-relative
	earth_lod = PlanetLOD.new()
	earth_lod.name = "EarthLOD"
	add_child(earth_lod)
	earth_lod.setup(e, earth_mat, earth_sample, 15 if Settings.quality_index() >= 1 else 14)
	cloud_mat = ProcGen.shader_mat("res://shaders/clouds.gdshader", {"site_a": Game.pad_dir, "site_b": Game.runway_dir}.merged(air))
	var cl := ProcGen.mesh_node(ProcGen.sphere(e.radius + 4500.0, seg, seg / 2), cloud_mat)
	cl.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cl.extra_cull_margin = 16384.0
	earth_node.add_child(cl)
	atmo_mat = ProcGen.shader_mat("res://shaders/atmosphere.gdshader", {"planet_r_km": e.radius / 1000.0, "atmo_r_km": e.radius / 1000.0 + 90.0})
	# The atmosphere is ray-marched analytically, so its proxy mesh is just a big sphere around
	# the camera (inside the far plane); the planet centre comes in as a uniform.
	atmo_node = ProcGen.mesh_node(ProcGen.sphere(1.0, 48, 24), atmo_mat)
	atmo_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	atmo_node.extra_cull_margin = 16384.0
	atmo_node.scale = Vector3.ONE * ATMO_PROXY_R
	add_child(atmo_node)
	var m: CelestialBody = Game.moon
	moon_node = Node3D.new()
	moon_node.name = "Moon"
	add_child(moon_node)
	moon_mat = ProcGen.shader_mat("res://shaders/moon.gdshader", {"site_dir": Game.lunar_site_dir, "lod": true})
	moon_lod = PlanetLOD.new()
	moon_lod.name = "MoonLOD"
	add_child(moon_lod)
	moon_lod.setup(m, moon_mat, func(d: Vector3) -> Vector3: return Vector3(m.natural_height(d, true), 0.0, 0.0), 13)


## Height / water / area-pack coverage for the Earth LOD chunks (worker threads): the detail
## region when one covers the point, else the real-Earth terrain (packs, global DEM).
static func earth_sample(d: Vector3) -> Vector3:
	var e: CelestialBody = Game.earth
	var r := Vector3(e.natural_height(d, true), 0.0, 0.0) if e.terrain == null else e.terrain.sample(d)
	if e.render_hook.is_valid():
		var rh: float = e.render_hook.call(d)
		if not is_nan(rh):
			r.x = rh
	return r


## NASA textures from the asset cache (tools/fetch_assets.sh); the procedural shaders stay as
## the fallback when they're missing (offline / not fetched yet).
func _apply_nasa_textures() -> void:
	var month := clampi(int(Settings.get_v("graphics", "earth_month")), 1, 12)
	var day := Geo.tex("earth_day_%02d.jpg" % month)
	if day == null:
		day = Geo.tex("earth_day_07.jpg")
	var night := Geo.tex("earth_night.jpg")
	var clouds := Geo.tex("earth_clouds.jpg")
	var height := Geo.tex("earth_height.png")
	var gfg := Geo.game_from_geo().inverse()
	if day and night and clouds and height:
		for mt: ShaderMaterial in [earth_mat, cloud_mat]:
			mt.set_shader_parameter("use_tex", true)
			mt.set_shader_parameter("geo_from_game", gfg)
			mt.set_shader_parameter("cloud_tex", clouds)
		earth_mat.set_shader_parameter("day_tex", day)
		earth_mat.set_shader_parameter("night_tex", night)
		earth_mat.set_shader_parameter("height_tex", height)
		print("Earth: NASA textures (month %d)" % month)
	# HD set (16k Blue Marble, 8k night / clouds, DEM normal map + land mask) streams in on a
	# worker thread and replaces the 5400 px set when ready (cached compressed after 1st run).
	if FileAccess.file_exists(Geo.asset_dir() + "/earth_normal.png") or FileAccess.file_exists(Geo.asset_dir() + "/earth_day_%02d_hd.jpg" % month):
		var wr: WeakRef = weakref(self)
		# tracked so quitting waits for it (an untracked decode during engine teardown crashes)
		_pack_tasks.append(WorkerThreadPool.add_task(func() -> void:
			var t0 := Time.get_ticks_msec()
			var out := {}
			for spec: Array in [["day_tex", "earth_day_%02d_hd.jpg" % month, "color"], ["night_tex", "earth_night_hd.jpg", "color"],
					["cloud_tex", "earth_clouds_hd.png", "gray"], ["normal_tex", "earth_normal.png", "normal"], ["mask_tex", "earth_mask.png", "gray"]]:
				var img := Geo.hd_image(spec[1], spec[2])
				if img:
					out[spec[0]] = img
			out["_ms"] = Time.get_ticks_msec() - t0
			(func() -> void:
				var w: Object = wr.get_ref()
				if w:
					w.call("_apply_hd", out)).call_deferred(), false, "earth HD textures"))
	var mc := Geo.tex("moon_color.jpg")
	var mh := Geo.tex("moon_height.png")
	if mc and mh:
		moon_mat.set_shader_parameter("use_tex", true)
		moon_mat.set_shader_parameter("color_tex", mc)
		moon_mat.set_shader_parameter("height_tex", mh)
		print("Moon: LRO textures")


func _apply_hd(out: Dictionary) -> void:
	var names := []
	for k: String in out:
		if k.begins_with("_"):
			continue
		var t := ImageTexture.create_from_image(out[k])
		names.append(k.trim_suffix("_tex"))
		if k == "cloud_tex":
			cloud_mat.set_shader_parameter(k, t)
		earth_mat.set_shader_parameter(k, t)
	earth_mat.set_shader_parameter("use_normal", out.has("normal_tex") and out.has("mask_tex"))
	print("Earth: HD textures %s (%d ms, cache %s/tex)" % [str(names), int(out.get("_ms", 0)), Geo.cache_dir()])


func apply_quality() -> void:
	var q := Settings.quality_index()
	env.ssao_enabled = q >= 2
	env.ssil_enabled = q >= 3
	env.ssr_enabled = q >= 3
	env.glow_enabled = true
	sun.shadow_enabled = q >= 1
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS if q >= 2 else DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	atmo_mat.set_shader_parameter("steps", [8, 12, 16, 24][q])
	atmo_mat.set_shader_parameter("light_steps", [4, 5, 6, 8][q])
	earth_mat.set_shader_parameter("detail", 0.5 if q == 0 else 1.0)
	RenderingServer.directional_shadow_atlas_set_size([2048, 4096, 8192, 8192][q], true)


# ------------------------------------------------------------------ entities
func _on_mission_loaded() -> void:
	for id in ent_nodes:
		(ent_nodes[id] as Node).queue_free()
	ent_nodes.clear()
	for f in fx_nodes:
		(f["node"] as Node).queue_free()
	fx_nodes.clear()
	_sync_entities()


func _make_entity_node(e: Dictionary) -> Node3D:
	match e["kind"]:
		"station":
			return Models.station()
		"booster":
			return Models.booster()
		"satellite":
			return Models.satellite()
		"pod":
			return Models.pod()
		"crystal":
			return Models.crystal(false)
		"crystal_rock":
			return Models.crystal_rock()
		"pad":
			return Models.pad()
		"runway":
			return Models.runway()
		"lunar_pad":
			return Models.lunar_pad()
		"field":
			return _make_field(e)
	return Node3D.new()


func _make_field(e: Dictionary) -> Node3D:
	var root := Node3D.new()
	var pos: PackedVector3Array = e.get("rock_pos", PackedVector3Array())
	var rad: PackedFloat32Array = e.get("rock_r", PackedFloat32Array())
	var variants := 4
	var rmat := Models.rock_material()
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	for v in variants:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = ProcGen.rock_mesh(100 + v, 0.38)
		var idxs := []
		for i in pos.size():
			if i % variants == v:
				idxs.append(i)
		mm.instance_count = idxs.size()
		for k in idxs.size():
			var i: int = idxs[k]
			var b := Basis.from_euler(Vector3(rng.randf() * TAU, rng.randf() * TAU, rng.randf() * TAU)).scaled(Vector3.ONE * rad[i])
			mm.set_instance_transform(k, Transform3D(b, pos[i]))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = rmat
		root.add_child(mmi)
	# a little dust glitter
	return root


func _sync_entities() -> void:
	var live := {}
	for e in Game.entities:
		var id: String = e["id"]
		live[id] = true
		if not ent_nodes.has(id):
			var n := _make_entity_node(e)
			n.name = id
			add_child(n)
			ent_nodes[id] = n
	for id in ent_nodes.keys():
		if not live.has(id):
			(ent_nodes[id] as Node).queue_free()
			ent_nodes.erase(id)


func _on_game_event(kind: String, data: Dictionary) -> void:
	if kind == "explosion":
		_spawn_explosion(data["pos"], float(data.get("radius", 10.0)), data.get("color", Color(1, 0.6, 0.3)))
	elif kind == "staged":
		_spawn_explosion(Game.sim.pos.copy(), 8.0, Color(1, 0.8, 0.6))


func _spawn_explosion(p: BigVec, radius: float, c: Color) -> void:
	var em := GPUParticles3D.new()
	em.amount = 220
	em.lifetime = 2.5
	em.one_shot = true
	em.explosiveness = 0.95
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3.UP
	pm.spread = 180.0
	pm.initial_velocity_min = radius * 0.5
	pm.initial_velocity_max = radius * 2.0
	pm.gravity = Vector3.ZERO
	pm.scale_min = 0.3
	pm.scale_max = 1.5
	pm.color = c
	em.process_material = pm
	var sm := SphereMesh.new()
	sm.radius = 0.4
	sm.height = 0.8
	sm.radial_segments = 6
	sm.rings = 3
	sm.material = ProcGen.glow_mat(c, 5.0)
	em.draw_pass_1 = sm
	add_child(em)
	em.emitting = true
	fx_nodes.append({"node": em, "pos": p, "t": 0.0})


# ------------------------------------------------------------------ per frame
## Scaled-space factor for a body: 1 while everything up to its horizon (+20 km of mountains)
## fits inside the far plane, so near the ground nothing is scaled and terrain, pads, buildings
## and the ship share one true-size space; further out the body shrinks about the camera.
func scaled_factor(d: float, radius: float) -> float:
	var need := sqrt(maxf(d * d - radius * radius, 0.0)) + 20000.0
	return minf(1.0, FAR_SAFE / maxf(need, 1.0))


func _place_scaled(node: Node3D, rel: Vector3, radius: float) -> float:
	var s := scaled_factor(rel.length(), radius)
	node.position = rel * s
	node.scale = Vector3.ONE * s
	return s


func _process(dt: float) -> void:
	_t += dt
	var g := Game
	var sim: ShipSim = g.sim
	var origin: BigVec = g.slew.view_pos(g)   # the ship, or the debug free camera
	_sync_entities()
	# Sun + eclipse test against the planet and moon
	var sd: Vector3 = g.sun_dir.normalized()
	sun.basis = Basis.looking_at(-sd, Vector3.UP if absf(sd.y) < 0.99 else Vector3.RIGHT)
	in_shadow = false
	for b in [g.earth, g.moon]:
		var body: CelestialBody = b
		var c := body.pos.rel(origin)
		var tca := c.dot(sd)
		if tca > 0.0 and (c - sd * tca).length() < body.radius * 0.995:
			in_shadow = true
	sun.light_energy = lerpf(sun.light_energy, 0.0 if in_shadow else 2.2, clampf(dt * 4.0, 0.0, 1.0))
	# Bodies
	var ep := g.earth.pos.rel(origin)
	earth_scale = _place_scaled(earth_node, ep, g.earth.radius)
	var mp := g.moon.pos.rel(origin)
	moon_scale = _place_scaled(moon_node, mp, g.moon.radius)
	_update_lod(g, origin)
	atmo_node.position = rig_xform.origin
	atmo_mat.set_shader_parameter("planet_center", ep)
	atmo_mat.set_shader_parameter("space_scale", earth_scale)
	for m in [earth_mat, cloud_mat, atmo_mat, moon_mat]:
		(m as ShaderMaterial).set_shader_parameter("sun_dir", sd)
	earth_mat.set_shader_parameter("time", g.t)
	earth_mat.set_shader_parameter("cloud_rot", g.t * 0.00002)
	cloud_mat.set_shader_parameter("time", g.t)
	cloud_mat.set_shader_parameter("cloud_rot", g.t * 0.00002)
	# Earthshine: light reflected from the big blue planet
	var to_e := ep.normalized()
	var phase := clampf((-to_e).dot(sd) * 0.5 + 0.5, 0.0, 1.0)
	var size := clampf(g.earth.radius / maxf(ep.length(), 1.0), 0.0, 1.0)
	earthshine.light_energy = 0.35 * phase * size
	earthshine.basis = Basis.looking_at(to_e, Vector3.UP if absf(to_e.y) < 0.99 else Vector3.RIGHT)
	# Daylight inside the atmosphere dims the stars and adds blue ambient
	var dom: CelestialBody = sim.dominant
	day_factor = 0.0
	var elev := sim.up_dir.dot(sd)
	var in_air := dom != null and dom.has_atmo and sim.altitude < dom.atmo_top
	if in_air:
		day_factor = smoothstep(-0.12, 0.2, elev) * (1.0 - clampf(sim.altitude / 45000.0, 0.0, 1.0))
	sky_mat.set_shader_parameter("star_intensity", lerpf(1.0, 0.0, smoothstep(0.0, 0.25, day_factor)))
	sky_mat.set_shader_parameter("milky_intensity", lerpf(1.0, 0.0, day_factor))
	env.ambient_light_color = Color(0.05, 0.06, 0.08).lerp(Color(0.35, 0.45, 0.6), day_factor)
	# Scripted "physically based" exposure (deterministic, so screenshots and bots match): bright
	# daytime sky stops down, sunlit space a little less, night in the atmosphere opens up.
	var night := (1.0 - clampf(sim.altitude / 45000.0, 0.0, 1.0)) * (1.0 - smoothstep(-0.12, 0.05, elev)) if in_air else 0.0
	var exp_target := lerpf(0.92, 0.78, day_factor) + night * 0.35
	exp_target *= 1.0 - 0.35 * g.cabin_dim     # bedtime: a darker, calmer view
	env.tonemap_exposure = lerpf(env.tonemap_exposure, exp_target, clampf(dt * 1.5, 0.0, 1.0)) if dt < 0.5 else exp_target
	_region_tick += 1
	if _region_tick % 60 == 0 and _fixed_region_dir() == "":
		_pick_region(origin)
	if region:
		region.place(origin)
	# Entities
	for e in g.entities:
		var n: Node3D = ent_nodes.get(e["id"])
		if n == null:
			continue
		var rel2 := (e["pos"] as BigVec).rel(origin)
		n.position = rel2
		n.basis = e["basis"]
		var far := 250000.0 if e["kind"] in ["pad", "runway", "lunar_pad"] else (60000.0 if e["kind"] != "field" else 500000.0)
		var vis := bool(e.get("visible", true)) and rel2.length() < far
		if e["mode"] == "surface":   # only while its planet is drawn true-size (not in scaled space)
			vis = vis and (earth_scale if e["body"] == g.earth else moon_scale) > 0.999
		n.visible = vis
		_animate_entity(e, n, dt)
	# FX
	for f in fx_nodes.duplicate():
		f["t"] = float(f["t"]) + dt
		var fn: Node3D = f["node"]
		fn.position = (f["pos"] as BigVec).rel(origin)
		if float(f["t"]) > 4.0:
			fn.queue_free()
			fx_nodes.erase(f)
	# Ship + camera rig
	ship.basis = sim.basis
	ship.position = sim.pos.rel(origin)
	ship.visible = true
	ship.animate(g, dt)
	var shake := Vector3(randf_range(-1, 1), randf_range(-1, 1), 0.0) * g.camera_shake * 0.04
	shake += Vector3(randf_range(-1, 1), randf_range(-1, 1), 0) * clampf(sim.dyn_pressure / 40000.0, 0.0, 0.03)
	if sim.thrust_now > 0.0 and sim.booster_attached:
		shake += Vector3(randf_range(-1, 1), randf_range(-1, 1), 0) * 0.02
	if g.slew.active and g.slew.mode == "cam":
		rig_xform = Transform3D(g.slew.cam_basis, Vector3.ZERO)
	elif g.view_mode == 0:
		rig_xform = Transform3D(sim.basis, sim.basis * (EYE + shake))
	else:
		rig_xform = chase_xform(sim, chase_distance(sim))
		rig_xform.origin += sim.basis * shake * 20.0
	# Hyperspace tunnel
	tunnel.visible = g.jump_phase > 0.0
	if tunnel.visible:
		tunnel.basis = sim.basis * Basis(Vector3.RIGHT, PI * 0.5)
		tunnel_mat.set_shader_parameter("intensity", sin(clampf(g.jump_phase, 0.0, 1.0) * PI) * 1.5 + g.jump_phase * 0.3)
		tunnel_mat.set_shader_parameter("time", _t)


# ------------------------------------------------------------------ real-size LOD terrain
func _update_lod(g: Node, origin: BigVec) -> void:
	var e: CelestialBody = g.earth
	var m: CelestialBody = g.moon
	var eb := e.pos.rel_d(origin)
	earth_lod.update(eb, earth_scale)
	moon_lod.update(m.pos.rel_d(origin), moon_scale)
	# camera (floating origin) in planet space: km for the air maths, mod 4096 m for wave phase
	earth_mat.set_shader_parameter("cam_planet_km", Vector3(-eb[0], -eb[1], -eb[2]) * 0.001)
	earth_mat.set_shader_parameter("wave_shift", Vector3(fposmod(-eb[0], 4096.0), fposmod(-eb[1], 4096.0), fposmod(-eb[2], 4096.0)))
	earth_mat.set_shader_parameter("lod_scale", earth_scale)
	if e.terrain != null and not e.terrain.packs.is_empty() and Engine.get_process_frames() % 30 == 0:
		_update_pack_textures(Vector3(-eb[0], -eb[1], -eb[2]).normalized())


## Up to 4 area packs nearest the camera get their Sentinel-2 imagery on the planet shader.
func _update_pack_textures(cdir: Vector3) -> void:
	var gfg := Geo.game_from_geo().inverse()
	var gd := gfg * cdir
	var lat := rad_to_deg(asin(clampf(gd.y, -1.0, 1.0)))
	var lon := rad_to_deg(atan2(gd.x, -gd.z))
	var pl: Array = Game.earth.terrain.packs.duplicate()
	pl.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return Vector2((float(a["s"]) + float(a["n"])) * 0.5 - lat, (float(a["w"]) + float(a["e"])) * 0.5 - lon).length() \
			< Vector2((float(b["s"]) + float(b["n"])) * 0.5 - lat, (float(b["w"]) + float(b["e"])) * 0.5 - lon).length())
	var n := 0
	for pk: Dictionary in pl:
		if n >= 4:
			break
		var id: String = pk["id"]
		if not _pack_tex.has(id):
			_load_pack_tex(id, str(pk["img"]))
			continue
		earth_mat.set_shader_parameter("pack_box%d" % n, Vector4(pk["s"], pk["w"], pk["n"], pk["e"]))
		earth_mat.set_shader_parameter("pack_tex%d" % n, _pack_tex[id])
		n += 1
	earth_mat.set_shader_parameter("pack_count", n)


func _load_pack_tex(id: String, path: String) -> void:
	if _pack_loading.has(id) or not FileAccess.file_exists(path):
		return
	_pack_loading[id] = true
	var wr: WeakRef = weakref(self)
	_pack_tasks.append(WorkerThreadPool.add_task(func() -> void:
		var img := Image.load_from_file(path)
		if img == null or img.is_empty():
			return
		img.generate_mipmaps()
		img.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_SRGB)
		(func() -> void:
			var w: Object = wr.get_ref()
			if w:
				w.call("_pack_tex_ready", id, img)).call_deferred(), false, "area pack imagery"))


## Quit / teardown: no worker may still be sampling terrain or decoding images while nodes and
## the engine go away (planet LOD first: its workers call back into the region view).
func _exit_tree() -> void:
	shutdown_workers()


## Called by Game.quit_game / the EVA client before get_tree().quit() as well.
func shutdown_workers() -> void:
	if earth_lod:
		earth_lod.quiesce()
	if is_instance_valid(region):
		region.quiesce()
	for t: int in _pack_tasks:
		WorkerThreadPool.wait_for_task_completion(t)
	_pack_tasks.clear()


func _pack_tex_ready(id: String, img: Image) -> void:
	_pack_tex[id] = ImageTexture.create_from_image(img)
	_pack_loading.erase(id)


## Area packs / regions changed on disk (area manager job finished): re-read and re-mesh.
func reload_terrain() -> void:
	if earth_lod:
		earth_lod.quiesce()     # no LOD worker may be sampling while packs / the region change
	if Game.earth.terrain != null:
		Game.earth.terrain.reload_packs()
	_pack_tex.clear()
	_scan_regions()
	if region and not DirAccess.dir_exists_absolute(region.dir):
		_set_region("")
	earth_lod.rebuild()


# ------------------------------------------------------------------ detail regions
var _regions: Array = []        # [{dir, s, w, n, e}] built regions (assets/regions/*/manifest.json)
var _region_tick := 0


## --region=NAME / --region-dir=DIR pin one region (tests, the Fredericton missions); otherwise
## the built region under (or nearest within 30 km of) the camera is loaded automatically.
func _fixed_region_dir() -> String:
	if Settings.cli.has("region-dir"):
		return str(Settings.cli["region-dir"])
	if Settings.cli.has("region"):
		return Geo.asset_dir() + "/regions/" + str(Settings.cli["region"])
	return ""


func _scan_regions() -> void:
	_regions.clear()
	var base := Geo.asset_dir() + "/regions"
	if not DirAccess.dir_exists_absolute(base):
		return
	for id in DirAccess.get_directories_at(base):
		var mf := base + "/" + id + "/manifest.json"
		if not FileAccess.file_exists(mf):
			continue
		var m: Variant = JSON.parse_string(FileAccess.get_file_as_string(mf))
		if typeof(m) != TYPE_DICTIONARY or not (m as Dictionary).has("bbox"):
			continue
		var bb: Array = m["bbox"]
		_regions.append({"dir": base + "/" + id, "s": float(bb[0]), "w": float(bb[1]), "n": float(bb[2]), "e": float(bb[3])})


func _set_region(d0: String) -> void:
	var d := d0 if d0 != "" else Geo.asset_dir() + "/regions/fredericton"
	if region and region.dir == d:
		return
	if earth_lod:
		earth_lod.quiesce()     # LOD workers call the region's render hook: stop them first
	if region:
		region.queue_free()
		remove_child(region)
		region = null
	region = RegionView.new()
	region.name = "Region"
	region.dir = d
	add_child(region)       # a missing / old region is a no-op node
	if earth_lod:
		earth_lod.rebuild()


func _pick_region(origin: BigVec) -> void:
	if _regions.is_empty():
		return
	var rel := Game.earth.pos.rel_d(origin)
	var cd := Vector3(-rel[0], -rel[1], -rel[2])
	var alt := cd.length() - Game.earth.radius
	if alt > 60000.0:
		return
	var gd := Geo.game_from_geo().inverse() * cd.normalized()
	var lat := rad_to_deg(asin(clampf(gd.y, -1.0, 1.0)))
	var lon := rad_to_deg(atan2(gd.x, -gd.z))
	var best := ""
	var best_d := 30.0
	for r: Dictionary in _regions:
		var dlat := maxf(maxf(float(r["s"]) - lat, lat - float(r["n"])), 0.0) * 110.54
		var dlon := maxf(maxf(float(r["w"]) - lon, lon - float(r["e"])), 0.0) * 111.32 * cos(deg_to_rad(lat))
		var dk := Vector2(dlat, dlon).length()
		if dk < best_d:
			best_d = dk
			best = r["dir"]
	if best != "" and (region == null or region.dir != best):
		_set_region(best)


func _animate_entity(e: Dictionary, n: Node3D, dt: float) -> void:
	match e["kind"]:
		"station":
			for c in n.get_children():
				if c.has_meta("spin"):
					(c as Node3D).rotate_object_local(Vector3(0, 0, 1), float(c.get_meta("spin")) * dt)
				if c.has_meta("blink"):
					(c as Node3D).visible = fmod(_t + c.position.x * 0.1, 1.5) < 0.2
				if c.has_meta("solar"):
					# arrays track the sun around their mast (local X)
					var ls: Vector3 = (e["basis"] as Basis).inverse() * Game.sun_dir
					var want := atan2(-ls.y, ls.z)
					(c as Node3D).rotation.x = lerp_angle((c as Node3D).rotation.x, want, clampf(dt * 2.0, 0.0, 1.0)) if dt < 0.5 else want
		"booster":
			var pl: Node3D = n.get_node_or_null("Plume")
			var thr_frac := 0.0
			var on := false
			if e["mode"] == "attached" and Game.sim.booster_attached and Game.sim.thrust_now > 0.0:
				on = true
				thr_frac = Game.sim.thrust_now / maxf(Game.sim.booster_thrust, 1.0)
			elif e["mode"] == "free" or str(e.get("recovery", "")) not in ["", "caught"]:
				thr_frac = float(e.get("thrust_frac", 0.0))
				on = thr_frac > 0.04
			if pl:
				var vac := 1.0 - clampf(Game.sim.density_now / 0.4, 0.0, 1.0)
				ProcGen.update_exhaust(pl, thr_frac if on else 0.0, vac, _t, 30.0 + vac * 25.0)
			var l: OmniLight3D = n.get_node_or_null("Light")
			if l:
				l.light_energy = 10.0 * thr_frac if on else 0.0
			var legs: Node3D = n.get_node_or_null("LandingLegs")
			if legs:
				legs.visible = bool(e.get("legs_deployed", false)) or str(e.get("recovery", "")) == "caught"
			var fins: Node3D = n.get_node_or_null("GridFins")
			if fins:
				fins.visible = bool(e.get("fins_deployed", true))
		"satellite":
			if e.get("deployed", false):
				for c in n.get_children():
					if c.has_meta("side"):
						var target := 0.0
						(c as Node3D).rotation.z = move_toward((c as Node3D).rotation.z, target, dt)
			else:
				for c in n.get_children():
					if c.has_meta("side"):
						(c as Node3D).rotation.z = float(c.get_meta("side")) * 1.4
		"crystal", "pod", "lunar_pad", "pad":
			if e["kind"] == "pad":
				var sticks: Node3D = n.get_node_or_null("Chopsticks")
				if sticks:
					var want_open := 1.0
					for be in Game.entities_of("booster"):
						var ph := str(be.get("recovery", ""))
						if ph in ["catching", "caught"] or (be.get("mode","") == "landed" and ph == "caught"):
							want_open = 0.0
							break
					var cur := float(sticks.get_meta("open", 1.0))
					cur = move_toward(cur, want_open, dt * 1.2)
					sticks.set_meta("open", cur)
					for arm in sticks.get_children():
						var side := -1.0 if str(arm.name).ends_with("L") else 1.0
						(arm as Node3D).position.z = side * lerpf(2.2, 6.5, cur)
				var smk: GPUParticles3D = n.get_node_or_null("PadSmoke")
				if smk:
					var near_pad: bool = Game.sim.thrust_now > 0.0 and Game.sim.agl < 400.0 and Game.sim.pos.rel(e["pos"]).length() < 600.0
					if near_pad and not smk.emitting:
						smk.emitting = true
					elif not near_pad and smk.emitting and Game.sim.agl > 400.0:
						smk.emitting = false
			for c in n.get_children():
				if c.has_meta("blink"):
					(c as Node3D).visible = fmod(_t, 1.2) < 0.4
			if e["kind"] == "crystal":
				n.rotate_y(dt * 0.8)
		"crystal_rock":
			n.rotate_y(dt * 0.05)


## Auto chase distance: longer with booster attached so the full stack fits in frame.
func chase_distance(sim: ShipSim) -> float:
	var fixed := float(Settings.get_v("display", "chase_distance_m"))
	if fixed > 1.0:
		return fixed
	return 75.0 if sim.booster_attached else 34.0


## Approximate stack length (m) for framing checks (ship alone vs ship+booster).
func chase_stack_length_m(sim: ShipSim) -> float:
	return 42.0 if sim.booster_attached else 15.0


## Docking camera (nose) and arm camera transforms, relative to the floating origin.
## Chase camera behind and above the ship; near the ground it swings to the side so it
## never ends up underground (e.g. the rocket standing on the pad).
## Look-at is the stack mid-body so ship + attached booster stay in frame together.
func chase_xform(sim: ShipSim, dist: float = -1.0) -> Transform3D:
	if dist < 0.0:
		dist = chase_distance(sim)
	var fwd := sim.forward()
	var up := sim.up_dir if sim.up_dir.length() > 0.5 else sim.basis.y
	var off := -fwd * dist + sim.basis.y * dist * 0.26
	if sim.agl < 2000.0 and off.dot(up) < 6.0 - minf(sim.agl, 1000.0) * 0.5:
		var side := sim.basis.x.slide(up).normalized()
		if side.length() < 0.5:
			side = up.cross(fwd).normalized()
		off = side * dist * 0.9 + up * (dist * 0.15) - fwd.slide(up) * dist * 0.3
	# Aim at stack centre (booster hangs +Z when attached).
	var aim_z := 8.0 if sim.booster_attached else 0.0
	var target := sim.basis * Vector3(0.0, 0.0, aim_z) + fwd * (dist * 0.05)
	var t := Transform3D(Basis.IDENTITY, off)
	var look_dir := (target - off)
	var look_up := up if look_dir.length() > 1e-4 and absf(look_dir.normalized().dot(up)) < 0.98 else sim.basis.y
	return t.looking_at(target, look_up)


func docking_cam_xform() -> Transform3D:
	var s: ShipSim = Game.sim
	return Transform3D(s.basis, s.basis * Vector3(0, 0, -8.2))


func arm_cam_xform() -> Transform3D:
	var s: ShipSim = Game.sim
	var tip: Vector3 = Game.arm_tip_rel()
	var d: Vector3 = Game.arm_dir_world()
	var up := s.basis.y if absf(d.dot(s.basis.y)) < 0.95 else -s.basis.z
	return Transform3D(Basis.looking_at(d, up), tip + d * 0.6)
