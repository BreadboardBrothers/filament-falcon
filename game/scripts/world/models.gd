class_name Models
extends RefCounted
## Procedural models for everything that is not the Falcon itself.


static func _metal() -> StandardMaterial3D:
	return ProcGen.mat(Color(0.6, 0.6, 0.62), 0.85, 0.35)


static func _white() -> StandardMaterial3D:
	var m := ProcGen.mat(Color(0.88, 0.88, 0.86), 0.05, 0.7)
	return m


static func _gold() -> StandardMaterial3D:
	return ProcGen.mat(Color(0.95, 0.72, 0.3), 1.0, 0.3)


static func _blink_light(parent: Node3D, pos: Vector3, c: Color, rng: float = 15.0) -> Node3D:
	var n := Node3D.new()
	n.position = pos
	n.set_meta("blink", true)
	var l := OmniLight3D.new()
	l.light_color = c
	l.omni_range = rng
	l.light_energy = 2.0
	n.add_child(l)
	n.add_child(ProcGen.mesh_node(ProcGen.sphere(0.25, 12, 6), ProcGen.glow_mat(c, 10.0)))
	parent.add_child(n)
	return n


static func _hull(color: Color, scale: float = 0.8, metallic: float = 0.05, rough: float = 0.42) -> ShaderMaterial:
	return ProcGen.shader_mat("res://shaders/hull.gdshader", {"base_color": color, "belly_tiles": 0.0, "stripes": 0.0,
		"panel_scale": scale, "metallic_base": metallic, "rough_base": rough})


static func _mli() -> ShaderMaterial:
	return ProcGen.shader_mat("res://shaders/hull.gdshader", {"mli": 1.0, "belly_tiles": 0.0, "stripes": 0.0, "panel_scale": 0.5, "bump_strength": 5.0})


## Small equipment boxes, handrails and vents scattered over a cylinder module (one MultiMesh each).
static func _greeble_cyl(parent: Node3D, center: Vector3, radius: float, length: float, axis: String, count: int, seed_v: int, mat: Material) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = ProcGen.box(Vector3.ONE)
	mm.instance_count = count
	for i in count:
		var a := rng.randf() * TAU
		var t := rng.randf_range(-0.45, 0.45) * length
		var sz := Vector3(rng.randf_range(0.2, 0.9), rng.randf_range(0.1, 0.35), rng.randf_range(0.2, 1.4))
		if rng.randf() < 0.3:
			sz = Vector3(0.06, 0.12, rng.randf_range(1.5, 3.5))   # handrail
		var radial := Vector3(cos(a), sin(a), 0.0)
		var along := Vector3(0, 0, 1)
		if axis == "x":
			radial = Vector3(0.0, cos(a), sin(a))
			along = Vector3(1, 0, 0)
		var pos := center + radial * (radius + sz.y * 0.5) + along * t
		var b := Basis(along.cross(radial).normalized(), radial, along).scaled(Vector3(sz.x, sz.y, sz.z))
		mm.set_instance_transform(i, Transform3D(b, pos))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	parent.add_child(mmi)


## A solar array wing: mast + two blankets with frames, procedural cell material.
static func _solar_wing(root: Node3D, pos: Vector3, length: float, width: float, panel: Material, metal: Material) -> Node3D:
	var wing := Node3D.new()
	wing.position = pos
	wing.set_meta("solar", true)
	root.add_child(wing)
	wing.add_child(ProcGen.mesh_node(ProcGen.cyl(0.18, 0.18, length, 8), metal, Vector3.ZERO, Vector3(0, 0, PI * 0.5)))
	for s: float in [-1.0, 1.0]:
		var c := Vector3(0, s * (width * 0.5 + 0.35), 0)
		wing.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(length, width, 0.06)), panel, c))
		wing.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(length, 0.12, 0.12)), metal, c + Vector3(0, s * width * 0.5, 0)))
		for k in 5:
			var x := -length * 0.5 + length * k / 4.0
			wing.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(0.1, width, 0.1)), metal, c + Vector3(x, 0, 0.05)))
	return wing


