local consts = {}

local vec3 = require("lib.mathsies").vec3

consts.tau = math.pi * 2

consts.rightVector = vec3(1, 0, 0)
consts.upVector = vec3(0, 1, 0)
consts.forwardVector = vec3(0, 0, 1)

consts.controls = {
	moveRight = "d",
	moveLeft = "a",
	moveUp = "e",
	moveDown = "q",
	moveForwards = "w",
	moveBackwards = "s",

	pitchDown = "k",
	pitchUp = "i",
	yawRight = "l",
	yawLeft = "j",
	rollAnticlockwise = "u",
	rollClockwise = "o"
}

consts.maxDeltaTime = 0.3

consts.starAttenuationTextureSteps = 48

consts.maxNebulae = 8
consts.nebulaResolution = 48
consts.minNebulaSize = 2
consts.maxNebulaSize = 10

consts.rayLength = 2000
consts.rayStepCount = 96
consts.nebulaStepCount = 32
consts.volumetricsCanvasFilter = "linear"

consts.starCountVariance = 0 -- Nonzero creates a blocky "texture" in the distribution of stars
consts.pointLightComputeThreadgroupSize = 64

consts.stellarDensityMultiplier = 7.5

consts.chunkSize = vec3(4)
consts.pointSetFreeRangeMultiplier = 1.2 -- Must be >= 1
consts.intensityPerPoint = 0.0001
consts.diskMeshVertices = 5
consts.pointLightBlurAngularRadius = 0.005
-- Derived
consts.chunkVolume = consts.chunkSize.x * consts.chunkSize.y * consts.chunkSize.z
consts.maxStarsPerChunk = math.ceil(consts.chunkVolume * (1 + consts.starCountVariance) * consts.stellarDensityMultiplier) + 1 -- + 1 for the random in getStarCount, just in case

consts.starCanvasScale = 1
consts.cloudCanvasScale = 1

consts.pointFadeRadius = 22
consts.cloudFadeRadius = 24

-- Derived
consts.chunkRange = vec3(
	math.ceil(consts.cloudFadeRadius * 2 / consts.chunkSize.x) + 1,
	math.ceil(consts.cloudFadeRadius * 2 / consts.chunkSize.y) + 1,
	math.ceil(consts.cloudFadeRadius * 2 / consts.chunkSize.z) + 1
)
consts.chunksInRange = consts.chunkRange.x * consts.chunkRange.y * consts.chunkRange.z
consts.maxPoints = consts.chunksInRange * consts.maxStarsPerChunk

consts.blurredPointVertexFormat = {
	{name = "VertexPosition", location = 0, format = "floatvec2"},
	{name = "VertexFade", location = 1, format = "float"}
}
consts.blurredPointBufferFormat = {
	{name = "direction", format = "floatvec3"},
	{name = "incomingLight", format = "floatvec3"}
}
consts.lightSourceBufferFormat = {
	{name = "position", format = "floatvec3"},
	{name = "luminousFlux", format = "float"},
	{name = "colour", format = "floatvec3"}
}
consts.floatsPerLightSource = 7 -- Must match above
consts.nebulaeBufferFormat = {
	{name = "position", format = "floatvec3"},
	{name = "size", format = "floatvec3"}
}
consts.indirectDrawBufferFormat = {
	{name = "vertexCount", format = "uint32"},
	{name = "instanceCount", format = "uint32"},
	{name = "baseVertex", format = "uint32"},
	{name = "baseInstance", format = "uint32"}
}

-- Derived
-- local _, mipmapFrexpResult = math.frexp(consts.volumetricTextureSideLength)
-- consts.volumetricTextureMipmapCount = mipmapFrexpResult

return consts
