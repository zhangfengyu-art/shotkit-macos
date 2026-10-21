-- Geometry-only target filtering. No UI, AX calls or screenshots here.
local M = {}
local excluded = {AXSplitter=true,AXScrollBar=true,AXRuler=true,AXGrowArea=true,AXHandle=true,AXSeparator=true}
local weights = {AXImage=4.2,AXRow=3.2,AXCell=3.0,AXTextArea=3.5,AXTextField=3.2,
    AXGroup=2.5,AXScrollArea=2.3,AXList=2.7,AXTable=2.8,AXButton=2.8,
    AXPopUpButton=2.7,AXComboBox=2.8,AXStaticText=1.7,AXWebArea=1.2,AXToolbar=1.1,AXWindow=0}
function M.inside(r,p,margin)
    margin=margin or 0
    return r and p and p.x>=r.x+margin and p.x<r.x+r.w-margin and p.y>=r.y+margin and p.y<r.y+r.h-margin
end
function M.same(a,b)
    return a and b and math.abs(a.x-b.x)<1.5 and math.abs(a.y-b.y)<1.5 and math.abs(a.w-b.w)<2 and math.abs(a.h-b.h)<2
end
local function number(n) return type(n)=="number" and n==n and math.abs(n)<1000000 end
local function edge(r,p,d) return M.inside(r,p,-d) and not M.inside(r,p,d) end
function M.window(windows,p,current)
    local top
    for _,w in ipairs(windows) do if M.inside(w.frame,p) then top=w; break end end
    if current and (not top or current.id~=top.id) and M.inside(current.frame,p,-4)
        and (not top or not M.inside(top.frame,p,6) or edge(current.frame,p,4)) then return current end
    return top
end
function M.normalise(raw,window)
    local out={}
    for _,r in ipairs(raw or {}) do
        if number(r.x) and number(r.y) and number(r.w) and number(r.h) and r.w>=24 and r.h>=20
            and not excluded[r.role] and (r.w/r.h<18 or (r.role=="AXToolbar" and r.h>=32)) and r.h/r.w<12 then
            local x,y=math.max(r.x,window.x),math.max(r.y,window.y)
            local right,bottom=math.min(r.x+r.w,window.x+window.w),math.min(r.y+r.h,window.y+window.h)
            local w,h=right-x,bottom-y
            -- AX sometimes reports an offscreen ancestor or a window border as content.
            if w>=24 and h>=20 and w*h>=r.w*r.h*0.92 and w*h<window.w*window.h*0.97 then
                local candidate={x=x,y=y,w=w,h=h,role=r.role or "AXGroup"}
                local duplicate=false
                for _,old in ipairs(out) do
                    if M.same(old,candidate) then duplicate=true; break end
                end
                if not duplicate then table.insert(out,candidate) end
            end
        end
    end
    table.insert(out,{x=window.x,y=window.y,w=window.w,h=window.h,role="AXWindow"})
    table.sort(out,function(a,b) return a.w*a.h<b.w*b.h end)
    return out
end
function M.merge(previous,incoming,window)
    local raw={}
    for _,r in ipairs(incoming or {}) do table.insert(raw,r) end
    for _,r in ipairs(previous or {}) do if #raw<96 then table.insert(raw,r) end end
    return M.normalise(raw,window)
end
function M.chain(candidates,p)
    local chain={}
    for _,r in ipairs(candidates or {}) do if M.inside(r,p) then table.insert(chain,r) end end
    table.sort(chain,function(a,b) return a.w*a.h<b.w*b.h end)
    return chain
end
local function score(r,window)
    if r.role=="AXWindow" then return -10 end
    local fraction=(r.w*r.h)/(window.w*window.h)
    return (weights[r.role] or 2)+math.min(1.4,r.w*r.h/6000)
        -math.abs(math.log(math.max(0.0001,fraction)/0.12))*0.42
        -(math.min(r.w,r.h)<28 and 2 or 0)
end
function M.choose(candidates,p,window,current)
    local best,bestScore
    for _,r in ipairs(candidates or {}) do
        local margin=r.role=="AXWindow" and 0 or math.min(5,r.h*0.12,r.w*0.12)
        if M.inside(r,p,margin) then
            local value=score(r,window)
            if not bestScore or value>bestScore then best,bestScore=r,value end
        end
    end
    if current then
        local known=false
        for _,r in ipairs(candidates or {}) do if M.same(r,current) then known=true; break end end
        -- A narrow band around the current border belongs to the current target.
        -- Do not suddenly jump to an unrelated ancestor or neighbouring frame.
        if known and edge(current,p,5) and M.inside(window,p,-2) then return current end
        if known and best and M.inside(current,p,5) and current.role~="AXWindow"
            and score(current,window)+0.65>=bestScore then return current end
    end
    return best
end
M.excluded=excluded
return M
