#import <AppKit/AppKit.h>
#import <IOKit/hid/IOHIDManager.h>
#import <ApplicationServices/ApplicationServices.h>
#include "axial/transport.hpp"
#include "axial/keys.hpp"
#include "axial/application.hpp"
#include "axial/web.hpp"
#include <atomic>
#include <cstdio>
#include <functional>
#include <memory>
#include <map>
#include <thread>
#include <vector>
#include <sys/file.h>
#include <signal.h>
#include <mach/mach.h>
#include <sys/resource.h>

using namespace sn;
namespace {
enum class Action : uint8_t {none,dominant,translation,rotation,faster,slower,fit};
struct Profile {
    Settings motion;
    bool led=true;
    std::array<int,32> keys;
    std::array<uint64_t,32> modifiers{};
    std::array<Action,32> actions{};
    Profile(){keys.fill(-1);}
};
struct Configuration { std::map<std::string,Profile> profiles;WebConfiguration web; };
std::unique_ptr<WebServer> webServer;
struct Peer {
    int fd=-1;
    pid_t pid=0;
    sn::ProcessIdentity identity;
    bool foreground=false;
    bool registered=false, observe=false, injecting=false, writeActive=false;
    Event incoming{};
    size_t readOffset=0,writeOffset=0;
    EventQueue<256> queue;
    dispatch_source_t reader=nullptr,writer=nullptr;
};
struct SocketLifetime {int fd;explicit SocketLifetime(int value):fd(value){}~SocketLifetime(){close(fd);}};
struct LEDOutput {
    IOHIDDeviceRef device;
    IOHIDElementRef element;
    std::atomic<bool> connected{true};
    std::atomic<int> state{-1};
    std::atomic<uint32_t> error{0};
    LEDOutput(IOHIDDeviceRef d,IOHIDElementRef e):device(d),element(e){CFRetain(d);CFRetain(e);}
    ~LEDOutput(){CFRelease(element);CFRelease(device);}
};
// Hardware zero calibration. 3DxWare rezeroes a device by setting vendor
// feature report 7 (usage 0xff00:0x22) to 0 while it blinks the LED.
struct RezeroOutput {
    IOHIDDeviceRef device;
    IOHIDElementRef element;
    std::atomic<bool> connected{true},busy{false};
    RezeroOutput(IOHIDDeviceRef d,IOHIDElementRef e):device(d),element(e){CFRetain(d);CFRetain(e);}
    ~RezeroOutput(){CFRelease(element);CFRelease(device);}
};
constexpr uint32_t rezeroReport=7,rezeroPage=0xff00,rezeroUsage=0x22;
struct HID {
    IOHIDDeviceRef device=nullptr;
    Decoder decoder;
    Profile profile;
    uint32_t previousButtons=0;
    uint32_t suppressedButtons=0;
    std::shared_ptr<LEDOutput> led;
    int requestedLED=-1;
    std::shared_ptr<RezeroOutput> rezero;
    bool deviceCalibrated=false;
};
struct Snapshot {
    std::array<Event,16> latest{};
    size_t count=0,clients=0;
    uint64_t reports=0,overflows=0,rejected=0;
    pid_t foreground=0;
    std::array<bool,16> ledSupported{};
    std::array<int,16> ledState{};
    std::array<uint32_t,16> ledError{};
    std::array<bool,16> rezero{},calibrating{},deviceCalibrated{};
};
dispatch_queue_t inputQueue;
std::array<Peer,32> peers;
std::array<HID,16> hidDevices;
std::array<Event,16> virtualDevices{};
std::array<uint32_t,16> virtualButtonState{};
std::unique_ptr<Configuration> configuration;
Profile activeProfile;
std::string foregroundBundle;
pid_t foregroundPID=0;
sn::ProcessIdentity foregroundIdentity;
void resolveForeground(Peer& peer) {
    peer.foreground=sn::belongsToApplication(peer.identity,foregroundIdentity,sn::processIdentity);
}
bool mockMode=false;
uint64_t reports=0,overflows=0,rejected=0;
dispatch_queue_t keyQueue;
dispatch_queue_t outputQueue;
dispatch_source_t keySource;
struct KeyWork {uint32_t device=0,buttons=0;bool release=false;std::array<int,32> keys{};std::array<uint64_t,32> modifiers{};};
std::array<KeyWork,128> keyWork;
std::atomic<size_t> keyRead{0},keyWrite{0};
std::atomic<bool> keyOverflow{false};
KeyState heldKeys;
NSDictionary* document;
NSMutableDictionary* commandCatalog;
NSString* settingsPath;
uint32_t nextDevice=1;

// Runs on the output queue.
IOReturn writeValue(IOHIDDeviceRef device,IOHIDElementRef element,CFIndex integer) {
    auto value=IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault,element,mach_absolute_time(),integer);
    IOReturn result=value?IOHIDDeviceSetValue(device,element,value):kIOReturnNoMemory;
    if(value)CFRelease(value);
    return result;
}
void writeLED(LEDOutput& output,bool enabled) {
    if(!output.connected.load())return;
    IOReturn result=writeValue(output.device,output.element,enabled?1:0);
    output.error=result;output.state=result==kIOReturnSuccess?int(enabled):-1;
}
void setLED(HID& hid,bool enabled) {
    if(!hid.led||hid.requestedLED==int(enabled))return;
    hid.requestedLED=enabled;auto output=hid.led;
    dispatch_async(outputQueue,^{writeLED(*output,enabled);});
}
// Hardware zero calibration, timed like 3DxWare: the LED blinks for about four
// seconds and the device is rezeroed halfway through, once the cap has settled.
void calibrate(HID& h) {
    auto rezero=h.rezero;auto led=h.led;uint32_t device=h.decoder.state.device;
    if(rezero->busy.exchange(true))return;
    auto step=std::make_shared<std::function<void(int)>>();
    *step=[rezero,led,device,step](int i){
        bool connected=rezero->connected.load();
        if(connected&&i==8){
            bool ok=writeValue(rezero->device,rezero->element,0)==kIOReturnSuccess;
            dispatch_async(inputQueue,^{for(auto& h:hidDevices)if(h.device&&h.decoder.state.device==device){h.deviceCalibrated=ok;break;}});
        }
        if(connected&&i<16){
            if(led)writeLED(*led,i%2==0);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,265*NSEC_PER_MSEC),outputQueue,^{(*step)(i+1);});
            return;
        }
        rezero->busy=false;
        // Restore the profile's LED state; breaks the step's self-reference.
        dispatch_async(inputQueue,^{for(auto& h:hidDevices)if(h.device&&h.decoder.state.device==device){h.requestedLED=-1;setLED(h,h.profile.led);break;}});
        *step=nullptr;
    };
    dispatch_async(outputQueue,^{(*step)(0);});
}

