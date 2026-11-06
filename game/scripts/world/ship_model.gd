class_name ShipModel
extends Node3D
## The Falcon, built from procedural parts: lifting-body fuselage with heat-shield belly,
## delta wings, tail fin, canopy, main engine with exhaust plume and light, RCS quads with
## puff particles, opening cargo-bay doors, robotic arm with tractor beam, landing gear
## (belly wheels + tail legs), docking port, nav/strobe/beacon lights, laser, plasma sheath.

var hull_mat: ShaderMaterial
var plume_mat: ShaderMaterial
var plume: MeshInstance3D
var engine_light: OmniLight3D
var door_l: Node3D
var door_r: Node3D
var arm_root: Node3D
var arm_seg: MeshInstance3D
var arm_tip: Node3D
var beam: MeshInstance3D
var beam_mat: ShaderMaterial
var laser: MeshInstance3D
var laser_mat: ShaderMaterial
var plasma: MeshInstance3D
var plasma_mat: ShaderMaterial
var wheels: Array[Node3D] = []
var legs: Array[Node3D] = []
var nav_red: OmniLight3D
var nav_green: OmniLight3D
var strobe: OmniLight3D
var beacon: OmniLight3D
var strobe_mesh: MeshInstance3D
var beacon_mesh: MeshInstance3D
var rcs_emitters: Array[GPUParticles3D] = []
var smoke: GPUParticles3D
var cargo_root: Node3D
var crew: CrewModel
var haze_mat: ShaderMaterial
var _t := 0.0


func _ready() -> void:
	_build()


