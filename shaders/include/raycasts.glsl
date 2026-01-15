struct ConvexRaycastResult {
	bool hit;
	float t1;
	float t2;
};
const ConvexRaycastResult convexRaycastMiss = ConvexRaycastResult(false, 0.0, 0.0);

ConvexRaycastResult sphereRaycast(vec3 spherePosition, float sphereRadius, vec3 rayStart, vec3 rayDirection) {
	vec3 sphereToStart = rayStart - spherePosition;
	float b = dot(sphereToStart, rayDirection);
	vec3 qc = sphereToStart - b * rayDirection;
	float h = sphereRadius * sphereRadius - dot(qc, qc);
	if (h < 0.0) {
		return convexRaycastMiss;
	}
	float sqrtH = sqrt(h);
	float t1 = -b - sqrtH;
	float t2 = -b + sqrtH;
	return ConvexRaycastResult(true, t1, t2);
}
