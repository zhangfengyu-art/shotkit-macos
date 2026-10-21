local M={}; M.__index=M
local ACCENT={red=0.04,green=0.48,blue=1,alpha=1}
local EMPTY={x=0,y=0,w=0,h=0}
local labels={AXWindow="窗口",AXImage="图片",AXButton="按钮",AXTextArea="文本区域",AXTextField="输入框",AXRow="内容行",AXCell="内容块",AXGroup="内容块",AXScrollArea="内容区域",AXToolbar="工具栏",AXStaticText="文字"}
local function clock() return hs.timer.absoluteTime()/1e9 end
local function copy(r) return r and {x=r.x,y=r.y,w=r.w,h=r.h,role=r.role} end
local function equal(a,b) return a and b and math.abs(a.x-b.x)<0.5 and math.abs(a.y-b.y)<0.5 and math.abs(a.w-b.w)<0.5 and math.abs(a.h-b.h)<0.5 end
local function inside(r,p) return r and p.x>=r.x and p.y>=r.y and p.x<r.x+r.w and p.y<r.y+r.h end
local function handles(r)
    return {{x=r.x,y=r.y,dir="nw"},{x=r.x+r.w/2,y=r.y,dir="n"},{x=r.x+r.w,y=r.y,dir="ne"},
        {x=r.x+r.w,y=r.y+r.h/2,dir="e"},{x=r.x+r.w,y=r.y+r.h,dir="se"},
        {x=r.x+r.w/2,y=r.y+r.h,dir="s"},{x=r.x,y=r.y+r.h,dir="sw"},{x=r.x,y=r.y+r.h/2,dir="w"}}
end
function M.new(session,motion,hidden)
    local self=setmetatable({s=session,screens={},motion=motion,hidden=hidden},M)
    for _,screen in ipairs(hs.screen.allScreens()) do
        local f=screen:fullFrame(); local c=hs.canvas.new(f)
        c:level(hs.canvas.windowLevels.overlay):behavior({"canJoinAllSpaces","stationary","fullScreenAuxiliary","ignoresCycle"}):clickActivating(false):wantsLayer(true)
        for i=1,4 do c:appendElements({type="rectangle",action="fill",fillColor={white=0,alpha=0.28},frame=EMPTY}) end
        c:appendElements(
            {type="rectangle",action="stroke",strokeColor={white=1,alpha=0.95},strokeWidth=1.2,frame=EMPTY},
            {type="rectangle",action="fill",fillColor={white=0.08,alpha=0.94},roundedRectRadii={xRadius=6,yRadius=6},frame=EMPTY},
            {type="text",text="",textSize=12,textFont=".AppleSystemUIFont",textColor={white=1},frame=EMPTY},
            {type="rectangle",action="fill",fillColor={white=0.06,alpha=0.94},roundedRectRadii={xRadius=12,yRadius=12},frame=EMPTY},
            {type="text",text="",textSize=12,textColor={white=1},textAlignment="center",frame=EMPTY})
        for i=1,8 do c:appendElements({type="rectangle",action="strokeAndFill",fillColor={white=1},strokeColor=ACCENT,strokeWidth=1.2,roundedRectRadii={xRadius=2,yRadius=2},frame=EMPTY}) end
        table.insert(self.screens,{screen=screen,frame=f,canvas=c,attributes={}})
    end
    self:paint()
    if not hidden then for _,item in ipairs(self.screens) do item.canvas:show(motion() and 0.07 or 0) end end
    return self
end
function M:setTarget(rect,animated)
    if equal(self.target,rect) then
        if not animated then self.animation=nil; self.drawRect=copy(rect) end
        self:paint(); return
    end
    local start=copy(self.drawRect)
    self.target=copy(rect)
    if animated and rect and start and self.motion() and not self.s.locked and not self.s.anchor then
        self.animation={from=start,to=copy(rect),started=clock(),duration=0.085}
    else self.animation=nil; self.drawRect=copy(rect) end
    self:paint()
end
function M:tick()
    local a=self.animation; if not a then return end
    local t=math.min(1,(clock()-a.started)/a.duration); local eased=1-(1-t)^3
    local r={}; for _,key in ipairs({"x","y","w","h"}) do r[key]=a.from[key]+(a.to[key]-a.from[key])*eased end
    r.role=a.to.role; self.drawRect=r
    if t>=1 then self.animation=nil; self.drawRect=copy(self.target) end
    self:paint()
