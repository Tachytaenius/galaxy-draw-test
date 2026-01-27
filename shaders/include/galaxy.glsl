// uniform float squashDirection; // galaxyForwards
uniform float squashAmount;
uniform float galaxyRadius;
uniform float haloProportion;
uniform vec3 galaxyForwards;
uniform vec3 galaxyUp;
uniform vec3 galaxyRight;
uniform float attenuationMultiplier;
uniform float intensityPerStar;
uniform float stellarDensityMultiplier;
uniform float stellarDensityCurvePower;
uniform float swirlAngleAtRadius;
uniform float coreProportion;
uniform float coreFullProportion;
uniform float armCount;

uniform sampler3D nebulaeTexture;
struct Nebula {
	vec3 position;
	vec3 size;
};
readonly buffer Nebulae {
	Nebula nebulae[];
};
uniform int nebulaCount;

vec2 rotate(vec2 v, float a) {
	float s = sin(a);
	float c = cos(a);
	mat2 m = mat2(c, s, -s, c);
	return m * v;
}

struct VolumetricSample {
	float attenuation;
	vec3 emission;
};

VolumetricSample sampleGalaxyWithoutNebulae(vec3 samplePosition) {
	float samplePositionElevation = dot(galaxyForwards, samplePosition);
	vec2 samplePosition2D = vec2(
		dot(galaxyRight, samplePosition),
		dot(galaxyUp, samplePosition)
	);
	vec2 samplePosition2DSwirled = rotate(samplePosition2D, swirlAngleAtRadius * length(samplePosition2D) / galaxyRadius);
	vec3 samplePositionSwirled =
		galaxyRight * samplePosition2D.x +
		galaxyUp * samplePosition2D.y +
		galaxyForwards * samplePositionElevation;

	float galaxyCoreFactor = clamp(1.0 - (length(samplePosition2D) - galaxyRadius * coreFullProportion) / (galaxyRadius * (coreProportion - coreFullProportion)) + 0.25, 0.0, 1.0);
	float armFactor =
		mix( // Mix between spiral arms and core with no arms
			pow(
				sin(atan(samplePosition2DSwirled.y, samplePosition2DSwirled.x) * float(armCount)) * 0.5 + 0.5,
				3.3 * length(samplePosition2D) / galaxyRadius
			),
			1.0,
			galaxyCoreFactor
		);
	float diskDensityMultiplier =
		armFactor * max(0.0, 1.0 - length(
			galaxyRight * samplePosition2D.x +
			galaxyUp * samplePosition2D.y +
			galaxyForwards * samplePositionElevation / squashAmount
		) / galaxyRadius);

	float haloDensityMultiplier = max(0.0, 1.0 - length(samplePosition) / galaxyRadius);

	float densityMultiplier = mix(diskDensityMultiplier, haloDensityMultiplier, haloProportion);
	densityMultiplier = clamp(densityMultiplier, 0.0, 1.0);
	float stellarDensity = stellarDensityMultiplier * pow(densityMultiplier, stellarDensityCurvePower);

	vec3 colour = vec3(1.0);
	vec3 emission = colour * intensityPerStar * stellarDensity;

	float attenuationNoise = 1.0;
	float attenuation = attenuationMultiplier * attenuationNoise * densityMultiplier;

	return VolumetricSample (
		attenuation,
		emission
	);
}

float sampleNebulaAttenuation(int nebulaId, vec3 samplePosition) {
	Nebula nebula = nebulae[nebulaId];
	vec3 texPosSingle = (samplePosition - nebula.position) / nebula.size * 0.5 + 0.5;
	if (
		texPosSingle.x < 0.0 || texPosSingle.x > 1.0 ||
		texPosSingle.y < 0.0 || texPosSingle.y > 1.0 ||
		texPosSingle.z < 0.0 || texPosSingle.z > 1.0
	) {
		return 0.0;
	}

	// TODO: Properly stop any bleeding, if this isn't right
	vec3 texPos = texPosSingle;
	texPosSingle.z = (texPosSingle.z + float(nebulaId)) / float(MAX_NEBULAE);

	return Texel(nebulaeTexture, texPos).r;
}

struct NebulaHit {
	float t1;
	float t2;
	int id;
};
struct RayNebulae {
	NebulaHit[MAX_NEBULAE] nebulaHitsOnRay;
	int count;
};
RayNebulae getNebulaeOnRay(vec3 rayStart, vec3 rayDirection) {
	NebulaHit[MAX_NEBULAE] result;
	int count = 0;

	for (int i = 0; i < nebulaCount; i++) {
		Nebula nebula = nebulae[i];
		ConvexRaycastResult raycastResult = sphereRaycast(
			nebula.position,
			max(
				max(
					nebula.size.x,
					nebula.size.y
				),
				nebula.size.z
			),
			rayStart,
			rayDirection
		);
		if (!raycastResult.hit) {
			continue;
		}
		if (raycastResult.t2 < 0.0) {
			continue;
		}
		result[count] = NebulaHit(max(0.0, raycastResult.t1), raycastResult.t2, i);
		count++;
	}

	return RayNebulae(result, count);
}
void sortNebulaeOnRayFurthestFirst(inout RayNebulae list) {
	// Insertion sort
	int i = 1;
	while (i < list.count) {
		int j = i;
		while (j > 0 && list.nebulaHitsOnRay[j - 1].t1 < list.nebulaHitsOnRay[j].t1) {
			// Swap
			NebulaHit temp = list.nebulaHitsOnRay[j - 1];
			list.nebulaHitsOnRay[j - 1] = list.nebulaHitsOnRay[j];
			list.nebulaHitsOnRay[j] = temp;
			j--;
		}
		i++;
	}
}
