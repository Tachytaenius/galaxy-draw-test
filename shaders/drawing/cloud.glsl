#ifdef PIXEL

uniform vec3 cameraPosition;
uniform float rayLength;
uniform uint rayStepCount;
uniform int nebulaStepCount;

// uniform vec3 textureSize; // Spatially, not in pixels

uniform sampler3D attenuation;
uniform sampler3D emission;

uniform float fadeInRadius;
uniform float fadeOutRadius;

// VolumetricSample sampleVolumetrics(vec3 position) {
// 	vec3 textureCoords = position / textureSize;
// 	return VolumetricSample (
// 		Texel(attenuation, textureCoords).r,
// 		Texel(emission, textureCoords).rgb
// 	);
// }

vec3 getRayColour(vec3 rayPosition, vec3 rayDirection) {
	vec3 totalRayLight = vec3(0.0);
	float totalTransmittance = 1.0;
	// Ray moves backwards from end to camera
	// We increase detail towards camera
	// Sample in the middle of each ray segment
	// Raymarch through nebulae on (or after) each segment
	RayNebulae rayNebulae = getNebulaeOnRay(rayPosition, rayDirection);
	sortNebulaeOnRayFurthestFirst(rayNebulae);
	int nebulaCheckStart = 0;

	float segmentStart = rayLength;
	for (uint rayStep = 0u; rayStep < rayStepCount; rayStep++) {
		float segmentEnd = rayLength * pow((1.0 - float(rayStep) / float(rayStepCount)), 2.5);
		float rayStepSize = segmentStart - segmentEnd; // Start is greater than end

		float sampleT = mix(segmentEnd, segmentStart, 0.5);
		vec3 samplePosition = rayPosition + rayDirection * sampleT;

		float emissionFadeMultiplier = clamp(
			(sampleT - fadeInRadius) / (fadeOutRadius - fadeInRadius),
			0.0, 1.0
		);

		float transmittanceThisStep = 1.0;

		for (int i = nebulaCheckStart; i < rayNebulae.count; i++) {
			NebulaHit hit = rayNebulae.nebulaHitsOnRay[i];
			if (segmentStart <= hit.t2) { // segmentStart (decreasing) went past nebula t2, which is where this shader's rays enter the nebula first (the side furthest from the camera). This means we are in (or past) the nebula and need to use it on this step.
				float nebulaSegmentLength = hit.t2 - hit.t1;
				float nebulaSegmentStepSize = nebulaSegmentLength / float(nebulaStepCount);
				for (uint nebulaStep = 0u; nebulaStep < nebulaStepCount; nebulaStep++) {
					// Don't bother sampling the rest of the galaxy at each step, it shouldn't vary much over the small scale of a nebula. Just get the attenuation from the nebula.
					vec3 nebulaSamplePosition = rayPosition + rayDirection * mix(hit.t1, hit.t2, (float(nebulaStep) + 0.5) / float(nebulaStepCount));
					float nebulaAttenuationHere = sampleNebulaAttenuation(hit.id, nebulaSamplePosition);
					transmittanceThisStep *= exp(-nebulaAttenuationHere * nebulaSegmentStepSize);
				}
				nebulaCheckStart = i + 1; // Nebula done, don't read from it again on this ray
			} else {
				// We haven't gone through this nebula yet, so wait to make more progress.
				break;
			}
		}

		VolumetricSample volumetricSample = sampleGalaxyWithoutNebulae(samplePosition);
		float attenuation = volumetricSample.attenuation;
		transmittanceThisStep *= exp(-attenuation * rayStepSize);

		vec3 rayLightThisStep = rayStepSize * volumetricSample.emission * emissionFadeMultiplier;
		totalRayLight = totalRayLight * transmittanceThisStep + rayLightThisStep;
		totalTransmittance *= transmittanceThisStep;

		segmentStart = segmentEnd;
	}
	return totalRayLight;
}

vec4 effect(vec4 loveColour, sampler2D image, vec2 textureCoords, vec2 windowCoords) {
	vec3 direction = normalize(directionPreNormalise);
	vec3 outColour = getRayColour(cameraPosition, direction);
	return vec4(outColour, 1.0);
}

#endif
