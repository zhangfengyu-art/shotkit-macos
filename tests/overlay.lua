local root="lua/"
local original=hs
local writes=0
local function canvas()
    local c={}
    for _,name in ipairs({"level","behavior","clickActivating","wantsLayer","appendElements","show","delete"}) do c[name]=function(self) return self end end
    c.elementAttribute=function(self) writes=writes+1; return self end
    return c
end
local screen={fullFrame=function() return {x=0,y=0,w=1440,h=900} end,frame=function() return {x=0,y=25,w=1440,h=850} end,currentMode=function() return {scale=2} end}
hs={timer={absoluteTime=function() return 1000000000 end},screen={allScreens=function() return {screen} end},canvas={new=canvas,windowLevels={overlay=102}},mouse={absolutePosition=function() return {x=300,y=300} end}}
local Overlay=dofile(root.."screenshot_overlay.lua")
local s={locked=true,id=1,sel={x=100,y=100,w=600,h=400},native={panel=function() end}}
local ui=Overlay.new(s,function() return false end,true)
ui:setTarget(s.sel,false)
local before=writes; ui:paint(); assert(writes==before,"unchanged paint must issue no canvas mutations")
assert(ui.toolbarFrame.w==508 and ui.toolbarFrame.h==94,"native toolbar layout")
assert(ui:toolbarHit({x=ui.toolbarFrame.x+10,y=ui.toolbarFrame.y+10}),"native toolbar mouse pass-through")
assert(ui:handleHit({x=100,y=100})=="nw","resize handle")
ui:delete(); hs=original
return {ok=true,tests=4,idleCanvasWrites=writes-before}
