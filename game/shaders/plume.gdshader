shader_type spatial;
// Additive rocket exhaust plume: shock diamonds in air, wide faint bell in vacuum.
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

#include "res://shaders/noise.gdshaderinc"

uniform float throttle = 0.0;
uniform float vacuum = 0.0;
uniform float time = 0.0;
uniform vec3 core_color : source_color = vec3(1.0, 0.75, 0.45);
uniform vec3 edge_color : source_color = vec3(0.35, 0.55, 1.0);

varying vec3 lp;

void vertex() {
	lp = VERTEX;
	// Radius is fixed at the actual nozzle lip. Vacuum fans out ONLY aft.
	float along = clamp(-VERTEX.y, 0.0, 1.0);
	VERTEX.xz *= 1.0 + (1.0 + vacuum * 6.0) * pow(along, 1.4);
}

void fragment() {
	// mesh: cylinder along local -Y from 0 (nozzle) to -1 (tail), radius 1
	float along = clamp(-lp.y, 0.0, 1.0);
	float r = length(lp.xz);
	float fres = pow(abs(dot(normalize(NORMAL), normalize(VIEW))), 1.5);
	float diamonds = 0.6 + 0.4 * sin(along * 38.0 - time * 3.0) * (1.0 - vacuum);
	float flicker = 0.8 + 0.4 * vnoise(vec3(lp.x * 3.0, along * 12.0 - time * 30.0, lp.z * 3.0));
	float fade = pow(1.0 - along, 1.6 + vacuum * 0.8);
	vec3 col = mix(core_color, edge_color, along * 0.6 + vacuum * 0.4);
	ALBEDO = col * fres * fade * smoothstep(0.0, 0.02, along) * diamonds * flicker * throttle * (3.5 - vacuum * 1.5);
}
