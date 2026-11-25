"""Local two-peer Steam API mock: validates game UDP <-> Steam transport both ways.
No real Steam account, port forwarding, or network access is used.
"""
from pathlib import Path
import os, socket, subprocess, threading, time, secrets, json

ROOT=Path(__file__).resolve().parent / "runtime"
ROOM=109775240917246251
processes=[]
logs=[]
stop=threading.Event()
server_traffic=[]

def game_server():
    sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
    sock.bind(("127.0.0.1",7777))
    sock.settimeout(.25)
    try:
        while not stop.is_set():
            try: msg,peer=sock.recvfrom(65535)
            except socket.timeout:continue
            server_traffic.append((len(msg),peer[0]))
            sock.sendto(msg,peer)
    finally:sock.close()

def stat(name):
    p=ROOT/name/"ipc"/"state.txt"
    if not p.exists():return {}
    return dict(line.split("\t",1) for line in p.read_text(encoding="utf-8").splitlines() if "\t" in line)

def wait_state(name,target,seconds=18):
    start=time.monotonic()
    while time.monotonic()-start<seconds:
        state=stat(name)
        if state.get("status")==target:return state
        if state.get("status")=="error":raise AssertionError(f"{name} error: {state.get('error')}")
        time.sleep(.12)
    raise AssertionError(f"{name} timeout for {target}: {stat(name)}")

def command(name,cmd):
    p=ROOT/name/"ipc"/"command.txt"
    start=time.monotonic()
    while p.exists() and time.monotonic()-start<4:time.sleep(.05)
    assert not p.exists(),p
    p.write_text(cmd,encoding="utf-8")