## Space station. Station frame: docking port at +Z (z = 21), roof +Y.
static func station() -> Node3D:
	var root := Node3D.new()
	var white := _hull(Color(0.88, 0.88, 0.86), 0.7)
	var grey := _hull(Color(0.55, 0.56, 0.58), 1.2, 0.6, 0.35)
	var gold := _mli()
	var metal := _metal()
	var dark := ProcGen.mat(Color(0.12, 0.12, 0.13), 0.5, 0.5)
	var panel := ProcGen.shader_mat("res://shaders/solar_panel.gdshader")
	var rx := Vector3(PI * 0.5, 0, 0)
	# core modules along Z
	root.add_child(ProcGen.mesh_node(ProcGen.cyl(2.6, 2.6, 16.0, 48), white, Vector3(0, 0, 6.0), rx))
	root.add_child(ProcGen.mesh_node(ProcGen.cyl(2.2, 2.6, 3.0, 48), white, Vector3(0, 0, 15.5), rx))
	root.add_child(ProcGen.mesh_node(ProcGen.cyl(1.3, 1.3, 4.0, 32), grey, Vector3(0, 0, 18.8), rx))
	root.add_child(ProcGen.mesh_node(ProcGen.cyl(3.2, 3.2, 14.0, 48), gold, Vector3(0, 0, -9.0), rx))
	root.add_child(ProcGen.mesh_node(ProcGen.sphere(3.4, 48, 24), white, Vector3(0, 0, -2.0)))
	# module ring frames
	for z: float in [-1.8, 3.0, 8.0, 13.8, -15.9, -2.2]:
		var r := 3.3 if z < -2.0 else 2.7
		root.add_child(ProcGen.mesh_node(ProcGen.torus(r - 0.08, r + 0.12, 48), grey, Vector3(0, 0, z), rx))
	_greeble_cyl(root, Vector3(0, 0, 6.0), 2.6, 15.0, "z", 70, 11, grey)
	_greeble_cyl(root, Vector3(0, 0, -9.0), 3.2, 13.0, "z", 40, 12, dark)
	# docking port ring + approach lights + target standoff cross
	root.add_child(ProcGen.mesh_node(ProcGen.torus(0.5, 0.85, 32), metal, Vector3(0, 0, 20.9), rx))
	for i in 8:
		var a0 := TAU * i / 8.0
		root.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(0.18, 0.18, 0.5)), dark, Vector3(cos(a0) * 1.05, sin(a0) * 1.05, 20.9)))
	var tgt_mat := ProcGen.mat(Color(0.05, 0.05, 0.05), 0.0, 0.8)
	var cross_mat := ProcGen.glow_mat(Color(1.0, 1.0, 1.0), 1.5)
	root.add_child(ProcGen.mesh_node(ProcGen.cyl(0.45, 0.45, 0.05, 24), tgt_mat, Vector3(1.6, 1.6, 20.8), rx))
	root.add_child(ProcGen.mesh_node(ProcGen.cyl(0.04, 0.04, 1.1, 6), cross_mat, Vector3(1.6, 1.6, 21.3), rx))
	root.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(0.7, 0.06, 0.02)), cross_mat, Vector3(1.6, 1.6, 21.86)))
	root.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(0.06, 0.7, 0.02)), cross_mat, Vector3(1.6, 1.6, 21.86)))
	for i in 4:
		var a := TAU * i / 4.0 + PI * 0.25
		_blink_light(root, Vector3(cos(a) * 1.2, sin(a) * 1.2, 21.0), Color(0.2, 1.0, 0.3), 6.0)
	# habitat side modules with windows
	var win_mat := ProcGen.glow_mat(Color(1.0, 0.82, 0.55), 2.5)
	for s: float in [-1.0, 1.0]:
		root.add_child(ProcGen.mesh_node(ProcGen.cyl(2.0, 2.0, 9.0, 40), white, Vector3(s * 6.5, 0, 2.0), Vector3(0, 0, PI * 0.5)))
		root.add_child(ProcGen.mesh_node(ProcGen.sphere(2.0, 32, 16), white, Vector3(s * 11.0, 0, 2.0)))
		_greeble_cyl(root, Vector3(s * 6.5, 0, 2.0), 2.0, 8.0, "x", 30, 20 + int(s), grey)
		for k in 4:
			root.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(0.6, 0.06, 0.4)), win_mat, Vector3(s * (4.0 + k * 1.6), 2.0, 2.0)))
	# cupola
	root.add_child(ProcGen.mesh_node(ProcGen.cyl(0.9, 1.3, 1.0, 12), grey, Vector3(0, -3.6, 4.0)))
	root.add_child(ProcGen.mesh_node(ProcGen.cyl(0.6, 0.6, 0.06, 12), win_mat, Vector3(0, -4.12, 4.0)))
	# main truss (lattice look: box chords + diagonal bays) along Y, with solar arrays
	for cx: float in [-0.5, 0.5]:
		for cz: float in [-0.5, 0.5]:
			root.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(0.14, 72.0, 0.14)), metal, Vector3(cx, 0, -6.0 + cz)))
	for k in 36:
		var y := -35.0 + k * 2.0
		root.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(1.0, 0.08, 0.08)), metal, Vector3(0, y, -5.5)))
		root.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(1.0, 0.08, 0.08)), metal, Vector3(0, y, -6.5)))
		var diag := ProcGen.mesh_node(ProcGen.box(Vector3(0.06, 2.2, 0.06)), metal, Vector3(0.5 if k % 2 == 0 else -0.5, y + 1.0, -6.0))
		diag.rotation = Vector3(0.46 if k % 2 == 0 else -0.46, 0, 0)
		root.add_child(diag)
	for s: float in [-1.0, 1.0]:
		for k in 2:
			var y2 := s * (18.0 + k * 16.0)
			var wing := _solar_wing(root, Vector3(0, y2, -6.0), 34.0, 6.5, panel, metal)
			wing.rotation = Vector3(0, 0, 0)
		# battery / electronics boxes on the truss
		root.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(1.6, 3.0, 1.4)), grey, Vector3(0, s * 10.5, -6.0)))
	# radiators (ribbed white panels)
	var rad_mat := _hull(Color(0.95, 0.95, 0.95), 3.0, 0.0, 0.3)
	for s: float in [-1.0, 1.0]:
		root.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(0.1, 9.0, 12.0)), rad_mat, Vector3(s * 3.9, 0, -9.0)))
		root.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(0.6, 0.2, 0.2)), metal, Vector3(s * 3.5, 0, -9.0)))
	# comms dish on a boom + antennas
	root.add_child(ProcGen.mesh_node(ProcGen.cyl(0.08, 0.08, 6.0, 8), metal, Vector3(2.0, 4.0, 10.0), Vector3(0, 0, -0.5)))
	var dish := ProcGen.mesh_node(ProcGen.cyl(1.4, 0.15, 0.5, 32), _white(), Vector3(3.4, 6.6, 10.0), Vector3(0.0, 0.0, -0.9))
	root.add_child(dish)
	for i in 3:
		root.add_child(ProcGen.mesh_node(ProcGen.cyl(0.03, 0.03, 3.0, 6), metal, Vector3(-1.2 + i * 1.2, 4.0, 12.0 - i * 3.0)))
	# rotating habitat ring
	var ring := Node3D.new()
	ring.position = Vector3(0, 0, -18.0)
	ring.set_meta("spin", 0.05)
	root.add_child(ring)
	var tm := ProcGen.torus(15.0, 17.5, 128)
	ring.add_child(ProcGen.mesh_node(tm, white, Vector3.ZERO, rx))
	for i in 4:
		var a2 := TAU * i / 4.0
		ring.add_child(ProcGen.mesh_node(ProcGen.cyl(0.5, 0.5, 15.0, 12), grey, Vector3(cos(a2), sin(a2), 0) * 8.0, Vector3(0, 0, a2 + PI * 0.5)))
	for i in 24:
		var a3 := TAU * i / 24.0
		var win := ProcGen.mesh_node(ProcGen.box(Vector3(1.0, 0.4, 0.2)), win_mat, Vector3(cos(a3), sin(a3), 0) * 16.25 + Vector3(0, 0, 1.3))
		win.rotation = Vector3(0, 0, a3 + PI * 0.5)
		ring.add_child(win)
	_blink_light(root, Vector3(0, 36.0, -6.0), Color(1, 0.1, 0.1), 20.0)
	_blink_light(root, Vector3(0, -36.0, -6.0), Color(1, 0.1, 0.1), 20.0)
	_blink_light(root, Vector3(11.5, 2.0, 2.0), Color(0.1, 1, 0.2), 10.0)
	_blink_light(root, Vector3(-11.5, 2.0, 2.0), Color(1, 0.1, 0.1), 10.0)
	var flood := SpotLight3D.new()
	flood.position = Vector3(0, 3.0, 16.0)
	flood.basis = Basis.looking_at(Vector3(0, -0.2, 1))
	flood.spot_range = 120.0
	flood.spot_angle = 30.0
	flood.light_energy = 3.0
	root.add_child(flood)
	return root