void postKey(int key,bool down,uint64_t modifiers){
    CGEventRef e=CGEventCreateKeyboardEvent(nullptr,CGKeyCode(key),down);
    if(e){CGEventSetFlags(e,CGEventFlags(modifiers));CGEventPost(kCGHIDEventTap,e);CFRelease(e);}
}
void clearHeld(uint32_t device=0){
    heldKeys.release(device,postKey);
}
void drainKeys(){
    bool overflowed=keyOverflow.exchange(false);
    if(overflowed)clearHeld();
    size_t r=keyRead.load(std::memory_order_relaxed);
    while(r!=keyWrite.load(std::memory_order_acquire)){
        KeyWork work=keyWork[r%keyWork.size()];keyRead.store(++r,std::memory_order_release);
        if(work.release){clearHeld(work.device);continue;}
        if(!AXIsProcessTrusted()){clearHeld();continue;}
        heldKeys.update(work.device,work.buttons,work.keys,work.modifiers,postKey);
    }
    if(keyOverflow.exchange(false)||overflowed)clearHeld();
}
void submitKeyWork(const KeyWork& work){
    size_t w=keyWrite.load(std::memory_order_relaxed);
    if(w-keyRead.load(std::memory_order_acquire)==keyWork.size()){keyOverflow=true;++overflows;}
    else{keyWork[w%keyWork.size()]=work;keyWrite.store(w+1,std::memory_order_release);}
    dispatch_source_merge_data(keySource,1);
}
void releaseKeys(uint32_t device=0) {
    KeyWork work;work.release=true;work.device=device;submitKeyWork(work);
}
void closePeer(Peer& p) {
    if(p.fd<0)return;
    dispatch_source_cancel(p.reader);
    if(!p.writeActive) dispatch_resume(p.writer);
    dispatch_source_cancel(p.writer);
    p.fd=-1; // The last dispatch-source cancellation closes the descriptor.
    p.reader=nullptr;p.writer=nullptr;p.queue.clear();p.writeOffset=0;
}
void flush(Peer& p) {
    while(!p.queue.empty()) {
        const char* bytes=reinterpret_cast<const char*>(&p.queue.front());
        ssize_t n=send(p.fd,bytes+p.writeOffset,sizeof(Event)-p.writeOffset,0);
        if(n<0&&(errno==EAGAIN||errno==EWOULDBLOCK))break;
        if(n<0&&errno==EINTR)continue;
        if(n<=0){closePeer(p);return;}
        p.writeOffset+=size_t(n);
        if(p.writeOffset==sizeof(Event)){p.queue.pop();p.writeOffset=0;}
    }
    bool needsWrite=!p.queue.empty();
    if(needsWrite&&!p.writeActive){dispatch_resume(p.writer);p.writeActive=true;}
    if(!needsWrite&&p.writeActive){dispatch_suspend(p.writer);p.writeActive=false;}
}
void enqueue(Peer& p,const Event& e) {
    // Never replace a partly written front frame: append a barrier if necessary.
    if(p.writeOffset && p.queue.size()==1) {
        // A stream short-write is exceptionally rare for 64 bytes. Disconnect rather
        // than corrupt an ABI frame or deliver stale partially rewritten motion.
        ++overflows;closePeer(p);return;
    }
    if(!p.queue.push(e)){++overflows;closePeer(p);return;}
    flush(p);
}
void route(const Event& raw) {
    ++reports;
    Profile* selected=&activeProfile;
    uint32_t suppressed=0;
    uint32_t ignoredPrevious=0;uint32_t* previous=&ignoredPrevious;
    if(mockMode)for(size_t i=0;i<virtualDevices.size();++i)if(virtualDevices[i].device==raw.device){previous=&virtualButtonState[i];break;}
    for(auto& h:hidDevices)if(h.device&&h.decoder.state.device==raw.device){selected=&h.profile;previous=&h.previousButtons;if(raw.kind==Kind::buttons)h.suppressedButtons&=raw.buttons;suppressed=h.suppressedButtons;break;}
    if(raw.kind==Kind::buttons){
        uint32_t pressed=raw.buttons&~*previous;*previous=raw.buttons;
        for(int i=0;i<32;++i)if(pressed&(1u<<i))switch(selected->actions[i]){
            case Action::dominant:selected->motion.dominant=!selected->motion.dominant;break;
            case Action::translation:selected->motion.translation=!selected->motion.translation;break;
            case Action::rotation:selected->motion.rotation=!selected->motion.rotation;break;
            case Action::faster:for(auto& gain:selected->motion.gain)gain=std::min(20.f,gain*1.25f);break;
            case Action::slower:for(auto& gain:selected->motion.gain)gain=std::max(.01f,gain/1.25f);break;
            case Action::fit:{Event command=raw;command.kind=Kind::command;command.flags=0x10000;
                if(webServer)webServer->receive(command);
                for(auto& p:peers)if(p.fd>=0&&p.registered&&!p.injecting&&!p.observe&&(mockMode||p.foreground))enqueue(p,command);break;}
            default:break;
        }
    }
    Event e=filter(raw,selected->motion);
    e.buttons&=~suppressed;
    if(webServer)webServer->receive(e);
    for(auto& p:peers) if(p.fd>=0&&p.registered&&!p.injecting) {
        if(p.observe) enqueue(p,raw);
        else if(mockMode||p.foreground||raw.kind==Kind::added||raw.kind==Kind::removed||raw.kind==Kind::reset)
            enqueue(p,e);
    }
    if(raw.kind==Kind::buttons&&!mockMode) {
        KeyWork work;work.device=raw.device;work.buttons=e.buttons;work.keys=selected->keys;work.modifiers=selected->modifiers;submitKeyWork(work);
    }
    if(raw.kind==Kind::removed||raw.kind==Kind::reset)releaseKeys(raw.device);
}
void resetFocus() {for(auto& h:hidDevices)if(h.device)h.suppressedButtons=h.decoder.state.buttons;Event e;e.kind=Kind::reset;e.received=now();route(e);}
void selectProfile() {
    activeProfile=Profile{};
    if(!configuration)return;
    auto it=configuration->profiles.find(foregroundBundle);
    if(it==configuration->profiles.end())it=configuration->profiles.find("*");
    if(it!=configuration->profiles.end())activeProfile=it->second;
    for(auto& h:hidDevices)if(h.device){
        h.profile=activeProfile;
        char suffix[16];snprintf(suffix,sizeof(suffix),"@%04x:%04x",h.decoder.state.vendor,h.decoder.state.product);
        auto device=configuration->profiles.find(foregroundBundle+suffix);
        if(device==configuration->profiles.end())device=configuration->profiles.find(std::string("*")+suffix);
        if(device!=configuration->profiles.end())h.profile=device->second;
        setLED(h,h.profile.led);
    }
}
void hidReport(void* context,IOReturn result,void*,IOHIDReportType,uint32_t reportID,uint8_t* bytes,CFIndex length) {
    uint64_t begin=now();
    if(result!=kIOReturnSuccess||length<=0||length>255)return;
    auto& h=*static_cast<HID*>(context);Event e;
    // IOKit numbered reports include the ID. Some transports omit it.
    std::array<uint8_t,256> corrected{};
    std::span<const uint8_t> report(bytes,size_t(length));
    if(bytes[0]!=reportID){corrected[0]=uint8_t(reportID);memcpy(corrected.data()+1,bytes,size_t(length));report={corrected.data(),size_t(length+1)};}
    if(h.decoder.decode(report,begin,e)){e.decoded=now();route(e);}
    else ++rejected;
}
void managerReport(void*,IOReturn result,void* sender,IOHIDReportType type,uint32_t reportID,uint8_t* bytes,CFIndex length) {
    for(auto& h:hidDevices)if(h.device==sender){hidReport(&h,result,sender,type,reportID,bytes,length);return;}
}
int property(IOHIDDeviceRef d,CFStringRef key) {
    auto n=IOHIDDeviceGetProperty(d,key);int result=0;
    if(n&&CFGetTypeID(n)==CFNumberGetTypeID())CFNumberGetValue((CFNumberRef)n,kCFNumberIntType,&result);
    return result;
}
// The Universal Receiver's primary usage is vendor-defined; its multi-axis
// collection is listed only among the interface's usage pairs.
bool multiAxis(IOHIDDeviceRef d) {
    if(property(d,CFSTR(kIOHIDPrimaryUsagePageKey))==1&&property(d,CFSTR(kIOHIDPrimaryUsageKey))==8)return true;
    auto pairs=IOHIDDeviceGetProperty(d,CFSTR(kIOHIDDeviceUsagePairsKey));
    if(!pairs||CFGetTypeID(pairs)!=CFArrayGetTypeID())return false;
    for(NSDictionary* pair in (__bridge NSArray*)pairs)
        if([pair isKindOfClass:NSDictionary.class]&&[pair[@(kIOHIDDeviceUsagePageKey)] isEqual:@1]&&[pair[@(kIOHIDDeviceUsageKey)] isEqual:@8])return true;
    return false;
}
void added(void*,IOReturn result,void*,IOHIDDeviceRef d) {
    if(result!=kIOReturnSuccess){fprintf(stderr,"Cannot exclusively open device: 0x%x\n",result);return;}
    int vid=property(d,CFSTR(kIOHIDVendorIDKey)),pid=property(d,CFSTR(kIOHIDProductIDKey));
    if(!deviceSpec(vid,pid)||!multiAxis(d))return;
    for(auto& h:hidDevices)if(!h.device) {
        h.device=d;CFRetain(d);h.decoder=Decoder{};h.previousButtons=0;h.suppressedButtons=0;
        h.led.reset();h.requestedLED=-1;h.rezero.reset();h.deviceCalibrated=false;
        NSArray* elements=CFBridgingRelease(IOHIDDeviceCopyMatchingElements(d,nullptr,kIOHIDOptionsTypeNone));
        for(id item in elements){auto element=(__bridge IOHIDElementRef)item;
            auto type=IOHIDElementGetType(element);auto page=IOHIDElementGetUsagePage(element),usage=IOHIDElementGetUsage(element);
            if(!h.led&&type==kIOHIDElementTypeOutput&&page==8&&usage==0x4b)h.led=std::make_shared<LEDOutput>(d,element);
            if(!h.rezero&&type==kIOHIDElementTypeFeature&&page==rezeroPage&&usage==rezeroUsage&&IOHIDElementGetReportID(element)==rezeroReport)h.rezero=std::make_shared<RezeroOutput>(d,element);
        }
        auto& e=h.decoder.state;e.device=nextDevice++;e.vendor=vid;e.product=pid;
        selectProfile();
        Event connected=e;connected.kind=Kind::added;connected.received=now();route(connected);return;
    }
}
void removed(void*,IOReturn,void*,IOHIDDeviceRef d) {
    for(auto& h:hidDevices)if(h.device==d){Event e=h.decoder.state;e.axes={};e.buttons=0;e.kind=Kind::removed;e.received=now();route(e);if(h.led)h.led->connected=false;h.led.reset();if(h.rezero)h.rezero->connected=false;h.rezero.reset();CFRelease(h.device);h.device=nullptr;return;}
}
int listener(bool control) {
    auto path=socketPath(control);auto parent=path.substr(0,path.find_last_of('/'));
    if(mkdir(parent.c_str(),0700)<0&&errno!=EEXIST)return -1;
    struct stat st{};
    if(lstat(parent.c_str(),&st)||!S_ISDIR(st.st_mode)||st.st_uid!=getuid()||(st.st_mode&077)!=0){errno=EACCES;return -1;}
    int fd=socket(AF_UNIX,SOCK_STREAM,0);if(fd<0)return -1;socketOptions(fd);
    sockaddr_un a{};a.sun_family=AF_UNIX;
    if(path.size()>=sizeof(a.sun_path)){close(fd);errno=ENAMETOOLONG;return -1;}
    memcpy(a.sun_path,path.c_str(),path.size()+1);unlink(path.c_str());
    if(bind(fd,(sockaddr*)&a,sizeof(a))||chmod(path.c_str(),0600)||listen(fd,32)){close(fd);return -1;}
    return fd;
}
bool sameUser(int fd) {uid_t uid;gid_t gid;return getpeereid(fd,&uid,&gid)==0&&uid==getuid();}
void readPeer(Peer& p) {
    while(p.fd>=0) {
        ssize_t n=recv(p.fd,reinterpret_cast<char*>(&p.incoming)+p.readOffset,sizeof(Event)-p.readOffset,0);
        if(n<0&&(errno==EAGAIN||errno==EWOULDBLOCK))return;
        if(n<0&&errno==EINTR)continue;
        if(n<=0){closePeer(p);return;}
        p.readOffset+=size_t(n);if(p.readOffset<sizeof(Event))continue;p.readOffset=0;
        Event e=p.incoming;
        if(!valid(e)){closePeer(p);return;}
        if(!p.registered) {
            if(e.kind!=Kind::hello){closePeer(p);return;}
            p.registered=true;p.observe=e.flags&Flags::monitor;p.injecting=e.flags&Flags::replay;
            if(p.injecting&&!mockMode){closePeer(p);return;}
            if(!p.injecting){
                for(const auto& h:hidDevices)if(h.device){Event a=h.decoder.state;a.kind=Kind::added;enqueue(p,a);if(p.fd<0)return;}
                for(const auto& a:virtualDevices)if(a.device){Event b=a;b.kind=Kind::added;enqueue(p,b);if(p.fd<0)return;}
            }
        } else if(p.injecting) {
            if(e.kind==Kind::hello){closePeer(p);return;}
            if(e.device){
                auto v=std::find_if(virtualDevices.begin(),virtualDevices.end(),[&](const auto& item){return item.device==e.device;});
                if(v==virtualDevices.end()&&e.kind!=Kind::removed)v=std::find_if(virtualDevices.begin(),virtualDevices.end(),[](const auto& item){return !item.device;});
                if(v!=virtualDevices.end()){
                    if(!v->device||e.kind==Kind::added||e.kind==Kind::removed)virtualButtonState[size_t(v-virtualDevices.begin())]=0;
                    *v=e.kind==Kind::removed?Event{}:e;
                }
            }
            e.decoded=now(); // Marks service entry for optional native benchmark diagnostics.
            route(e);
        } else {closePeer(p);return;}
    }
}
void acceptEvents(int listenerFD) {
    int fd=accept(listenerFD,nullptr,nullptr);if(fd<0)return;socketOptions(fd);
    if(!sameUser(fd)){close(fd);return;}
    for(auto& p:peers)if(p.fd<0) {
        p=Peer{};p.fd=fd;
        socklen_t size=sizeof(p.pid);
        if(getsockopt(fd,SOL_LOCAL,LOCAL_PEERPID,&p.pid,&size)){close(fd);p.fd=-1;return;}
        p.identity=sn::processIdentity(p.pid);resolveForeground(p);
        fcntl(fd,F_SETFL,O_NONBLOCK);
        int buffer=4096;setsockopt(fd,SOL_SOCKET,SO_SNDBUF,&buffer,sizeof(buffer));
        Peer* ptr=&p;
        p.reader=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,fd,0,inputQueue);
        p.writer=dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE,fd,0,inputQueue);
        auto socket=std::make_shared<SocketLifetime>(fd);
        dispatch_source_set_cancel_handler(p.reader,^{(void)socket;});
        dispatch_source_set_cancel_handler(p.writer,^{(void)socket;});
        dispatch_source_set_event_handler(p.reader,^{readPeer(*ptr);});
        dispatch_source_set_event_handler(p.writer,^{flush(*ptr);});
        dispatch_resume(p.reader);return;
    }
    close(fd);
}
bool number(id x){return [x isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)x)!=CFBooleanGetTypeID()&&std::isfinite([x doubleValue]);}
bool boolean(id x){return x&&CFGetTypeID((__bridge CFTypeRef)x)==CFBooleanGetTypeID();}
std::unique_ptr<Configuration> parseConfig(NSDictionary* d) {
    if(![d isKindOfClass:NSDictionary.class]||!number(d[@"version"])||![d[@"version"] isEqual:@1]||![d[@"profiles"] isKindOfClass:NSDictionary.class])return nullptr;
    NSDictionary* profiles=d[@"profiles"];if(profiles.count>128)return nullptr;
    auto c=std::make_unique<Configuration>();
    c->web.enabled=!mockMode;
    NSString* webDirectory=mockMode?[settingsPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"web"]:@"/Library/Application Support/Axial/Web";
    c->web.certificate=[[webDirectory stringByAppendingPathComponent:@"server.crt"] UTF8String];
    c->web.key=[[webDirectory stringByAppendingPathComponent:@"server.key"] UTF8String];
    if(id web=d[@"web"]){
        if(![web isKindOfClass:NSDictionary.class]||(web[@"enabled"]&&!boolean(web[@"enabled"])))return nullptr;
        if(web[@"enabled"])c->web.enabled=[web[@"enabled"] boolValue];
    }
    for(NSString* key in profiles){
        if(![key isKindOfClass:NSString.class]||key.length==0||key.length>255)return nullptr;
        NSDictionary* v=profiles[key];if(![v isKindOfClass:NSDictionary.class])return nullptr;
        Profile p;
        for(NSString* field in @[@"gain",@"deadzone",@"invert"]){
            NSArray* a=v[field];if(!a)continue;
            if(![a isKindOfClass:NSArray.class]||a.count!=6)return nullptr;
            for(int i=0;i<6;++i){if([field isEqual:@"invert"]?!boolean(a[i]):!number(a[i]))return nullptr;
                double x=[a[i] doubleValue];
                if([field isEqual:@"gain"]){if(x<0||x>20)return nullptr;p.motion.gain[i]=x;}
                else if([field isEqual:@"deadzone"]){if(x<0||x>1000)return nullptr;p.motion.deadzone[i]=x;}
                else p.motion.invert[i]=[a[i] boolValue];
            }
        }
        for(NSString* field in @[@"dominant",@"translation",@"rotation",@"orbit",@"led"]){
            if(v[field]&&!boolean(v[field]))return nullptr;
        }
        p.motion.dominant=[v[@"dominant"] boolValue];
        p.motion.translation=v[@"translation"]?[v[@"translation"] boolValue]:true;
        p.motion.rotation=v[@"rotation"]?[v[@"rotation"] boolValue]:true;
        p.motion.orbit=v[@"orbit"]?[v[@"orbit"] boolValue]:true;
        p.led=v[@"led"]?[v[@"led"] boolValue]:true;
        NSArray* buttons=v[@"buttons"];
        if(buttons){if(![buttons isKindOfClass:NSArray.class]||buttons.count>32)return nullptr;
            for(NSUInteger i=0;i<buttons.count;++i){NSDictionary* b=buttons[i];if(![b isKindOfClass:NSDictionary.class])return nullptr;
                if(b[@"keyCode"]){if(!number(b[@"keyCode"]))return nullptr;double key=[b[@"keyCode"] doubleValue];if(key<0||key>127||std::floor(key)!=key)return nullptr;p.keys[i]=[b[@"keyCode"] intValue];}
                if(b[@"modifiers"]){if(!number(b[@"modifiers"]))return nullptr;double flags=[b[@"modifiers"] doubleValue];if(flags<0||flags>0xffffffff||std::floor(flags)!=flags)return nullptr;p.modifiers[i]=[b[@"modifiers"] unsignedLongLongValue];}
                if(b[@"command"]&&(![b[@"command"] isKindOfClass:NSString.class]||[b[@"command"] length]>4096||b[@"keyCode"]))return nullptr;
                if(b[@"label"]&&(![b[@"label"] isKindOfClass:NSString.class]||[b[@"label"] length]>128))return nullptr;
                if(b[@"action"]){
                    if(![b[@"action"] isKindOfClass:NSString.class]||b[@"keyCode"]||b[@"command"])return nullptr;
                    NSArray* actions=@[@"",@"dominant",@"translation",@"rotation",@"faster",@"slower",@"fit"];
                    NSUInteger action=[actions indexOfObject:b[@"action"]];if(action==NSNotFound)return nullptr;p.actions[i]=Action(action);
                }
            }
        }
        std::array<std::string,32> commands{};
        if(buttons)for(NSUInteger i=0;i<buttons.count;++i){NSString* command=buttons[i][@"command"];if(command)commands[i]=command.UTF8String;}
        c->web.commands.emplace(key.UTF8String,std::move(commands));
        c->profiles.emplace(key.UTF8String,p);
    }
    return c;
}
NSDictionary* status() {
    __block Snapshot snapshot;
    __block NSString* bundle;
    dispatch_sync(inputQueue,^{
        for(const auto& h:hidDevices)if(h.device&&snapshot.count<16){size_t i=snapshot.count++;snapshot.latest[i]=h.decoder.state;snapshot.ledSupported[i]=bool(h.led);snapshot.ledState[i]=h.led?h.led->state.load():-1;snapshot.ledError[i]=h.led?h.led->error.load():0;
            snapshot.rezero[i]=bool(h.rezero);snapshot.calibrating[i]=h.rezero&&h.rezero->busy.load();snapshot.deviceCalibrated[i]=h.deviceCalibrated;}
        for(const auto& e:virtualDevices)if(e.device&&snapshot.count<16)snapshot.latest[snapshot.count++]=e;
        for(const auto& p:peers)if(p.fd>=0&&p.registered)++snapshot.clients;
        snapshot.reports=reports;snapshot.overflows=overflows;snapshot.rejected=rejected;snapshot.foreground=foregroundPID;
        bundle=[NSString stringWithUTF8String:foregroundBundle.c_str()];
    });
    NSMutableArray* items=[NSMutableArray array];
    for(size_t i=0;i<snapshot.count;++i){const auto& e=snapshot.latest[i];auto spec=deviceSpec(e.vendor,e.product);
        NSMutableArray* axes=[NSMutableArray array];for(int16_t x:e.axes)[axes addObject:@(x)];
        [items addObject:@{@"id":@(e.device),@"vendor":@(e.vendor),@"product":@(e.product),@"name":spec?@(spec->name):@"Unknown",@"buttonCount":@(spec?spec->buttons.size():0),@"axes":axes,@"buttons":@(e.buttons),@"ledSupported":@(snapshot.ledSupported[i]),@"ledState":@(snapshot.ledState[i]),@"ledError":@(snapshot.ledError[i]),
            @"rezero":@(snapshot.rezero[i]),@"calibrating":@(snapshot.calibrating[i]),@"deviceCalibrated":@(snapshot.deviceCalibrated[i])}];
    }
    mach_task_basic_info_data_t memory{};mach_msg_type_number_t count=MACH_TASK_BASIC_INFO_COUNT;
    task_info(mach_task_self(),MACH_TASK_BASIC_INFO,reinterpret_cast<task_info_t>(&memory),&count);
    rusage usage{};getrusage(RUSAGE_SELF,&usage);
    double cpu=usage.ru_utime.tv_sec+usage.ru_stime.tv_sec+(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1e6;
    auto webText=webServer->status();NSData* webData=[NSData dataWithBytes:webText.data() length:webText.size()];
    id web=[NSJSONSerialization JSONObjectWithData:webData options:0 error:nil];
    return @{@"version":@1,@"mock":@(mockMode),@"devices":items,@"clients":@(snapshot.clients),@"reports":@(snapshot.reports),@"overflows":@(snapshot.overflows),@"rejected":@(snapshot.rejected),@"foregroundPID":@(snapshot.foreground),@"foregroundApp":bundle?:@"",@"accessibility":@(bool(AXIsProcessTrusted())),@"residentBytes":@(memory.resident_size),@"cpuSeconds":@(cpu),@"web":web?:@{}};
}
NSDictionary* handle(NSDictionary* request) {
    NSString* op=request[@"op"];
    if([op isEqual:@"status"])return status();
    if([op isEqual:@"retryWeb"]){webServer->retry();return @{@"ok":@YES};}
    if([op isEqual:@"requestAccessibility"]){
        bool trusted=AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString*)kAXTrustedCheckOptionPrompt:@YES});
        return @{@"trusted":@(trusted)};
    }
    if([op isEqual:@"calibrate"]){
        id device=request[@"device"];
        if(device&&(!number(device)||[device doubleValue]<1||[device doubleValue]>UINT32_MAX||std::floor([device doubleValue])!=[device doubleValue]))return @{@"error":@"device must be a device id"};
        uint32_t target=device?[device unsignedIntValue]:0;
        __block NSUInteger count=0;
        dispatch_sync(inputQueue,^{for(auto& h:hidDevices)if(h.device&&h.rezero&&(!target||h.decoder.state.device==target)){calibrate(h);++count;}});
        return @{@"calibrated":@(count)};
    }
    if([op isEqual:@"stop"]){dispatch_async(dispatch_get_main_queue(),^{kill(getpid(),SIGTERM);});return @{@"ok":@YES};}
    if([op isEqual:@"getConfig"])return document;
    if([op isEqual:@"getCommands"])return commandCatalog;
    if([op isEqual:@"commands"]){NSString* app=request[@"app"];NSArray* commands=request[@"commands"];
        if(![app isKindOfClass:NSString.class]||app.length==0||app.length>255||![commands isKindOfClass:NSArray.class]||commands.count>4096)return @{@"error":@"Invalid commands"};
        if(!commandCatalog[app]&&commandCatalog.count>=128)return @{@"error":@"Command catalog is full"};
        for(id command in commands) {
            if(![command isKindOfClass:NSDictionary.class])return @{@"error":@"Invalid command"};
            id identifier=command[@"id"],label=command[@"label"];
            if(![identifier isKindOfClass:NSString.class]||[identifier length]==0||[identifier length]>4096||![label isKindOfClass:NSString.class]||[label length]>4096)return @{@"error":@"Invalid command"};
        }
        NSMutableDictionary* candidate=[commandCatalog mutableCopy];candidate[app]=commands;
        NSData* encoded=[NSJSONSerialization dataWithJSONObject:candidate options:0 error:nil];
        if(!encoded||encoded.length>=1024*1024)return @{@"error":@"Command catalog exceeds the response size limit"};
        commandCatalog=candidate;return @{@"ok":@YES};
    }
    if([op isEqual:@"setConfig"]){
        NSDictionary* d=request[@"config"];auto c=parseConfig(d);
        if(!c)return @{@"error":@"Invalid version 1 configuration"};
        NSError* error=nil;NSData* data=[NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted error:&error];
        if(!data||![data writeToFile:settingsPath options:NSDataWritingAtomic error:&error])return @{@"error":error.localizedDescription?:@"Could not save settings"};
        webServer->configure(c->web);
        document=[d copy];Configuration* ptr=c.release();
        // Configuration changes execute between reports, never while decoding one.
        dispatch_sync(inputQueue,^{resetFocus();configuration.reset(ptr);selectProfile();});
        return @{@"ok":@YES};
    }
    return @{@"error":@"Unknown operation"};
}
void controlLoop(int fd) {
    pthread_setname_np("Axial control");
    for(;;){int client=accept(fd,nullptr,nullptr);if(client<0){if(errno==EINTR)continue;return;}
        @autoreleasepool {
            socketOptions(client);if(!sameUser(client)){close(client);continue;}
            fcntl(client,F_SETFL,O_NONBLOCK);
            const uint64_t deadline=now()+2000000000;
            std::string input;bool complete=false;
            while(now()<deadline){
                char buffer[4096];auto n=recv(client,buffer,sizeof(buffer),0);
                if(n>0){
                    const auto* end=static_cast<const char*>(memchr(buffer,'\n',size_t(n)));
                    input.append(buffer,end?size_t(end-buffer):size_t(n));
                    if(input.size()>256*1024)break;
                    if(end){complete=true;break;}
                    continue;
                }
                if(n<0&&errno==EINTR)continue;
                if(n<0&&(errno==EAGAIN||errno==EWOULDBLOCK)&&waitSocket(client,POLLIN,deadline))continue;
                break;
            }
            NSData* data=[NSData dataWithBytes:input.data() length:input.size()];
            id json=complete?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
            NSDictionary* response=[json isKindOfClass:NSDictionary.class]?handle(json):@{@"error":@"Expected a JSON object"};
            NSData* bytes=[NSJSONSerialization dataWithJSONObject:response options:NSJSONWritingSortedKeys error:nil];
            std::string output(static_cast<const char*>(bytes.bytes),bytes.length);output+='\n';
            size_t sent=0;
            while(sent<output.size()&&now()<deadline){
                auto n=send(client,output.data()+sent,output.size()-sent,0);
                if(n>0){sent+=size_t(n);continue;}
                if(n<0&&errno==EINTR)continue;
                if(n<0&&(errno==EAGAIN||errno==EWOULDBLOCK)&&waitSocket(client,POLLOUT,deadline))continue;
                break;
            }
            close(client);
        }
    }
}
}
int main(int argc,char** argv) {@autoreleasepool {
    bool appOwned=false;pid_t owner=getppid();
    for(int i=1;i<argc;++i){if(std::string(argv[i])=="--mock")mockMode=true;else if(std::string(argv[i])=="--app-owned")appOwned=true;else{fprintf(stderr,"usage: axial-service [--mock] [--app-owned]\n");return 2;}}
    if(appOwned&&owner<=1){fprintf(stderr,"An owning app is required\n");return 2;}
    auto path=socketPath();auto parent=path.substr(0,path.find_last_of('/'));
    mkdir(parent.c_str(),0700);
    struct stat parentStat{};
    if(lstat(parent.c_str(),&parentStat)||!S_ISDIR(parentStat.st_mode)||parentStat.st_uid!=getuid()||(parentStat.st_mode&077)) {fprintf(stderr,"Unsafe socket directory\n");return 1;}
    int lock=open((path+".lock").c_str(),O_CREAT|O_RDWR|O_NOFOLLOW,0600);
    if(lock<0||flock(lock,LOCK_EX|LOCK_NB)){fprintf(stderr,"Axial already running or socket directory unavailable\n");return 1;}
    int events=listener(false),controls=listener(true);
    if(events<0||controls<0){perror("listen");return 1;}
    inputQueue=dispatch_queue_create("pro.jest.input",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0));
    keyQueue=dispatch_queue_create("pro.jest.shortcuts",DISPATCH_QUEUE_SERIAL);
    outputQueue=dispatch_queue_create("pro.jest.output",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_UTILITY,0));
    keySource=dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD,0,0,keyQueue);
    dispatch_source_set_event_handler(keySource,^{drainKeys();});dispatch_resume(keySource);
    const char* custom=getenv("AXIAL_CONFIG");
    settingsPath=custom?@(custom):[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Axial/settings.json"];
    [[NSFileManager defaultManager] createDirectoryAtPath:settingsPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSData* existing=[NSData dataWithContentsOfFile:settingsPath];
    document=existing?[NSJSONSerialization JSONObjectWithData:existing options:0 error:nil]:nil;
    configuration=parseConfig(document);
    if(!configuration){document=@{@"version":@1,@"profiles":@{@"*":@{}}};configuration=parseConfig(document);}
    webServer=std::make_unique<WebServer>();webServer->configure(configuration->web);
    commandCatalog=[NSMutableDictionary dictionary];selectProfile();
    dispatch_source_t source=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,events,0,inputQueue);
    dispatch_source_set_event_handler(source,^{acceptEvents(events);});dispatch_resume(source);
    std::thread(controlLoop,controls).detach();
    auto updateFocus=^{NSRunningApplication* app=NSWorkspace.sharedWorkspace.frontmostApplication;
        pid_t pid=app.processIdentifier;NSString* bundle=app.bundleIdentifier?:@"";
        auto identity=sn::processIdentity(pid);
        dispatch_async(inputQueue,^{if(foregroundPID!=pid||foregroundIdentity.birth!=identity.birth){resetFocus();foregroundPID=pid;foregroundIdentity=identity;foregroundBundle=bundle.UTF8String;for(auto& p:peers)if(p.fd>=0)resolveForeground(p);selectProfile();}});
    };
    id observer=[NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification*){updateFocus();}];
    updateFocus();
    IOHIDManagerRef hid=nullptr;
    if(!mockMode){
        hid=IOHIDManagerCreate(kCFAllocatorDefault,kIOHIDOptionsTypeNone);
        NSMutableArray* matching=[NSMutableArray array];
        for(const auto& device:sn::devices)[matching addObject:@{@(kIOHIDVendorIDKey):@(device.vendor),@(kIOHIDProductIDKey):@(device.product),@(kIOHIDTransportKey):@"USB",@(kIOHIDDeviceUsagePageKey):@1,@(kIOHIDDeviceUsageKey):@8}];
        IOHIDManagerSetDeviceMatchingMultiple(hid,(__bridge CFArrayRef)matching);
        IOHIDManagerRegisterDeviceMatchingCallback(hid,added,nullptr);IOHIDManagerRegisterDeviceRemovalCallback(hid,removed,nullptr);
        IOHIDManagerRegisterInputReportCallback(hid,managerReport,nullptr);
        IOHIDManagerSetDispatchQueue(hid,inputQueue);
        dispatch_sync(inputQueue,^{
            IOReturn result=IOHIDManagerOpen(hid,kIOHIDOptionsTypeSeizeDevice);
            if(result!=kIOReturnSuccess){fprintf(stderr,"Exclusive HID open failed: 0x%x. Check Input Monitoring permission.\n",result);exit(1);}
            IOHIDManagerActivate(hid);
        });
    }
    signal(SIGTERM,SIG_IGN);signal(SIGINT,SIG_IGN);
    dispatch_source_t termination=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGTERM,0,dispatch_get_main_queue());
    dispatch_source_t interrupt=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGINT,0,dispatch_get_main_queue());
    auto shutdown=^{dispatch_sync(inputQueue,^{resetFocus();for(auto& p:peers)closePeer(p);for(auto& h:hidDevices)if(h.device)setLED(h,false);});dispatch_sync(outputQueue,^{});dispatch_sync(keyQueue,^{drainKeys();clearHeld();});unlink(socketPath().c_str());unlink(socketPath(true).c_str());exit(0);};
    dispatch_source_set_event_handler(termination,shutdown);dispatch_source_set_event_handler(interrupt,shutdown);
    dispatch_resume(termination);dispatch_resume(interrupt);
    // A crashed or force-quit menu-bar app must not leave a headless driver behind.
    // Kernel process-exit notification adds no polling to the input path.
    dispatch_source_t ownerExit=nullptr;
    if(appOwned){
        ownerExit=dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC,uintptr_t(owner),DISPATCH_PROC_EXIT,dispatch_get_main_queue());
        if(!ownerExit){fprintf(stderr,"Cannot monitor the owning app\n");shutdown();}
        dispatch_source_set_event_handler(ownerExit,shutdown);dispatch_resume(ownerExit);
        if(getppid()!=owner)shutdown();
    }
    fprintf(stderr,"Axial %s listening at %s\n",mockMode?"mock service":"USB service",socketPath().c_str());
    (void)observer;CFRunLoopRun();
    return 0;
}}
