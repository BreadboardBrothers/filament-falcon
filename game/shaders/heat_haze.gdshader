shader_type spatial;
// Heat shimmer behind the engine: refracts the scene through moving noise. Strength follows
// the throttle; strongest near the nozzle, fades along the plume and at grazing angles.
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

#include "res://shaders/noise.gdshaderinc"

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float strength = 0.0;
uniform float time = 0.0;

varying vec3 lp;

void vertex() {
	lp = VERTEX;
}

void fragment() {
	float along = clamp(-lp.y, 0.0, 1.0);
	float fres = pow(abs(dot(normalize(NORMAL), normalize(VIEW))), 2.0);
	vec2 n = vec2(vnoise(vec3(lp.x * 4.0, along * 9.0 - time * 14.0, lp.z * 4.0)),
		vnoise(vec3(lp.z * 4.0 + 5.0, along * 9.0 - time * 12.0, lp.x * 4.0))) - 0.5;
	float amt = strength * fres * (1.0 - along) * 0.012;
	ALBEDO = textureLod(screen_tex, SCREEN_UV + n * amt, 0.0).rgb;
	// Fade the proxy as well as its refraction toward the tail.
	ALPHA = clamp(strength * fres * 1.5, 0.0, 1.0) * pow(1.0 - along, 2.0);
}
