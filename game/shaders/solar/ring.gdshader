shader_type spatial;
render_mode cull_disabled, blend_mix, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

uniform vec4 color_inner : source_color = vec4(0.85, 0.75, 0.55, 0.85);
uniform vec4 color_outer : source_color = vec4(0.55, 0.5, 0.4, 0.35);
uniform float inner = 1.2;
uniform float outer = 2.2;
uniform float opacity = 0.85;

void fragment() {
	float r = length(UV - vec2(0.5, 0.5)) * 2.0 * outer;
	// UV mapped 0..1 across ring mesh; use VERTEX xz radius instead
	float rr = length(VERTEX.xz);
	float t = clamp((rr - inner) / max(outer - inner, 1e-3), 0.0, 1.0);
	float dens = smoothstep(0.0, 0.05, t) * (1.0 - smoothstep(0.92, 1.0, t));
	// Cassini-ish gap
	dens *= 1.0 - 0.85 * smoothstep(0.45, 0.48, t) * (1.0 - smoothstep(0.52, 0.55, t));
	ALBEDO = mix(color_inner.rgb, color_outer.rgb, t);
	ALPHA = dens * opacity * mix(color_inner.a, color_outer.a, t);
	ROUGHNESS = 0.95;
}
