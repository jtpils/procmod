local S = terralib.require("qs.lib.std")
local smc = terralib.require("smc.smc")
local Mesh = terralib.require("mesh")(double)
local Vec3 = terralib.require("linalg.vec")(double, 3)
local Shapes = terralib.require("shapes")(double)
local tmath = terralib.require("qs.lib.tmath")


-- NOTE: subroutines are currently not allowed, so helper functions must be macros.


terralib.require("qs").initrand()


local spaceship = smc.program(function()

	local lerp = macro(function(lo, hi, t)
		return `(1.0-t)*lo + t*hi
	end)

	local addBox = smc.makeGeoPrim(Shapes.addBox)

	local addWingSeg = smc.makeGeoPrim(terra(mesh: &Mesh, xbase: double, zbase: double, xlen: double, ylen: double, zlen: double)
		Shapes.addBox(mesh, Vec3.create(xbase + 0.5*xlen, 0.0, zbase), xlen, ylen, zlen)
		Shapes.addBox(mesh, Vec3.create(-(xbase + 0.5*xlen), 0.0, zbase), xlen, ylen, zlen)
	end)

	local terra wi(i: int, w: double)
		return tmath.exp(-w*i)
	end
	wi:setinlined(true)

	local struct WingState
	{
		xbase: double,
		zlo: double,
		zhi: double,
		i: uint
	}
	WingState.methods.new = macro(function(stacks, xbase, zlo, zhi)
		return quote
			stacks.wings:insert(WingState {
				xbase = xbase,
				zlo = zlo,
				zhi = zhi,
				i = 0
			})
		end
	end)
	WingState.methods.advance = macro(function(self, mesh, stacks)
		return quote
			var zbase = smc.uniform(self.zlo, self.zhi)
			var xlen = smc.uniform(0.25, 2.0)
			var ylen = smc.uniform(0.25, 1.25)
			var zlen = smc.uniform(0.5, 4.0)
			addWingSeg(mesh, self.xbase, zbase, xlen, ylen, zlen)
			if smc.flip(wi(self.i, 0.6)) then
				stacks.wings:insert(WingState {
					xbase = self.xbase + xlen,
					zlo = zbase - 0.5*zlen,
					zhi = zbase + 0.5*zlen,
					i = self.i + 1
				})
			end
		end
	end)

	local struct FinState
	{
		ybase: double,
		zlo: double,
		zhi: double,
		xmax: double,
		i: uint
	}
	FinState.methods.new = macro(function(stacks, ybase, zlo, zhi, xmax)
		return quote
			stacks.fins:insert(FinState {
				ybase = ybase,
				zlo = zlo,
				zhi = zhi,
				xmax = xmax,
				i = 0
			})
		end
	end)
	FinState.methods.advance = macro(function(self, mesh, stacks)
		return quote
			var xlen = smc.uniform(0.5, 1.0) * self.xmax
			var ylen = smc.uniform(0.1, 0.5)
			var zlen = smc.uniform(0.5, 1.0) * (self.zhi - self.zlo)
			var zbase = 0.5*(self.zlo+self.zhi)
			addBox(mesh, Vec3.create(0.0, self.ybase + 0.5*ylen, zbase), xlen, ylen, zlen)
			if smc.flip(wi(self.i, 0.2)) then
				stacks.fins:insert(FinState {
					ybase = self.ybase + ylen,
					zlo = zbase - 0.5*zlen,
					zhi = zbase + 0.5*zlen,
					xmax = xlen,
					i = self.i + 1
				})
			end
		end
	end)


	local struct BodyState
	{
		rearz: double
		i: uint
	}
	local struct DecideIfWingState
	{
		i: uint,
		xlen: double,
		rearz: double,
		zlen: double
	}
	DecideIfWingState.methods.new = macro(function(stacks, i, xlen, rearz, zlen)
		return quote
			stacks.ifwings:insert(DecideIfWingState {
				i = i,
				xlen = xlen,
				rearz = rearz,
				zlen = zlen
			})
		end
	end)
	DecideIfWingState.methods.advance = macro(function(self, mesh, stacks)
		return quote
			var wingprob = wi(self.i+1, 0.5)
			if smc.flip(wingprob) then
				var xbase = 0.5*self.xlen
				var zlo = self.rearz + 0.5
				var zhi = self.rearz + self.zlen - 0.5
				WingState.new(stacks, xbase, zlo, zhi)
			end
		end
	end)
	local struct DecideIfFinState
	{
		ylen: double,
		rearz: double,
		zlen: double,
		xlen: double
	}
	DecideIfFinState.methods.new = macro(function(stacks, ylen, rearz, zlen, xlen)
		return quote
			stacks.iffins:insert(DecideIfFinState {
				ylen = ylen,
				rearz = rearz,
				zlen = zlen,
				xlen = xlen
			})
		end
	end)
	DecideIfFinState.methods.advance = macro(function(self, mesh, stacks)
		return quote
			-- Gen fin?
			var finprob = 0.7
			if smc.flip(finprob) then
				var ybase = 0.5*self.ylen
				var zlo = self.rearz
				var zhi = self.rearz + self.zlen
				var xmax = 0.6*self.xlen
				FinState.new(stacks, ybase, zlo, zhi, xmax)
			end
		end
	end)
	BodyState.methods.new = macro(function(stacks, rearz)
		return quote
			stacks.bodies:insert(BodyState {
				rearz = rearz,
				i = 0
			})
		end
	end)
	BodyState.methods.advance = macro(function(self, mesh, stacks)
		return quote
			var xlen = smc.uniform(1.0, 3.0)
			var ylen = smc.uniform(0.5, 1.0) * xlen
			var zlen = smc.uniform(2.0, 5.0)
			addBox(mesh, Vec3.create(0.0, 0.0, self.rearz + 0.5*zlen), xlen, ylen, zlen)
			if smc.flip(wi(self.i, 0.4)) then
				stacks.bodies:insert(BodyState {
					rearz = self.rearz + zlen,
					i = self.i + 1
				})
			end
			-- Gen wing?
			DecideIfWingState.new(stacks, self.i, xlen, self.rearz, zlen)
			-- Gen fin?
			DecideIfFinState.new(stacks, ylen, self.rearz, zlen, xlen)
		end
	end)

	local struct Stacks(S.Object)
	{
		bodies: S.Vector(BodyState),
		wings: S.Vector(WingState),
		fins: S.Vector(FinState),
		ifwings: S.Vector(DecideIfWingState),
		iffins: S.Vector(DecideIfFinState)
	}

	terra Stacks:size()
		var size = 0U
		escape
			for _,e in ipairs(Stacks.entries) do
				emit quote
					size = size + self.[e.field]:size()
				end
			end
		end
		return size
	end

	terra Stacks:isEmpty()
		return self:size() == 0
	end

	Stacks.methods.advanceRandom = macro(function(self, mesh)
		local function checkStack(entryIndex, i)
			if entryIndex > #Stacks.entries then
				return quote
					S.assert(false)
				end
			end
			local stack = `self.[Stacks.entries[entryIndex].field]
			return quote
				if i < stack:size() then
					var thing = stack:remove(i)
					thing:advance(mesh, self)
				else
					i = i - stack:size()
					[checkStack(entryIndex+1, i)]
				end
			end
		end
		local function checkStacks(i)
			return checkStack(1, i)
		end
		return quote
			var n = self:size()
			var i = smc.uniformInt(0, n)
			-- S.printf("i: %u, n: %u\n", i, n)
			[checkStacks(i)]
		end
	end)

	return smc.main(macro(function(mesh)
		return quote
			var stacks = Stacks.salloc():init()
			var rearz = -5.0
			BodyState.new(stacks, rearz)
			while not stacks:isEmpty() do
				stacks:advanceRandom(mesh)
			end
		end
	end))
end)


local N_PARTICLES = 200
local RECORD_HISTORY = true
local run = smc.run(spaceship)
return terra(generations: &S.Vector(S.Vector(smc.Sample)))
	generations:clear()
	run(N_PARTICLES, generations, RECORD_HISTORY, true)
end