static func booster() -> Node3D:
	## Super-Heavy-style booster: stainless body, outset dark band (no z-fight), grid fins,
	## foldable legs, and a dense Raptor 3 cluster (1 + 6 + 12). Keeps Plume / Light node names.
	var root := Node3D.new()
	var white := _white()
	var dark := ProcGen.bump_priority(ProcGen.mat(Color(0.07, 0.07, 0.08), 0.25, 0.65), 1)
	var metal := _metal()
	var cool := ProcGen.mat(Color(0.55, 0.14, 0.07), 0.35, 0.5)
	var bell := ProcGen.bump_priority(ProcGen.shader_mat("res://shaders/hull.gdshader", {"base_color": Color(0.27, 0.25, 0.23), "belly_tiles": 0.0, "stripes": 0.0,
		"panel_scale": 10.0, "metallic_base": 0.94, "rough_base": 0.28, "bump_strength": 0.5}), 2)
	var rx := Vector3(PI * 0.5, 0, 0)
	# Body slightly under dark band radius so the black ring never coplanar-fights the skin.
	root.add_child(ProcGen.mesh_node(ProcGen.cyl(2.55, 2.55, 22.0, 36), white, Vector3.ZERO, rx))
	root.add_child(ProcGen.mesh_node(ProcGen.cyl(1.85, 2.55, 2.4, 36), dark, Vector3(0, 0, -12.0), rx))
	root.add_child(ProcGen.mesh_node(ProcGen.cyl(2.68, 2.68, 1.7, 36), dark, Vector3(0, 0, 3.8), rx))  # outset band
	# Grid fins (4) — thin plates clear of the barrel
	var fins := Node3D.new()
	fins.name = "GridFins"
	root.add_child(fins)
	for i in 4:
		var a := TAU * i / 4.0 + 0.2
		var fin_root := Node3D.new()
		fin_root.position = Vector3(cos(a) * 2.85, sin(a) * 2.85, -6.5)
		fin_root.rotation = Vector3(0, 0, a)
		fins.add_child(fin_root)
		fin_root.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(0.12, 2.8, 2.4)), dark, Vector3(0.7, 0, 0)))
		for g in 3:
			fin_root.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(0.04, 2.6, 0.08)), metal, Vector3(0.7, 0, -0.8 + g * 0.8)))
	# Landing legs (folded along body; World/SOLAR can rotate via meta)
	var legs := Node3D.new()
	legs.name = "LandingLegs"
	legs.visible = false
	root.add_child(legs)
	for i in 4:
		var a2 := TAU * i / 4.0
		var leg := Node3D.new()
		leg.position = Vector3(cos(a2) * 2.4, sin(a2) * 2.4, 9.5)
		leg.rotation = Vector3(0, 0, a2)
		legs.add_child(leg)
		leg.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(0.18, 0.18, 4.5)), metal, Vector3(1.2, 0, 1.5)))
		leg.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(1.2, 0.08, 0.8)), dark, Vector3(2.0, 0, 3.5)))
	# Raptor 3 cluster: centre + ring of 6 + ring of 12
	var aft_z := 11.5
	root.add_child(ProcGen.mesh_node(ProcGen.cyl(2.2, 2.2, 0.2, 36), metal, Vector3(0, 0, aft_z - 0.35), rx))
	var positions: Array = [Vector3.ZERO]
	for i in 6:
		var a3 := TAU * i / 6.0
		positions.append(Vector3(cos(a3), sin(a3), 0) * 0.85)
	for i in 12:
		var a4 := TAU * i / 12.0 + 0.1
		positions.append(Vector3(cos(a4), sin(a4), 0) * 1.75)
	var nozzles: Array = []
	for i in positions.size():
		var p: Vector3 = positions[i]
		var z_off := 0.15 if i == 0 else (0.05 if i <= 6 else 0.0)
		var r_bot := 0.42 if i == 0 else (0.38 if i <= 6 else 0.34)
		var h := 1.35 if i == 0 else 1.2
		var add_pos := p + Vector3(0, 0, aft_z + z_off)
		root.add_child(ProcGen.mesh_node(ProcGen.cyl(0.14, 0.14, 0.2, 12), metal, add_pos + Vector3(0, 0, -0.55), rx))
		root.add_child(ProcGen.mesh_node(ProcGen.cyl(0.18, 0.18, 0.05, 12), cool, add_pos + Vector3(0, 0, -0.4), rx))
		var engine := ProcGen.mesh_node(ProcGen.nozzle_mesh(0.15, r_bot, h, 16), bell, add_pos, Vector3(-PI * 0.5, 0, 0))
		engine.name = "Engine" + str(i)
		root.add_child(engine)
		nozzles.append({"pos": add_pos + Vector3(0, 0, h * 0.5 + 0.01), "radius": r_bot, "engine": engine.name})
	var pivot := ProcGen.exhaust_cluster(nozzles)
	root.add_child(pivot)
	var l := OmniLight3D.new()
	l.name = "Light"
	l.position = Vector3(0, 0, aft_z + 4.5)
	l.light_color = Color(1.0, 0.6, 0.3)
	l.omni_range = 300.0
	l.light_energy = 0.0
	root.add_child(l)
	root.set_meta("legs", legs)
	root.set_meta("fins", fins)
	return root


