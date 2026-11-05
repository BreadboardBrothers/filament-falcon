shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 albedo_color : source_color = vec4(0.6, 0.6, 0.6, 1.0);
uniform sampler2D day_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D night_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D cloud_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform bool use_day = false;
uniform bool use_night = false;
uniform bool use_clouds = false;
uniform bool use_normal = false;
uniform bool is_star = false;
uniform float emissive_boost = 0.0;
uniform float atmosphere = 0.0;
uniform vec3 atmo_color = vec3(0.4, 0.65, 1.0);
uniform float cloud_opacity = 0.45;
uniform float roughness_f = 0.85;
uniform float metalness_f = 0.0;

varying vec3 v_n;
varying vec3 v_v;

void vertex() {
	v_n = NORMAL;
	v_v = VERTEX;
}

void fragment() {
	vec3 n = normalize(v_n);
	vec2 uv = UV;
	vec3 day = albedo_color.rgb;
	if (use_day) {
		day = texture(day_tex, uv).rgb;
	}
	float ndl = clamp(dot(n, normalize(vec3(0.4, 0.2, 1.0))), 0.0, 1.0); // filler; light comes from DirectionalLight
	// Godot lights handle diffuse; we just set ALBEDO / EMISSION
	ALBEDO = day;
	ROUGHNESS = roughness_f;
	METALLIC = metalness_f;
	if (use_normal) {
		NORMAL_MAP = texture(normal_tex, uv).xyz;
		NORMAL_MAP_DEPTH = 0.7;
	}
	if (use_night) {
		vec3 night = texture(night_tex, uv).rgb;
		// night lights where unlit — approximate with view-space light hint via COLOR unused; use emission gated by a soft factor
		EMISSION += night * 1.6 * (1.0 - smoothstep(0.0, 0.35, abs(dot(n, vec3(0.0, 0.0, 1.0)))));
	}
	if (use_clouds) {
		float c = texture(cloud_tex, uv).r;
		ALBEDO = mix(ALBEDO, vec3(1.0), c * cloud_opacity);
	}
	if (is_star) {
		EMISSION = day * (2.5 + emissive_boost);
		ALBEDO = day;
	} else if (emissive_boost > 0.0) {
		EMISSION += day * emissive_boost;
	}
	if (atmosphere > 0.0) {
		float fres = pow(1.0 - clamp(dot(normalize(-v_v), n), 0.0, 1.0), 2.5);
		EMISSION += atmo_color * fres * atmosphere;
	}
}
