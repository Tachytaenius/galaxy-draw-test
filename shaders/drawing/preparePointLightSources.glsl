readonly buffer ChunkStarCounts {
	int chunkStarCounts[];
};
uniform int maxStarsPerChunk;
uniform int chunksStart;

struct LightSource {
	vec3 position;
	float luminousFlux;
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

struct IndirectDrawArgs {
	uint vertexCount;
	uint instanceCount;
	uint baseVertex;
	uint baseInstance;
};
buffer IndirectDrawBuffer {
	IndirectDrawArgs indirectDrawBuffer[];
};

uniform uint pointStart;
uniform uint pointCount;
uniform uint skipIndex;
uniform vec3 cameraPosition;
uniform mat4 skyToClip;
uniform sampler3D starAttenuationTexture;
uniform ivec3 chunkBufferSize;
uniform vec3 viewMinFloatLocationInChunkBuffer;
uniform float luminanceCalculationConstant;

uniform float fadeInRadius;
uniform float fadeOutRadius;

uniform vec3 cameraForwards;
uniform float minDot;

vec3 perspectiveDivide(vec4 v) {
	return v.xyz / v.w;
}

ivec3 bvecToIvec(bvec3 v) {
	return ivec3(
		v.x ? 1 : 0,
		v.y ? 1 : 0,
		v.z ? 1 : 0
	);
}

layout(local_size_x = THREADGROUP_SIZE, local_size_y = 1, local_size_z = 1) in;
void computemain() {
	uint i = love_GlobalThreadID.x + pointStart;
	if (i >= pointStart + pointCount) {
		return;
	}

	if (i == skipIndex) {
		return;
	}

	if (
		maxStarsPerChunk >= 0 &&
		(int(i) - chunksStart) % maxStarsPerChunk >= chunkStarCounts[
			(int(i) - chunksStart) / maxStarsPerChunk
		]
	) {
		return;
	}

	int chunkIndex = (int(i) - chunksStart) / maxStarsPerChunk;
	ivec3 chunkBufferPos = ivec3(
		chunkIndex % chunkBufferSize.x,
		(chunkIndex / chunkBufferSize.x) % chunkBufferSize.y,
		(chunkIndex / chunkBufferSize.x) / chunkBufferSize.y
	);

	LightSource lightSource = lightSources[i];
	ivec3 chunkPos = chunkBufferPos + chunkBufferSize * bvecToIvec(lessThan(chunkBufferPos, viewMinFloatLocationInChunkBuffer));
	vec3 lightSourcePosition = chunkPos + lightSource.position;
	vec3 difference = lightSourcePosition - cameraPosition;

	float dist = length(difference);
	vec3 direction = difference / dist;

	float dotResult = dot(cameraForwards, direction);
	if (dotResult < minDot) {
		return;
	}

	float dist2 = dist * dist;

	float pointFadeMultiplier = clamp(
		1.0 - (dist - fadeInRadius) / (fadeOutRadius - fadeInRadius),
		0.0, 1.0
	);

	float luminance = lightSource.luminousFlux / dist2 * luminanceCalculationConstant; // Luminance within the star's spherical cap on the celestial sphere. All combined, it should be flux / (dist^2 * 4pi * diskSolidAngle), where flux / (dist^2 * 4pi) takes it from luminous flux to luminous exitance (I think) and then the exitance divided by the disk solid angle gets you the luminance. I think.
	vec3 incomingLightPreExtinction = luminance * lightSource.colour * pointFadeMultiplier;
	vec3 clipSpacePos = perspectiveDivide(skyToClip * vec4(direction, 1.0));
	vec3 textureSamplePos = clipSpacePos;
	textureSamplePos.xy = textureSamplePos.xy * 0.5 + 0.5;
	textureSamplePos.z = dist / fadeOutRadius;
	float transmittance = Texel(starAttenuationTexture, textureSamplePos).r;

	Point point = Point (
		direction,
		transmittance * incomingLightPreExtinction
	);
	uint pointsIndex = atomicAdd(indirectDrawBuffer[0].instanceCount, 1);
	points[pointsIndex] = point;
}
