uniform float multiplier;

vec4 effect(vec4 loveColour, sampler2D image, vec2 textureCoords, vec2 windowCoords) {
	vec4 col = loveColour * Texel(image, textureCoords);
	col.rgb *= multiplier;
	return col;
}
