#pragma language glsl4

const float tau = 6.28318530717958647692528676655900576839433879875021164194988918461563281257241799725606965068423413; // Thanks OEIS

// Assumes additive mode

varying float fade;
varying vec3 colour;

// These depend on angular radius
uniform float diskDistanceToSphere;
uniform float scale;
uniform float diskArea;

#ifdef VERTEX

#ifdef INSTANCED
struct Point {
	vec3 direction;
	vec3 incomingLight;
};
readonly buffer Points {
	Point points[];
};
uniform uint pointStart;
#else
uniform vec3 direction;
uniform vec3 incomingLight;
#endif

uniform vec3 cameraUp;
uniform vec3 cameraRight;
uniform mat4 worldToClip;

layout (location = 0) in vec2 VertexPosition;
layout (location = 1) in float VertexFade;

void vertexmain() {
	fade = VertexFade;

#ifdef INSTANCED
	uint i = gl_InstanceID + pointStart;
	Point point = points[i];
	colour = point.incomingLight;
	vec3 direction = point.direction;
#else
	colour = incomingLight;
#endif

	vec3 billboardRight = cross(cameraUp, direction);
	if (length(billboardRight) == 0.0) {
		// Singularity
		billboardRight = cameraRight;
	}
	vec3 billboardUp = cross(direction, billboardRight);
	vec3 centre = direction * (1.0 - diskDistanceToSphere);
	vec3 celestialSpherePos = centre + scale * (billboardRight * VertexPosition.x + billboardUp * VertexPosition.y);
	gl_Position = worldToClip * vec4(celestialSpherePos, 1.0);
}

#endif

#ifdef PIXEL

out vec4 outColour;

void pixelmain() {
	if (colour == vec3(0.0)) {
		discard;
	}
	// float fadeMultiplier = 1.0 - fade;
	outColour = vec4(colour / diskArea, 1.0);
}

#endif