func _build() -> void:
	# Starship-style: 304L stainless body, black hex heat tiles on the windward belly,
	# ogive nose, forward + aft flaps, crew-deck windows, Raptor cluster aft.
	hull_mat = ProcGen.shader_mat("res://shaders/hull.gdshader", {"base_color": Color(0.74, 0.75, 0.77), "metallic_base": 0.85,
		"rough_base": 0.3, "stripes": 0.0, "belly_tiles": 1.0, "panel_scale": 0.9, "bump_strength": 0.5})
	var profile: Array = EvaScenarios.PROFILE
	var body := ProcGen.mesh_node(_hull_mesh(profile, 64, EvaScenarios.YS), hull_mat)
	body.name = "Hull"
	add_child(body)
	# dark cabin shell behind the windows, so you never look into an empty model
	var cabin := ProcGen.mat(Color(0.16, 0.17, 0.19), 0.2, 0.7)
	cabin.cull_mode = BaseMaterial3D.CULL_DISABLED
	add_child(ProcGen.mesh_node(ProcGen.box(Vector3(2.6, 0.08, 3.8)), cabin, Vector3(0, 0.2, -4.6)))     # deck
	add_child(ProcGen.mesh_node(ProcGen.box(Vector3(3.2, 2.6, 0.08)), cabin, Vector3(0, 0.6, -2.75)))    # aft bulkhead
	var panel := ProcGen.mat(Color(0.05, 0.06, 0.07), 0.3, 0.4, Color(0.2, 0.55, 1.0), 0.6)
	add_child(ProcGen.mesh_node(ProcGen.box(Vector3(1.8, 0.35, 0.1)), panel, Vector3(0, 0.75, -5.95), Vector3(-0.5, 0, 0)))
	# crew windows: tinted, see-through glass over the cut-outs in the hull
	var glass := ProcGen.mat(Color(0.1, 0.14, 0.2, 0.35), 0.9, 0.04)
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.cull_mode = BaseMaterial3D.CULL_DISABLED
	glass.rim_enabled = true
	glass.rim = 0.5
	add_child(ProcGen.mesh_node(ProcGen.sphere(1.0, 40, 20), glass, EvaSim.CANOPY_C, Vector3.ZERO, EvaSim.CANOPY_R))
	crew = CrewModel.new()
	crew.name = "Crew"
	add_child(crew)
	# flaps (hinged near the waterline; tiles on the windward face)
	var flap_mat := ProcGen.bump_priority(ProcGen.shader_mat("res://shaders/hull.gdshader", {"base_color": Color(0.08, 0.08, 0.09), "metallic_base": 0.1,
		"rough_base": 0.7, "stripes": 0.0, "belly_tiles": 1.0, "panel_scale": 3.0}), 1)
	for sx: float in [-1.0, 1.0]:
		var fwd := PackedVector2Array([Vector2(0.0, -5.6), Vector2(1.5 * sx, -5.0), Vector2(1.5 * sx, -3.9), Vector2(0.0, -3.4)])
		if sx > 0.0:
			fwd.reverse()
		var ff := ProcGen.mesh_node(ProcGen.extrude(fwd, 0.14), flap_mat, Vector3(sx * 1.62, -0.42, 0))
		ff.name = "FwdFlap"
		add_child(ff)
		var aft := PackedVector2Array([Vector2(0.0, 3.4), Vector2(2.1 * sx, 4.6), Vector2(2.1 * sx, 6.9), Vector2(0.0, 7.0)])
		if sx > 0.0:
			aft.reverse()
		var af := ProcGen.mesh_node(ProcGen.extrude(aft, 0.18), flap_mat, Vector3(sx * 1.92, -0.42, 0))
		af.name = "AftFlap"
		add_child(af)
		# flap hinge fairings
		add_child(ProcGen.mesh_node(ProcGen.box(Vector3(0.3, 0.3, 1.8)), hull_mat, Vector3(sx * 1.55, -0.3, -4.5)))
		add_child(ProcGen.mesh_node(ProcGen.box(Vector3(0.3, 0.3, 3.2)), hull_mat, Vector3(sx * 1.85, -0.3, 5.3)))
	# Raptor 3 cluster: 3 centre sea-level (short) + 3 outer vacuum (large), no coplanar skirts.
	var metal := ProcGen.mat(Color(0.22, 0.21, 0.2), 0.92, 0.32)
	var bell_sl := ProcGen.bump_priority(ProcGen.shader_mat("res://shaders/hull.gdshader", {"base_color": Color(0.28, 0.26, 0.24), "belly_tiles": 0.0, "stripes": 0.0,
		"panel_scale": 9.0, "metallic_base": 0.95, "rough_base": 0.28, "bump_strength": 0.55}), 2)
	var bell_vac := ProcGen.bump_priority(ProcGen.shader_mat("res://shaders/hull.gdshader", {"base_color": Color(0.32, 0.3, 0.28), "belly_tiles": 0.0, "stripes": 0.0,
		"panel_scale": 11.0, "metallic_base": 0.95, "rough_base": 0.22, "bump_strength": 0.45}), 2)
	var cool := ProcGen.mat(Color(0.55, 0.15, 0.08), 0.4, 0.45)  # regenerative cooling ring tint
	# Aft heat-shield dome (slightly forward of bells so it never shares a plane with nozzles)
	add_child(ProcGen.mesh_node(ProcGen.cyl(1.55, 1.55, 0.18, 48), metal, Vector3(0, 0, 7.15), Vector3(PI * 0.5, 0, 0)))
	var hot := ProcGen.bump_priority(ProcGen.glow_mat(Color(1.0, 0.45, 0.15), 2.2), 3)
	add_child(ProcGen.mesh_node(ProcGen.cyl(0.55, 0.55, 0.04, 24), hot, Vector3(0, 0, 7.28), Vector3(PI * 0.5, 0, 0)))
	for k in 3:
		var ang := TAU * k / 3.0 + 0.15
		var p_sl := Vector3(cos(ang) * 0.48, sin(ang) * 0.48 * EvaScenarios.YS, 7.85)
		# SL Raptor 3: short nozzle + cooling band + throat (stacked with gaps)
		add_child(ProcGen.mesh_node(ProcGen.cyl(0.16, 0.16, 0.22, 16), metal, p_sl + Vector3(0, 0, -0.35), Vector3(PI * 0.5, 0, 0)))
		add_child(ProcGen.mesh_node(ProcGen.cyl(0.2, 0.2, 0.06, 16), cool, p_sl + Vector3(0, 0, -0.2), Vector3(PI * 0.5, 0, 0)))
		add_child(ProcGen.mesh_node(ProcGen.cyl(0.17, 0.36, 0.7, 24), bell_sl, p_sl, Vector3(PI * 0.5, 0, 0)))
		var ang2 := ang + PI / 3.0
		var p_v := Vector3(cos(ang2) * 1.12, sin(ang2) * 1.12 * EvaScenarios.YS, 8.35)
		# Vac Raptor 3: longer, wider nozzle; cooling ring inset from bell lip
		add_child(ProcGen.mesh_node(ProcGen.cyl(0.2, 0.2, 0.28, 16), metal, p_v + Vector3(0, 0, -0.55), Vector3(PI * 0.5, 0, 0)))
		add_child(ProcGen.mesh_node(ProcGen.cyl(0.26, 0.26, 0.07, 16), cool, p_v + Vector3(0, 0, -0.35), Vector3(PI * 0.5, 0, 0)))
		add_child(ProcGen.mesh_node(ProcGen.cyl(0.22, 0.72, 1.55, 28), bell_vac, p_v, Vector3(PI * 0.5, 0, 0)))
	plume_mat = ProcGen.shader_mat("res://shaders/plume.gdshader")
	var pm := CylinderMesh.new()
	pm.top_radius = 1.0
	pm.bottom_radius = 1.0
	pm.height = 1.0
	pm.radial_segments = 24
	pm.rings = 8
	plume = ProcGen.mesh_node(pm, plume_mat)
	plume.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var plume_pivot := Node3D.new()
	plume_pivot.position = Vector3(0, 0, 9.55)  # past vac bell lips — no coplanar overlap
	plume_pivot.rotation = Vector3(-PI * 0.5, 0, 0)
	add_child(plume_pivot)
	plume.position = Vector3(0, -0.5, 0)
	plume_pivot.add_child(plume)
	plume_pivot.name = "PlumePivot"
	haze_mat = ProcGen.shader_mat("res://shaders/heat_haze.gdshader")
	var haze := ProcGen.mesh_node(pm, haze_mat, Vector3(0, -0.55, 0), Vector3.ZERO, Vector3(1.15, 1.0, 1.15))
	haze.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	haze.name = "Haze"
	plume_pivot.add_child(haze)
	_greebles(metal)
	engine_light = OmniLight3D.new()
	engine_light.position = Vector3(0, 0, 11.2)
	engine_light.light_color = Color(1.0, 0.65, 0.35)
	engine_light.omni_range = 120.0
	engine_light.light_energy = 0.0
	engine_light.shadow_enabled = false
	add_child(engine_light)
	# Exhaust smoke (only in air)
	smoke = GPUParticles3D.new()
	smoke.amount = 160
	smoke.lifetime = 4.0
	smoke.local_coords = false
	smoke.position = Vector3(0, 0, 12.0)
	var spm := ParticleProcessMaterial.new()
	spm.direction = Vector3(0, 0, 1)
	spm.spread = 8.0
	spm.initial_velocity_min = 30.0
	spm.initial_velocity_max = 50.0
	spm.gravity = Vector3.ZERO
	spm.scale_min = 4.0
	spm.scale_max = 9.0
	spm.damping_min = 2.0
	spm.damping_max = 4.0
	var sgrad := Gradient.new()
	sgrad.set_color(0, Color(1.0, 0.8, 0.6, 0.5))
	sgrad.set_color(1, Color(0.7, 0.7, 0.7, 0.0))
	var sgt := GradientTexture1D.new()
	sgt.gradient = sgrad
	spm.color_ramp = sgt
	smoke.process_material = spm
	var quad := QuadMesh.new()
	quad.size = Vector2(1, 1)
	var smat := StandardMaterial3D.new()
	smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	smat.vertex_color_use_as_albedo = true
	smat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	smat.albedo_texture = _soft_dot()
	quad.material = smat
	smoke.draw_pass_1 = quad
	smoke.emitting = false
	add_child(smoke)
	# RCS quads and puff emitters
	var rcs_pos := [Vector3(1.75, 0.6, -5.5), Vector3(-1.75, 0.6, -5.5), Vector3(1.6, 0.6, 6.2), Vector3(-1.6, 0.6, 6.2)]
	for p in rcs_pos:
		add_child(ProcGen.mesh_node(ProcGen.box(Vector3(0.35, 0.35, 0.35)), metal, p))
		var em := GPUParticles3D.new()
		em.amount = 24
		em.lifetime = 0.35
		em.one_shot = false
		em.explosiveness = 0.0
		em.position = p
		var ppm := ParticleProcessMaterial.new()
		ppm.direction = Vector3(signf(p.x), 0.3, 0)
		ppm.spread = 25.0
		ppm.initial_velocity_min = 8.0
		ppm.initial_velocity_max = 14.0
		ppm.gravity = Vector3.ZERO
		ppm.scale_min = 0.3
		ppm.scale_max = 0.9
		ppm.color_ramp = sgt
		em.process_material = ppm
		em.draw_pass_1 = quad
		em.emitting = false
		add_child(em)
		rcs_emitters.append(em)
	# Cargo bay doors (hinged along the top edges)
	var door_mesh := ProcGen.box(Vector3(1.3, 0.12, 6.0))
	door_l = Node3D.new()
	door_l.position = Vector3(-1.45, 1.42, 1.5)
	add_child(door_l)
	door_l.add_child(ProcGen.mesh_node(door_mesh, hull_mat, Vector3(0.65, 0, 0)))
	door_r = Node3D.new()
	door_r.position = Vector3(1.45, 1.42, 1.5)
	add_child(door_r)
	door_r.add_child(ProcGen.mesh_node(door_mesh, hull_mat, Vector3(-0.65, 0, 0)))
	var bay_mat := ProcGen.shader_mat("res://shaders/hull.gdshader", {"mli": 1.0, "belly_tiles": 0.0, "stripes": 0.0, "panel_scale": 0.8, "bump_strength": 5.0})
	add_child(ProcGen.mesh_node(ProcGen.box(Vector3(2.5, 0.1, 5.8)), bay_mat, Vector3(0, 0.85, 1.5)))
	cargo_root = Node3D.new()
	add_child(cargo_root)
	# Robotic arm
	arm_root = Node3D.new()
	arm_root.position = Vector3(0, 1.75, 1.0)
	add_child(arm_root)
	var arm_mat := ProcGen.mat(Color(0.92, 0.92, 0.9), 0.3, 0.4)
	arm_root.add_child(ProcGen.mesh_node(ProcGen.sphere(0.35), arm_mat))
	arm_seg = ProcGen.mesh_node(ProcGen.cyl(0.14, 0.18, 1.0, 12), arm_mat)
	arm_root.add_child(arm_seg)
	arm_tip = Node3D.new()
	arm_root.add_child(arm_tip)
	arm_tip.add_child(ProcGen.mesh_node(ProcGen.cyl(0.25, 0.1, 0.5, 12), metal, Vector3.ZERO, Vector3(PI * 0.5, 0, 0)))
	beam_mat = ProcGen.shader_mat("res://shaders/glow_fx.gdshader", {"color": Color(0.3, 0.75, 1.0), "mode": 0, "intensity": 1.2})
	beam = ProcGen.mesh_node(ProcGen.cyl(4.0, 0.3, 1.0, 24), beam_mat)
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	beam.visible = false
	arm_tip.add_child(beam)
	# Laser (nose)
	laser_mat = ProcGen.shader_mat("res://shaders/glow_fx.gdshader", {"color": Color(1.0, 0.2, 0.15), "mode": 1, "intensity": 2.5})
	laser = ProcGen.mesh_node(ProcGen.cyl(0.12, 0.12, 1.0, 8), laser_mat)
	laser.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	laser.visible = false
	add_child(laser)
	# Docking port ring at the nose
	add_child(ProcGen.mesh_node(ProcGen.torus(0.45, 0.7, 32), metal, Vector3(0, 0, -7.75), Vector3(PI * 0.5, 0, 0)))
	# Lights
	nav_red = _light(Vector3(-6.7, -0.3, 5.0), Color(1, 0.1, 0.1), 0.6)
	nav_green = _light(Vector3(6.7, -0.3, 5.0), Color(0.1, 1, 0.2), 0.6)
	strobe = _light(Vector3(0, 4.5, 7.3), Color(1, 1, 1), 0.0)
	beacon = _light(Vector3(0, 1.75, -1.5), Color(1, 0.2, 0.1), 0.0)
	add_child(ProcGen.mesh_node(ProcGen.sphere(0.12), ProcGen.glow_mat(Color(1, 0.1, 0.1), 6.0), Vector3(-6.7, -0.3, 5.0)))
	add_child(ProcGen.mesh_node(ProcGen.sphere(0.12), ProcGen.glow_mat(Color(0.1, 1, 0.2), 6.0), Vector3(6.7, -0.3, 5.0)))
	strobe_mesh = ProcGen.mesh_node(ProcGen.sphere(0.14), ProcGen.glow_mat(Color(1, 1, 1), 12.0), Vector3(0, 4.5, 7.3))
	add_child(strobe_mesh)
	beacon_mesh = ProcGen.mesh_node(ProcGen.sphere(0.16), ProcGen.glow_mat(Color(1, 0.15, 0.05), 10.0), Vector3(0, 1.75, -1.5))
	add_child(beacon_mesh)
	# Plasma sheath (re-entry glow)
	plasma_mat = ProcGen.shader_mat("res://shaders/glow_fx.gdshader", {"color": Color(1.0, 0.45, 0.15), "mode": 2, "intensity": 0.0})
	plasma = ProcGen.mesh_node(ProcGen.sphere(1.0, 32, 16), plasma_mat, Vector3.ZERO, Vector3.ZERO, Vector3(9, 6, 13))
	plasma.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	plasma.visible = false
	add_child(plasma)


