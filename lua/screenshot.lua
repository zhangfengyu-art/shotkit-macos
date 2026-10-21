-- Screenshot Plus v4.2 · Control + Command + A
-- Fast WindowServer geometry; resident asynchronous AX and native AppKit controls.
local M = {}
local Snap = require("screenshot_snap")
local Overlay = require("screenshot_overlay")
local Native = require("screenshot_native")
local ROOT = hs.configdir .. "/screenshot-data"
local HELPER = hs.configdir .. "/ShotKit.app/Contents/MacOS/ShotKit"
local PREFIX = "screenshotPlus."
local S = { serial = 0, jobs = {}, pins = {}, hotkeys = {}, generation = 0 }
local capture, startSession, stopSession, deliver, showHistory, showActions, finishLong, nextLong, beginLong, endLong, selectionAction
local function now() return hs.timer.absoluteTime() / 1e9 end
local function notify(text, seconds)
    if S.native and S.native.ready and not S.stopped then
        local screen=hs.mouse.getCurrentScreen() or hs.screen.mainScreen(); local f=screen:frame()
        S.native:request("toast",{text=text,duration=seconds or 1.5,centerX=f.x+f.w/2,bottomY=f.y+f.h-36,screenWidth=f.w,
            motion=hs.settings.get(PREFIX.."motion")~=false and not S.reduceMotion},nil,2,"toast")
    else hs.alert.show(text,seconds or 1.5) end
end
local function setting(key, fallback)
    local value = hs.settings.get(PREFIX .. key)
    if value == nil then return fallback end
    return value
end
local function set(key, value) hs.settings.set(PREFIX .. key, value) end
local function fileURL(path)
    return "file://" .. path:gsub("([^%w%-%._~/])", function(c) return string.format("%%%02X", c:byte()) end)