static func satellite() -> Node3D:
	var root := Node3D.new()
	root.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(1.2, 1.0, 1.6)), _gold()))
	var dish := ProcGen.mesh_node(ProcGen.cyl(0.7, 0.1, 0.3, 24), _white(), Vector3(0, 0.75, 0))
	root.add_child(dish)
	var panel := ProcGen.shader_mat("res://shaders/solar_panel.gdshader")
	for s: float in [-1.0, 1.0]:
		var w := Node3D.new()
		w.name = "Wing%d" % int(s)
		w.position = Vector3(s * 0.6, 0, 0)
		w.set_meta("side", s)
		root.add_child(w)
		w.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(3.2, 0.05, 1.2)), panel, Vector3(s * 1.6, 0, 0)))
	return root


static func pod() -> Node3D:
	var root := Node3D.new()
	root.add_child(ProcGen.mesh_node(ProcGen.cyl(0.6, 1.4, 2.0, 24), ProcGen.mat(Color(1.0, 0.45, 0.1), 0.1, 0.5)))
	root.add_child(ProcGen.mesh_node(ProcGen.sphere(1.4, 24, 12), _white(), Vector3(0, -1.0, 0), Vector3.ZERO, Vector3(1, 0.4, 1)))
	root.add_child(ProcGen.mesh_node(ProcGen.sphere(0.3), ProcGen.glow_mat(Color(0.3, 0.8, 1.0), 4.0), Vector3(0, 0.3, 1.05)))
	_blink_light(root, Vector3(0, 1.2, 0), Color(1.0, 0.3, 0.1), 40.0)
	return root


