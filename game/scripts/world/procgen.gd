class_name ProcGen
extends RefCounted
## Procedural meshes and materials (no external model files needed).


## Unit exhaust: nozzle at y=0, tail at y=-1. Bake the origin into vertices,
## not a child translation: scaling must NEVER move the upstream end forward.
## Rotation -PI/2 around X maps -Y to the authored ship's aft +Z axis.
static func exhaust_mesh() -> ArrayMesh:
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 1.0
	cylinder.bottom_radius = 1.0
	cylinder.height = 1.0
	cylinder.radial_segments = 24
	cylinder.rings = 8
	var arrays := cylinder.get_mesh_arrays()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for i in vertices.size():
		vertices[i].y -= 0.5
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func mat(color: Color, metallic: float = 0.0, roughness: float = 0.6, emission: Color = Color.BLACK, emission_energy: float = 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = metallic
	m.roughness = roughness
	if emission != Color.BLACK:
		m.emission_enabled = true
		m.emission = emission
		m.emission_energy_multiplier = emission_energy
	return m


static func bump_priority(mat: Material, pri: int) -> Material:
	if mat is BaseMaterial3D:
		(mat as BaseMaterial3D).render_priority = pri
	elif mat is ShaderMaterial:
		(mat as ShaderMaterial).render_priority = pri
	return mat


static func glow_mat(color: Color, energy: float = 4.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = color * energy
	return m


static func shader_mat(path: String, params: Dictionary = {}) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load(path)
	for k in params:
		m.set_shader_parameter(k, params[k])
	return m


static func mesh_node(mesh: Mesh, material: Material, pos: Vector3 = Vector3.ZERO, rot: Vector3 = Vector3.ZERO, scl: Vector3 = Vector3.ONE) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material
	mi.position = pos
	mi.rotation = rot
	mi.scale = scl
	return mi


static func box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b


static func cyl(r_top: float, r_bot: float, h: float, seg: int = 24) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = r_top
	c.bottom_radius = r_bot
	c.height = h
	c.radial_segments = seg
	c.rings = 1
	return c


static func sphere(r: float, seg: int = 32, rings: int = 16) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	s.radial_segments = seg
	s.rings = rings
	return s


static func torus(inner: float, outer: float, seg: int = 48) -> TorusMesh:
	var t := TorusMesh.new()
	t.inner_radius = inner
	t.outer_radius = outer
	t.rings = seg
	t.ring_segments = 12
	return t


## Surface of revolution around the Z axis. profile: Array of Vector2(z, radius).
static func lathe(profile: Array, segments: int = 40, y_scale: float = 1.0) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(profile.size() - 1):
		var a: Vector2 = profile[i]
		var b: Vector2 = profile[i + 1]
		for s in segments:
			var t0 := TAU * s / segments
			var t1 := TAU * (s + 1) / segments
			var p00 := Vector3(cos(t0) * a.y, sin(t0) * a.y * y_scale, a.x)
			var p01 := Vector3(cos(t1) * a.y, sin(t1) * a.y * y_scale, a.x)
			var p10 := Vector3(cos(t0) * b.y, sin(t0) * b.y * y_scale, b.x)
			var p11 := Vector3(cos(t1) * b.y, sin(t1) * b.y * y_scale, b.x)
			st.add_vertex(p00)
			st.add_vertex(p11)
			st.add_vertex(p10)
			st.add_vertex(p00)
			st.add_vertex(p01)
			st.add_vertex(p11)
	st.generate_normals()
	return st.commit()


## Flat polygon (in the XZ plane, points as Vector2(x, z)) extruded `thick` along Y.
static func extrude(poly: PackedVector2Array, thick: float, bevel_y_top: float = 0.0) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var idx := Geometry2D.triangulate_polygon(poly)
	var h := thick * 0.5
	for i in range(0, idx.size(), 3):
		var a := poly[idx[i]]
		var b := poly[idx[i + 1]]
		var c := poly[idx[i + 2]]
		st.add_vertex(Vector3(a.x, h + bevel_y_top, a.y))
		st.add_vertex(Vector3(c.x, h + bevel_y_top, c.y))
		st.add_vertex(Vector3(b.x, h + bevel_y_top, b.y))
		st.add_vertex(Vector3(a.x, -h, a.y))
		st.add_vertex(Vector3(b.x, -h, b.y))
		st.add_vertex(Vector3(c.x, -h, c.y))
	for i in poly.size():
		var p := poly[i]
		var q := poly[(i + 1) % poly.size()]
		var t0 := Vector3(p.x, h + bevel_y_top, p.y)
		var t1 := Vector3(q.x, h + bevel_y_top, q.y)
		var b0 := Vector3(p.x, -h, p.y)
		var b1 := Vector3(q.x, -h, q.y)
		st.add_vertex(t0)
		st.add_vertex(t1)
		st.add_vertex(b1)
		st.add_vertex(t0)
		st.add_vertex(b1)
		st.add_vertex(b0)
	st.generate_normals()
	var m := st.commit()
	return m


## Lumpy asteroid: displaced sphere.
static func rock_mesh(seed_v: int, rough: float = 0.35) -> ArrayMesh:
	var base := sphere(1.0, 28, 14)
	var arr := base.get_mesh_arrays()
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var n := FastNoiseLite.new()
	n.seed = seed_v
	n.frequency = 1.1
	n.fractal_octaves = 4
	var stretch := Vector3(1.0 + (seed_v % 3) * 0.25, 0.8 + (seed_v % 2) * 0.2, 1.0)
	for i in verts.size():
		var v := verts[i]
		var d := v.normalized()
		var k := 1.0 + n.get_noise_3dv(d * 1.7) * rough + n.get_noise_3dv(d * 5.0) * rough * 0.3
		verts[i] = d * k * stretch
	arr[Mesh.ARRAY_VERTEX] = verts
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	for i in idx:
		st.add_vertex(verts[i])
	st.generate_normals()
	return st.commit()


## Curved ground patch that follows the body's real terrain_height().
## Local frame: x = east, y = up, z = east x up. Grid is denser near the centre.
static func terrain_patch(body: CelestialBody, center: Vector3, half: float, n: int, expo: float = 1.7) -> ArrayMesh:
	var up := center.normalized()
	var east := CelestialBody.east_at(up)
	var zax := east.cross(up)
	var R := body.radius
	var h0 := 0.0
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	verts.resize((n + 1) * (n + 1))
	uvs.resize((n + 1) * (n + 1))
	for j in n + 1:
		for i in n + 1:
			var u := float(i) / n * 2.0 - 1.0
			var v := float(j) / n * 2.0 - 1.0
			var x := signf(u) * pow(absf(u), expo) * half
			var z := signf(v) * pow(absf(v), expo) * half
			var dir := (up + (east * x + zax * z) / R).normalized()
			var h := body.terrain_height(dir)
			var ang := up.angle_to(dir)
			# position relative to the patch origin (centre at radius R), in local frame
			var rr := R + h
			var off := dir * rr - up * R
			var edge := maxf(absf(u), absf(v))
			# sink the outer rim slightly so it blends under the planet sphere horizon
			var sink := smoothstep(0.92, 1.0, edge) * 25.0
			off -= up * sink * (1.0 if ang > 0.0 else 1.0)
			verts[j * (n + 1) + i] = Vector3(off.dot(east), off.dot(up) + h0, off.dot(zax))
			uvs[j * (n + 1) + i] = Vector2(edge, 0.0)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for j in n:
		for i in n:
			var a := j * (n + 1) + i
			var b := a + 1
			var c := a + n + 1
			var d := c + 1
			for k in [a, b, d, a, d, c]:
				st.set_uv(uvs[k])
				st.add_vertex(verts[k])
	st.generate_normals()
	st.generate_tangents()
	return st.commit()