## Small surface details: canopy frame, OMS pods, RCS nozzle clusters, antennas, sensor dome.
func _greebles(metal: Material) -> void:
	var frame := ProcGen.mat(Color(0.08, 0.08, 0.09), 0.6, 0.4)
	# window frames (mullions) over the crew windows
	for x: float in [-0.35, 0.35]:
		add_child(ProcGen.mesh_node(ProcGen.box(Vector3(0.05, 0.05, 2.6)), hull_mat, Vector3(x, 1.43, -4.6), Vector3(0.1, 0, 0)))
	# RCS nozzle clusters (three little cones per quad)
	for p: Vector3 in [Vector3(1.75, 0.6, -5.5), Vector3(-1.75, 0.6, -5.5), Vector3(1.6, 0.6, 6.2), Vector3(-1.6, 0.6, 6.2)]:
		var sx := signf(p.x)
		for k in 3:
			var cone := ProcGen.mesh_node(ProcGen.cyl(0.05, 0.11, 0.18, 10), metal, p + Vector3(sx * 0.2, -0.1 + k * 0.1, -0.12 + k * 0.12), Vector3(0, 0, -sx * PI * 0.5))
			add_child(cone)
	# antennas and a sensor dome
	add_child(ProcGen.mesh_node(ProcGen.cyl(0.02, 0.03, 0.9, 6), metal, Vector3(0.5, 1.95, 0.0)))
	add_child(ProcGen.mesh_node(ProcGen.cyl(0.02, 0.03, 0.6, 6), metal, Vector3(-0.6, 1.9, -1.8)))
	add_child(ProcGen.mesh_node(ProcGen.sphere(0.28, 16, 8), ProcGen.mat(Color(0.85, 0.85, 0.8), 0.0, 0.3), Vector3(0, -1.55, -2.0), Vector3.ZERO, Vector3(1, 0.5, 1)))
	# hatch outline on the side (outset + priority so it never z-fights the hull skin)
	var hatch := ProcGen.bump_priority(frame, 2)
	for s2: float in [-1.0, 1.0]:
		add_child(ProcGen.mesh_node(ProcGen.box(Vector3(0.04, 0.85, 0.65)), hatch, Vector3(s2 * 1.72, 0.5, -1.5)))


