// Test-only Steamworks impersonator. Never shipped to users.
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <set>
#include <vector>
#pragma comment(lib,"ws2_32.lib")
#define API extern "C" __declspec(dllexport)
static constexpr uint64_t BASE=70000000000000000ULL, ROOM=109775240917246251ULL;
struct Shared{LONG owner,guest,ready,epoch;ULONGLONG joinTick;char name[128],tag[128],transport[128],stage[32],bans[128],hostPhase[32],guestPhase[32];};
static Shared* sh=nullptr;static HANDLE mapping=nullptr;static SOCKET udp=INVALID_SOCKET;
static int slot=0;static uint64_t steamId=0,call=11;
struct Packet{uint64_t peer;int ch;std::vector<uint8_t> data;};
struct Result{uint64_t handle;int callback;std::vector<uint8_t> data;};
static std::deque<Packet> incoming;
static std::map<uint64_t,std::deque<Packet>> held;
static std::set<uint64_t> accepted,requested,sent;
static std::deque<Result> completed;
static std::deque<std::pair<int,std::vector<uint8_t>>> callbacks;
static std::vector<uint8_t> callbackData;
static std::map<int,Packet> lobbyChat;
static int nextChatId=10;
struct CallbackMsg{int user,callback;void* param;int size;};
static void emit(int id,const void* data,int size){
 callbacks.emplace_back(id,std::vector<uint8_t>((uint8_t*)data,(uint8_t*)data+size));
}
static uint64_t complete(int id,const void* data,int size){
 uint64_t h=call++;
 completed.push_back({h,id,std::vector<uint8_t>((uint8_t*)data,(uint8_t*)data+size)});
 struct Done{uint64_t h;int cb;uint32_t sz;} c{h,id,(uint32_t)size};
 emit(703,&c,sizeof(c));return h;
}
API int SteamAPI_InitFlat(char*){
 char buf[8]={};size_t len=0;
 getenv_s(&len,buf,sizeof(buf),"ROTM_MOCK_SLOT");
 slot=atoi(buf);if(slot<1||slot>2)return 1;
 steamId=BASE+slot;
 mapping=CreateFileMappingA(INVALID_HANDLE_VALUE,nullptr,PAGE_READWRITE,0,
  sizeof(Shared),"Local\\RotM_Bridge_Mock_2026");
 if(!mapping)return 1;bool fresh=GetLastError()!=ERROR_ALREADY_EXISTS;
 sh=(Shared*)MapViewOfFile(mapping,FILE_MAP_ALL_ACCESS,0,0,sizeof(Shared));
 if(!sh)return 1;if(fresh)ZeroMemory(sh,sizeof(Shared));
 WSADATA w{};if(WSAStartup(MAKEWORD(2,2),&w))return 1;
 udp=socket(AF_INET,SOCK_DGRAM,IPPROTO_UDP);if(udp==INVALID_SOCKET)return 1;
 u_long nb=1;ioctlsocket(udp,FIONBIO,&nb);
 sockaddr_in a{};a.sin_family=AF_INET;a.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
 a.sin_port=htons(48040+slot);
 return bind(udp,(sockaddr*)&a,sizeof(a))?1:0;
}
API void SteamAPI_Shutdown(){
 if(udp!=INVALID_SOCKET)closesocket(udp);
 if(sh)UnmapViewOfFile(sh);if(mapping)CloseHandle(mapping);
 WSACleanup();
}
API int SteamAPI_GetHSteamPipe(){return 1;}
API void SteamAPI_ManualDispatch_Init(){}
API void SteamAPI_ManualDispatch_RunFrame(int){
 for(int i=0;i<256;i++){
  uint8_t b[2048];int n=recv(udp,(char*)b,sizeof(b),0);if(n<16)break;
  uint64_t peer;int chan;uint32_t sz;
  memcpy(&peer,b,8);memcpy(&chan,b+8,4);memcpy(&sz,b+12,4);
  if(peer==steamId||sz>(uint32_t)(n-16))continue;
  Packet p{peer,chan,std::vector<uint8_t>(b+16,b+16+sz)};
  if(chan==97){
    int cid=nextChatId++;
    lobbyChat[cid]=p;
    struct LobbyChatMsg{uint64_t lobby,member;uint8_t type,pad[3];uint32_t chatId;} e{ROOM,peer,1,{0,0,0},(uint32_t)cid};
    emit(507,&e,sizeof(e));
    continue;
  }
  if(accepted.count(peer)||sent.count(peer))incoming.push_back(std::move(p));
  else {
   held[peer].push_back(std::move(p));
   if(requested.insert(peer).second)emit(1202,&peer,8);
  }
 }
}
API bool SteamAPI_ManualDispatch_GetNextCallback(int,CallbackMsg* out){
 if(callbacks.empty()||!out)return false;
 callbackData=callbacks.front().second;
 *out={1,callbacks.front().first,callbackData.data(),(int)callbackData.size()};
 return true;
}
API void SteamAPI_ManualDispatch_FreeLastCallback(int){
 if(!callbacks.empty())callbacks.pop_front();
}
API bool SteamAPI_ManualDispatch_GetAPICallResult(int,uint64_t h,void* dst,int n,int cb,bool* failed){
 for(auto it=completed.begin();it!=completed.end();++it)
  if(it->handle==h&&it->callback==cb&&it->data.size()==(size_t)n){
   memcpy(dst,it->data.data(),n);completed.erase(it);*failed=false;return true;
  }
 *failed=true;return false;
}
API void* SteamAPI_SteamMatchmaking_v009(){return (void*)1;}
API void* SteamAPI_SteamFriends_v017(){return (void*)1;}
API void* SteamAPI_SteamUser_v023(){return (void*)1;}
API void* SteamAPI_SteamNetworking_v006(){return (void*)1;}
API uint64_t SteamAPI_ISteamUser_GetSteamID(void*){return steamId;}
API const char* SteamAPI_ISteamFriends_GetPersonaName(void*){return slot==1?"MockHost":"MockGuest";}
API int SteamAPI_ISteamFriends_GetFriendCount(void*,int){return 0;}
API uint64_t SteamAPI_ISteamFriends_GetFriendByIndex(void*,int,int){return 0;}
API const char* SteamAPI_ISteamFriends_GetFriendPersonaName(void*,uint64_t id){
 return id==BASE+1?"MockHost":id==BASE+2?"MockGuest":"";
}
API bool SteamAPI_ISteamFriends_RequestUserInformation(void*,uint64_t,bool){return false;}
API int SteamAPI_ISteamFriends_GetFriendPersonaState(void*,uint64_t){return 0;}
API bool SteamAPI_ISteamFriends_GetFriendGamePlayed(void*,uint64_t,void*){return false;}
API bool SteamAPI_ISteamFriends_SetRichPresence(void*,const char*,const char*){return true;}
API void SteamAPI_ISteamFriends_ActivateGameOverlayInviteDialog(void*,uint64_t){}
API bool SteamAPI_ISteamMatchmaking_InviteUserToLobby(void*,uint64_t,uint64_t){return true;}
API uint64_t SteamAPI_ISteamMatchmaking_CreateLobby(void*,int,int){
 if(!sh)return 0;sh->owner=slot;sh->guest=sh->ready=sh->epoch=0;
 sh->stage[0]=0;sh->bans[0]=0;sh->hostPhase[0]=sh->guestPhase[0]=0;
 struct Created{int32_t result,pad;uint64_t room;} x{1,0,ROOM};
 return complete(513,&x,sizeof(x));
}
API uint64_t SteamAPI_ISteamMatchmaking_RequestLobbyList(void*){
 int cnt=(sh&&sh->owner)?1:0;return complete(510,&cnt,4);
}
API void SteamAPI_ISteamMatchmaking_AddRequestLobbyListStringFilter(void*,const char*,const char*,int){}
API void SteamAPI_ISteamMatchmaking_AddRequestLobbyListDistanceFilter(void*,int){}
API void SteamAPI_ISteamMatchmaking_AddRequestLobbyListResultCountFilter(void*,int){}
API uint64_t SteamAPI_ISteamMatchmaking_GetLobbyByIndex(void*,int){return ROOM;}
API uint64_t SteamAPI_ISteamMatchmaking_JoinLobby(void*,uint64_t id){
 if(!sh||id!=ROOM||!sh->owner)return 0;
 sh->guest=slot;sh->joinTick=GetTickCount64();
 struct Enter{uint64_t room;uint32_t perms;uint8_t locked,pad[3];uint32_t response;} e{ROOM,0,0,{0,0,0},1};
 return complete(504,&e,sizeof(e));
}
API void SteamAPI_ISteamMatchmaking_LeaveLobby(void*,uint64_t){
 if(!sh)return;
 if(sh->owner==slot){sh->owner=sh->guest=sh->ready=0;}
 else if(sh->guest==slot)sh->guest=0;
}
API bool SteamAPI_ISteamMatchmaking_SetLobbyData(void*,uint64_t,const char* key,const char* value){
 if(!sh||sh->owner!=slot)return false;
 char* d=nullptr;
 if(!strcmp(key,"rotm"))d=sh->tag;
 if(!strcmp(key,"name"))d=sh->name;
 if(!strcmp(key,"transport"))d=sh->transport;
 if(!strcmp(key,"stage"))d=sh->stage;
 if(!strcmp(key,"bans"))d=sh->bans;
 if(!strcmp(key,"ready")){sh->ready=atoi(value);return true;}
 if(!strcmp(key,"epoch")){sh->epoch=atoi(value);return true;}
 if(d)strncpy_s(d,128,value,127);
 return true;
}
API const char* SteamAPI_ISteamMatchmaking_GetLobbyData(void*,uint64_t,const char* key){
 if(!sh)return "";
 if(!strcmp(key,"rotm"))return sh->tag;
 if(!strcmp(key,"name"))return sh->name;
 if(!strcmp(key,"transport"))return sh->transport;
 if(!strcmp(key,"stage"))return sh->stage;
 if(!strcmp(key,"bans"))return sh->bans;
 if(!strcmp(key,"ready"))return sh->ready?"1":"0";
 if(!strcmp(key,"epoch")){static char out[18];sprintf_s(out,"%d",(int)sh->epoch);return out;}
 return "";
}
API int SteamAPI_ISteamMatchmaking_GetNumLobbyMembers(void*,uint64_t){
 if(!sh)return 0;
 // The host's Steam lobby roster deliberately lags the P2PSessionRequest
 // callback, reproducing the real-world join/roster race.
 if(slot==sh->owner && sh->guest && GetTickCount64()-sh->joinTick<1800)
     return 1;
 return 1+(sh->guest!=0);
}
API uint64_t SteamAPI_ISteamMatchmaking_GetLobbyMemberByIndex(void*,uint64_t,int ix){
 return sh&&ix==0?BASE+sh->owner:sh&&ix==1&&sh->guest?BASE+sh->guest:0;
}
API uint64_t SteamAPI_ISteamMatchmaking_GetLobbyOwner(void*,uint64_t){
 return sh&&sh->owner&&(slot==sh->owner||slot==sh->guest)?BASE+sh->owner:0;
}
API bool SteamAPI_ISteamMatchmaking_RequestLobbyData(void*,uint64_t){return true;}
API void SteamAPI_ISteamMatchmaking_SetLobbyMemberData(
   void*,uint64_t,const char* key,const char* value){
 if(sh && !strcmp(key,"phase")){
   char* d=slot==sh->owner?sh->hostPhase:sh->guestPhase;
   strncpy_s(d,32,value,31);
 }
}
API const char* SteamAPI_ISteamMatchmaking_GetLobbyMemberData(
  void*,uint64_t,uint64_t id,const char* key){
 if(!sh||strcmp(key,"phase"))return "";
 return id==BASE+sh->owner?sh->hostPhase:id==BASE+sh->guest?sh->guestPhase:"";
}
API bool SteamAPI_ISteamMatchmaking_SendLobbyChatMsg(
  void*,uint64_t lobby,const uint8_t* data,int n){
 if(!sh||lobby!=ROOM||!data||n<1||n>500)return false;
 int destination=(slot==sh->owner?sh->guest:sh->owner);
 if(destination<1||destination>2)return false;
 uint8_t packet[516];uint32_t len=n;int channel=97;
 memcpy(packet,&steamId,8);memcpy(packet+8,&channel,4);
 memcpy(packet+12,&len,4);memcpy(packet+16,data,n);
 sockaddr_in dst{};dst.sin_family=AF_INET;
 dst.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
 dst.sin_port=htons(48040+destination);
 return sendto(udp,(char*)packet,16+n,0,(sockaddr*)&dst,sizeof(dst))==16+n;
}
API int SteamAPI_ISteamMatchmaking_GetLobbyChatEntry(
 void*,uint64_t lobby,int chatId,uint64_t* sender,
 uint8_t* data,int maxBytes,int* entryType){
 if(lobby!=ROOM||!sender||!data||!entryType)return 0;
 auto it=lobbyChat.find(chatId);
 if(it==lobbyChat.end()||it->second.data.size()>(size_t)maxBytes)return 0;
 *sender=it->second.peer;*entryType=1;
 int n=(int)it->second.data.size();
 memcpy(data,it->second.data.data(),n);lobbyChat.erase(it);
 return n;
}
API bool SteamAPI_ISteamNetworking_AllowP2PPacketRelay(void*,bool){return true;}
API bool SteamAPI_ISteamNetworking_AcceptP2PSessionWithUser(void*,uint64_t peer){
 accepted.insert(peer);
 for(auto& p:held[peer])incoming.push_back(std::move(p));
 held.erase(peer);return true;
}
API bool SteamAPI_ISteamNetworking_CloseP2PSessionWithUser(void*,uint64_t peer){
 accepted.erase(peer);requested.erase(peer);sent.erase(peer);held.erase(peer);
 return true;
}
API bool SteamAPI_ISteamNetworking_GetP2PSessionState(void*,uint64_t peer,void* target){
 struct State{uint8_t active,connecting,error,relay;int32_t queuedBytes,queuedPackets;uint32_t remoteIP;uint16_t port;};
 State a{};a.active=(accepted.count(peer)||sent.count(peer))?1:0;a.relay=1;
 memcpy(target,&a,sizeof(a));return true;
}
API bool SteamAPI_ISteamNetworking_SendP2PPacket(void*,uint64_t peer,const uint8_t* data,uint32_t size,int,int channel){
 if(peer<BASE+1||peer>BASE+2||size<1||size>1200||channel<0)return false;
 uint8_t packet[1216];
 memcpy(packet,&steamId,8);memcpy(packet+8,&channel,4);memcpy(packet+12,&size,4);
 memcpy(packet+16,data,size);
 sockaddr_in to{};to.sin_family=AF_INET;to.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
 to.sin_port=htons(48040+(int)(peer-BASE));
 int n=sendto(udp,(char*)packet,16+size,0,(sockaddr*)&to,sizeof(to));
 sent.insert(peer);return n==(int)(16+size);
}
API bool SteamAPI_ISteamNetworking_IsP2PPacketAvailable(void*,uint32_t* size,int channel){
 for(auto& p:incoming)if(p.ch==channel){*size=(uint32_t)p.data.size();return true;}
 return false;
}
API bool SteamAPI_ISteamNetworking_ReadP2PPacket(void*,uint8_t* dst,uint32_t cap,uint32_t* size,uint64_t* peer,int channel){
 for(auto it=incoming.begin();it!=incoming.end();++it)
  if(it->ch==channel){
   if(it->data.size()>cap)return false;
   memcpy(dst,it->data.data(),it->data.size());*size=(uint32_t)it->data.size();*peer=it->peer;
   incoming.erase(it);return true;
  }
 return false;
}
