uniform layout(r16f) writeonly image3D attenuation;
uniform layout(rgba16f) writeonly image3D emission;

uniform vec3 textureSize; // Spatially, not in pixels

uniform float intensityPerPoint;

float vmax(vec3 v) {
	return max(max(v.x, v.y), v.z);
}

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;
void computemain() {
	ivec3 xyz = ivec3(gl_GlobalInvocationID.xyz);
	ivec3 whd = imageSize(attenuation);
	if (xyz.x > whd.x || xyz.y > whd.y || xyz.z > whd.z) {
		return;
	}
	vec3 position = (vec3(xyz) / vec3(whd)) * textureSize;

	// float numberDensity =
	vec3 emissionAmount = vec3(intensityPerPoint * numberDensity);

	imageStore(attenuation, xyz, vec4(0.0, 0.0, 0.0, 1.0));
	imageStore(emission, xyz, vec4(emissionAmount, 1.0));
}
