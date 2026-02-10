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
consts.minNebulaSize = 2e18
consts.maxNebulaSize = 1e19

consts.rayLength = 4e20*2.5
consts.rayStepCount = 128
consts.nebulaStepCount = 32
consts.volumetricsCanvasFilter = "linear"

consts.starCountVariance = 0 -- Nonzero creates a blocky "texture" in the distribution of stars
consts.pointLightComputeThreadgroupSize = 64

consts.stellarDensityMultiplier = 4.72e-51 -- Stellar density near the sun

consts.chunkSize = vec3(4e17)

consts.starLuminousFluxUpperLimit = 3.75e28 -- Luminous flux of the sun
consts.starLuminousFluxLowerLimit = 4.33e26 -- Red dwarf stars have luminosities in the range of 0.0003 to 0.07 times that of the sun. We pick the middle, then multiply it by a red dwarf luminous efficacy figure I found of 32.2 lm/W. Thus, average red dwarf star luminous flux (maybe)
consts.starDistributionRandomPower = 10 -- Higher numbers bias towards lower limit. The limits can be swapped around

-- Derived
consts.starIntensityUpperLimit = consts.starLuminousFluxUpperLimit / (consts.tau * 2)
consts.starIntensityLowerLimit = consts.starLuminousFluxLowerLimit / (consts.tau * 2)
-- Point intensity is lower + (upper - lower) * random ^ power, so this is the average:
consts.intensityPerPoint = consts.starIntensityLowerLimit + (consts.starIntensityUpperLimit - consts.starIntensityLowerLimit) / (consts.starDistributionRandomPower + 1)

consts.diskMeshVertices = 5
consts.pointLightBlurAngularRadius = 0.005
-- Derived
consts.chunkVolume = consts.chunkSize.x * consts.chunkSize.y * consts.chunkSize.z
consts.maxStarsPerChunk = math.ceil(consts.chunkVolume * (1 + consts.starCountVariance) * consts.stellarDensityMultiplier) + 1 -- + 1 for the random in getStarCount, just in case

consts.starCanvasScale = 1
consts.cloudCanvasScale = 0.75

consts.cloudFadeRadius = consts.chunkSize.x * 8
consts.pointFadeRadius = consts.cloudFadeRadius * 0.9

consts.outputLuminanceMultiplier = 1 / 0.0005

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