static func crystal(big: bool = false) -> Node3D:
	var root := Node3D.new()
	var cm := ProcGen.mat(Color(0.3, 1.0, 0.9), 0.2, 0.1, Color(0.2, 1.0, 0.85), 3.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 99 if big else 7
	for i in 7:
		var len := rng.randf_range(0.8, 1.8) * (1.0 if not big else 3.0)
		var c := ProcGen.mesh_node(ProcGen.cyl(0.0, 0.22 * len, len, 6), cm)
		c.basis = Basis.looking_at(Vector3(rng.randf_range(-1, 1), rng.randf_range(0.2, 1), rng.randf_range(-1, 1)).normalized()) * Basis(Vector3.RIGHT, -PI * 0.5)
		c.position = c.basis.y * len * 0.4
		root.add_child(c)
	var l := OmniLight3D.new()
	l.light_color = Color(0.3, 1.0, 0.9)
	l.omni_range = 30.0 if big else 10.0
	l.light_energy = 2.0
	root.add_child(l)
	return root


static func rock_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.36, 0.33, 0.3)
	m.roughness = 0.95
	var nt := NoiseTexture2D.new()
	var fn := FastNoiseLite.new()
	fn.frequency = 0.02
	fn.fractal_octaves = 5
	nt.noise = fn
	nt.width = 512
	nt.height = 512
	nt.seamless = true
	m.albedo_texture = nt
	m.uv1_triplanar = true
	m.uv1_scale = Vector3(0.6, 0.6, 0.6)
	var nn := NoiseTexture2D.new()
	nn.noise = fn
	nn.width = 512
	nn.height = 512
	nn.seamless = true
	nn.as_normal_map = true
	nn.bump_strength = 6.0
	m.normal_enabled = true
	m.normal_texture = nn
	return m


static func crystal_rock() -> Node3D:
	var root := Node3D.new()
	var rock := ProcGen.mesh_node(ProcGen.rock_mesh(31, 0.3), rock_material(), Vector3.ZERO, Vector3.ZERO, Vector3.ONE * 11.0)
	root.add_child(rock)
	var c := crystal(true)
	c.position = Vector3(0, 7.0, 0)
	root.add_child(c)
	var c2 := crystal(true)
	c2.position = Vector3(5.0, -4.0, 4.0)
	c2.rotation = Vector3(2.0, 0.5, 0)
	root.add_child(c2)
	return root