def main():
    for name,num in [("host","1"),("guest","2")]:
        d=ROOT/name
        ipc=d/"ipc"
        ipc.mkdir(parents=True,exist_ok=True)
        (ipc/"heartbeat.txt").write_text(str(time.time()))
        for fname in ("state.txt","lobbies.txt","friends.txt","members.txt","command.txt"):
            p=ipc/fname
            if p.exists():p.unlink()
        env=os.environ.copy()
        env["ROTM_MOCK_SLOT"]=num
        logfile=(d/"mock-bridge.log").open("wb")
        logs.append(logfile)
        proc=subprocess.Popen([str(d/"RotMSteamBridge.exe"),"--serve",str(ipc)],
            cwd=str(d),env=env,stdout=logfile,stderr=subprocess.STDOUT)
        processes.append(proc)
        print("MOCK_STARTED",name,proc.pid,flush=True)
        wait_state(name,"ready")
    command("host","create|p2p|Mock host")
    state=wait_state("host","hosting")
    assert int(state["lobby"])==ROOM
    assert not state["endpoint"]
    print("MOCK_REALISM lobby created, no IP published",flush=True)
    command("guest","list")
    wait_state("guest","listed")
    for _ in range(40):
        rows=(ROOT/"guest"/"ipc"/"lobbies.txt").read_text(encoding="utf-8").splitlines()
        if any(row.startswith(f"{ROOM}\t") for row in rows):break
        time.sleep(.1)
    assert any(row.startswith(f"{ROOM}\t") for row in rows),rows
    print("LOBBY_DISCOVERY_BEFORE_MEMBERSHIP_PASS",flush=True)
    command("guest",f"join|{ROOM}")
    wait_state("guest","waiting_host")
    command("host","ready")
    wait_state("guest","joined")
    # The host status snapshot is written asynchronously to the guest's.
    for _ in range(60):
        h=stat("host");g=stat("guest")
        if (g.get("p2p_verified")=="true"
            and int(h.get("p2p_control_in","0"))>0
            and int(g.get("p2p_control_in","0"))>0):break
        time.sleep(.1)
    assert g["p2p_verified"]=="true",g
    assert int(h["p2p_control_in"])>0,h
    assert int(g["p2p_control_in"])>0,g
    print("MOCK_P2P_TWO_WAY_HANDSHAKE_OK",h["p2p_control_in"],g["p2p_control_in"],flush=True)
    for _ in range(40):
        rows=(ROOT/"host"/"ipc"/"members.txt").read_text(encoding="utf-8").splitlines()
        if len(rows)==2:break
        time.sleep(.12)
    assert len(rows)==2,rows
    assert rows[0].split("\t")[2]=="1" and rows[1].split("\t")[2]=="0"
    assert "MockHost" in rows[0] and "MockGuest" in rows[1]
    print("REAL_LOBBY_MEMBER_ROSTER_HOST_AND_GUEST_PASS",flush=True)
    # A Windows client can keep the old status snapshot open without
    # FILE_SHARE_DELETE. Atomic replace must retry, never kill the Steam API.
    with (ROOT/"host"/"ipc"/"state.txt").open("rb") as held:
        command("host","roster")
        time.sleep(.8)
        assert processes[0].poll() is None, "Bridge died on Windows state.txt share violation"
        assert held.read(6), "Existing snapshot was unexpectedly truncated"
    print("WINDOWS_IPC_FILE_SHARING_LOCK_BRIDGE_SURVIVES_PASS",flush=True)
    host_log=(ROOT/"host"/"mock-bridge.log").read_text(encoding="utf-8",errors="replace")
    assert "P2P_SESSION_PENDING_LOBBY_ROSTER" in host_log, host_log[-1000:]
    assert "P2P_SESSION_ACCEPTED" in host_log, host_log[-1000:]
    print("LOBBY_ROSTER_RACE_RECOVERED",flush=True)
    command("guest", "game_start")
    wait_state("guest", "connecting_game")
    command("guest", "list")
    wait_state("guest", "connecting_game")
    assert stat("guest")["role"]=="guest"
    print("LOBBY_SEARCH_DID_NOT_OVERRIDE_GAME_CONNECTION",flush=True)
    game=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
    game.bind(("127.0.0.1",0));game.settimeout(8)
    try:
        destination=("127.0.0.1",int(g["local_port"]))
        for size in (64,1055,1300,4096,8192,16000,65507):
            data=secrets.token_bytes(size)
            game.sendto(data,destination)
            answer,src=game.recvfrom(65535)
            assert answer==data,(size,len(answer),"payload corrupted")
            assert src==destination,(size,src,destination)
            print("UDP_STEAM_P2P_ECHO_OK",size,flush=True)
    finally:game.close()
    h=stat("host");g=stat("guest")
    # IPC status snapshots update every three seconds, independently from data forwarding.
    for _ in range(60):
        h=stat("host");g=stat("guest")
        if min(int(h["p2p_in"]),int(h["p2p_out"]),
               int(g["p2p_in"]),int(g["p2p_out"]))>=7:
            break
        time.sleep(.1)
    assert int(h["p2p_in"])>=7 and int(h["p2p_out"])>=7, h
    assert int(g["p2p_in"])>=7 and int(g["p2p_out"])>=7, g
    command("guest", "game_ready")
    playing=wait_state("guest", "playing")
    assert playing["client_game_ready"]=="true"
    command("guest", "list")
    wait_state("guest", "playing")
    command("guest", "join|"+str(ROOM))
    wait_state("guest", "playing")
    command("guest", "create|p2p|Incorrect host from guest")
    wait_state("guest", "playing")
    assert stat("guest")["role"]=="guest"
    print("GUEST_GAME_LOGIN_AND_DUPLICATE_JOIN_GUARD_PASS",flush=True)
    command("guest", "game_disconnected")
    wait_state("guest", "disconnected")
    # Unreal map travel: host temporarily closes the level, then reopens it;
    # the same Steam lobby and local P2P proxy survive the transition.
    command("host","busy")
    for _ in range(65):
        h=stat("host");g=stat("guest")
        if h.get("host_ready")=="false" and g.get("remote_ready")=="false":break
        time.sleep(.15)
    assert h.get("host_ready")=="false" and g.get("remote_ready")=="false",(h,g)
    assert g.get("p2p_verified")=="true"
    print("MAP_TRAVEL_PAUSE_PROPAGATED",flush=True)
    command("host","ready")
    for _ in range(65):
        h=stat("host");g=stat("guest")
        if h.get("game_epoch")=="2" and g.get("game_epoch")=="2" and g.get("remote_ready")=="true":break
        time.sleep(.15)
    assert h.get("game_epoch")=="2" and g.get("game_epoch")=="2",(h,g)
    new_game=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
    new_game.bind(("127.0.0.1",0));new_game.settimeout(8)
    try:
        msg=secrets.token_bytes(2000)
        new_game.sendto(msg,("127.0.0.1",int(g["local_port"])))
        reply,_=new_game.recvfrom(65535)
        assert reply==msg
    finally:new_game.close()
    print("MAP_TRAVEL_NEW_GAME_PORT_RECONNECTED",flush=True)
    command("host","stage|hub")
    for _ in range(80):
        h=stat("host");g=stat("guest")
        if h.get("session_stage")=="hub" and g.get("session_stage")=="hub":break
        time.sleep(.1)
    assert h["session_stage"]=="hub" and g["session_stage"]=="hub",(h,g)
    command("host","stage|run")
    for _ in range(80):
        h=stat("host");g=stat("guest")
        if h.get("session_stage")=="run" and g.get("session_stage")=="run":break
        time.sleep(.1)
    assert h["session_stage"]=="run" and g["session_stage"]=="run",(h,g)
    print("HUB_TO_RUN_SESSION_STAGE_REPLICATED_PASS",flush=True)
    assert all(peer=="127.0.0.1" for _,peer in server_traffic)
    print("TRANSPORT_COUNTS",json.dumps({"host":{"in":h["p2p_in"],"out":h["p2p_out"],"drop":h["p2p_dropped"]},"guest":{"in":g["p2p_in"],"out":g["p2p_out"],"drop":g["p2p_dropped"]}}),flush=True)
    print("TWO_IDENTITY_STEAM_TUNNEL_MOCK_TEST_PASS",flush=True)
    guest_id=next(row.split("\t")[0] for row in
        (ROOT/"host"/"ipc"/"members.txt").read_text(encoding="utf-8").splitlines()
        if "MockGuest" in row)
    command("host","kick|"+guest_id)
    wait_state("guest","kicked",10)
    for _ in range(45):
        h=stat("host")
        if h.get("member_count")=="1":break
        time.sleep(.12)
    assert h["member_count"]=="1",h
    print("STEAM_LOBBY_OWNER_KICK_AND_REVOKE_P2P_PASS",flush=True)
    command("guest","join|"+str(ROOM))
    wait_state("guest","kicked")
    print("KICKED_MEMBER_CANNOT_REJOIN_SAME_LOBBY_PASS",flush=True)

thread=threading.Thread(target=game_server,daemon=True)
try:
    thread.start()
    time.sleep(.2)
    main()
finally:
    stop.set()
    for name in ("guest","host"):
        try:command(name,"shutdown")
        except:pass
    for p in processes:
        try:p.wait(timeout=6)
        except subprocess.TimeoutExpired:p.kill()
    for f in logs:f.close()
    print("MOCK_PROCESSES_CLOSED",flush=True)
