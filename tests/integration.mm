#import <Foundation/Foundation.h>
#include "support.hpp"
#include "axial/connexion.h"
#include <cerrno>
#define __cdecl
#include <navlib/navlib.h>
#include <dlfcn.h>
#include <atomic>
#include <functional>
#include <iostream>
#include <vector>
extern "C" void AxialPreviewStart();
extern "C" void AxialPreviewStop();
extern "C" bool AxialPreviewRead(uint32_t,double*,uint32_t*);
extern "C" bool AxialPreviewPopLog(uint64_t*,uint32_t*,uint32_t*,uint32_t*,uint32_t*,uint32_t*);
extern "C" uint64_t AxialPreviewLostLogs();
#define CHECK(x) do{if(!(x)){std::cerr<<__FILE__<<":"<<__LINE__<<" " #x "\n";throw std::runtime_error(#x);}}while(0)
namespace {
std::atomic<int> addedCount=0,motionCount=0,buttonCount=0,removedCount=0;
std::atomic<int> lastX=0,lastY=0,lastButtons=0;
std::atomic<int> appPressed=0,appReleased=0;
void appMessage(uint32_t,uint32_t type,void* data){auto s=static_cast<ConnexionDeviceState*>(data);CHECK(type==0x33645352);if(s->command==11){CHECK(s->value==2);if(s->appEventPressed)++appPressed;else ++appReleased;}}
std::atomic<uint16_t> client=0;
void (*cleanupDuringMessage)()=nullptr;
std::atomic<int> reentrantCleanups=0;
void (*unregisterDuringReset)(uint16_t)=nullptr;
uint16_t retiringClient=0;
int retiredCallbacks=0,survivingCallbacks=0;
void unregisterMessage(uint32_t,uint32_t,void* data){
    auto state=static_cast<ConnexionDeviceState*>(data);
    if(state->client==retiringClient){
        CHECK(state->command==3&&retiredCallbacks==0);++retiredCallbacks;unregisterDuringReset(retiringClient);
    }else ++survivingCallbacks;
}
void added(uint32_t){++addedCount;}
void removed(uint32_t){++removedCount;}
void message(uint32_t,uint32_t type,void* data){auto s=static_cast<ConnexionDeviceState*>(data);CHECK(type==0x33645352);if(cleanupDuringMessage&&s->command==3){auto cleanup=cleanupDuringMessage;cleanupDuringMessage=nullptr;cleanup();++reentrantCleanups;return;}CHECK(s->client==client.load());if(s->command==3){lastX=s->axis[0];lastY=s->axis[1];++motionCount;}if(s->command==2){lastButtons=s->buttons;++buttonCount;}}
bool waitFor(std::function<bool()> condition,int attempts=300){for(int i=0;i<attempts;++i){if(condition())return true;CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,true);}return condition();}
struct CameraState {
    navlib::matrix_t matrix{};
    std::atomic<int> frames=0,transactions=0,motion=0;
    bool perspective=true,rotatable=true;
    decltype(&navlib::NlClose) closeDuringGet=nullptr;
    navlib::nlHandle_t handle=0;
    bool wasClosed=false;
    std::vector<std::string> commands;
    navlib::box_t extents{{-10,-10,-10},{10,10,10}};
    CameraState(){matrix.m00=matrix.m11=matrix.m22=matrix.m33=1;matrix.m23=10;}
};
long getCamera(navlib::param_t param,navlib::property_t name,navlib::value_t* out){
    auto& c=*reinterpret_cast<CameraState*>(param);
    CHECK(!c.wasClosed);
    if(!strcmp(name,"view.affine"))*out=c.matrix;
    else if(!strcmp(name,"view.perspective"))*out=c.perspective;
    else if(!strcmp(name,"view.rotatable"))*out=c.rotatable;
    else if(!strcmp(name,"view.target"))*out=navlib::point_t{0,0,0};
    else if(!strcmp(name,"view.extents"))*out=c.extents;
    else if(!strcmp(name,"model.extents"))*out=navlib::box_t{{-1,-1,-1},{1,1,1}};
    else return navlib::make_result_code(0x201);
    if(c.closeDuringGet&&!strcmp(name,"view.perspective")){auto close=c.closeDuringGet;c.closeDuringGet=nullptr;CHECK(close(c.handle)==0);c.wasClosed=true;}
    return 0;
}
long setCamera(navlib::param_t param,navlib::property_t name,const navlib::value_t* value){
    auto& c=*reinterpret_cast<CameraState*>(param);
    if(!strcmp(name,"view.affine")){c.matrix=value->matrix;++c.frames;}
    else if(!strcmp(name,"transaction")){CHECK(value->l==0||value->l==1);c.transactions+=value->l?1:-1;CHECK(c.transactions>=0&&c.transactions<=1);}
    else if(!strcmp(name,"motion"))c.motion=value->b;
    else if(!strcmp(name,"view.extents"))c.extents=value->box;
    else if(!strcmp(name,"commands.activeCommand"))c.commands.emplace_back(value->string.p);
    return 0;
}
}
int main(int argc,char** argv){try {@autoreleasepool {
    if(argc!=4){std::cerr<<"usage: integration-tests service client-dylib navlib-dylib\n";return 2;}
    MockService service(argv[1],true);
    CHECK(waitFor([]{auto status=sn::request("{\"op\":\"status\"}");return status.find("\"accessibility\":true")!=std::string::npos||status.find("\"accessibility\":false")!=std::string::npos;}));
    void* legacy=dlopen(argv[2],RTLD_NOW|RTLD_LOCAL);CHECK(legacy);
    auto install=reinterpret_cast<decltype(&SetConnexionHandlers)>(dlsym(legacy,"SetConnexionHandlers"));
    auto reg=reinterpret_cast<decltype(&RegisterConnexionClient)>(dlsym(legacy,"RegisterConnexionClient"));
    auto mask=reinterpret_cast<decltype(&SetConnexionClientButtonMask)>(dlsym(legacy,"SetConnexionClientButtonMask"));
    auto control=reinterpret_cast<decltype(&ConnexionClientControl)>(dlsym(legacy,"ConnexionClientControl"));
    auto cleanup=reinterpret_cast<decltype(&CleanupConnexionHandlers)>(dlsym(legacy,"CleanupConnexionHandlers"));
    auto unregister=reinterpret_cast<decltype(&UnregisterConnexionClient)>(dlsym(legacy,"UnregisterConnexionClient"));
    CHECK(install&&reg&&mask&&control&&cleanup&&unregister);
    CHECK(install(message,added,removed,false)==0);
    client=reg(0,reinterpret_cast<const uint8_t*>("\013PrusaSlicer"),1,0x3fff);CHECK(client!=0);
    int inject=sn::openEvents(sn::Flags::replay);CHECK(inject>=0);
    CHECK(waitFor([]{auto s=sn::request("{\"op\":\"status\"}");return s.find("\"clients\":2")!=std::string::npos;}));
    sn::Event e;e.device=1;e.vendor=0x046d;e.product=0xc627;e.kind=sn::Kind::added;e.received=sn::now();
    CHECK(sn::writeAll(inject,&e,sizeof(e)));CHECK(waitFor([]{return addedCount==1;}));
    int32_t device=0;CHECK(control(client,0x33646964,0,&device)==0);CHECK(uint32_t(device)==0x046dc627);
    // Device IDs grow across hotplug cycles; IDs 1 and 17 must not alias.
    auto another=e;another.device=17;another.vendor=0x256f;another.product=0xc635;
    CHECK(sn::writeAll(inject,&another,sizeof(another)));CHECK(waitFor([]{return addedCount==2;}));
    another.kind=sn::Kind::removed;CHECK(sn::writeAll(inject,&another,sizeof(another)));CHECK(waitFor([]{return removedCount==1;}));
    CHECK(control(client,0x33646964,0,&device)==0);CHECK(uint32_t(device)==0x046dc627);
    CHECK(sn::request("{\"op\":\"status\"}").find("\"product\":50727")!=std::string::npos);
    e.kind=sn::Kind::motion;e.axes={350,0,0,0,0,0};e.received=sn::now();CHECK(sn::writeAll(inject,&e,sizeof(e)));CHECK(waitFor([]{return lastX==350;}));
    e.kind=sn::Kind::buttons;e.buttons=5;mask(client,1);CHECK(sn::writeAll(inject,&e,sizeof(e)));CHECK(waitFor([]{return lastButtons==1;}));
    std::string config=R"({"op":"setConfig","config":{"version":1,"profiles":{"*":{"gain":[2,1,1,1,1,1]}}}})";
    CHECK(sn::request(config).find("\"ok\":true")!=std::string::npos);
    CHECK(sn::request(R"({"op":"setConfig","config":{"version":1,"profiles":{"*":{"led":false}}}})").find("\"ok\":true")!=std::string::npos);
    CHECK(sn::request("{\"op\":\"getConfig\"}").find("\"led\":false")!=std::string::npos);
    CHECK(sn::request(R"({"op":"setConfig","config":{"version":1,"profiles":{},"web":{"enabled":"true"}}})").find("error")!=std::string::npos);
    CHECK(sn::request(R"({"op":"setConfig","config":{"version":1,"profiles":{},"web":{"enabled":false}}})").find("\"ok\":true")!=std::string::npos);
    CHECK(sn::request(R"({"op":"setConfig","config":{"version":1,"profiles":{"*":{"led":1}}}})").find("error")!=std::string::npos);
    CHECK(sn::request(config).find("\"ok\":true")!=std::string::npos);
    e.kind=sn::Kind::motion;e.received=sn::now();CHECK(sn::writeAll(inject,&e,sizeof(e)));CHECK(waitFor([]{return lastX==700;}));
    CHECK(sn::request(R"({"op":"setConfig","config":{"version":1,"profiles":{"*":{"gain":[-1,1,1,1,1,1]}}}})").find("error")!=std::string::npos);
    for(const char* invalid:{R"({"buttons":[{"keyCode":{}}]})",R"({"buttons":[{"keyCode":1.5}]})",R"({"buttons":[{"modifiers":-1}]})",R"({"buttons":[{"command":42}]})",R"({"dominant":1})"}){
        CHECK(sn::request(std::string("{\"op\":\"setConfig\",\"config\":{\"version\":1,\"profiles\":{\"*\":")+invalid+"}}}").find("error")!=std::string::npos);
    }
    CHECK(sn::request(R"({"op":"setConfig","config":{"version":1,"profiles":{"*":{"buttons":[{"action":"dominant"}]}}}})").find("\"ok\":true")!=std::string::npos);
    e.kind=sn::Kind::buttons;e.buttons=0;CHECK(sn::writeAll(inject,&e,sizeof(e)));e.buttons=1;CHECK(sn::writeAll(inject,&e,sizeof(e)));
    e.kind=sn::Kind::motion;e.axes={100,20,0,0,0,0};CHECK(sn::writeAll(inject,&e,sizeof(e)));CHECK(waitFor([]{return lastX==100;}));CHECK(lastY==0);
    CHECK(sn::request(config).find("\"ok\":true")!=std::string::npos);
    e.kind=sn::Kind::removed;e.axes={};e.buttons=0;CHECK(sn::writeAll(inject,&e,sizeof(e)));CHECK(waitFor([]{return removedCount==2;}));
    unregister(client);CHECK(waitFor([]{return sn::request("{\"op\":\"status\"}").find("\"clients\":1")!=std::string::npos;}));
    cleanup();int saved=motionCount;CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.02,true);CHECK(saved==motionCount);
    CHECK(waitFor([]{return sn::request("{\"op\":\"status\"}").find("\"clients\":1")!=std::string::npos;}));
    // Client handles must remain unique when the 16-bit counter wraps.
    CHECK(install(nullptr,nullptr,nullptr,false)==0);auto retained=reg(0,nullptr,1,0);
    for(int i=0;i<65536;++i){auto temporary=reg(0,nullptr,1,0);CHECK(temporary&&temporary!=retained);unregister(temporary);}
    unregister(retained);cleanup();
    CHECK(install(unregisterMessage,nullptr,nullptr,false)==0);
    retiringClient=reg(0,nullptr,1,0x3fff);auto survivor=reg(0,nullptr,1,0x3fff);unregisterDuringReset=unregister;
    CHECK(waitFor([]{return sn::request("{\"op\":\"status\"}").find("\"clients\":2")!=std::string::npos;}));
    auto reset=e;reset.kind=sn::Kind::reset;CHECK(sn::writeAll(inject,&reset,sizeof(reset)));CHECK(waitFor([]{return retiredCallbacks==1;}));
    reset.kind=sn::Kind::motion;CHECK(sn::writeAll(inject,&reset,sizeof(reset)));CHECK(waitFor([]{return survivingCallbacks>0;}));
    unregister(survivor);cleanup();
    CHECK(waitFor([]{return sn::request("{\"op\":\"status\"}").find("\"clients\":1")!=std::string::npos;}));
    // Same ABI using a worker callback thread, as Blender does.
    CHECK(install(appMessage,added,removed,false)==0);client=reg(0x626c6e64,reinterpret_cast<const uint8_t*>("\007blender"),1,0x3f00);mask(client,0);
    CHECK(waitFor([]{return sn::request("{\"op\":\"status\"}").find("\"clients\":2")!=std::string::npos;}));
    e.kind=sn::Kind::added;e.buttons=0;CHECK(sn::writeAll(inject,&e,sizeof(e)));
    e.kind=sn::Kind::buttons;e.buttons=1u<<10;CHECK(sn::writeAll(inject,&e,sizeof(e)));CHECK(waitFor([]{return appPressed==1;}));
    auto globalReset=e;globalReset.kind=sn::Kind::reset;globalReset.device=0;globalReset.buttons=0;
    CHECK(sn::writeAll(inject,&globalReset,sizeof(globalReset)));CHECK(waitFor([]{return appReleased==1;}));
    e.kind=sn::Kind::removed;e.buttons=0;CHECK(sn::writeAll(inject,&e,sizeof(e)));cleanup();
    CHECK(waitFor([]{return sn::request("{\"op\":\"status\"}").find("\"clients\":1")!=std::string::npos;}));
    CHECK(install(message,added,removed,true)==0);client=reg(0,nullptr,1,0x3f00);CHECK(client);
    e.kind=sn::Kind::motion;e.axes[0]=11;std::this_thread::sleep_for(std::chrono::milliseconds(30));CHECK(sn::writeAll(inject,&e,sizeof(e)));CHECK(waitFor([]{return lastX==22;}));cleanup();
    CHECK(waitFor([]{return sn::request("{\"op\":\"status\"}").find("\"clients\":1")!=std::string::npos;}));
    // A callback may tear down every registration while handling a reset, which
    // otherwise continues into its button callback and the next registration.
    CHECK(install(message,added,removed,false)==0);client=reg(0,nullptr,1,0x3fff);CHECK(reg(0,nullptr,1,0x3fff));
    CHECK(waitFor([]{return sn::request("{\"op\":\"status\"}").find("\"clients\":2")!=std::string::npos;}));
    cleanupDuringMessage=cleanup;e.kind=sn::Kind::reset;e.axes={};e.buttons=0;
    CHECK(sn::writeAll(inject,&e,sizeof(e)));CHECK(waitFor([]{return reentrantCleanups==1;}));
    CHECK(dlclose(legacy)==0);CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.05,true);
    void* library=dlopen(argv[3],RTLD_NOW|RTLD_LOCAL);CHECK(library);
    auto create=reinterpret_cast<decltype(&navlib::NlCreate)>(dlsym(library,"NlCreate"));
    auto write=reinterpret_cast<decltype(&navlib::NlWriteValue)>(dlsym(library,"NlWriteValue"));
    auto read=reinterpret_cast<decltype(&navlib::NlReadValue)>(dlsym(library,"NlReadValue"));
    auto type=reinterpret_cast<decltype(&navlib::NlGetType)>(dlsym(library,"NlGetType"));
    auto close=reinterpret_cast<decltype(&navlib::NlClose)>(dlsym(library,"NlClose"));
    CHECK(create&&write&&read&&type&&close);CHECK(type("view.affine")==navlib::matrix_type);CHECK(type("unknown")==navlib::unknown_type);
    CameraState camera;navlib::accessor_t accessors[]={
        {"view.affine",getCamera,setCamera,reinterpret_cast<uint64_t>(&camera)},
        {"view.perspective",getCamera,nullptr,reinterpret_cast<uint64_t>(&camera)},
        {"view.rotatable",getCamera,nullptr,reinterpret_cast<uint64_t>(&camera)},
        {"view.target",getCamera,nullptr,reinterpret_cast<uint64_t>(&camera)},
        {"view.extents",getCamera,setCamera,reinterpret_cast<uint64_t>(&camera)},
        {"model.extents",getCamera,nullptr,reinterpret_cast<uint64_t>(&camera)},
        {"motion",nullptr,setCamera,reinterpret_cast<uint64_t>(&camera)},
        {"commands.activeCommand",nullptr,setCamera,reinterpret_cast<uint64_t>(&camera)},
        {"transaction",nullptr,setCamera,reinterpret_cast<uint64_t>(&camera)}};
    navlib::nlCreateOptions_t options{sizeof(options),false,navlib::row_major_order};navlib::nlHandle_t handle;
    CHECK(create(&handle,"mock-fusion",accessors,std::size(accessors),&options)==0);
    // Presence must follow hardware events instead of always reporting true.
    navlib::value_t present;CHECK(read(handle,"device.present",&present)==0);CHECK(!present.b);
    e.kind=sn::Kind::added;CHECK(sn::writeAll(inject,&e,sizeof(e)));
    CHECK(waitFor([&]{return read(handle,"device.present",&present)==0&&present.b;}));
    e.kind=sn::Kind::removed;CHECK(sn::writeAll(inject,&e,sizeof(e)));
    CHECK(waitFor([&]{return read(handle,"device.present",&present)==0&&!present.b;}));
    e.kind=sn::Kind::added;CHECK(sn::writeAll(inject,&e,sizeof(e)));
    CHECK(waitFor([&]{return read(handle,"device.present",&present)==0&&present.b;}));
    navlib::value_t timing(long(1));CHECK(write(handle,"frame.timingSource",&timing)==0);
    CHECK(waitFor([]{return sn::request("{\"op\":\"status\"}").find("\"clients\":2")!=std::string::npos;}));
    e.kind=sn::Kind::motion;e.axes={350,0,0,0,0,0};e.received=sn::now();CHECK(sn::writeAll(inject,&e,sizeof(e)));CHECK(waitFor([&]{return camera.motion==1;}));
    navlib::value_t time(100.0);CHECK(write(handle,"frame.time",&time)==0);CHECK(camera.frames>0);CHECK(camera.matrix.m03>0);CHECK(camera.transactions==0);
    camera.perspective=false;e.axes={0,350,0,0,0,0};e.received=sn::now();CHECK(sn::writeAll(inject,&e,sizeof(e)));CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.02,true);
    CHECK(waitFor([&]{time.d+=16;CHECK(write(handle,"frame.time",&time)==0);return camera.extents.max.x>10;}));
    auto validExtents=camera.extents;int validFrames=camera.frames;
    camera.extents.max.x=std::numeric_limits<double>::infinity();time.d+=16;
    CHECK(write(handle,"frame.time",&time)==0);CHECK(camera.frames==validFrames);CHECK(camera.transactions==0);camera.extents=validExtents;
    e.axes={};CHECK(sn::writeAll(inject,&e,sizeof(e)));CHECK(waitFor([&]{return camera.motion==0;}));
    int frames=camera.frames;time=132.0;CHECK(write(handle,"frame.time",&time)==0);CHECK(camera.frames==frames);
    navlib::value_t invalid(1.0);CHECK(write(handle,"active",&invalid)!=0);CHECK(read(handle,"unknown",&invalid)!=0);
    e.kind=sn::Kind::command;e.flags=0x10000;e.received=sn::now();double beforeFit=camera.matrix.m23;
    CHECK(sn::writeAll(inject,&e,sizeof(e)));CHECK(waitFor([&]{return camera.matrix.m23!=beforeFit;}));CHECK(camera.transactions==0);
    CHECK(close(handle)==0);CHECK(close(handle)!=0);
    CHECK(waitFor([]{return sn::request("{\"op\":\"status\"}").find("\"clients\":1")!=std::string::npos;}));
    // Per-device bindings and edge state; neutral motion must not clear a held button.
    CHECK(sn::request(R"({"op":"setConfig","config":{"version":1,"profiles":{"*@046d:c627":{"buttons":[{"command":"first-device"}]},"*@256f:c635":{"buttons":[{"command":"second-device"}]}}}})").find("\"ok\":true")!=std::string::npos);
    CHECK(create(&handle,"multi-device",accessors,std::size(accessors),&options)==0);
    CHECK(write(handle,"frame.timingSource",&timing)==0);
    e.kind=sn::Kind::added;e.flags=0;e.buttons=0;e.axes={};CHECK(sn::writeAll(inject,&e,sizeof(e)));
    another=e;another.device=17;another.vendor=0x256f;another.product=0xc635;CHECK(sn::writeAll(inject,&another,sizeof(another)));
    auto button=[&](sn::Event event,uint32_t buttons){event.kind=sn::Kind::buttons;event.buttons=buttons;CHECK(sn::writeAll(inject,&event,sizeof(event)));};
    CHECK(waitFor([&]{
        button(e,0);button(another,0);button(e,1);button(another,1);
        return std::find(camera.commands.begin(),camera.commands.end(),"first-device")!=camera.commands.end()&&std::find(camera.commands.begin(),camera.commands.end(),"second-device")!=camera.commands.end();
    }));
    // Drain the readiness probes, then start with both devices released.
    button(e,0);button(another,0);CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.05,false);camera.commands.clear();
    button(e,1);button(another,1);CHECK(waitFor([&]{return camera.commands.size()==2;}));
    CHECK(camera.commands[0]=="first-device"&&camera.commands[1]=="second-device");
    e.kind=sn::Kind::motion;e.axes={};CHECK(sn::writeAll(inject,&e,sizeof(e)));button(e,1);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.03,false);CHECK(camera.commands.size()==2);
    button(e,0);button(another,0);CHECK(waitFor([&]{return camera.commands.size()==4;}));
    CHECK(camera.commands[2].empty()&&camera.commands[3].empty());
    another.kind=sn::Kind::removed;CHECK(sn::writeAll(inject,&another,sizeof(another)));
    CHECK(close(handle)==0);
    CHECK(waitFor([]{return sn::request("{\"op\":\"status\"}").find("\"clients\":1")!=std::string::npos;}));
    CHECK(sn::request(config).find("\"ok\":true")!=std::string::npos);
    camera.matrix={};camera.matrix.m00=camera.matrix.m11=camera.matrix.m22=camera.matrix.m33=1;camera.matrix.m32=10;
    options.options=navlib::none;
    CHECK(create(&handle,"column-major",accessors,std::size(accessors),&options)==0);
    CHECK(write(handle,"frame.timingSource",&timing)==0);
    CHECK(waitFor([]{return sn::request("{\"op\":\"status\"}").find("\"clients\":2")!=std::string::npos;}));
    e.kind=sn::Kind::motion;e.flags=sn::Flags::orbit;e.axes={350,0,0,0,0,0};e.received=sn::now();CHECK(sn::writeAll(inject,&e,sizeof(e)));CHECK(waitFor([&]{return camera.motion==1;}));
    time=100.0;CHECK(write(handle,"frame.time",&time)==0);CHECK(camera.matrix.m30>0);CHECK(camera.matrix.m03==0);CHECK(close(handle)==0);
    CHECK(waitFor([]{return sn::request("{\"op\":\"status\"}").find("\"clients\":1")!=std::string::npos;}));
    CHECK(create(&handle,"automatic-clock",accessors,std::size(accessors),&options)==0);
    CHECK(waitFor([]{return sn::request("{\"op\":\"status\"}").find("\"clients\":2")!=std::string::npos;}));
    int automaticFrames=camera.frames;e.received=sn::now();CHECK(sn::writeAll(inject,&e,sizeof(e)));
    CHECK(waitFor([&]{return camera.frames>automaticFrames;}));
    CHECK(waitFor([&]{return camera.motion==0;})); // stale cap input stops the clock
    automaticFrames=camera.frames;CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.05,false);CHECK(camera.frames==automaticFrames);
    CHECK(close(handle)==0);
    CHECK(waitFor([]{return sn::request("{\"op\":\"status\"}").find("\"clients\":1")!=std::string::npos;}));
    CHECK(create(&handle,"reentrant-close",accessors,std::size(accessors),&options)==0);
    CHECK(write(handle,"frame.timingSource",&timing)==0);
    CHECK(waitFor([]{return sn::request("{\"op\":\"status\"}").find("\"clients\":2")!=std::string::npos;}));
    camera.handle=handle;camera.closeDuringGet=close;e.received=sn::now();CHECK(sn::writeAll(inject,&e,sizeof(e)));CHECK(waitFor([&]{return camera.motion==1;}));
    time=100.0;CHECK(write(handle,"frame.time",&time)==0);CHECK(camera.wasClosed);CHECK(close(handle)!=0);
    CHECK(dlclose(library)==0);CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.05,true);
    // Slow clients cannot grow memory without bound or silently lose button edges.
    // Fill a monitor's receive buffers without reading. The service must disconnect it.
    int slow=sn::openEvents(sn::Flags::monitor);CHECK(slow>=0);
    int smallBuffer=1024;setsockopt(slow,SOL_SOCKET,SO_RCVBUF,&smallBuffer,sizeof(smallBuffer));
    std::this_thread::sleep_for(std::chrono::milliseconds(30));
    e.kind=sn::Kind::buttons;
    for(int i=0;i<4096;++i){e.buttons=i%2;e.received=sn::now();CHECK(sn::writeAll(inject,&e,sizeof(e)));}
    CHECK(waitFor([]{return sn::request("{\"op\":\"status\"}").find("\"overflows\":0")==std::string::npos;}));
    ::close(slow);
    int fragmented=sn::connectSocket();CHECK(fragmented>=0);sn::Event hello;hello.kind=sn::Kind::hello;hello.flags=sn::Flags::monitor;
    CHECK(sn::writeAll(fragmented,&hello,7));CHECK(sn::writeAll(fragmented,reinterpret_cast<char*>(&hello)+7,sizeof(hello)-7));
    sn::Event received;CHECK(sn::readAll(fragmented,&received,sizeof(received)));CHECK(received.kind==sn::Kind::added);
    e.kind=sn::Kind::motion;e.axes={-123,0,0,0,0,0};CHECK(sn::writeAll(inject,&e,sizeof(e)));CHECK(sn::readAll(fragmented,&received,sizeof(received)));CHECK(received.axes[0]==-123);
    ::close(fragmented);
    // Exercise descriptor reuse while dispatch-source cancellation is pending.
    // These clients are intentionally short lived, as when an app restarts.
    for(int i=0;i<200;++i){
        int peer=sn::openEvents(sn::Flags::monitor);CHECK(peer>=0);
        CHECK(sn::readAll(peer,&received,sizeof(received)));CHECK(received.kind==sn::Kind::added);::close(peer);
    }
    CHECK(sn::request("{\"op\":\"status\"}").find("\"mock\":true")!=std::string::npos);
    // Virtual devices have no calibration feature report to rezero.
    CHECK(sn::request("{\"op\":\"calibrate\"}")=="{\"calibrated\":0}");
    for(const char* invalid:{R"({"op":"calibrate","device":0})",R"({"op":"calibrate","device":1.5})",R"({"op":"calibrate","device":"1"})"})CHECK(sn::request(invalid).find("error")!=std::string::npos);
    // The native test tab receives full event edges, independently of its UI
    // refresh. Short press/release pairs must both reach the session log.
    AxialPreviewStart();
    CHECK(waitFor([]{return sn::request("{\"op\":\"status\"}").find("\"clients\":2")!=std::string::npos;}));
    e.kind=sn::Kind::buttons;e.buttons=0;e.received=sn::now();CHECK(sn::writeAll(inject,&e,sizeof(e)));
    e.buttons=5;CHECK(sn::writeAll(inject,&e,sizeof(e)));e.buttons=0;CHECK(sn::writeAll(inject,&e,sizeof(e)));
    e.kind=sn::Kind::motion;e.axes={321,-12,0,0,0,0};
    // Preview motion expires after 250 ms. Refresh its event timestamp while
    // waiting so a slow CI runner cannot make the sample stale before reading it.
    bool previewMotion=false;
    for(int attempt=0;attempt<10&&!previewMotion;++attempt){
        e.received=sn::now();CHECK(sn::writeAll(inject,&e,sizeof(e)));
        previewMotion=waitFor([]{double axes[6]{};uint32_t buttons=0;return AxialPreviewRead(1,axes,&buttons)&&axes[0]==321&&axes[1]==-12&&buttons==0;},30);
    }
    CHECK(previewMotion);
    uint64_t timestamp=0;uint32_t deviceID=0,changed=0,buttons=0,reason=0,identity=0,presses=0,releases=0;
    while(AxialPreviewPopLog(&timestamp,&deviceID,&changed,&buttons,&reason,&identity))if(deviceID==1&&reason==uint32_t(sn::Kind::buttons)){CHECK(identity==0x046dc627);presses|=changed&buttons;releases|=changed&~buttons;}
    CHECK((presses&5)==5&&(releases&5)==5);CHECK(AxialPreviewLostLogs()==0);
    // Queued edges keep their hardware identity after unplug and numeric ID reuse.
    button(e,1u<<13);
    auto removal=e;removal.kind=sn::Kind::removed;removal.vendor=0;removal.product=0;
    CHECK(sn::writeAll(inject,&removal,sizeof(removal)));
    auto replacement=e;replacement.kind=sn::Kind::added;replacement.vendor=0x256f;replacement.product=0xc635;replacement.buttons=0;
    CHECK(sn::writeAll(inject,&replacement,sizeof(replacement)));button(replacement,2);
    CHECK(sn::writeAll(inject,&removal,sizeof(removal)));
    auto barrier=replacement;barrier.device=17;barrier.kind=sn::Kind::motion;barrier.axes={233,0,0,0,0,0};barrier.received=sn::now();
    CHECK(sn::writeAll(inject,&barrier,sizeof(barrier)));
    CHECK(waitFor([]{double axes[6]{};uint32_t buttons=0;return AxialPreviewRead(17,axes,&buttons)&&axes[0]==233;}));
    struct Edge {uint32_t identity,changed,buttons,reason;};
    const Edge expectedEdges[]={
        {0x046dc627,1u<<13,1u<<13,uint32_t(sn::Kind::buttons)},
        {0x046dc627,1u<<13,0,uint32_t(sn::Kind::removed)},
        {0x256fc635,2,2,uint32_t(sn::Kind::buttons)},
        {0x256fc635,2,0,uint32_t(sn::Kind::removed)}
    };
    size_t edge=0;
    while(AxialPreviewPopLog(&timestamp,&deviceID,&changed,&buttons,&reason,&identity))if(deviceID==1){
        CHECK(edge<std::size(expectedEdges));const auto& expected=expectedEdges[edge++];
        CHECK(identity==expected.identity&&changed==expected.changed&&buttons==expected.buttons&&reason==expected.reason);
    }
    CHECK(edge==std::size(expectedEdges)&&AxialPreviewLostLogs()==0);
    AxialPreviewStop();
    std::thread starter([]{for(int i=0;i<30;++i){AxialPreviewStart();AxialPreviewStop();}});
    for(int i=0;i<30;++i){AxialPreviewStart();AxialPreviewStop();}starter.join();AxialPreviewStop();
    // Invalid command catalogs must not break the app's Codable response.
    for(const char* invalid:{R"({"op":"commands","app":"mock","commands":[1]})",R"({"op":"commands","app":"mock","commands":[{"id":4,"label":"bad"}]})"})CHECK(sn::request(invalid).find("error")!=std::string::npos);
    // An incomplete control frame must not mutate settings, even if its JSON is valid.
    int incomplete=sn::connectSocket(true);CHECK(incomplete>=0);
    std::string command=R"({"op":"commands","app":"incomplete","commands":[]})";
    CHECK(sn::writeAll(incomplete,command.data(),command.size()));shutdown(incomplete,SHUT_WR);
    char response[256];recv(incomplete,response,sizeof(response),0);::close(incomplete);
    CHECK(sn::request("{\"op\":\"getCommands\"}").find("incomplete")==std::string::npos);
    // Accepted command data must always fit in a readable getCommands response.
    std::string entries;
    for(int i=0;i<128;++i){if(i)entries+=',';entries+="{\"id\":\""+std::to_string(i)+"\",\"label\":\""+std::string(1024,'x')+"\"}";}
    bool bounded=false;
    for(int i=0;i<12;++i){auto result=sn::request("{\"op\":\"commands\",\"app\":\"large-"+std::to_string(i)+"\",\"commands\":["+entries+"]}");if(result.find("response size limit")!=std::string::npos){bounded=true;break;}}
    CHECK(bounded);auto catalog=sn::request("{\"op\":\"getCommands\"}");CHECK(catalog.size()<1024*1024);CHECK(catalog.find("large-0")!=std::string::npos);
    ::close(inject);
    std::cout<<"Integration: real IPC, legacy main/worker callbacks, masks, profiles, Navlib camera/zoom/transactions/neutral passed\n";
}}catch(const std::exception& e){std::cerr<<e.what()<<"\n";return 1;}}