## Soft round particle sprite.
static func _soft_tex() -> GradientTexture2D:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.add_point(0.55, Color(1, 1, 1, 0.55))
	g.set_color(g.get_point_count() - 1, Color(1, 1, 1, 0))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(0.5, 0.0)
	t.width = 128
	t.height = 128
	return t


## Billowing exhaust/steam cloud that rolls out of the flame trench at lift-off (lit by the sun).
static func pad_smoke() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "PadSmoke"
	p.amount = 420
	p.lifetime = 9.0
	p.local_coords = false
	p.visibility_aabb = AABB(Vector3(-400, -20, -400), Vector3(800, 300, 800))
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.emission_sphere_radius = 6.0
	m.direction = Vector3(0, 0.15, 1)
	m.spread = 70.0
	m.initial_velocity_min = 25.0
	m.initial_velocity_max = 60.0
	m.gravity = Vector3(0, 1.5, 0)
	m.damping_min = 6.0
	m.damping_max = 10.0
	m.scale_min = 8.0
	m.scale_max = 18.0
	var sc := Curve.new()
	sc.add_point(Vector2(0, 0.4))
	sc.add_point(Vector2(1, 2.6))
	var sct := CurveTexture.new()
	sct.curve = sc
	m.scale_curve = sct
	var gr := Gradient.new()
	gr.set_color(0, Color(1.0, 0.85, 0.65, 0.0))
	gr.add_point(0.08, Color(0.95, 0.93, 0.9, 0.75))
	gr.set_color(gr.get_point_count() - 1, Color(0.8, 0.8, 0.82, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = gr
	m.color_ramp = gt
	m.angle_min = 0.0
	m.angle_max = 360.0
	p.process_material = m
	var q := QuadMesh.new()
	var sm := StandardMaterial3D.new()
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.vertex_color_use_as_albedo = true
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	sm.albedo_texture = _soft_tex()
	sm.roughness = 1.0
	sm.disable_receive_shadows = true
	q.material = sm
	p.draw_pass_1 = q
	p.emitting = false
	return p


## Launch pad (local frame: y = up). Flame trench runs toward +Z.
static func pad() -> Node3D:
	var root := Node3D.new()
	var concrete := _hull(Color(0.58, 0.57, 0.55), 0.12, 0.0, 0.92)
	var scorched := ProcGen.mat(Color(0.18, 0.17, 0.16), 0.0, 0.95)
	var steel := ProcGen.mat(Color(0.78, 0.26, 0.1), 0.55, 0.45)
	var grey_steel := ProcGen.mat(Color(0.5, 0.52, 0.55), 0.8, 0.4)
	var white := _white()
	root.add_child(ProcGen.mesh_node(ProcGen.cyl(45.0, 50.0, 4.0, 64), concrete, Vector3(0, 0.0, 0)))
	root.add_child(ProcGen.mesh_node(ProcGen.cyl(9.0, 9.0, 0.1, 32), scorched, Vector3(0, 2.02, 0)))
	# flame trench + deflector
	root.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(12, 4.5, 60)), ProcGen.mat(Color(0.12, 0.12, 0.12), 0, 0.9), Vector3(0, 0.2, 30)))
	var defl := ProcGen.mesh_node(ProcGen.box(Vector3(10, 0.6, 12)), grey_steel, Vector3(0, 1.0, 6))
	defl.rotation = Vector3(-0.5, 0, 0)
	root.add_child(defl)
	# launch mount ring
	root.add_child(ProcGen.mesh_node(ProcGen.torus(3.2, 4.4, 32), grey_steel, Vector3(0, 2.4, 0)))
	# tower lattice: corner columns, horizontal girts, diagonal braces each 4 m bay
	for i in 16:
		var y := 2.0 + i * 4.0
		for c: Vector3 in [Vector3(-3, 0, -3), Vector3(3, 0, -3), Vector3(-3, 0, 3), Vector3(3, 0, 3)]:
			root.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(0.45, 4.0, 0.45)), steel, Vector3(14, y + 2.0, 0) + c))
		for zz: float in [-3.0, 3.0]:
			root.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(6.4, 0.25, 0.25)), steel, Vector3(14, y, zz)))
			var br := ProcGen.mesh_node(ProcGen.box(Vector3(7.2, 0.16, 0.16)), steel, Vector3(14, y + 2.0, zz))
			br.rotation = Vector3(0, 0, 0.59 if i % 2 == 0 else -0.59)
			root.add_child(br)
		for xx: float in [11.0, 17.0]:
			root.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(0.25, 0.25, 6.4)), steel, Vector3(xx, y, 0)))
			var br2 := ProcGen.mesh_node(ProcGen.box(Vector3(0.16, 0.16, 7.2)), steel, Vector3(xx, y + 2.0, 0))
			br2.rotation = Vector3(0.59 if i % 2 == 0 else -0.59, 0, 0)
			root.add_child(br2)
		if i % 3 == 1:
			root.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(7.0, 0.2, 7.0)), grey_steel, Vector3(14, y + 0.1, 0)))   # work platform
	root.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(7.0, 3.0, 7.0)), white, Vector3(14, 67.5, 0)))   # tower top house
	root.add_child(ProcGen.mesh_node(ProcGen.cyl(0.15, 0.25, 14.0, 8), grey_steel, Vector3(14, 76.0, 0)))  # lightning rod
	# crew access arm + umbilical arms
	root.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(9.0, 2.2, 2.2)), white, Vector3(8.0, 44.0, 0)))
	root.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(2.6, 2.6, 2.6)), white, Vector3(3.6, 44.0, 0)))
	for yy: float in [18.0, 30.0]:
		root.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(10.0, 0.6, 0.6)), steel, Vector3(8.5, yy, 0)))
		root.add_child(ProcGen.mesh_node(ProcGen.cyl(0.18, 0.18, 9.0, 8), ProcGen.mat(Color(0.1, 0.1, 0.1), 0.2, 0.6), Vector3(8.5, yy - 0.6, 0.6), Vector3(0, 0, PI * 0.5)))
	# lightning masts with catenary wires to the tower top
	for a: float in [0.6, 2.6, 4.6]:
		var mp := Vector3(cos(a), 0, sin(a)) * 60.0
		root.add_child(ProcGen.mesh_node(ProcGen.cyl(0.4, 0.8, 90.0, 10), grey_steel, mp + Vector3(0, 45, 0)))
		var wire_dir := (Vector3(14, 75, 0) - (mp + Vector3(0, 90, 0)))
		var wire := ProcGen.mesh_node(ProcGen.cyl(0.04, 0.04, wire_dir.length(), 4), ProcGen.mat(Color(0.1, 0.1, 0.1), 0.6, 0.5), mp + Vector3(0, 90, 0) + wire_dir * 0.5)
		wire.basis = Basis(Quaternion(Vector3.UP, wire_dir.normalized()))
		root.add_child(wire)
		_blink_light(root, mp + Vector3(0, 91, 0), Color(1, 0.1, 0.1), 10.0)
	# water tower and propellant spheres
	root.add_child(ProcGen.mesh_node(ProcGen.cyl(6.0, 6.0, 10.0, 32), white, Vector3(-80, 35, 60)))
	for k in 4:
		var lx := -80.0 + (k % 2) * 8.0 - 4.0
		var lz := 60.0 + (k / 2) * 8.0 - 4.0
		root.add_child(ProcGen.mesh_node(ProcGen.cyl(0.3, 0.3, 30.0, 6), grey_steel, Vector3(lx, 15, lz)))
	for k in 2:
		root.add_child(ProcGen.mesh_node(ProcGen.sphere(7.0, 32, 16), white, Vector3(70 + k * 18, 7.5, -60)))
	# floodlight masts
	for a: float in [0.0, 2.1, 4.2]:
		var p := Vector3(cos(a), 0, sin(a)) * 70.0
		root.add_child(ProcGen.mesh_node(ProcGen.cyl(0.4, 0.6, 40.0, 8), grey_steel, p + Vector3(0, 20, 0)))
		root.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(3.0, 1.2, 0.4)), ProcGen.glow_mat(Color(1, 0.95, 0.85), 3.0), p + Vector3(0, 40.5, 0)))
		var sp := SpotLight3D.new()
		sp.position = p + Vector3(0, 40, 0)
		sp.basis = Basis.looking_at((Vector3(0, 30, 0) - sp.position).normalized())
		sp.spot_range = 160.0
		sp.spot_angle = 22.0
		sp.light_energy = 6.0
		sp.light_color = Color(1.0, 0.95, 0.85)
		root.add_child(sp)
		_blink_light(root, p + Vector3(0, 41.5, 0), Color(1, 0.1, 0.1), 10.0)
	# Mechazilla chopsticks (catch arms) — open by default; close when a booster is caught.
	var sticks := Node3D.new()
	sticks.name = "Chopsticks"
	sticks.position = Vector3(10.0, 58.0, 0.0)
	root.add_child(sticks)
	var arm_mat := ProcGen.mat(Color(0.55, 0.56, 0.58), 0.85, 0.35)
	for side: float in [-1.0, 1.0]:
		var arm := Node3D.new()
		arm.name = "ArmL" if side < 0.0 else "ArmR"
		arm.position = Vector3(0, 0, side * 6.5)
		sticks.add_child(arm)
		arm.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(14.0, 0.7, 1.1)), arm_mat, Vector3(-5.0, 0, 0)))
		arm.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(1.2, 1.2, 1.2)), arm_mat, Vector3(-12.0, 0, 0)))
	sticks.set_meta("open", 1.0)  # 1 = open, 0 = closed on booster
	var smk := pad_smoke()
	smk.position = Vector3(0, 3.0, 40.0)
	root.add_child(smk)
	return root


