local function obj(n,t)
 t=t or {}; t.IsValid=function()return true end; t.GetFullName=function()return n end; return t
end
local gi=obj("GI_Mage_C /Engine/Transient.GameEngine_1:GI_Mage_C_2")
local world=obj("World /Game/Arenas/MageHub_New")
local controller=obj("PC /Game/PC",{HUD=obj("HUD_InGame_C /Game/HUD")})
local prefix="/Engine/Transient.GameEngine_1:GI_Mage_C_2."
local hud=obj("BPW_GameHUD_C "..prefix.."BPW_GameHUD_C_3",{IsInViewport=function()return true end,GetOwningPlayer=function()return controller end})
local stale=obj("BPW_GameHUD_C "..prefix.."BPW_GameHUD_C_4",{IsInViewport=function()return false end})
local texture=obj("Texture2D /Game/Spell")
local function image(n)
 return obj(n,{Brush={},GetVisibility=function()return 2 end,SetVisibility=function(self,v)self.vis=v end,SetBrushFromTexture=function(self,t)self.Brush.ResourceObject=t end})
end
local foreground=image("Image /Game/ForegroundImage")
local key=image("Image /Game/KeyImage")
local root=obj("Panel /Game/root",{GetChildrenCount=function()return 2 end,GetChildAt=function(_,i)return i==0 and foreground or key end})
local panel=obj("BPW_ActiveSpellsPanel_C "..prefix.."BPW_GameHUD_C_3.WidgetTree.ActiveSpellsPanel",{BPW_ActivePrimarySpellControl=obj("Slot /Game/Slot",{WidgetTree=obj("WidgetTree /Game/Tree",{RootWidget=root})})})
controller.Pawn=obj("Pawn /Game/Guest",{CharacterRobeComponent=obj("Robe /Game/Robe",{OwnedAbilityMap={ForEach=function(_,cb)cb({get=function()return 1 end},{get=function()return {Icon=texture} end})end}})})
local sys=obj("Kismet",{IsStandalone=function()return false end,IsServer=function()return false end})
local st=obj("Statics",{GetPlayerController=function()return controller end,GetGameInstance=function()return gi end})
package.preload.UEHelpers=function()return {GetKismetSystemLibrary=function()return sys end,GetGameplayStatics=function()return st end}end
function FindAllOf(c) if c=="BPW_GameHUD_C" then return {stale,hud} else return {panel} end end
function StaticFindObject()return texture end
function ExecuteInGameThread(f) f() end
local tick
function LoopAsync(_,f)tick=f end
local errors={}
local m=dofile("mod/RotMCoop/Scripts/hud_spells.lua")
m.install({}, {current_world=function()return world end,log=function(s)if s:find("error") then errors[#errors+1]=s end end})
tick()
assert(#errors==0,table.concat(errors,";"))
assert(foreground.Brush.ResourceObject==texture and foreground.vis==0,"guest icon not restored")
assert(key.Brush.ResourceObject==texture and key.vis==0,"key icon not restored")
print("Guest HUD game-instance regression passed")

-- Two native host HUDs can both be attached to the same controller.
-- Preserve the actual controller.HUD, not whichever FindAllOf yields first.
local duplicate=obj("BPW_GameHUD_C "..prefix.."BPW_GameHUD_C_5",{
    IsInViewport=function(self)return not self.removed end,
    GetOwningPlayer=function()return controller end,
    RemoveFromParent=function(self)self.removed=true end,
})
controller.HUD=hud
function FindAllOf(c)if c=="BPW_GameHUD_C"then return {duplicate,stale,hud}else return {panel}end end
assert(m.local_hud(st,world,controller)==hud,"Canonical controller HUD lost")
assert(m.prune_duplicate_huds(st,world,controller,function()end)==1,"Duplicate HUD not removed")
assert(duplicate.removed and hud:IsInViewport(),"Canonical HUD must remain attached")
print("Canonical native HUD deduplication passed")