end
local function exists(path) return path and hs.fs.attributes(path, "mode") == "file" end
local function read(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local data = f:read("*a"); f:close(); return data
end
local function write(path, data)
    local f, err = io.open(path, "wb"); if not f then return nil, err end
    local ok, reason = f:write(data); f:close(); return ok, reason
end
local function json(path)
    local data = read(path); if not data then return {} end
    local ok, value = pcall(hs.json.decode, data); return ok and type(value) == "table" and value or {}
end
local function pngSize(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local h = f:read(24); f:close()
    if not h or #h < 24 or h:sub(1,8) ~= "\137PNG\r\n\26\n" then return nil end
    local function u32(i) return h:byte(i)*16777216+h:byte(i+1)*65536+h:byte(i+2)*256+h:byte(i+3) end
    return u32(17), u32(21)
end
local function shotPath()
    S.serial = S.serial + 1
    return string.format("%s/shot_%s_%03d_%04d.png", ROOT, os.date("%Y%m%d_%H%M%S"), math.floor(hs.timer.secondsSinceEpoch()*1000)%1000, S.serial)
end
local function metadata(path, update)
    local data = json(path .. ".json")
    for key, value in pairs(update or {}) do data[key] = value end
    write(path .. ".json", hs.json.encode(data))
    return data
end
local function shots()
    local list = {}
    if hs.fs.attributes(ROOT, "mode") ~= "directory" then return list end
    for name in hs.fs.dir(ROOT) do
        if name:match("^shot_[%d_]+%.png$") then
            local path = ROOT .. "/" .. name; local a = hs.fs.attributes(path)
            if a then table.insert(list, { path = path, time = a.modification, size = a.size }) end
        end
    end
    table.sort(list, function(a,b) if a.time == b.time then return a.path > b.path end; return a.time > b.time end)
    return list
end
local function prune(keep)
    -- Failed/abandoned long-capture segments are recoverable for 24 hours.
    if hs.fs.attributes(ROOT,"mode")=="directory" then
        for name in hs.fs.dir(ROOT) do
            local dir=ROOT.."/"..name
            if name:match("^long%-%d") and hs.fs.attributes(dir,"mode")=="directory"
                and (not S.long or S.long.dir~=dir) and os.time()-(hs.fs.attributes(dir,"modification") or os.time())>86400 then
                for file in hs.fs.dir(dir) do if file:match("^part%-%d+%.png$") then os.remove(dir.."/"..file) end end
                hs.fs.rmdir(dir)
            elseif name:match("^shot_[%d_]+%.png%.[%a]+%.txt$")
                and os.time()-(hs.fs.attributes(dir,"modification") or os.time())>86400 then os.remove(dir) end
        end
    end
    local total, count = 0, 0
    for _, item in ipairs(shots()) do
        total = total + item.size; count = count + 1
        if item.path ~= keep and (count > setting("historyCount",60) or total > 300*1024*1024 or os.time()-item.time > 30*86400) then
            os.remove(item.path); os.remove(item.path .. ".json"); os.remove(item.path .. ".thumb.png")
        end
    end
end
local function later(seconds, fn) return hs.timer.doAfter(seconds, fn) end
local function helper(args, callback, timeout)
    if not exists(HELPER) then notify("截图原生模块缺失，请重新安装升级包"); return nil end
    local task, watchdog
    task = hs.task.new(HELPER, function(code, output, errors)
        S.jobs[task] = nil
        if watchdog then watchdog:stop() end
        if S.stopped then return end
        local ok, result = pcall(hs.json.decode, output or "")
        if not ok or type(result) ~= "table" then result = {} end
        if callback then callback(code, result, errors) end
    end, args)
    if not task then notify("无法创建原生截图任务"); return nil end
    S.jobs[task] = true
    if not task:start() then S.jobs[task] = nil; notify("无法启动原生截图模块"); return nil end
    if timeout then
        watchdog = later(timeout,function()
            if S.jobs[task] then task:terminate() end
        end)
    end
    return task
end
local function copied(path)
    local data = read(path); if not data then notify("截图文件已不存在"); return false end
    if not hs.pasteboard.writeDataForUTI(nil,"public.png",data,false) then notify("剪贴板写入失败，请从历史重试"); return false end
    hs.pasteboard.writeDataForUTI(nil,"public.file-url",fileURL(path),true)
    return true
end
local function sound()
    if setting("sound",true) then
        S.sound = hs.sound.getByFile("/System/Library/Sounds/Pop.aiff")
        if S.sound then S.sound:volume(0.15); S.sound:play() end
    end
end
local function saveDesktop(path)
    local dest = os.getenv("HOME") .. "/Desktop/截图-" .. os.date("%Y%m%d-%H%M%S") .. "-" .. tostring(S.serial) .. ".png"
    local bytes = read(path)
    if bytes and write(dest,bytes) then notify("已保存到桌面",2) else notify("保存失败；原图仍在截图历史中",3) end
end
local function saveAs(path)
    helper({"save",path},function(code,result)
        if code~=0 then notify(result.error or "保存失败",3)
        elseif result.path then notify("已保存图片",1.2) end
    end)
end
local function openEditor(path)
    if not exists(path) then notify("还没有截图"); return end
    helper({"edit",path,shotPath()},function(code,result)
        if result.cancelled then return end
        if code == 0 and exists(result.path) then deliver(result.path,"copy")
        else notify(result.error or "编辑未完成",3) end
    end)
end
local function pin(path)
    if not exists(path) then notify("还没有截图"); return end
    if #S.pins >= 6 then local old = table.remove(S.pins,1); if old:isRunning() then old:terminate() end end
    local task = helper({"pin",path},function(code,result)
        if code ~= 0 and result.error then notify(result.error) end
    end)
    if task then table.insert(S.pins,task) end
end
local function ocr(path, action, target)
    if not exists(path) then notify("还没有截图"); return end
    if action == "translate" and S.native and S.native.ready then
        S.native:request("translate",{path=path,target=target},function(ok,result)
            if not ok or result.error then notify(result.error or "翻译窗口未能打开，请重试",3) end
        end,3)
        return
    end
    local clipboardCount = hs.pasteboard.changeCount()
    notify(action == "qr" and "正在读取二维码…" or "正在本地识别文字…",1)
    local function recognized(code,result)
        if code ~= 0 then notify(result.error or "识别失败或超时",3); return end
        local text = result.text or ""
        metadata(path,{ text = text, codes = result.codes or {} })
        if action == "qr" then text = table.concat(result.codes or {},"\n") end
        if text == "" then notify(action == "qr" and "未发现可读取的二维码或条形码" or "未识别到文字",2); return end
        if action == "translate" then
            local textPath = path .. ".translation.txt"
            if not write(textPath,text) then notify("无法创建翻译内容"); return end
            helper({"translate",textPath},function(code,result)
                os.remove(textPath)
                if code ~= 0 and result.error then notify(result.error,3) end
            end)
        elseif hs.pasteboard.changeCount() == clipboardCount then
            hs.pasteboard.setContents(text)
            notify(action == "qr" and "二维码内容已复制（未自动打开链接）" or "文字已复制",2)
        else notify("识别完成，已存入历史；你的剪贴板已有新内容",3) end
        if action~="translate" then
            local textPath=path..".result.txt"
            if write(textPath,text) then helper({"text",textPath,action},function(code,result)
                os.remove(textPath); if code~=0 and result.error then notify(result.error,3) end
            end) end
        end
    end
    if S.native and S.native.ready then
        S.native:request("recognize",{path=path,codesOnly=action=="qr"},function(ok,result)
            recognized(ok and not result.error and 0 or 1,result)
        end,30)
    else helper({action=="qr" and "qr" or "ocr",path},recognized,30) end
end
local function ai(path)
    if copied(path) then
        hs.application.launchOrFocusByBundleID("com.openai.chat")
        notify("截图已复制；在 ChatGPT 按 ⌘V 后发送",3)
    end
end
deliver = function(path, action)
    local w,h = pngSize(path)
    if not w or w < 2 or h < 2 then os.remove(path); notify("截图为空或无效，请重试",2); return end
    metadata(path,{ width = w, height = h, created = hs.timer.secondsSinceEpoch() })
    S.lastPath = path
    -- Read/write the original PNG, retaining its real pixel resolution.
    local translationTarget=action and action:match("^translate:(.+)$")
    if action == "ocr" or action == "qr" or action == "translate" or translationTarget then ocr(path,translationTarget and "translate" or action,translationTarget)
    elseif action == "edit" then openEditor(path)
    else
        if copied(path) then
            if action == "save" then saveAs(path)
            elseif action == "desktop" then saveDesktop(path)
            else notify(string.format("已复制 %d × %d",w,h),0.8) end
            sound()
        end
        if action == "pin" then pin(path) elseif action == "ai" then ai(path) end
    end
    helper({"thumbnail",path,path..".thumb.png"},nil,10)
    prune(path)
end

local function pointIn(r,p) return r and p.x >= r.x and p.x < r.x+r.w and p.y >= r.y and p.y < r.y+r.h end
local function same(a,b)
    return a and b and math.abs(a.x-b.x)<1 and math.abs(a.y-b.y)<1 and math.abs(a.w-b.w)<1 and math.abs(a.h-b.h)<1
end
local function clone(r) return { x=r.x,y=r.y,w=r.w,h=r.h,role=r.role } end
local function rectPoints(a,b) return {x=math.min(a.x,b.x),y=math.min(a.y,b.y),w=math.abs(a.x-b.x),h=math.abs(a.y-b.y)} end
local function screenAt(p)
    for _,screen in ipairs(hs.screen.allScreens()) do if pointIn(screen:fullFrame(),p) then return screen end end
    return hs.screen.mainScreen()
end
local function visibleRegion(r)
    if not r then return false end
    for _,screen in ipairs(hs.screen.allScreens()) do
        local f=screen:fullFrame()
        if r.x < f.x+f.w and r.x+r.w > f.x and r.y < f.y+f.h and r.y+r.h > f.y then return true end
    end
    return false
end
local function valid(r) return r and r.w >= 2 and r.h >= 2 and visibleRegion(r) end
local function runCapture(rect,path,callback)
    if S.busy then notify("正在截图，请稍候"); return end
    local token = {path=path}; S.busy = token
    local r = string.format("%d,%d,%d,%d",math.floor(rect.x),math.floor(rect.y),math.floor(rect.w+0.5),math.floor(rect.h+0.5))
    local task,watchdog
    -- Give WindowServer time to remove the selection/HUD before taking pixels.
    local function settled(ok)
        if S.busy~=token then return end
        if not ok then S.busy=nil; notify("截图工具栏未能及时收起，请重试"); if callback then callback(nil) end; return end
        token.timer = later(0.065,function()
        if S.busy ~= token then return end
        task = hs.task.new("/usr/sbin/screencapture",function(code,_,errors)
            if watchdog then watchdog:stop() end
            if S.busy ~= token or S.stopped then return end
            S.busy = nil
            if code ~= 0 or not pngSize(path) then
                os.remove(path); notify("截图失败，请检查屏幕录制权限后重试",3)
                if callback then callback(nil,errors) end
            elseif callback then callback(path) end
        end,{"-R",r,"-x","-t","png",path})
        token.task = task
        if not task or not task:start() then S.busy=nil; notify("无法启动系统截图"); if callback then callback(nil) end; return end
        watchdog = later(8,function()
            if S.busy == token then S.busy=nil; task:terminate(); os.remove(path); notify("系统截图超时，请重试",3); if callback then callback(nil) end end
        end)
        token.watchdog=watchdog
        end)
    end
    if S.native then S.native:request("dismissToast",{},nil,0.6,"toast"); S.native:barrier(settled) else settled(true) end
end
local function cancelCapture()
    local token=S.busy; if not token then return end
    S.busy=nil
    if token.timer then token.timer:stop() end
    if token.watchdog then token.watchdog:stop() end
    if token.task then token.task:terminate() end
    if token.path then os.remove(token.path) end
end
local function cancelDelay()
    if S.delayTimer then S.delayTimer:stop(); S.delayTimer=nil; notify("已取消延时截图") end
end
capture = function(rect,action)
    if not valid(rect) then notify("选区无效，或原屏幕已断开"); return end
    if action~="delay" then cancelDelay() end
    rect = clone(rect); set("lastRect",rect)
    stopSession()
    if action == "delay" then
        cancelDelay(); notify("3 秒后截图；再按 ⌃⌘A 可取消",2)
        S.delayTimer = later(3,function() S.delayTimer=nil; capture(rect,"copy") end)
        return
    end
    runCapture(rect,shotPath(),function(path) if path then deliver(path,action or "copy") end end)
end

local function motion() return setting("motion",true) and not S.reduceMotion end
local function updateOverlay(animated)
    local s=S.session; if s and s.ui then s.ui:setTarget(s.sel,animated) end
end
local function windowAt(p,s)
    if not s.windowCache or now()-(s.windowCacheAt or 0)>0.18 then
        s.windowCache={}; s.windowCacheAt=now()
        for _,w in ipairs(hs.window.list(true) or {}) do
            local b=w.kCGWindowBounds
            if w.kCGWindowLayer==0 and w.kCGWindowIsOnscreen and (w.kCGWindowAlpha or 1)>0
                and w.kCGWindowOwnerPID~=hs.processInfo.processID and b and b.Width>=24 and b.Height>=24 then
                table.insert(s.windowCache,{id=w.kCGWindowNumber,pid=w.kCGWindowOwnerPID,frame={x=b.X,y=b.Y,w=b.Width,h=b.Height}})
            end
        end
    end
    return Snap.window(s.windowCache,p,s.currentWindow)
end
local function adopt(s,r,immediate)
    if not r then return end
    if same(s.sel,r) then s.pendingTarget=nil; return end
    if not immediate and s.sel then
        if not Snap.same(s.pendingTarget,r) then s.pendingTarget=clone(r); s.pendingSince=now(); return end
        if now()-(s.pendingSince or 0)<0.045 then return end
    end
    s.pendingTarget=nil; s.sel=clone(r); updateOverlay(not immediate)
end
local function selectWindow(p,s)
    local win=windowAt(p,s)
    if not win then
        s.windowID=nil; s.currentWindow=nil; s.sel=nil; s.chain={}; updateOverlay(false); return nil
    end
    if s.windowID~=win.id or not same(s.currentWindow and s.currentWindow.frame,win.frame) then
        s.currentWindow=win; s.windowID=win.id
        s.candidates=Snap.normalise({},win.frame); s.chain=s.candidates; s.chainIndex=1
        s.lastAXPoint=nil; s.pendingTarget=nil; s.axSerial=(s.axSerial or 0)+1
        adopt(s,s.candidates[1],true)
    else s.currentWindow=win end
    return win
end
local function chooseCached(s,p,immediate)
    local win=s.currentWindow; if not win then return end
    local candidates=s.candidates or Snap.normalise({},win.frame)
    s.chain=Snap.chain(candidates,p)
    local target=Snap.choose(candidates,p,win.frame,s.sel)
    if target then
        for i,r in ipairs(s.chain) do if Snap.same(r,target) then s.chainIndex=i; break end end
        adopt(s,target,immediate)
    end
end
local function scheduleAX(s,p,win)
    if s.axTask or now()-(s.lastAXAt or 0)<0.065 then return end
    if s.lastAXPoint and math.abs(p.x-s.lastAXPoint.x)<5 and math.abs(p.y-s.lastAXPoint.y)<5 then return end
    s.lastAXAt=now(); s.lastAXPoint={x=p.x,y=p.y}
    local serial=s.axSerial
    s.axTask=S.native:request("ax",{pid=win.pid,x=p.x,y=p.y},function(ok,result)
        if S.session~=s then return end
        s.axTask=nil
        if not ok or serial~=s.axSerial or s.locked or s.anchor or s.windowID~=win.id then return end
        -- Keep useful geometry even if the mouse has moved since this query.
        -- Pick again at the current pointer; never apply an old point's target.
        s.candidates=Snap.merge(s.candidates,result.frames or {},win.frame)
        s.needsAuto=true; if s.timer then s.timer:start() end
    end,0.45)
end
local function stepChain(direction)
    local s=S.session; if not s or s.locked or s.anchor or not s.chain or #s.chain==0 then return end
    s.chainIndex=math.min(#s.chain,math.max(1,(s.chainIndex or 1)+direction))
    s.sel=clone(s.chain[s.chainIndex]); s.levelPoint=hs.mouse.absolutePosition()
    s.pendingTarget=nil; updateOverlay(true)
end
local function confirmSelection(s,r)
    if not valid(r) then return end
    s.sel=clone(r); s.locked=true; s.manual=true; s.anchor=nil; s.pendingTarget=nil
    s.axSerial=(s.axSerial or 0)+1
    if s.axTask then s.axTask:terminate(); s.axTask=nil end
    updateOverlay(false)
end
local function reselect(s)
    if S.session~=s then return end
    s.locked=false; s.manual=false; s.anchor=nil; s.lastAXPoint=nil; s.needsAuto=true
    s.pendingTarget=nil; updateOverlay(false); if s.timer then s.timer:start() end
end
selectionAction = function(s,action)
    if S.session~=s then return end
    if action=="cancel" then stopSession(); return end
    if action=="reselect" then reselect(s); return end
    if action=="more" then
        s.tap:stop()
        local popup=hs.menubar.new(false)
        local list={}
        for _,item in ipairs({{"读取二维码 / 条形码","qr"},{"延时 3 秒截图","delay"},{"复制并打开 ChatGPT","ai"},{"重新选择区域","reselect"}}) do
            local id=item[2]
            table.insert(list,{title=item[1],fn=function() later(0.03,function() selectionAction(s,id) end) end})
        end
        popup:setMenu(list):popupMenu(hs.mouse.absolutePosition()); popup:delete()
        if S.session==s then s.tap:start() end
        return
    end
    if not valid(s.sel) then return end
    local rect=clone(s.sel)
    if action=="long" then beginLong(rect) else capture(rect,action) end
end
stopSession = function()
    local s=S.session; if not s then return end
    S.lastStop=now(); S.session=nil; S.generation=S.generation+1
    if s.tap then s.tap:stop() end
    if s.timer then s.timer:stop() end
    if s.axTask then s.axTask:terminate(); s.axTask=nil end
    if s.ui then s.ui:delete() end
end

local function longHUD()
    local l=S.long; if not l then return end
    if not l.hudFrame then
        local f=screenAt({x=l.rect.x,y=l.rect.y}):frame()
        local width,height=504,118
        local y=f.y+16
        -- Prefer a place outside the captured content so the controls don't cover it.
        if l.rect.y-f.y>=height+24 then y=l.rect.y-height-12
        elseif l.rect.y+l.rect.h+height+24<f.y+f.h then y=l.rect.y+l.rect.h+12 end
        l.hudFrame={x=math.max(f.x+10,math.min(f.x+f.w-width-10,l.rect.x+(l.rect.w-width)/2)),y=y,w=width,h=height}
    end
    S.native:panel("long",{visible=true,frame=l.hudFrame,session=l.id,count=#l.paths,motion=motion()})
end

endLong = function(remove)
    local l=S.long; if not l then return end
    S.long=nil
    if S.busy and S.busy.owner==l then cancelCapture() end
    S.native:panel("long",{visible=false})
    if l.tap then l.tap:stop() end
    if remove then
        for _,path in ipairs(l.paths) do os.remove(path) end
        hs.fs.rmdir(l.dir)
    end
end
nextLong = function()
    local l=S.long; if not l or l.busy or S.busy then return end
    if #l.paths>=20 then finishLong(); return end
    l.busy=true
    S.native:panel("long",{visible=false})
    local path=l.dir..string.format("/part-%02d.png",#l.paths+1)
    runCapture(l.rect,path,function(result)
        if S.long~=l then if result then os.remove(result) end; return end
        l.busy=false
        if result then table.insert(l.paths,result) end
        longHUD()
    end)
    if S.busy then S.busy.owner=l end
end
beginLong = function(rect)
    if not valid(rect) or rect.h<100 then notify("长截图请框选高度至少100的滚动内容区"); return end
    stopSession(); set("lastRect",clone(rect))
    prune(S.lastPath)
    S.serial=S.serial+1
    local dir=ROOT.."/long-"..os.date("%Y%m%d-%H%M%S").."-"..tostring(S.serial)
    hs.fs.mkdir(dir)
    S.generation=S.generation+1
    S.long={rect=clone(rect),dir=dir,paths={},id=S.generation}
    S.long.tap=hs.eventtap.new({hs.eventtap.event.types.keyDown},function(e)
        if e:getKeyCode()==53 then endLong(true); notify("已取消长截图"); return true end
        return false
    end):start()
    nextLong()
end
finishLong = function()
    local l=S.long; if not l then return end
    if l.busy then notify("当前分段正在截取，请稍候"); return end
    if #l.paths<2 then notify("先向下滚动，按 ⌃⌘A 再截一段"); return end
    local args={"stitch",shotPath()}; for _,p in ipairs(l.paths) do table.insert(args,p) end
    endLong(false); notify("正在拼接，完成后将打开编辑预览…",2)
    helper(args,function(code,result)
        if code==0 and exists(result.path) then
            for _,path in ipairs(l.paths) do os.remove(path) end; hs.fs.rmdir(l.dir)
            deliver(result.path,"edit")
        else
            notify((result.error or "拼接失败").."；分段保存在截图历史目录的 long 文件夹",5)
        end
    end,45)
end
local selectionActions={[36]="copy",[76]="copy",[8]="copy",[1]="save",[31]="ocr",[12]="qr",[17]="translate",[35]="pin",[14]="edit",[37]="long",[2]="delay",[0]="ai"}
startSession = function()
    S.triggers=(S.triggers or 0)+1
    if S.session then stopSession(); return end
    if S.delayTimer then cancelDelay(); return end
    if S.long then nextLong(); return end
    if S.busy then notify("正在截图，请稍候"); return end
    if not hs.accessibilityState() or not hs.screenRecordingState() then notify("请在系统设置中允许 Hammerspoon 辅助功能和屏幕录制",4); return end
    if hs.eventtap.isSecureInputEnabled() then notify("请离开密码输入框后重试截图",3); return end
    S.native:request("dismissToast",{},nil,0.6,"toast")
    S.generation=S.generation+1
    local s={chain={},started=now(),axSerial=0,native=S.native,id=S.generation}; S.session=s; S.lastStart=s.started
    s.hoverPoint=hs.mouse.absolutePosition(); s.ui=Overlay.new(s,motion)
    selectWindow(s.hoverPoint,s); updateOverlay(false)
    s.timer=hs.timer.new(1/60,function()
        if S.session~=s then return end
        s.ui:tick()
        local p=s.hoverPoint or hs.mouse.absolutePosition()
        s.mouseChanged=false
        if s.locked or s.anchor then if not s.ui.animation then s.timer:stop() end; return end
        if s.levelPoint then
            if math.abs(p.x-s.levelPoint.x)<12 and math.abs(p.y-s.levelPoint.y)<12 then if not s.ui.animation then s.timer:stop() end; return end
            s.levelPoint=nil
        end
        local needsQuery=not s.axTask and (not s.lastAXPoint or math.abs(p.x-s.lastAXPoint.x)>=5 or math.abs(p.y-s.lastAXPoint.y)>=5)
        local queryDue=needsQuery and now()-(s.lastAXAt or 0)>=0.065
        if not s.needsAuto and not s.pendingTarget and not queryDue then
            if not needsQuery and not s.ui.animation then s.timer:stop() end
            return
        end
        s.needsAuto=false
        local win=selectWindow(p,s)
        if win then chooseCached(s,p,false); scheduleAX(s,p,win) elseif not s.ui.animation then s.timer:stop() end
    end):start()
    s.needsAuto=true
    local types=hs.eventtap.event.types
    s.tap=hs.eventtap.new({types.mouseMoved,types.scrollWheel,types.leftMouseDown,types.leftMouseDragged,types.leftMouseUp,types.rightMouseDown,types.keyDown},function(e)
        if S.session~=s then return false end
        local kind=e:getType(); local flags=e:getFlags()
        if s.menuOpen then return false end
        if kind~=types.keyDown then
            local hit=s.ui:toolbarHit(e:location())
            if kind==types.leftMouseDown and hit then s.nativeMouseDown=true; return false end
            if s.nativeMouseDown then
                if kind==types.leftMouseUp then s.nativeMouseDown=nil end
                return false
            end
            if hit then return false end
        end
        if not s.timer:running() then s.timer:start() end
        if kind==types.keyDown then
            local key=e:getKeyCode()
            if key==53 then stopSession(); return true end
            if key==0 and flags.cmd and flags.ctrl then
                if now()-s.started>0.20 and (e:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat) or 0)==0 then stopSession() end
                return true
            end
            if key==49 then confirmSelection(s,s.sel); return true end
            if key==46 then if s.locked then reselect(s) else confirmSelection(s,s.sel) end; return true end
            if s.locked and (key==123 or key==124 or key==125 or key==126) and s.sel then
                local step=flags.alt and 10 or 1; local r=clone(s.sel)
                if flags.shift then
                    if key==123 then r.w=math.max(2,r.w-step) elseif key==124 then r.w=r.w+step elseif key==126 then r.h=math.max(2,r.h-step) else r.h=r.h+step end
                else
                    if key==123 then r.x=r.x-step elseif key==124 then r.x=r.x+step elseif key==126 then r.y=r.y-step else r.y=r.y+step end
                end
                s.sel=r; updateOverlay(false); return true
            end
            if not s.locked and (key==126 or key==125 or key==48) then
                stepChain((key==126 or (key==48 and flags.shift)) and 1 or -1); return true
            end
            local action=selectionActions[key]
            if action then later(0,function() selectionAction(s,action) end) end
            return true
        elseif kind==types.rightMouseDown then
            if s.locked then reselect(s) else stopSession() end; return true
        elseif kind==types.mouseMoved then
            s.hoverPoint=e:location(); s.mouseChanged=true; s.needsAuto=true
        elseif kind==types.scrollWheel then
            if not s.locked and now()-(s.wheelAt or 0)>0.11 then
                local delta=e:getProperty(hs.eventtap.event.properties.scrollWheelEventDeltaAxis1) or 0
                if delta~=0 then stepChain(delta>0 and 1 or -1); s.wheelAt=now() end
            end
        elseif kind==types.leftMouseDown then
            local p=e:location()
            s.dragHandle=s.ui:handleHit(p)
            s.moving=s.locked and not s.dragHandle and pointIn(s.sel,p)
            if s.locked and not s.moving and not s.dragHandle then
                reselect(s); s.hoverPoint=p; selectWindow(p,s); chooseCached(s,p,true)
            end
            s.anchor=p; s.downSel=s.sel and clone(s.sel); s.dragged=false
            s.clickCount=e:getProperty(hs.eventtap.event.properties.mouseEventClickState) or 1
            s.axSerial=(s.axSerial or 0)+1; updateOverlay(false)
        elseif kind==types.leftMouseDragged and s.anchor then
            local p=e:location(); local dx,dy=p.x-s.anchor.x,p.y-s.anchor.y
            if math.abs(dx)>2 or math.abs(dy)>2 then
                local r=rectPoints(s.anchor,p)
                if s.dragHandle and s.downSel then
                    local old=s.downSel; local left,top,right,bottom=old.x,old.y,old.x+old.w,old.y+old.h
                    if s.dragHandle:find("w",1,true) then left=math.min(p.x,right-2) end
                    if s.dragHandle:find("e",1,true) then right=math.max(p.x,left+2) end
                    if s.dragHandle:find("n",1,true) then top=math.min(p.y,bottom-2) end
                    if s.dragHandle:find("s",1,true) then bottom=math.max(p.y,top+2) end
                    r={x=left,y=top,w=right-left,h=bottom-top}
                elseif s.moving and s.downSel then r=clone(s.downSel); r.x=r.x+dx; r.y=r.y+dy end
                s.dragged=true; s.manual=true; s.sel=r; updateOverlay(false)
            end
        elseif kind==types.leftMouseUp then
            local p=e:location()
            if not s.anchor then return true end
            local rect=(s.dragged and s.sel) or s.downSel
            s.anchor=nil
            if valid(rect) then
                s.sel=rect
                if (s.clickCount or 1)>=2 and not s.dragged or flags.alt or (setting("quickCopy",false) and not flags.shift) then
                    later(0,function() selectionAction(s,"copy") end)
                else confirmSelection(s,rect) end
            else reselect(s) end
        end
        return true
    end)
    s.tap:start()
    if not s.tap:isEnabled() then stopSession(); notify("截图手势未能启动，请检查辅助功能权限",3) end
end

local function latest()
    if exists(S.lastPath) then return S.lastPath end
    local list=shots(); return list[1] and list[1].path
end
local function actionItems(path)
    return {
        {title="复制图片",fn=function() if copied(path) then notify("已复制") end end},
        {title="编辑 / 箭头 / 文字 / 打码 / 裁剪",fn=function() openEditor(path) end},
        {title="贴图置顶",fn=function() pin(path) end},
        {title="识别文字并复制",fn=function() ocr(path,"ocr") end},
        {title="翻译截图文字…",fn=function() ocr(path,"translate") end},
        {title="读取二维码 / 条形码",fn=function() ocr(path,"qr") end},
        {title="复制并打开 ChatGPT",fn=function() ai(path) end},
        {title="另存为…",fn=function() saveAs(path) end},
        {title="保存到桌面",fn=function() saveDesktop(path) end},
        {title="在访达中显示",fn=function() hs.task.new("/usr/bin/open",nil,{"-R",path}):start() end},
    }
end
showActions = function(path)
    if not exists(path) then notify("还没有截图"); return end
    local popup=hs.menubar.new(false); popup:setMenu(actionItems(path)); popup:popupMenu(hs.mouse.absolutePosition()); popup:delete()
end
showHistory = function()
    stopSession()
    if S.native and S.native.ready then
        local items={}
        for _,item in ipairs(shots()) do
            local info=metadata(item.path); local w,h=info.width,info.height
            if not w then w,h=pngSize(item.path) end
            local text=info.text or ""; local at=utf8.offset(text,257); if at then text=text:sub(1,at-1) end
            table.insert(items,{path=item.path,thumb=item.path..".thumb.png",title=os.date("%m月%d日 %H:%M:%S",item.time),
                detail=string.format("%d × %d",w or 0,h or 0),text=text})
        end
        S.native:request("history",{items=items},nil,3,"history"); return
    end
    local choices={}
    for _,item in ipairs(shots()) do
        local info=metadata(item.path)
        local w,h=info.width,info.height; if not w then w,h=pngSize(item.path) end
        table.insert(choices,{text=os.date("%m-%d %H:%M:%S",item.time)..string.format("  ·  %d × %d",w or 0,h or 0),
            subText=(function() local t=info.text or "右键：编辑 / 置顶 / 文字识别 / 翻译 / AI；回车复制"; local at=utf8.offset(t,121); return at and t:sub(1,at-1) or t end)(),
            image=exists(item.path..".thumb.png") and hs.image.imageFromPath(item.path..".thumb.png") or nil,path=item.path})
    end
    if #choices==0 then notify("截图历史为空"); return end
    S.chooser=hs.chooser.new(function(choice)
        if not choice then return end
        local flags=hs.eventtap.checkKeyboardModifiers()
        if flags.alt then openEditor(choice.path) elseif flags.shift then pin(choice.path)
        elseif copied(choice.path) then notify("已从历史复制") end
    end):choices(choices):rows(8):width(62):searchSubText(true)
    S.chooser:placeholderText("搜索时间或已识别文字 · 回车复制 · 右键更多功能")
    S.chooser:rightClickCallback(function(row)
        if choices[row] then S.chooser:hide(); later(0.1,function() showActions(choices[row].path) end) end
    end)
    S.chooser:show()
end
local function screenCapture()
    local screen=hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
    capture(screen:fullFrame(),"copy")
end
local HELP = [[⌃⌘A 开始截图；⇧⌃⌘A 打开历史。

1. 移动鼠标自动选目标，或拖动框选。滚轮切换范围。
2. 单击或松开鼠标，出现操作工具栏。
3. 点击复制、标注、提取文字、翻译、贴图、保存或长截图。

选中后：拖动内部移动，拖动八个方点调整大小。
双击选区或按 Enter 快速复制；右键重新选择；Esc 退出。
方向键微调位置，Shift+方向键微调大小，Option 加速。
想沿用松手复制，可在菜单中打开“松开鼠标直接复制”。

长截图：只框选滚动内容，点“长截图”。
向下滚动一些，保留至少三分之一重叠，再点“取下一段”。
最后点“完成并拼接”，检查预览后复制或保存。

提取文字：会打开结果窗口，可以修改、复制全部或只复制选中内容。
标注：工具全部展开，每个工具都有对应操作说明。
翻译：进入后自动翻译；首次可能需要下载系统语言包。
贴图：拖动移动、滚轮缩放、右键调整透明度或关闭。
更多功能里有读二维码、延时截图和AI入口。]]

local function menuItems()
    local list={}
    if S.long then
        table.insert(list,{title="长截图：取下一段  ⌃⌘A",fn=nextLong})
        table.insert(list,{title="长截图：结束并拼接  ⇧⌃⌘A",fn=finishLong})
        table.insert(list,{title="取消长截图",fn=function() endLong(true) end})
        table.insert(list,{title="-"})
    end
    table.insert(list,{title="选区截图  ⌃⌘A",fn=function() later(0.12,startSession) end})
    table.insert(list,{title="当前屏幕截图",fn=function() later(0.12,screenCapture) end})
    table.insert(list,{title="重复截取上次区域",disabled=not setting("lastRect"),fn=function() capture(setting("lastRect"),"copy") end})
    table.insert(list,{title="延时3秒截上次区域",disabled=not setting("lastRect"),fn=function() capture(setting("lastRect"),"delay") end})
    table.insert(list,{title="截图历史  ⇧⌃⌘A",fn=showHistory})
    table.insert(list,{title="最近截图操作",disabled=not latest(),menu=latest() and actionItems(latest()) or {}})
    table.insert(list,{title="-"})
    table.insert(list,{title="轻量动效",checked=motion(),disabled=S.reduceMotion,fn=function() set("motion",not setting("motion",true)) end})
    table.insert(list,{title="松开鼠标直接复制",checked=setting("quickCopy",false),fn=function() set("quickCopy",not setting("quickCopy",false)) end})
    table.insert(list,{title="截图声音",checked=setting("sound",true),fn=function() set("sound",not setting("sound",true)) end})
    table.insert(list,{title="历史保留数量",menu=(function()
        local counts={}; for _,n in ipairs({12,60,100}) do table.insert(counts,{title=tostring(n).." 张",checked=setting("historyCount",60)==n,fn=function() set("historyCount",n); prune(latest()) end}) end; return counts
    end)()})
    table.insert(list,{title="打开截图历史目录",fn=function() hs.urlevent.openURL(fileURL(ROOT)) end})
    table.insert(list,{title="功能与按键说明",fn=function() hs.dialog.blockAlert("截图",HELP,"好") end})
    return list
end
function M.stop()
    stopSession(); endLong(true); cancelDelay(); S.stopped=true; S.historyVisible=false
    cancelCapture()
    for task in pairs(S.jobs) do task:terminate() end; S.jobs={}
    for _,key in ipairs(S.hotkeys) do key:delete() end; S.hotkeys={}
    if S.screenWatcher then S.screenWatcher:stop() end
    if S.menu then S.menu:delete(); S.menu=nil end
    if S.chooser then S.chooser:hide() end
    if S.native then S.native:stop(); S.native=nil end
end
function M.start()
    M.stop(); S.stopped=false; S.nativeMenuIcon=false; hs.fs.mkdir(ROOT)
    S.native=Native.new(HELPER,function(event)
        if event.event=="ready" or event.event=="environment" then
            S.reduceMotion=event.reduceMotion
            if event.menuIcon then S.nativeIconURL=event.menuIcon end
            if S.nativeIconURL and S.menu then
                local icon=hs.image.imageFromURL(S.nativeIconURL)
                if icon then S.menu:setTitle(""):setIcon(icon:setSize({w=18,h=18}):template(true)); S.nativeMenuIcon=true end
            end
            local s=S.session
            if s and S.reduceMotion then updateOverlay(false) end
        elseif event.event=="recognized" then
            local path=event.path
            if type(path)=="string" and path:sub(1,#ROOT+1)==ROOT.."/" and exists(path) and type(event.text)=="string" then metadata(path,{text=event.text}) end
        elseif event.event=="translationStatus" then
            S.translationStatus={stage=event.stage,ocrMs=event.ocrMs,translationMs=event.translationMs,visibleMs=event.visibleMs,cacheHit=event.cacheHit}
        elseif event.event=="historyVisibility" then S.historyVisible=event.visible
        elseif event.event=="historyAction" then
            local path=event.path; local action=event.action
            if type(path)~="string" or path:sub(1,#ROOT+1)~=ROOT.."/" or not exists(path) then return end
            if action=="copy" then if copied(path) then notify("已复制图片",0.9) end
            elseif action=="edit" then openEditor(path)
            elseif action=="pin" then pin(path)
            elseif action=="ocr" or action=="translate" or action=="qr" then ocr(path,action)
            elseif action=="save" then saveAs(path)
            elseif action=="ai" then ai(path)
            elseif action=="finder" then hs.task.new("/usr/bin/open",nil,{"-R",path}):start() end
        elseif event.event=="unavailable" then
            stopSession(); if S.long then endLong(false) end
            notify("截图原生服务已重启，请重新框选",2)
        elseif event.event=="menu" then
            local s=S.session; if s and s.id==event.session then s.menuOpen=event.open; if not event.open then s.nativeMouseDown=nil end end
        elseif event.event=="action" then
            local s,l=S.session,S.long
            if event.kind=="toolbar" and s and s.id==event.session then
                later(0,function() selectionAction(s,event.action) end)
            elseif event.kind=="long" and l and l.id==event.session then
                later(0,function()
                    if S.long~=l then return end
                    if event.action=="next" then nextLong() elseif event.action=="finish" then finishLong() elseif event.action=="cancel" then endLong(true) end
                end)
            end
        end
    end)
    S.native:start()
    S.hotkeys={hs.hotkey.bind({"cmd","ctrl"},"A",startSession),hs.hotkey.bind({"cmd","ctrl","shift"},"A",function() if S.long then finishLong() else showHistory() end end)}
    local icon=hs.image.imageFromName("NSTouchBarScreenshotTemplate")
    S.menu=hs.menubar.new()
    if icon then S.menu:setIcon(icon:setSize({w=18,h=18}):template(true)) else S.menu:setTitle("▣") end
    S.menu:setTooltip("截图 · ⌃⌘A"):setMenu(menuItems)
    if S.nativeIconURL then
        local nativeIcon=hs.image.imageFromURL(S.nativeIconURL)
        if nativeIcon then S.menu:setTitle(""):setIcon(nativeIcon:setSize({w=18,h=18}):template(true)); S.nativeMenuIcon=true end
    end
    S.screenWatcher=hs.screen.watcher.new(function()
        if S.session then stopSession(); notify("屏幕布局已改变，请重新选择截图区域") end
        if S.long then endLong(false); notify("屏幕布局变化，长截图已停止；分段原图保留") end
    end):start()
    prune(latest())
end
function M.status()
    return {version="4.2",selecting=S.session~=nil,capturing=S.busy~=nil,longScreenshot=S.long~=nil,
        helper=exists(HELPER),historyCount=#shots(),accessibility=hs.accessibilityState(),screenRecording=hs.screenRecordingState()}
end
-- Explicit entry points support diagnostics without synthesizing global shortcuts.
M.diagnostics=function()
    local s=S.session
    return {triggers=S.triggers or 0,lastStart=S.lastStart,lastStop=S.lastStop,historyVisible=S.historyVisible or (S.chooser and S.chooser:isVisible()) or false,
        rect=s and s.sel,toolbar=s and s.ui and s.ui.toolbarFrame,chainCount=s and s.chain and #s.chain,
        locked=s and s.locked or false,motion=motion(),timerRunning=s and s.timer and s.timer:running() or false,
        translation=S.translationStatus,native=S.native and S.native:diagnostics(),nativeMenuIcon=S.nativeMenuIcon or false}
end
M.confirm=function(rect) local s=S.session; if s then confirmSelection(s,rect or s.sel) end end

M.begin=startSession; M.cancel=stopSession; M.history=showHistory; M.capture=capture
M.help=HELP; M._pngSize=pngSize; M._rectPoints=rectPoints; M._fileURL=fileURL
return M