end
function M:paint()
    local r=self.drawRect; local target=self.s.sel or r
    local mouse=self.s.hoverPoint or hs.mouse.absolutePosition()
    for _,item in ipairs(self.screens) do
        local f,c=item.frame,item.canvas
        local function put(index,key,value)
            local cacheKey=index..":"..key
            local encoded=type(value)=="table" and string.format("%.2f,%.2f,%.2f,%.2f",value.x,value.y,value.w,value.h) or value
            if item.attributes[cacheKey]~=encoded then item.attributes[cacheKey]=encoded; c:elementAttribute(index,key,value) end
        end
        local dims={{x=0,y=0,w=f.w,h=f.h},EMPTY,EMPTY,EMPTY}
        local hit
        if r then
            local x1,y1=math.max(f.x,r.x),math.max(f.y,r.y)
            local x2,y2=math.min(f.x+f.w,r.x+r.w),math.min(f.y+f.h,r.y+r.h)
            if x2>x1 and y2>y1 then
                hit={x=x1-f.x,y=y1-f.y,w=x2-x1,h=y2-y1}
                dims={{x=0,y=0,w=f.w,h=hit.y},{x=0,y=hit.y+hit.h,w=f.w,h=f.h-hit.y-hit.h},
                    {x=0,y=hit.y,w=hit.x,h=hit.h},{x=hit.x+hit.w,y=hit.y,w=f.w-hit.x-hit.w,h=hit.h}}
            end
        end
        for i=1,4 do put(i,"frame",dims[i]) end
        put(5,"frame",hit and {x=r.x-f.x,y=r.y-f.y,w=r.w,h=r.h} or EMPTY)
        if hit and target and target.w>=2 and target.h>=2 then
            local scale=(item.screen:currentMode() or {}).scale or 1
            local text=string.format("%s%d × %d",self.s.locked and "" or ((labels[target.role] or "内容块").." · "),math.floor(target.w*scale+0.5),math.floor(target.h*scale+0.5))
            local labelWidth=16
            for _,code in utf8.codes(text) do labelWidth=labelWidth+(code>255 and 12 or 7) end
            labelWidth=math.min(280,math.max(92,labelWidth))
            local x=math.min(math.max(8,hit.x),math.max(8,f.w-labelWidth-8)); local y=hit.y>=32 and hit.y-28 or math.min(f.h-25,hit.y+7)
            put(6,"frame",{x=x,y=y,w=labelWidth,h=23}); put(7,"frame",{x=x+8,y=y+3,w=labelWidth-16,h=19}); put(7,"text",text)
        else
            put(6,"frame",EMPTY); put(7,"frame",EMPTY); put(7,"text","")
        end
        local hint=not self.s.locked and inside(f,mouse)
        local width=math.min(490,f.w-32)
        put(8,"frame",hint and {x=(f.w-width)/2,y=f.h-55,w=width,h=32} or EMPTY)
        put(9,"frame",hint and {x=(f.w-width)/2+8,y=f.h-48,w=width-16,h=22} or EMPTY)
        put(9,"text",hint and (self.s.anchor and "松开鼠标确定选区，然后选择要做的操作" or "单击选中目标  ·  拖动自由框选  ·  滚轮切换范围  ·  Esc 退出") or "")
        local points=self.s.locked and r and handles(r) or {}
        for i=1,8 do
            local p=points[i]
            put(9+i,"frame",p and {x=p.x-f.x-3.5,y=p.y-f.y-3.5,w=7,h=7} or EMPTY)
        end
    end
    self:placeToolbar()
end
function M:placeToolbar()
    if not self.s.locked or self.s.anchor or not self.s.sel then
        if self.toolbarFrame then self.s.native:panel("toolbar",{visible=false}) end
        self.toolbarFrame=nil; return
    end
    local r=self.s.sel; local chosen=self.screens[1]
    for _,item in ipairs(self.screens) do if inside(item.frame,{x=r.x+r.w/2,y=r.y+r.h/2}) then chosen=item; break end end
    local f=chosen.screen:frame(); local width,height=508,94
    local x=math.min(f.x+f.w-width-10,math.max(f.x+10,r.x+r.w-width))
    local y=r.y+r.h+13
    if y+height>f.y+f.h-10 then y=r.y-height-13 end
    if y<f.y+10 then y=math.min(f.y+f.h-height-10,math.max(f.y+10,r.y+r.h-height-13)) end
    local frame={x=x,y=y,w=width,h=height}
    if not equal(self.toolbarFrame,frame) then
        self.toolbarFrame=frame
        if not self.hidden then self.s.native:panel("toolbar",{visible=true,frame=frame,session=self.s.id,motion=self.motion()}) end
    end
end
function M:toolbarHit(point) return inside(self.toolbarFrame,point) end
function M:hover() end
function M:handleHit(point)
    if not self.s.locked or not self.s.sel then return nil end
    for _,p in ipairs(handles(self.s.sel)) do if math.abs(point.x-p.x)<=9 and math.abs(point.y-p.y)<=9 then return p.dir end end
end
function M:delete()
    if self.toolbarFrame then self.s.native:panel("toolbar",{visible=false}); self.toolbarFrame=nil end
    for _,item in ipairs(self.screens) do item.canvas:delete() end
end
return M
