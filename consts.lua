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
consts.pointIdSetSideLengthChunks = 10
consts.intensityPerPoint = 0.0001
consts.diskMeshVertices = 5
consts.pointLightBlurAngularRadius = 0.005
-- Derived
consts.chunkVolume = consts.chunkSize.x * consts.chunkSize.y * consts.chunkSize.z
consts.pointIdSetSize = consts.chunkSize * consts.pointIdSetSideLengthChunks
consts.chunksPerIdPointSet = consts.pointIdSetSideLengthChunks ^ 3
consts.maxStarsPerChunk = consts.chunkVolume * (1 + consts.starCountVariance) * consts.stellarDensityMultiplier + 1 -- + 1 for the random in getStarCount, just in case
consts.pointsPerIdSetMultiplier = 0.5 -- At the galactic core (highest star count), not all of each point id set is used. Save VRAM by assuming we will use less points than we would if every chunk had full density and they were all loaded.
consts.pointsPerIdSet = consts.chunksPerIdPointSet * consts.maxStarsPerChunk * consts.pointsPerIdSetMultiplier

consts.pointFadeRadius = 17
consts.cloudFadeRadius = 18

consts.maxPointIdSets = 8 -- Should be made to be derived from cloudFadeRadius, pointsPerIdSet, highest number of point id sets that can be in view, etc
-- Derived
consts.maxPoints = consts.maxPointIdSets * consts.pointsPerIdSet

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

-- Derived
-- local _, mipmapFrexpResult = math.frexp(consts.volumetricTextureSideLength)
-- consts.volumetricTextureMipmapCount = mipmapFrexpResult

return consts
