uniform layout(r16f) writeonly image3D nebulaeTexture;

uniform int nebulaTextureResolution;
uniform int nebulaId;

uniform vec3 nebulaPosition;
uniform vec3 nebulaSize; // Spatially, not in pixels

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;
void computemain() {
	ivec3 whd = ivec3(nebulaTextureResolution);
	ivec3 xyz = ivec3(gl_GlobalInvocationID.xyz);
	if (xyz.x > whd.x || xyz.y > whd.y || xyz.z > whd.z) {
		return;
	}
	ivec3 writePos = xyz + ivec3(nebulaId * whd.x, 0, 0);
	vec3 overallPos = vec3(xyz) / vec3(whd) * 2.0 - 1.0; // Had no idea what to call this? Some might say normalised coords, but...
	float fadeout = max(0.0, 0.95 - length(overallPos)); // 0.95 instead of 1.0 to make it reach complete transparency slightly before the boundary so that texture filtering works OK

	vec3 position = nebulaPosition + nebulaSize * overallPos;

	// float noiseValue = pow(max(0.0, snoise(position / (nebulaSize / 4.0)) * 0.5 + 0.5), 5.0);
	// float noiseValue = max(0.0, 0.05 * voronoiDistance(position.xy / (nebulaSize.xy / 10.0)));
	vec3 shift = vec3(
		snoise(vec4(nebulaPosition + overallPos / 1.8 * (length(overallPos) + 1.5), 0.0)) * 0.5 + 0.5,
		snoise(vec4(nebulaPosition + overallPos / 1.8 * (length(overallPos) + 1.5), 5.0)) * 0.5 + 0.5,
		snoise(vec4(nebulaPosition + overallPos / 1.8 * (length(overallPos) + 1.5), 10.0)) * 0.5 + 0.5
	);
	vec3 newSamplePos = overallPos + shift * 0.3;
	float noiseValue = pow(max(0.0, snoise(nebulaPosition + newSamplePos / 0.8) * 0.5 + 0.5), 5.0);
	float strength = (snoise(vec4(nebulaPosition + overallPos / 8.0, 15.0)) * 0.5 + 0.5) * 75.0 + 25.0;
	float attenuation = fadeout * (
		pow(max(0.0, noiseValue), 2.5) * strength +
		pow(max(0.0, fadeout), 2.0) * 1.5
	);

	imageStore(nebulaeTexture, writePos, vec4(attenuation, 0.0, 0.0, 1.0));
}
