local snap=dofile("lua/screenshot_snap.lua")
local window={x=100,y=80,w=1000,h=700}
local image={x=200,y=180,w=380,h=260,role="AXImage"}
local raw={image,{x=195,y=180,w=4,h=270,role="AXSplitter"},
    {x=100,y=80,w=1000,h=20,role="AXToolbar"},
    {x=-200,y=-100,w=1600,h=1000,role="AXGroup"},
    {x=230,y=210,w=80,h=24,role="AXStaticText"}}
local candidates=snap.normalise(raw,window)
assert(#candidates==3,"Splitter / out-of-window ancestor should be removed")
assert(snap.choose(candidates,{x=300,y=250},window,nil).role=="AXImage","Prefer a useful image block")
assert(snap.same(snap.choose(candidates,{x=199,y=250},window,image),image),"Keep target at its border")
assert(snap.choose(candidates,{x=187,y=250},window,image).role=="AXWindow","Release target after leaving its border")
assert(snap.choose(candidates,{x=250,y=81},window,nil).role=="AXWindow","Do not select a toolbar edge")
local old={id=1,frame=window}
local nextWindow={id=2,frame={x=1100,y=80,w=400,h=700}}
assert(snap.window({nextWindow,old},{x=1101,y=300},old).id==1,"Window border should not toggle targets")
assert(snap.window({nextWindow,old},{x=1112,y=300},old).id==2,"Enter the next window after crossing border")
assert(#snap.normalise({{x=0/0,y=0,w=100,h=100}},window)==1,"Reject invalid AX geometry")
return {ok=true,tests=8}