static func runway(length_m: float = 3600.0, width_m: float = 60.0) -> Node3D:
	var root := Node3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(length_m, width_m)
	pm.subdivide_width = 64
	var rmat := ProcGen.shader_mat("res://shaders/runway.gdshader", {"length_m": length_m, "width_m": width_m})
	root.add_child(ProcGen.mesh_node(pm, rmat, Vector3(0, 0.15, 0)))
	# edge lights via MultiMesh
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = ProcGen.sphere(0.35, 8, 4)
	var count := int(length_m / 60.0) * 2
	mm.instance_count = count + 40
	var k := 0
	for i in int(length_m / 60.0):
		var x := -length_m * 0.5 + i * 60.0
		mm.set_instance_transform(k, Transform3D(Basis(), Vector3(x, 0.5, width_m * 0.5 + 1.0)))
		mm.set_instance_transform(k + 1, Transform3D(Basis(), Vector3(x, 0.5, -width_m * 0.5 - 1.0)))
		k += 2
	# approach light bars (west end)
	for j in 20:
		mm.set_instance_transform(k, Transform3D(Basis(), Vector3(-length_m * 0.5 - 60.0 - j * 30.0, 1.0, 0)))
		k += 1
	for j in 20:
		mm.set_instance_transform(k, Transform3D(Basis(), Vector3(-length_m * 0.5 - 60.0 - j * 30.0, 1.0, 6.0 if j % 2 == 0 else -6.0)))
		k += 1
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = ProcGen.glow_mat(Color(1.0, 0.9, 0.6), 6.0)
	root.add_child(mmi)
	# tower + hangars
	var bmat := ProcGen.mat(Color(0.7, 0.72, 0.75), 0.4, 0.5)
	root.add_child(ProcGen.mesh_node(ProcGen.cyl(4, 5, 30, 16), bmat, Vector3(200, 15, 160)))
	root.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(14, 6, 14)), ProcGen.glow_mat(Color(0.4, 0.8, 1.0), 0.6), Vector3(200, 33, 160)))
	for i in 4:
		root.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(70, 20, 50)), bmat, Vector3(-400 + i * 110, 10, 190)))
	return root


