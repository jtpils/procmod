local S = terralib.require("qs.lib.std")
local gl = terralib.require("gl.gl")
local Vec = terralib.require("linalg.vec")
local Mat = terralib.require("linalg.mat")
local BBox = terralib.require("bbox")
local BinaryGrid = terralib.require("binaryGrid3d")
local Intersections = terralib.require("intersection")


-- Super simple mesh struct that can accumulate geometry and draw itself

local Mesh = S.memoize(function(real)

	assert(real == float or real == double,
		"Mesh: real must be float or double")

	local Vec3 = Vec(real, 3)
	local Mat4 = Mat(real, 4, 4)
	local BBox3 = BBox(Vec3)

	local glVertex = real == float and gl.glVertex3fv or gl.glVertex3dv
	local glNormal = real == float and gl.glNormal3fv or gl.glNormal3dv

	local struct Mesh(S.Object)
	{
		vertices: S.Vector(Vec3),
		normals: S.Vector(Vec3),
		indices: S.Vector(uint)
	}

	terra Mesh:draw()
		-- Just simple immediate mode drawing for now
		gl.glBegin(gl.mGL_TRIANGLES())
		for i in self.indices do
			glNormal(&(self.normals(i).entries[0]))
			glVertex(&(self.vertices(i).entries[0]))
		end
		gl.glEnd()
	end

	terra Mesh:clear()
		self.vertices:clear()
		self.normals:clear()
		self.indices:clear()
	end

	terra Mesh:append(other: &Mesh)
		var nverts = self.vertices:size()
		for ov in other.vertices do
			self.vertices:insert(ov)
		end
		for on in other.normals do
			self.normals:insert(on)
		end
		for oi in other.indices do
			self.indices:insert(oi + nverts)
		end
	end

	terra Mesh:transform(xform: &Mat4)
		for i=0,self.vertices:size() do
			self.vertices(i) = xform:transformPoint(self.vertices(i))
		end
		-- TODO: Implement 4x4 matrix inversion and use the inverse transpose
		--    for the normals (I expect to only use rotations and uniform scales
		--    for the time being, so this should be fine for now).
		for i=0,self.normals:size() do
			self.normals(i) = xform:transformVector(self.normals(i))
		end
	end

	terra Mesh:bbox()
		var bbox : BBox3
		bbox:init()
		for v in self.vertices do
			bbox:expand(v)
		end
		return bbox
	end

	local Vec2 = Vec(real, 2)
	local Intersection = Intersections(real)
	local terra voxelizeTriangle(outgrid: &BinaryGrid, v0: Vec3, v1: Vec3, v2: Vec3, solid: bool) : {}
		var tribb = BBox3.salloc():init()
		tribb:expand(v0); tribb:expand(v1); tribb:expand(v2)
		-- If a triangle is perfectly axis-aligned, it will 'span' zero voxels, so the loops below
		--    will do nothing. To get around this, we expand the bbox a little bit.
		tribb:expand(0.000001)
		var minI = tribb.mins:floor()
		var maxI = tribb.maxs:ceil()
		-- Take care to ensure that we don't loop over any voxels that are outside the actual grid.
		minI:maxInPlace(Vec3.create(0.0))
		maxI:minInPlace(Vec3.create(real(outgrid.cols), real(outgrid.rows), real(outgrid.slices)))
		-- S.printf("===========================\n")
		-- S.printf("mins: %g, %g, %g   |   maxs: %g, %g, %g\n",
		-- 	tribb.mins(0), tribb.mins(1), tribb.mins(2), tribb.maxs(0), tribb.maxs(1), tribb.maxs(2))
		-- S.printf("minI: %g, %g, %g   |   maxi: %g, %g, %g\n",
		-- 	minI(0), minI(1), minI(2), maxI(0), maxI(1), maxI(2))
		for k=uint(minI(2)),uint(maxI(2)) do
			for i=uint(minI(1)),uint(maxI(1)) do
				for j=uint(minI(0)),uint(maxI(0)) do
					var v = Vec3.create(real(j), real(i), real(k))
					var voxel = BBox3.salloc():init(
						v,
						v + Vec3.create(1.0)
					)
					-- Triangle has to intersect the voxel
					-- S.printf("----------------------\n")
					if voxel:intersects(v0, v1, v2) then
						outgrid:setVoxel(i,j,k)
						-- If we only want a hollow voxelization, then we're done.
						-- Otherwise, we need to 'line trace' to fill in internal voxels.
						if solid then
							-- First, check that the voxel center even lies within the 2d projection
							--    of the triangle (early out to try and avoid ray tests)
							var pointTriIsect = Intersection.intersectPointTriangle(
								Vec2.create(v0(0), v0(1)),
								Vec2.create(v1(0), v1(1)),
								Vec2.create(v2(0), v2(1)),
								Vec2.create(v(0), v(1))
							)
							if pointTriIsect then
								-- Trace rays (basically, we don't want to fill in a line of internal
								--    voxels if this triangle only intersects a sliver of this voxel--that
								--    would 'bloat' our voxelixation and make it inaccurate)
								var rd0 = Vec3.create(0.0, 0.0, 1.0)
								var rd1 = Vec3.create(0.0, 0.0, -1.0)
								var t0 : real, t1 : real, _u0 : real, _u1 : real, _v0 : real, _v1 : real
								var b0 = Intersection.intersectRayTriangle(v0, v1, v2, v, rd0, &t0, &_u0, &_v0, 0.0, 1.0)
								var b1 = Intersection.intersectRayTriangle(v0, v1, v2, v, rd1, &t1, &_u1, &_v1, 0.0, 1.0)
								if (b0 and t0 <= 0.5) or (b1 and t1 <= 0.5) then
									for kk=k+1,outgrid.slices do
										outgrid:toggleVoxel(i,j,kk)
									end
								end
							end
						end
					else
						-- S.printf("box/tri intersect FAILED\n")
					end
				end
			end
		end
	end

	terra Mesh:voxelize(outgrid: &BinaryGrid, bounds: &BBox3, xres: uint, yres: uint, zres: uint, solid: bool) : {}
		outgrid:resize(yres, xres, zres)
		var extents = bounds:extents()
		var xsize = extents(0)/xres
		var ysize = extents(1)/yres
		var zsize = extents(2)/zres
		var worldtovox = Mat4.scale(1.0/xsize, 1.0/ysize, 1.0/zsize) * Mat4.translate(-bounds.mins)
		var numtris = self.indices:size() / 3
		var gridbounds = BBox3.salloc():init(
			Vec3.create(0.0),
			Vec3.create(real(outgrid.cols), real(outgrid.rows), real(outgrid.slices))
		)
		for i=0,numtris do
			var p0 = worldtovox:transformPoint(self.vertices(self.indices(3*i)))
			var p1 = worldtovox:transformPoint(self.vertices(self.indices(3*i + 1)))
			var p2 = worldtovox:transformPoint(self.vertices(self.indices(3*i + 2)))
			var tribb = BBox3.salloc():init()
			tribb:expand(p0); tribb:expand(p1); tribb:expand(p2)
			if tribb:intersects(gridbounds) then
				voxelizeTriangle(outgrid, p0, p1, p2, solid)
			end
		end
		-- -- If we asked for a solid voxelization, then we do a simple parity count method
		-- --    to fill in the interior voxels.
		-- -- This is not robust to a whole host of things, but the meshes I'm working with should
		-- --    be well-behaved enough for it not to matter.
		-- if solid then
		-- 	for k=0,outgrid.slices do
		-- 		for i=0,outgrid.rows do
		-- 			-- Parity bit starts out false (outside)
		-- 			var parity = false
		-- 			var lastCellVal = false
		-- 			for j=0,outgrid.cols do
		-- 				var currCellVal = outgrid:isVoxelSet(i,j,k)
		-- 				-- If we transition from an empty to a filled voxel,
		-- 				--    then we flip the parity bit
		-- 				if currCellVal and not lastCellVal then
		-- 					parity = not parity
		-- 				end
		-- 				-- If we're at an empty voxel and the parity bit is on (inside),
		-- 				--    then we fill that voxel
		-- 				if not currCellVal and parity then
		-- 					outgrid:setVoxel(i,j,k)
		-- 				end
		-- 				lastCellVal = currCellVal
		-- 			end
		-- 		end
		-- 	end
		-- end
	end

	-- Find xres,yres,zres given a target voxel size
	terra Mesh:voxelize(outgrid: &BinaryGrid, bounds: &BBox3, voxelSize: real, solid: bool) : {}
		var numvox = (bounds:extents() / voxelSize):ceil()
		self:voxelize(outgrid, bounds, uint(numvox(0)), uint(numvox(1)), uint(numvox(2)), solid)
	end

	-- Use mesh's bounding box as bounds for voxelization
	terra Mesh:voxelize(outgrid: &BinaryGrid, xres: uint, yres: uint, zres: uint, solid: bool) : {}
		var bounds = self:bbox()
		self:voxelize(outgrid, &bounds, xres, yres, zres, solid)
	end
	terra Mesh:voxelize(outgrid: &BinaryGrid, voxelSize: real, solid: bool) : {}
		var bounds = self:bbox()
		self:voxelize(outgrid, &bounds, voxelSize, solid)
	end

	return Mesh

end)

return Mesh



