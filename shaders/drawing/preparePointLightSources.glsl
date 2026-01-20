readonly buffer ChunkStarCounts {
	int chunkStarCounts[];
};
uniform int maxStarsPerChunk;
uniform int chunksStart;

struct LightSource {
	vec3 position;
	float luminousIntensity;
	vec3 colour;
};
readonly buffer LightSources {
	LightSource lightSources[];
};

struct Point {
	vec3 direction;
	vec3 incomingLight;
};
writeonly buffer Points {
	Point points[];
};

uniform uint pointStart;
uniform uint pointCount;
uniform uint skipIndex;
uniform vec3 cameraPosition;
uniform mat4 skyToClip;
uniform sampler3D starAttenuationTexture;

uniform float fadeInRadius;
uniform float fadeOutRadius;

vec3 perspectiveDivide(vec4 v) {
	return v.xyz / v.w;
}

layout(local_size_x = THREADGROUP_SIZE, local_size_y = 1, local_size_z = 1) in;
void computemain() {
	uint i = love_GlobalThreadID.x + pointStart;
	if (i >= pointStart + pointCount) {
		return;
	}

	LightSource lightSource = lightSources[i];
	vec3 difference = lightSource.position - cameraPosition;
	float dist = length(difference);

	float dist2 = dist * dist;
	vec3 direction = difference / dist;

	float pointFadeMultiplier = clamp(
		1.0 - (dist - fadeInRadius) / (fadeOutRadius - fadeInRadius),
		0.0, 1.0
	);

	float luminance = lightSource.luminousIntensity / dist2;
	vec3 incomingLightPreExtinction = luminance * lightSource.colour * pointFadeMultiplier;
	vec3 clipSpacePos = perspectiveDivide(skyToClip * vec4(direction, 1.0));
	vec3 textureSamplePos = clipSpacePos;
	textureSamplePos.xy = textureSamplePos.xy * 0.5 + 0.5;
	textureSamplePos.z = dist / fadeOutRadius;
	float transmittance = Texel(starAttenuationTexture, textureSamplePos).r;

	bool skip =
		i == skipIndex ||
		maxStarsPerChunk >= 0 &&
			(int(i) - chunksStart) % maxStarsPerChunk >= chunkStarCounts[
				(int(i) - chunksStart) / maxStarsPerChunk
			];

	Point point = Point (
		direction,
		skip ? vec3(0.0) : transmittance * incomingLightPreExtinction
	);
	points[i] = point;
}