static func lunar_pad() -> Node3D:
	var root := Node3D.new()
	var paint := ProcGen.mat(Color(0.85, 0.85, 0.8), 0.0, 0.8)
	root.add_child(ProcGen.mesh_node(ProcGen.torus(18.0, 20.0, 64), paint, Vector3(0, 0.1, 0), Vector3.ZERO, Vector3(1, 0.05, 1)))
	root.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(2.0, 0.2, 16.0)), paint, Vector3(-5, 0.1, 0)))
	root.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(2.0, 0.2, 16.0)), paint, Vector3(5, 0.1, 0)))
	root.add_child(ProcGen.mesh_node(ProcGen.box(Vector3(10.0, 0.2, 2.0)), paint, Vector3(0, 0.1, 0)))
	var mast := ProcGen.mesh_node(ProcGen.cyl(0.2, 0.3, 12.0, 8), _metal(), Vector3(26, 6, 0))
	root.add_child(mast)
	_blink_light(root, Vector3(26, 12.4, 0), Color(0.2, 1.0, 0.3), 60.0)
	for a in 6:
		var p := Vector3(cos(TAU * a / 6.0), 0.4, sin(TAU * a / 6.0)) * 22.0
		_blink_light(root, p, Color(0.3, 0.7, 1.0), 8.0)
	return root
