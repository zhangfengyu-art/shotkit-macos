local M={}; M.__index=M
local function now() return hs.timer.absoluteTime()/1e9 end

function M.new(path,onEvent)
    return setmetatable({path=path,onEvent=onEvent,pending={},queue={},serial=0,stats={requests=0,ax=0,axTotal=0,restarts=0,handlerErrors=0}},M)
end
function M:flush()
    if not self.ready or self.writing or not self.task then return end
    local item=table.remove(self.queue,1); if not item then return end
    self.writing=item.id
    self.task:setInput(hs.json.encode(item).."\n")
end
function M:receive(event)
    if event.event=="ready" then
        self.ready=true; self:flush()
        if self.onEvent then self.onEvent(event) end
    elseif event.event=="ack" then
        if self.writing==event.id then self.writing=nil; self:flush() end
    elseif event.event=="reply" then
        local pending=self.pending[event.id]; self.pending[event.id]=nil
        if pending then
            if pending.timer then pending.timer:stop() end
            if pending.op=="ax" then
                self.stats.ax=self.stats.ax+1; self.stats.axTotal=self.stats.axTotal+(now()-pending.started)*1000
                self.stats.lastAX=event.data and event.data.milliseconds
            end
            if pending.callback then pending.callback(true,event.data) end
        end
    elseif self.onEvent then self.onEvent(event) end
end
function M:start()
    if self.task then return end
    self.stopped=false; self.buffer=""; self.ready=false; self.writing=nil
    local task
    task=hs.task.new(self.path,function()
        if self.task~=task then return end
        self.task=nil; self.ready=false; self.writing=nil; self.queue={}
        local pending=self.pending; self.pending={}
        for _,item in pairs(pending) do
            if item.timer then item.timer:stop() end
            if item.callback then item.callback(false,{error="原生服务已退出"}) end
        end
        if not self.stopped then
            self.stats.restarts=self.stats.restarts+1
            self.restart=hs.timer.doAfter(0.5,function() self.restart=nil; self:start() end)
            if self.onEvent then self.onEvent({event="unavailable"}) end
        end
    end,function(_,output)
        self.buffer=self.buffer..(output or "")
        -- stdout contains only small JSON protocol messages; bound corrupt input.
        if #self.buffer>1024*1024 then self.buffer="" end
        while true do
            local at=self.buffer:find("\n",1,true); if not at then break end
            local line=self.buffer:sub(1,at-1); self.buffer=self.buffer:sub(at+1)
            local ok,event=pcall(hs.json.decode,line)
            if ok and type(event)=="table" then
                local delivered,err=pcall(self.receive,self,event)
                if not delivered then self.stats.handlerErrors=self.stats.handlerErrors+1; self.lastError=tostring(err); hs.printf("截图回调错误：%s",tostring(err)) end
            end
        end
        return true
    end,{"service"})
    self.task=task
    if not task or not task:start() then self.task=nil; return false end
    return true
end
function M:request(op,data,callback,timeout,coalesce)
    self.serial=self.serial+1; local id=self.serial
    local pending={op=op,callback=callback,started=now()}
    self.pending[id]=pending; self.stats.requests=self.stats.requests+1
    pending.timer=hs.timer.doAfter(timeout or 1,function()
        if self.pending[id]~=pending then return end
        self.pending[id]=nil
        -- Discard expired commands that have not been written yet.
        for i=#self.queue,1,-1 do if self.queue[i].id==id then table.remove(self.queue,i) end end
        if callback then callback(false,{error="原生服务响应超时"}) end
        if self.writing==id and self.task then self.task:terminate() end
    end)
    if coalesce then
        for i=#self.queue,1,-1 do
            local old=self.queue[i]
            if old.key==coalesce then
                local item=self.pending[old.id]
                if item and item.timer then item.timer:stop() end
                self.pending[old.id]=nil; table.remove(self.queue,i)
            end
        end
    end
    table.insert(self.queue,{id=id,op=op,data=data,key=coalesce})
    self:flush()
    local token={}; local owner=self
    function token:terminate()
        if pending.timer then pending.timer:stop() end
        owner.pending[id]=nil
        for i=#owner.queue,1,-1 do if owner.queue[i].id==id then table.remove(owner.queue,i) end end
    end
    return token
end
function M:panel(kind,data)
    data.kind=kind
    self:request("panel",data,nil,1,"panel:"..kind)
end
function M:barrier(callback) self:request("ping",{},callback,0.6) end
function M:stop()
    self.stopped=true
    if self.restart then self.restart:stop(); self.restart=nil end
    local task=self.task; self.task=nil; self.ready=false
    if task then task:closeInput(); task:terminate() end
    for _,item in pairs(self.pending) do if item.timer then item.timer:stop() end end
    self.pending={}; self.queue={}; self.writing=nil
end
function M:diagnostics()
    return {ready=self.ready,pid=self.task and self.task:pid(),requests=self.stats.requests,ax=self.stats.ax,
        meanAXms=self.stats.ax>0 and self.stats.axTotal/self.stats.ax or nil,lastAXms=self.stats.lastAX,
        restarts=self.stats.restarts,queued=#self.queue,handlerErrors=self.stats.handlerErrors,lastError=self.lastError}
end
return M