## Lathe like ProcGen.lathe but indexed (smooth normals), closed at both ends, with the hull
## cut away under the crew windows (the canopy ellipsoid) so the crew inside can be seen.
func _hull_mesh(profile: Array, seg: int, ys: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings := profile.size()
	for i in rings:
		var a: Vector2 = profile[i]
		for k in seg + 1:
			var t := TAU * k / seg
			st.set_uv(Vector2(float(k) / seg, float(i) / (rings - 1)))
			st.add_vertex(Vector3(cos(t) * a.y, sin(t) * a.y * ys, a.x))
	for i in rings - 1:
		for k in seg:
			var i0 := i * (seg + 1) + k
			var i1 := i0 + seg + 1
			var a: Vector2 = profile[i]
			var b: Vector2 = profile[i + 1]
			var tm := TAU * (k + 0.5) / seg
			var zm := (a.x + b.x) * 0.5
			var rm := (a.y + b.y) * 0.5
			var cen := Vector3(cos(tm) * rm, sin(tm) * rm * ys, zm)
			if ((cen - EvaSim.CANOPY_C) / EvaSim.CANOPY_R).length() < 0.97:
				continue   # window cut-out (glass covers it)
			st.add_index(i0)
			st.add_index(i1 + 1)
			st.add_index(i1)
			st.add_index(i0)
			st.add_index(i0 + 1)
			st.add_index(i1 + 1)
	st.generate_normals()
	return st.commit()


func _light(p: Vector3, c: Color, e: float) -> OmniLight3D:
	var l := OmniLight3D.new()
	l.position = p
	l.light_color = c
	l.light_energy = e
	l.omni_range = 8.0
	add_child(l)
	return l


static func _soft_dot() -> GradientTexture2D:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(0.5, 0.0)
	t.width = 64
	t.height = 64
	return t


## Animate from game state (called every frame by the World).
func animate(g: Node, dt: float) -> void:
	if crew:
		crew.animate(g.crew_wave, dt)
	_t += dt
	var sim: ShipSim = g.sim
	var thr_frac := sim.thrust_now / maxf(sim.main_thrust, 1.0)
	if sim.booster_attached:
		thr_frac = 0.0
	var vac := 1.0 - clampf(sim.density_now / 0.4, 0.0, 1.0)
	plume.visible = thr_frac > 0.01
	plume.scale = Vector3(1.0 + vac * 2.5, 9.0 + thr_frac * 14.0 + vac * 10.0, 1.0 + vac * 2.5)
	plume_mat.set_shader_parameter("throttle", thr_frac * (1.3 if sim.boost else 1.0))
	haze_mat.set_shader_parameter("strength", clampf(thr_frac, 0.0, 1.0) * (1.0 - 0.8 * vac))
	haze_mat.set_shader_parameter("time", _t)
	plume_mat.set_shader_parameter("vacuum", vac)
	plume_mat.set_shader_parameter("time", _t)
	var haze: Node3D = plume.get_parent().get_node("Haze")
	haze.visible = thr_frac > 0.01
	haze.scale = Vector3(1.6 + vac * 2.0, 6.0 + thr_frac * 8.0, 1.6 + vac * 2.0)
	engine_light.light_energy = thr_frac * 6.0 * (0.85 + 0.15 * sin(_t * 40.0))
	smoke.emitting = thr_frac > 0.05 and sim.density_now > 0.05
	if smoke.emitting:
		var spm: ParticleProcessMaterial = smoke.process_material
		var air := sim.basis.transposed() * (-sim.surface_vel)
		spm.direction = (Vector3(0, 0, 1) * 40.0 + air).normalized()
		spm.initial_velocity_min = 30.0 + air.length() * 0.9
		spm.initial_velocity_max = 50.0 + air.length()
	# RCS puffs
	var tr := sim.rcs_trans_activity
	var rr := sim.rcs_rot_activity
	var act := [tr.x < -0.1 or rr.y > 0.3, tr.x > 0.1 or rr.y < -0.3, tr.x < -0.1 or rr.y < -0.3, tr.x > 0.1 or rr.y > 0.3]
	var any_v := absf(tr.y) > 0.1 or absf(tr.z) > 0.1 or absf(rr.x) > 0.3 or absf(rr.z) > 0.3
	for i in rcs_emitters.size():
		rcs_emitters[i].emitting = act[i] or any_v
	# Doors and arm
	door_l.rotation.z = -g.cargo_door * deg_to_rad(150.0)
	door_r.rotation.z = g.cargo_door * deg_to_rad(150.0)
	var ext: float = g.arm_extend
	arm_root.visible = ext > 0.01
	var dir_b: Vector3 = g.arm_dir_body()
	var length: float = g.arm_len * ext
	if arm_root.visible:
		var b := Basis.looking_at(dir_b, Vector3.UP if absf(dir_b.y) < 0.95 else Vector3.BACK)
		arm_seg.basis = b * Basis(Vector3.RIGHT, PI * 0.5)
		arm_seg.position = dir_b * length * 0.5
		arm_seg.scale = Vector3(1, maxf(length, 0.05), 1)
		arm_tip.position = dir_b * length
		arm_tip.basis = b
	beam.visible = g.beam_on
	if beam.visible:
		beam.basis = Basis(Vector3.RIGHT, -PI * 0.5)
		beam.scale = Vector3(1, 60.0, 1)
		beam.position = Vector3(0, 0, -30.0)
		beam_mat.set_shader_parameter("time", _t)
	# Laser
	laser.visible = g.laser_on
	if laser.visible:
		var dist := float(g.mission.guidance.get("laser_dist", 900.0)) if g.mission else 900.0
		laser.basis = Basis(Vector3.RIGHT, PI * 0.5)
		laser.scale = Vector3(1, dist, 1)
		laser.position = Vector3(0, -0.6, -7.8 - dist * 0.5)
	# Gear
	var gp: float = sim.gear_pos
	for w in wheels:
		w.visible = gp > 0.02
		w.scale = Vector3(1, maxf(gp, 0.05), 1)
	for lg in legs:
		lg.visible = gp > 0.02
		var out: Vector3 = lg.get_meta("out")
		var foot := out * 0.6 + Vector3(0, 0, 1.6 * gp)
		var leg_mesh: MeshInstance3D = lg.get_child(0)
		var foot_mesh: MeshInstance3D = lg.get_child(1)
		leg_mesh.position = foot * 0.5
		leg_mesh.basis = Basis.looking_at(foot.normalized(), Vector3.UP if absf(foot.normalized().y) < 0.9 else Vector3.RIGHT) * Basis(Vector3.RIGHT, PI * 0.5)
		leg_mesh.scale = Vector3(1, foot.length(), 1)
		foot_mesh.position = foot
		foot_mesh.basis = Basis(Vector3.RIGHT, PI * 0.5)
	# Lights
	nav_red.visible = InputHub.on("nav_lights")
	nav_green.visible = nav_red.visible
	var strobe_on := InputHub.on("strobe") and fmod(_t, 1.2) < 0.08
	strobe.light_energy = 6.0 if strobe_on else 0.0
	strobe_mesh.visible = strobe_on
	var beacon_on := InputHub.on("beacon") and fmod(_t, 1.0) < 0.5
	beacon.light_energy = 2.0 if beacon_on else 0.0
	beacon_mesh.visible = beacon_on
	# Heat
	var heat := clampf((sim.hull_temp - 700.0) / 900.0, 0.0, 1.2)
	hull_mat.set_shader_parameter("heat_glow", heat)
	var pl := clampf(sim.heat_flux / 120000.0, 0.0, 1.5)
	plasma.visible = pl > 0.02
	if plasma.visible:
		plasma_mat.set_shader_parameter("intensity", pl * 1.6)
		plasma_mat.set_shader_parameter("time", _t)
		plasma_mat.set_shader_parameter("flow_dir", sim.basis.transposed() * sim.surface_vel.normalized())
