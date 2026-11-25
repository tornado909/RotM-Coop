local M={}
function M.new(delay)
    local self={ready=false,world="",elapsed=0}
    function self:step(world,valid,dt)
        if self.ready then return true end
        if not valid or world=="" then self.world="";self.elapsed=0;return false end
        if world~=self.world then self.world=world;self.elapsed=0;return false end
        self.elapsed=self.elapsed+dt
        self.ready=self.elapsed>=delay
        return self.ready
    end
    return self
end
return M