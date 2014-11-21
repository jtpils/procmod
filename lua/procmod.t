local S = terralib.require("qs.lib.std")
local LS = terralib.require("lua.std")
local Mesh = terralib.require("mesh")(double)
local Vec = terralib.require("linalg.vec")
local BBox = terralib.require("bbox")
local BinaryGrid = terralib.require("binaryGrid3d")
local prob = terralib.require("lua.prob")
local smc = terralib.require("lua.smc")
local distrib = terralib.require("qs.distrib")

local Vec3 = Vec(double, 3)
local BBox3 = BBox(Vec3)

local globals = terralib.require("globals")

---------------------------------------------------------------

local VOXEL_FACTOR_WEIGHT = 0.01
-- local VOXEL_FILLED_FACTOR_WEIGHT = 0.01
-- local VOXEL_EMPTY_FACTOR_WEIGHT = 0.08
local OUTSIDE_FACTOR_WEIGHT = 0.01

---------------------------------------------------------------

local softeq = macro(function(val, target, s)
	return `[distrib.gaussian(double)].logprob(val, target, s)
end)

---------------------------------------------------------------

-- The procedural-modeling specific state that gets cached with
--    every particle/trace. Stores the mesh-so-far and the
--    grid-so-far, etc.
local struct State(S.Object)
{
	mesh: Mesh
	grid: BinaryGrid
	hasSelfIntersections: bool
	score: double
}
-- Also give the State class all the lua.std metatype stuff
LS.Object(State)

terra State:__init()
	self:initmembers()
	self.hasSelfIntersections = false
	self.score = 0.0
end

terra State:clear()
	self.mesh:clear()
	self.grid:clear()
	self.hasSelfIntersections = false
	self.score = 0.0 
end

terra State:update(newmesh: &Mesh, updateScore: bool)
	if updateScore then
		self.hasSelfIntersections =
			self.hasSelfIntersections or newmesh:intersects(&self.mesh)
		if not self.hasSelfIntersections then
			self.grid:resize(globals.targetGrid.rows,
							 globals.targetGrid.cols,
							 globals.targetGrid.slices)
			newmesh:voxelize(&self.grid, &globals.targetBounds, globals.VOXEL_SIZE, globals.SOLID_VOXELIZE)
		end
	end
	self.mesh:append(newmesh)
	if updateScore then
		-- Compute score
		if self.hasSelfIntersections then
			self.score = [-math.huge]
		else
			var meshbb = self.mesh:bbox()
			var targetext = globals.targetBounds:extents()
			var extralo = (globals.targetBounds.mins - meshbb.mins):max(Vec3.create(0.0)) / targetext
			var extrahi = (meshbb.maxs - globals.targetBounds.maxs):max(Vec3.create(0.0)) / targetext
			var percentOutside = extralo(0) + extralo(1) + extralo(2) + extrahi(0) + extrahi(1) + extrahi(2)
			var percentSame = globals.targetGrid:percentCellsEqualPadded(&self.grid)
			self.score = softeq(percentSame, 1.0, VOXEL_FACTOR_WEIGHT) +
				   		 softeq(percentOutside, 0.0, OUTSIDE_FACTOR_WEIGHT)
			-- var percentSameFilled = globals.targetGrid:percentFilledCellsEqualPadded(&self.grid)
			-- var percentSameEmpty = globals.targetGrid:percentEmptyCellsEqualPadded(&self.grid)
			-- self.score = softeq(percentSameFilled, 1.0, VOXEL_FILLED_FACTOR_WEIGHT) +
			-- 			 softeq(percentSameEmpty, 1.0, VOXEL_EMPTY_FACTOR_WEIGHT) +
			-- 			 softeq(percentOutside, 0.0, OUTSIDE_FACTOR_WEIGHT)
		end
	end
end

-- State for the currently executing program
local globalState = global(&State, 0)

---------------------------------------------------------------

-- Wrap a generative procedural modeling function such that it takes
--    a State as an argument and does the right thing with it.
local function statewrap(fn)
	return function(state)
		local prevstate = globalState:get()
		globalState:set(state)
		local succ, err = pcall(fn)
		globalState:set(prevstate)
		if not succ then
			error(err)
		end
	end
end

-- Generate symbols for the arguments to a geo prim function
local function geofnargs(geofn)
	local paramtypes = geofn:gettype().parameters
	local asyms = terralib.newlist()
	for i=2,#paramtypes do 	 -- Skip first arg (the mesh itself)
		asyms:insert(symbol(paramtypes[i]))
	end
	return asyms
end

---------------------------------------------------------------

-- Run sequential importance sampling on a procedural modeling program,
--    saving the generated meshes
-- 'outgenerations' is a cdata Vector(Vector(Sample(Mesh)))
-- Options are:
--    * recordHistory: record meshes all the way through, not just the final ones
--    * any other options recognized by smc.SIR
local function SIR(module, outgenerations, opts)

	local function makeGeoPrim(geofn)
		-- First, we make a Terra function that does all the perf-critical stuff:
		--    creates new geometry, tests for intersections, voxelizes, etc.
		local args = geofnargs(geofn)
		local terra update([args])
			var tmpmesh = Mesh.salloc():init()
			geofn(tmpmesh, [args])
			globalState:update(tmpmesh, true)
		end
		-- Now we wrap this in a Lua function that checks whether this work
		--    needs to be done at all
		return function(...)
			if smc.willStopAtNextSync() then
				update(...)
			end
			-- Always set the trace likelihood to be the current score
			prob.likelihood(globalState:get().score)
			-- If we're using stochastic futures, provide an opportunity to switch
			--    to a different future.
			prob.future.yield()
			-- SMC barrier synchronization
			smc.sync()
		end
	end

	-- Copy meshes from a Lua table of smc Particles to a cdata Vector of Sample(Mesh)
	local function copyMeshes(particles, outgenerations)
		local newgeneration = outgenerations:insert()
		LS.luainit(newgeneration)
		for _,p in ipairs(particles) do
			local samp = newgeneration:insert()
			-- The first arg of the particle's trace is the procmod State object.
			-- This is a bit funky, but I think it's the best way to get a this data.
			samp.value:copy(p.trace.args[1].mesh)
			-- samp.logprob = p.trace.logposterior
			-- samp.loglikelihood = p.trace.loglikelihood
			samp.logprob = p.trace.loglikelihood
		end
	end

	-- Install the SMC geo prim generator
	local program = module(makeGeoPrim)
	-- Wrap program so that it takes procmod State as argument
	program = statewrap(program)
	-- Create the beforeResample, afterResample, and exit callbacks
	local function dorecord(particles)
		copyMeshes(particles, outgenerations)
	end
	local newopts = LS.copytable(opts)
	newopts.exit = dorecord
	if opts.recordHistory then
		newopts.beforeResample = dorecord
		newopts.afterResample = dorecord
	end
	-- Run smc.SIR with an initial empty State object as argument
	local initstate = State.luaalloc():luainit()
	smc.SIR(program, {initstate}, newopts)
end

---------------------------------------------------------------

-- Just run the program forward without enforcing any constraints
-- Useful for development and debugging
local function ForwardSample(module, outgenerations, numsamples)

	local function makeGeoPrim(geofn)
		local args = geofnargs(geofn)
		return terra([args])
			var tmpmesh = Mesh.salloc():init()
			geofn(tmpmesh, [args])
			globalState:update(tmpmesh, false)
		end
	end

	local program = statewrap(module(makeGeoPrim))
	local state = State.luaalloc():luainit()
	local samples = outgenerations:insert()
	LS.luainit(samples)
	for i=1,numsamples do
		program(state)
		local samp = samples:insert()
		samp.value:copy(state.mesh)
		samp.logprob = 0.0
		state:clear()
	end
end

---------------------------------------------------------------

-- Like forward sampling, but reject any 0-probability samples
-- Keep running until numsamples have been accumulated
local function RejectionSample(module, outgenerations, numsamples)
	
	local function makeGeoPrim(geofn)
		local args = geofnargs(geofn)
		return terra([args])
			var tmpmesh = Mesh.salloc():init()
			geofn(tmpmesh, [args])
			globalState:update(tmpmesh, true)
		end
	end

	local program = statewrap(module(makeGeoPrim))
	local state = State.luaalloc():luainit()
	local samples = outgenerations:insert()
	LS.luainit(samples)
	while samples:size() < numsamples do
		program(state)
		if state.score > -math.huge then
			local samp = samples:insert()
			samp.value:copy(state.mesh)
			samp.logprob = state.score
		end
		state:clear()
	end
end

---------------------------------------------------------------

return
{
	Sample = terralib.require("qs").Sample(Mesh),
	SIR = SIR,
	ForwardSample = ForwardSample,
	RejectionSample = RejectionSample
}





