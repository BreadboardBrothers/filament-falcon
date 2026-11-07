shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, fog_disabled;

uniform sampler2D galaxy_image : source_color, filter_linear_mipmap, repeat_disable;
uniform bool has_image = false;
uniform vec4 tint : source_color = vec4(0.7, 0.75, 0.9, 1.0);

void fragment() {
    vec2 p = UV * 2.0 - 1.0;
    // Zero at every quad edge, including opaque/non-black photographic borders.
    float edge = 1.0 - smoothstep(0.72, 1.0, max(abs(p.x), abs(p.y)));
    if (has_image) {
        vec4 photo = texture(galaxy_image, UV);
        // Galaxy photos commonly use JPEG black backgrounds: key only this
        // material, never the generic planet texture loader. Retain source alpha.
        float luminance = max(photo.r, max(photo.g, photo.b));
        ALBEDO = photo.rgb;
        ALPHA = photo.a * smoothstep(0.015, 0.12, luminance) * edge * 0.95;
    } else {
        // Offline schematic: a soft elliptical glow, not a painted rectangle.
        float r2 = dot(p, p);
        float glow = exp(-r2 * 5.0) * (1.0 - smoothstep(0.45, 1.0, length(p)));
        ALBEDO = tint.rgb;
        ALPHA = glow * edge * 0.55;
    }
}
