uniform float rayLength;
uniform ivec3 textureSize;
uniform mat4 clipToSky;
uniform vec3 cameraPosition;
uniform layout(r16f) image3D resultTexture;

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;
void computemain() {
	ivec2 screenPosition = ivec2(love_GlobalThreadID.xy);
	if (
		screenPosition.x >= textureSize.x ||
		screenPosition.y >= textureSize.y
	) {
		return;
	}

	vec3 direction = normalize((
		clipToSky * vec4(
			(vec2(screenPosition) + 0.5) / vec2(textureSize.xy) * 2.0 - 1.0,
			-1.0,
			1.0
		)
	).xyz);

	float rayStepSize = rayLength / float(textureSize.z);
	vec3 rayStepVec = direction * rayStepSize;
	vec3 currentPosition = cameraPosition;
	float transmittance = 1.0;

	// Ray moves forwards from camera to end
	RayNebulae rayNebulae = getNebulaeOnRay(cameraPosition, direction);
	for (int rayStep = 0; rayStep < textureSize.z; rayStep++) {
		imageStore(resultTexture, ivec3(screenPosition.xy, rayStep), vec4(transmittance, 0.0, 0.0, 0.0));

		VolumetricSample volumetricSample = sampleGalaxyWithoutNebulae(currentPosition);
		float attenuation = volumetricSample.attenuation;
		for (int i = 0; i < rayNebulae.count; i++) {
			attenuation += sampleNebulaAttenuation(rayNebulae.nebulaHitsOnRay[i].id, currentPosition);
		}

		transmittance *= exp(-attenuation * rayStepSize);
		currentPosition += rayStepVec;
	}
}
