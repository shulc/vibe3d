module perspective_camera_rig_helpers;
import core.sys.posix.signal : SIGTERM,SIGKILL;
import core.thread : Thread;
import core.time : msecs;
import std.process : Pid, Config, spawnProcess, wait, tryWait, thisProcessID, kill;
import std.socket : Socket,AddressFamily,SocketType,ProtocolType,InternetAddress,SocketOptionLevel,SocketOption;
import std.stdio : File,stdin;
import std.file : mkdirRecurse,rmdirRecurse,exists,readText,getcwd,symlink;
import std.path : buildPath;
import std.conv : to;
import http_client : getJson,postJson;

struct PerspectiveCameraRig {
    string base,root,logPath;
    ushort port;
    Pid pid;
    static PerspectiveCameraRig launch() {
        PerspectiveCameraRig r;
        auto s=new Socket(AddressFamily.INET,SocketType.STREAM,ProtocolType.TCP);
        s.bind(new InternetAddress(InternetAddress.ADDR_ANY,0));
        r.port=(cast(InternetAddress)s.localAddress).port;s.close();
        r.base="http://127.0.0.1:"~r.port.to!string;
        r.root=buildPath("/tmp","vibe3d_perspective_camera_"~thisProcessID().to!string~"_"~r.port.to!string);
        mkdirRecurse(r.root);
        scope(failure)r.stop();
        const repo=getcwd();
        symlink(buildPath(repo,"config"),buildPath(r.root,"config"));
        symlink(buildPath(repo,"assets"),buildPath(r.root,"assets"));
        r.logPath=buildPath(r.root,"editor.log");
        auto f=File(r.logPath,"wb");
        string[string] env=["VIBE3D_CONFIG_DIR":r.root,"VIBE3D_TEST_DIRTY_KEY":"1"];
        r.pid=spawnProcess([buildPath(repo,"vibe3d"),"--test","--http-port",r.port.to!string,
            "--viewport","1152x974"],stdin,f,f,env,Config.none,r.root);
        bool ready;
        foreach(_;0..1200) {
            if(tryWait(r.pid).terminated)break;
            try {auto j=getJson("/api/registry",r.base);if(j.toString.length>10000){ready=true;break;}}
            catch(Exception){}
            Thread.sleep(25.msecs);
        }
        assert(ready,"OWNED_CAMERA_REGISTRY: "~readText(r.logPath));
        const c=getJson("/api/camera",r.base);
        assert(c["width"].integer==1152&&c["height"].integer==974&&
               c["vpX"].integer==150&&c["vpY"].integer==28,"OWNED_CAMERA_REAL_LAYOUT");
        return r;
    }
    void command(string line) {
        auto r=postJson("/api/command",line,base);
        assert(r["status"].str=="ok","OWNED_CAMERA_COMMAND "~line~": "~r.toString);
    }
    void stop() {
        if(pid !is null) {
            try kill(pid,SIGTERM);catch(Exception){}
            bool ended;
            foreach(_;0..40) {
                if(tryWait(pid).terminated){ended=true;break;}
                Thread.sleep(25.msecs);
            }
            if(!ended){try kill(pid,SIGKILL);catch(Exception){} try wait(pid);catch(Exception){}}
            pid=null;
        }
        if(root.length&&exists(root))rmdirRecurse(root);
        auto probe=new Socket(AddressFamily.INET,SocketType.STREAM,ProtocolType.TCP);
        scope(exit)probe.close();
        probe.setOption(SocketOptionLevel.SOCKET,SocketOption.REUSEADDR,1);
        probe.bind(new InternetAddress(InternetAddress.ADDR_ANY,port));
    }
}
