#include "axial/web.hpp"
#import <Foundation/Foundation.h>
#include "axial/navigation.hpp"
#include "axial/transport.hpp"
#include <boost/asio.hpp>
#include <boost/asio/ssl.hpp>
#include <boost/beast.hpp>
#include <boost/beast/ssl.hpp>
#include <boost/json/src.hpp>
#include <atomic>
#include <cmath>
#include <deque>
#include <functional>
#include <map>
#include <mutex>
#include <thread>
#include <vector>
#include <unistd.h>

namespace sn {
namespace net=boost::asio;
namespace beast=boost::beast;
namespace http=beast::http;
namespace ws=beast::websocket;
namespace json=boost::json;
using tcp=net::ip::tcp;
using Error=boost::system::error_code;
namespace {
constexpr auto rpcURI="wss://127.51.68.120/3dconnexion#";
constexpr auto controllerURI="wss://127.51.68.120/3dconnexion3dcontroller/";
// Browser initialization includes image catalogs (Onshape sends over 360 KiB).
// Leave room for RPC envelopes when receiving or reading back stored properties.
constexpr size_t maxWebMessageBytes=2*1024*1024;
constexpr size_t maxControllerPropertyBytes=1024*1024;
constexpr size_t maxWebQueuedBytes=2*1024*1024;
std::string string(const json::value& value){return value.is_string()?std::string(value.as_string()):std::string{};}
double number(const json::value& value){return value.is_number()?value.to_number<double>():NAN;}
bool boolean(const json::value& value){return value.is_bool()&&value.as_bool();}
json::value member(const json::object& object,const char* key){auto p=object.if_contains(key);return p?*p:json::value{};}
bool numbers(const json::value& value,size_t count){
    if(!value.is_array()||value.as_array().size()!=count)return false;
    for(const auto& n:value.as_array())if(!std::isfinite(number(n)))return false;
    return true;
}
std::atomic<uint64_t> nextID{1};
std::string identifier(){return std::to_string(nextID.fetch_add(1));}
}

struct WebServer::Impl {
    struct Session;
    net::io_context io;
    net::executor_work_guard<net::io_context::executor_type> work{net::make_work_guard(io)};
    std::thread thread;
    std::shared_ptr<net::ssl::context> tls;
    std::unique_ptr<tcp::acceptor> acceptor;
    net::steady_timer timer{io};
    std::map<std::string,std::shared_ptr<Session>> sessions;
    std::map<uint32_t,Event> devices;
    std::string focused;
    mutable std::mutex mutex;
    WebConfiguration requested,configuration;
    std::deque<Event> incoming;
    bool overflow=false;
    json::object diagnostics{{"enabled",false},{"listening",false},{"connections",0},{"unsupported",0},{"error",""},{"setupRequired",false}};
    std::atomic<bool> enabled{false};
    std::string address;
    uint16_t port,boundPort=0;
    uint64_t epoch=0;
    bool shuttingDown=false;
    Impl(std::string address,uint16_t port);
    ~Impl();
    void apply(WebConfiguration config);
    void accept(uint64_t generation);
    void tick();
    void stop();
    void error(const std::string& message){std::lock_guard lock(mutex);diagnostics["error"]=message;}
    void unsupported(){std::lock_guard lock(mutex);diagnostics["unsupported"]=diagnostics["unsupported"].to_number<uint64_t>()+1;}
};

struct WebServer::Impl::Session:std::enable_shared_from_this<Session> {
    struct Controller {
        std::string id,name;
        bool subscribed=false,focus=false,moving=false,busy=false,fit=false;
        // Matrix layout: rowMajorOrder from create, otherwise detected per frame.
        bool rowMajor=false,layoutFixed=false;
        uint64_t lastInput=0,lastFrame=0,generation=0;
        Event input;
        json::object properties;
        std::map<uint32_t,uint32_t> buttons;
        bool commandHeld=false;
    };
    struct Pending {uint64_t deadline;std::function<void(bool,json::value)> done;};
    Impl& server;
    std::string id=identifier(),mouse;
    std::shared_ptr<net::ssl::context> tls;
    ws::stream<beast::ssl_stream<beast::tcp_stream>> socket;
    beast::flat_buffer buffer;
    http::request_parser<http::string_body> parser;
    std::shared_ptr<http::response<http::string_body>> response;
    std::deque<std::string> outgoing;
    size_t queuedBytes=0;
    std::map<std::string,std::string> prefixes;
    std::map<std::string,std::shared_ptr<Controller>> controllers;
    std::map<std::string,Pending> pending;
    bool open=false,closed=false;
    Session(Impl& owner,tcp::socket peer):server(owner),tls(owner.tls),socket(std::move(peer),*tls){}
    void close(){
        if(closed)return;closed=true;open=false;
        for(auto& [key,c]:controllers)if(server.focused==key)server.focused.clear();
        pending.clear();
        Error ignored;beast::get_lowest_layer(socket).socket().cancel(ignored);beast::get_lowest_layer(socket).socket().close(ignored);
        // An async write may still reference outgoing.front(). Keep storage until
        // its completion releases this session.
        server.sessions.erase(id);
        std::lock_guard lock(server.mutex);server.diagnostics["connections"]=server.sessions.size();
    }
    void start(){
        beast::get_lowest_layer(socket).expires_after(std::chrono::seconds(5));
        socket.next_layer().async_handshake(net::ssl::stream_base::server,[self=shared_from_this()](Error ec){
            if(ec){self->close();return;}self->parser.body_limit(4096);self->parser.header_limit(8192);
            http::async_read(self->socket.next_layer(),self->buffer,self->parser,[self](Error error,size_t){
                if(error){self->close();return;}self->request();
            });
        });
    }
    void request(){@autoreleasepool {
        const auto& request=parser.get();auto origin=std::string(request[http::field::origin]);
        // Public navigation API, isolated from Axial's local control socket.
        // Accept secure websites and local/native clients without a host list.
        NSURLComponents* url=[NSURLComponents componentsWithString:@(origin.c_str())];
        bool local=[url.host isEqual:@"localhost"]||[url.host isEqual:@"127.0.0.1"]||[url.host isEqual:@"127.51.68.120"];
        bool allowed=origin.empty()||origin=="null"||((url.host.length>0)&&!url.user&&!url.password&&!url.query&&!url.fragment&&!url.path.length&&([url.scheme isEqual:@"https"]||(local&&[url.scheme isEqual:@"http"])));
        if(request[http::field::host]!=server.address+":"+std::to_string(server.boundPort)){reply(http::status::bad_request,"Invalid host","");return;}
        if(!allowed){reply(http::status::forbidden,"Origin is not allowed","");return;}
        if(request.method()==http::verb::options&&request.target()=="/3dconnexion/nlproxy"){
            reply(http::status::no_content,"",origin);return;
        }
        if(request.method()!=http::verb::get){reply(http::status::method_not_allowed,"GET required",origin);return;}
        if(request.target()=="/3dconnexion/nlproxy"){
            reply(http::status::ok,json::serialize(json::object{{"port",server.boundPort},{"version","1.0.0"}}),origin);return;
        }
        if(request.target()!="/"||!ws::is_upgrade(request)){reply(http::status::not_found,"Not found",origin);return;}
        // Accept a comma-separated subprotocol list, but negotiate only WAMP v1.
        std::string protocols(request[http::field::sec_websocket_protocol]);bool wamp=false;
        for(size_t start=0;start<protocols.size();){auto end=protocols.find(',',start);auto token=protocols.substr(start,end-start);auto a=token.find_first_not_of(" \t");auto b=token.find_last_not_of(" \t");if(a!=std::string::npos&&token.substr(a,b-a+1)=="wamp")wamp=true;if(end==std::string::npos)break;start=end+1;}
        if(!wamp){reply(http::status::bad_request,"WAMP v1 required",origin);return;}
        socket.set_option(ws::stream_base::decorator([](ws::response_type& r){r.set(http::field::sec_websocket_protocol,"wamp");}));
        socket.set_option(ws::stream_base::timeout::suggested(beast::role_type::server));
        socket.read_message_max(maxWebMessageBytes);socket.text(true);
        beast::get_lowest_layer(socket).expires_never();
        socket.async_accept(request,[self=shared_from_this()](Error ec){
            if(ec){self->close();return;}self->open=true;self->send(json::array{0,self->id,1,"Axial"});self->read();
        });
    }}
    void reply(http::status code,std::string body,const std::string& origin){
        response=std::make_shared<http::response<http::string_body>>(code,11);
        response->set(http::field::content_type,"application/json");response->set(http::field::cache_control,"no-store");
        if(!origin.empty()){
            response->set(http::field::access_control_allow_origin,origin);response->set(http::field::vary,"Origin");
            response->set(http::field::access_control_allow_methods,"GET, OPTIONS");
            response->set(http::field::access_control_allow_headers,"Content-Type");
            response->set("Access-Control-Allow-Private-Network","true");
        }
        response->body()=std::move(body);response->prepare_payload();response->keep_alive(false);
        http::async_write(socket.next_layer(),*response,[self=shared_from_this()](Error,size_t){self->close();});
    }
    void send(json::value value){
        if(!open||closed)return;
        auto text=json::serialize(value);
        if(outgoing.size()>=256||queuedBytes+text.size()>maxWebQueuedBytes){server.error("Web client output overflow");close();return;}
        queuedBytes+=text.size();outgoing.push_back(std::move(text));if(outgoing.size()==1)write();
    }
    void write(){
        socket.async_write(net::buffer(outgoing.front()),[self=shared_from_this()](Error ec,size_t){
            if(ec||self->closed){self->close();return;}
            self->queuedBytes-=self->outgoing.front().size();self->outgoing.pop_front();if(!self->outgoing.empty())self->write();
        });
    }
    void read(){
        socket.async_read(buffer,[self=shared_from_this()](Error ec,size_t){
            if(ec==ws::error::message_too_big)self->server.error("Web client message exceeds 2 MiB limit");
            // TLS teardown can replace Beast's size error when the peer sends
            // its WebSocket close reply after TLS close_notify. Keep that error
            // visible too; ordinary disconnects use a different error category.
            else if(ec&&ec.category()==net::error::get_ssl_category())self->server.error("Web client TLS read failed: "+ec.message());
            if(ec||!self->socket.got_text()){self->close();return;}
            Error parse;auto value=json::parse(beast::buffers_to_string(self->buffer.data()),parse);self->buffer.consume(self->buffer.size());
            if(parse||!value.is_array()){self->close();return;}
            try{self->message(value.as_array());}catch(const std::exception&){self->server.error("Malformed WAMP message");self->close();}
            if(!self->closed)self->read();
        });
    }
    std::string resolve(std::string uri){auto colon=uri.find(':');if(colon!=std::string::npos){auto it=prefixes.find(uri.substr(0,colon));if(it!=prefixes.end())return it->second+uri.substr(colon+1);}return uri;}
    auto findController(const json::value& reference){
        // Browser clients address instances by a declared CURIE or full URI.
        // Keep bare IDs compatible, but only strip our exact controller namespace.
        auto key=resolve(string(reference));
        if(key.starts_with(controllerURI))key.erase(0,std::char_traits<char>::length(controllerURI));
        return controllers.find(key);
    }
    void failure(const json::value& call,const char* reason){server.unsupported();send(json::array{4,call,"wamp.error.invalid_argument",reason});}
    void result(const json::value& call,json::value value){send(json::array{3,call,std::move(value)});}
    void stop(const std::shared_ptr<Controller>& c,bool releaseButtons=true){
        ++c->generation;c->input.axes={};c->lastInput=0;c->lastFrame=0;c->busy=false;c->fit=false;
        if(c->moving){c->moving=false;remote(c,"self:update",json::array{"motion",false},{});}
        if(releaseButtons){
            if(c->commandHeld){c->commandHeld=false;remote(c,"self:update",json::array{"commands.activeCommand",""},{});}
            c->buttons.clear();
        }
    }
    void message(const json::array& a){
        if(a.empty()||!a[0].is_int64())throw std::runtime_error("type");
        int type=a[0].as_int64();
        if(type==1&&a.size()==3&&a[1].is_string()&&a[2].is_string()&&a[1].as_string().size()<=128&&a[2].as_string().size()<=1024&&prefixes.size()<32){prefixes[string(a[1])]=string(a[2]);return;}
        if((type==3||type==4)&&a.size()>=3){auto it=pending.find(string(a[1]));if(it==pending.end())return;auto done=std::move(it->second.done);pending.erase(it);if(done)done(type==3,a[2]);return;}
        if((type==5||type==6)&&a.size()==2){
            auto it=findController(a[1]);if(it==controllers.end())return;auto c=it->second;
            c->subscribed=type==5;if(type==6){c->focus=false;if(server.focused==it->first)server.focused.clear();stop(c);}return;
        }
        if(type!=2||a.size()<3||!a[1].is_string()||!a[2].is_string())throw std::runtime_error("call");
        const auto& call=a[1];auto method=resolve(string(a[2]));
        if(method==std::string(rpcURI)+"create"){
            if(a.size()==5&&a[3]=="3dconnexion:3dmouse"&&mouse.empty()){mouse="mouse"+identifier();result(call,json::object{{"connexion",mouse}});return;}
            if(a.size()==6&&a[3]=="3dconnexion:3dcontroller"&&!mouse.empty()&&string(a[4])==mouse&&a[5].is_object()&&controllers.size()<16){
                auto name=string(member(a[5].as_object(),"name"));if(name.size()>1024){failure(call,"Controller name too long");return;}
                auto c=std::make_shared<Controller>();c->id="controller"+identifier();c->name=std::move(name);
                if(auto order=a[5].as_object().if_contains("rowMajorOrder");order&&order->is_bool()){c->rowMajor=order->as_bool();c->layoutFixed=true;}
                controllers[c->id]=c;result(call,json::object{{"instance",c->id}});return;
            }
        }else if(method==std::string(rpcURI)+"update"&&a.size()==5&&a[4].is_object()){
            auto it=findController(a[3]);if(it==controllers.end()){failure(call,"Unknown controller");return;}auto c=it->second;
            const auto& values=a[4].as_object();auto properties=c->properties;
            for(const auto& entry:values)properties[entry.key()]=entry.value();
            if(properties.size()>256){failure(call,"Too many properties");return;}
            if(json::serialize(properties).size()>maxControllerPropertyBytes){failure(call,"Controller properties exceed 1 MiB limit");return;}
            if(auto focus=values.if_contains("focus")){
                if(!focus->is_bool()){failure(call,"focus must be boolean");return;}
                c->focus=focus->as_bool();if(c->focus)server.focused=c->id;else if(server.focused==c->id)server.focused.clear();
                stop(c);
            }
            c->properties=std::move(properties);
            result(call,json::value{});return;
        }else if(method==std::string(rpcURI)+"read"&&a.size()==5){
            auto it=findController(a[3]);if(it==controllers.end()){failure(call,"Unknown controller");return;}
            auto property=string(a[4]);if(property=="device.present")result(call,!server.devices.empty());
            else if(property=="focus")result(call,it->second->focus&&server.focused==it->first);
            else if(property=="motion")result(call,it->second->moving);
            else if(auto p=it->second->properties.if_contains(property))result(call,*p);
            else failure(call,"Unsupported property");return;
        }else if(method==std::string(rpcURI)+"delete"&&a.size()==4){
            auto it=findController(a[3]);if(it!=controllers.end()){stop(it->second);if(server.focused==it->first)server.focused.clear();controllers.erase(it);result(call,{});return;}
            if(string(a[3])==mouse){for(auto& [key,c]:controllers)stop(c);controllers.clear();mouse.clear();result(call,{});return;}
        }
        failure(call,"Unsupported call or arguments");
    }
    void remote(const std::shared_ptr<Controller>& c,const char* method,json::array arguments,std::function<void(bool,json::value)> done){
        if(closed||!c->subscribed){if(done)done(false,{});return;}
        if(pending.size()>=128){server.error("Too many pending web callbacks");close();return;}
        // Only calls with a callback are tracked. 3DxWare does not wait for
        // replies to self:update, and clients such as driftlock.online answer
        // none of them (or answer "transaction" with an error).
        auto call=identifier();if(done)pending.emplace(call,Pending{now()+2000000000,std::move(done)});
        json::array payload{2,call,method,""};for(auto& arg:arguments)payload.push_back(std::move(arg));
        send(json::array{8,controllerURI+c->id,std::move(payload)});
    }
    void receive(const Event& e){
        for(auto& [key,c]:controllers){
            if(e.kind==Kind::reset||e.kind==Kind::removed){stop(c);continue;}
            if(!c->focus||!c->subscribed||server.focused!=key)continue;
            if(e.kind==Kind::motion){c->input=e;c->lastInput=now();if(std::none_of(e.axes.begin(),e.axes.end(),[](int x){return x!=0;}))stop(c,false);}
            if(e.kind==Kind::command&&(e.flags&0x10000))c->fit=true;
            if(e.kind==Kind::buttons){
                auto previous=c->buttons[e.device];c->buttons[e.device]=e.buttons;uint32_t changed=previous^e.buttons;
                char suffix[16];snprintf(suffix,sizeof(suffix),"@%04x:%04x",e.vendor,e.product);
                auto& bindings=server.configuration.commands;auto found=bindings.end();
                for(const auto& profile:{"web:"+c->name+suffix,std::string("*")+suffix,"web:"+c->name,std::string("*")}){found=bindings.find(profile);if(found!=bindings.end())break;}
                if(found!=bindings.end())for(unsigned i=0;i<32;++i)if((changed&(1u<<i))&&!found->second[i].empty()){
                    c->commandHeld=bool(e.buttons&(1u<<i));remote(c,"self:update",json::array{"commands.activeCommand",c->commandHeld?found->second[i]:""},{});
                }
            }
        }
    }
    void tick(uint64_t time){
        std::vector<std::function<void(bool,json::value)>> expired;
        for(auto it=pending.begin();it!=pending.end();)if(time>it->second.deadline){expired.push_back(std::move(it->second.done));it=pending.erase(it);}else ++it;
        if(!expired.empty())server.error("Web callback timed out");
        for(auto& done:expired)if(done)done(false,{});
        if(closed)return;
        for(auto& [key,c]:controllers){
            if(!c->focus||!c->subscribed||server.focused!=key){if(c->moving||c->busy)stop(c);continue;}
            if(c->lastInput&&time-c->lastInput>250000000){stop(c,false);continue;}
            if(c->busy||(!c->lastInput&&!c->fit))continue;
            frame(c,time);
        }
    }
    void frame(const std::shared_ptr<Controller>& c,uint64_t time){
        c->busy=true;auto generation=c->generation;
        auto values=std::make_shared<json::object>();auto remaining=std::make_shared<int>(7);
        const char* properties[]={"view.affine","view.perspective","view.extents","model.extents","pivot.position","view.target","view.rotatable"};
        std::weak_ptr<Session> weak=shared_from_this();
        for(auto property:properties){
            remote(c,"self:read",json::array{property},[weak,c,generation,values,remaining,property,time](bool ok,json::value value){
                auto self=weak.lock();if(!self||self->closed||c->generation!=generation)return;
                if(ok)(*values)[property]=std::move(value);
                if(--*remaining==0)self->applyFrame(c,*values,time);
            });
        }
    }
    void applyFrame(const std::shared_ptr<Controller>& c,const json::object& values,uint64_t time){
        if(!c->focus||server.focused!=c->id){stop(c);return;}
        auto affine=member(values,"view.affine"),extents=member(values,"view.extents"),bounds=member(values,"model.extents");
        if(!numbers(affine,16)){c->busy=false;stop(c);server.error("Client did not supply view.affine");return;}
        const auto& m=affine.as_array();
        if(!c->layoutFixed){
            // Clients such as driftlock.online send row-major matrices without
            // declaring it; 3DxWare accepts them. The homogeneous row (0,0,0,1)
            // reveals the layout whenever the translation is non-zero.
            auto zero=[&](int i){return std::abs(number(m[i]))<1e-9;};
            bool column=zero(3)&&zero(7)&&zero(11),row=zero(12)&&zero(13)&&zero(14);
            if(column!=row)c->rowMajor=row;
        }
        auto at=[&](int i){return number(m[c->rowMajor?(i%4)*4+i/4:i]);};
        Camera camera{{at(0),at(1),at(2)},{at(4),at(5),at(6)},{at(8),at(9),at(10)},{at(12),at(13),at(14)}};
        auto position=member(values,"pivot.position");if(!numbers(position,3))position=member(values,"view.target");
        Vec pivot{};if(numbers(position,3))pivot={number(position.as_array()[0]),number(position.as_array()[1]),number(position.as_array()[2])};
        else if(numbers(bounds,6)){const auto& b=bounds.as_array();pivot={(number(b[0])+number(b[3]))/2,(number(b[1])+number(b[4]))/2,(number(b[2])+number(b[5]))/2};}
        bool perspective=!values.contains("view.perspective")||boolean(member(values,"view.perspective"));
        bool rotatable=!values.contains("view.rotatable")||boolean(member(values,"view.rotatable"));
        bool hasExtents=numbers(extents,6);double scale=std::max(1e-3,length(camera.position-pivot));
        if(!perspective&&hasExtents)scale=std::max(1e-3,number(extents.as_array()[4])-number(extents.as_array()[1]));
        double dt=c->lastFrame?double(time-c->lastFrame)/1e9:1.0/120;c->lastFrame=time;
        if(c->fit){
            c->fit=false;
            if(numbers(bounds,6)){const auto& b=bounds.as_array();Vec size{number(b[3])-number(b[0]),number(b[4])-number(b[1]),number(b[5])-number(b[2])};
                double radius=std::max(1e-6,length(size)/2);camera.position=pivot+camera.back*(radius/std::sin(0.7853981633974483/2)*1.05);
                if(hasExtents){auto& x=extents.as_array();double height=number(x[4])-number(x[1]);double aspect=height>0?(number(x[3])-number(x[0]))/height:1;aspect=std::max(.01,aspect);x[0]=-radius*std::max(1.,aspect);x[3]=-number(x[0]);x[1]=-radius*std::max(1.,1/aspect);x[4]=-number(x[1]);}
            }
        }else{
            NavigationView view{camera,pivot,perspective,rotatable,bool(c->input.flags&Flags::orbit),hasExtents};
            if(hasExtents)for(int i=0;i<6;++i)view.extents[i]=number(extents.as_array()[i]);
            view.advance(c->input.axes,dt,scale);camera=view.camera;
            if(hasExtents)for(int i=0;i<6;++i)extents.as_array()[i]=view.extents[i];
        }
        double next[16]{camera.right.x,camera.right.y,camera.right.z,0,camera.up.x,camera.up.y,camera.up.z,0,camera.back.x,camera.back.y,camera.back.z,0,camera.position.x,camera.position.y,camera.position.z,1};
        json::array matrix;for(int i=0;i<16;++i)matrix.push_back(next[c->rowMajor?(i%4)*4+i/4:i]);
        if(!numbers(matrix,16)){stop(c);return;}
        if(!c->moving){c->moving=true;remote(c,"self:update",json::array{"motion",true},{});}
        remote(c,"self:update",json::array{"transaction",1},{});
        remote(c,"self:update",json::array{"view.affine",std::move(matrix)},{});
        if(!perspective&&hasExtents)remote(c,"self:update",json::array{"view.extents",extents},{});
        std::weak_ptr<Session> weak=shared_from_this();auto generation=c->generation;
        remote(c,"self:update",json::array{"transaction",0},[weak,c,generation](bool,json::value){if(auto self=weak.lock();self&&c->generation==generation)c->busy=false;});
        if(!c->lastInput)stop(c);
    }
};

WebServer::Impl::Impl(std::string host,uint16_t service):address(std::move(host)),port(service){
    OPENSSL_init_ssl(OPENSSL_INIT_NO_LOAD_CONFIG,nullptr);
    tick();thread=std::thread([this]{@autoreleasepool {io.run();}});
}
WebServer::Impl::~Impl(){net::post(io,[this]{shuttingDown=true;stop();timer.cancel();work.reset();});thread.join();}
void WebServer::Impl::stop(){
    ++epoch;enabled=false;if(acceptor){Error ignored;acceptor->close(ignored);acceptor.reset();}
    while(!sessions.empty()){auto session=sessions.begin()->second;session->close();}
    focused.clear();tls.reset();std::lock_guard lock(mutex);diagnostics["listening"]=false;
}
void WebServer::Impl::apply(WebConfiguration config){
    stop();configuration=std::move(config);
    {std::lock_guard lock(mutex);diagnostics["enabled"]=configuration.enabled;diagnostics["error"]="";diagnostics["setupRequired"]=false;}
    if(!configuration.enabled)return;
    if(access(configuration.certificate.c_str(),R_OK)||access(configuration.key.c_str(),R_OK)){
        std::lock_guard lock(mutex);diagnostics["setupRequired"]=true;diagnostics["error"]="Web navigation needs setup in Axial.";return;
    }
    try{
        tls=std::make_shared<net::ssl::context>(net::ssl::context::tls_server);
        SSL_CTX_set_min_proto_version(tls->native_handle(),TLS1_2_VERSION);
        tls->use_certificate_chain_file(configuration.certificate);tls->use_private_key_file(configuration.key,net::ssl::context::pem);
        if(SSL_CTX_check_private_key(tls->native_handle())!=1)throw std::runtime_error("Certificate/key mismatch");
        acceptor=std::make_unique<tcp::acceptor>(io);
        acceptor->open(tcp::v4());acceptor->set_option(net::socket_base::reuse_address(true));
        auto bindAddress=net::ip::make_address(address);if(!bindAddress.is_loopback())throw std::runtime_error("Web API requires a loopback address");
        acceptor->bind(tcp::endpoint(bindAddress,port));acceptor->listen(16);boundPort=acceptor->local_endpoint().port();
        enabled=true;{std::lock_guard lock(mutex);diagnostics["listening"]=true;diagnostics["port"]=boundPort;}accept(epoch);
    }catch(const boost::system::system_error& e){
        stop();std::lock_guard lock(mutex);
        if(e.code().value()==EADDRNOTAVAIL){diagnostics["setupRequired"]=true;diagnostics["error"]="The local web address needs setup in Axial.";}
        else if(e.code().value()==EADDRINUSE)diagnostics["error"]="Another application is using web navigation port 8181. Quit the other driver, then retry.";
        else {diagnostics["setupRequired"]=true;diagnostics["error"]="Web navigation could not start. Check its setup in Axial.";}
        fprintf(stderr,"Axial web listener: %s\n",e.what());
    }catch(const std::exception& e){stop();error("Web navigation could not start. Check its setup in Axial.");fprintf(stderr,"Axial web listener: %s\n",e.what());}
}
void WebServer::Impl::accept(uint64_t generation){
    acceptor->async_accept([this,generation](Error ec,tcp::socket socket){
        if(generation!=epoch)return;
        if(!ec&&sessions.size()<32){auto session=std::make_shared<Session>(*this,std::move(socket));sessions[session->id]=session;{std::lock_guard lock(mutex);diagnostics["connections"]=sessions.size();}session->start();}
        if(acceptor&&acceptor->is_open())accept(generation);
    });
}
void WebServer::Impl::tick(){
    if(shuttingDown)return;
    timer.expires_after(std::chrono::milliseconds(8));timer.async_wait([this](Error ec){
        // Cancellation cannot change an already queued successful completion.
        // Prevent that completion from rearming the timer during shutdown.
        if(ec||shuttingDown)return;std::deque<Event> events;bool lost;
        {std::lock_guard lock(mutex);events.swap(incoming);lost=overflow;overflow=false;}
        if(lost){Event reset;reset.kind=Kind::reset;events.clear();events.push_back(reset);error("Web input queue overflow; motion reset");}
        for(const auto& e:events){
            if(e.kind==Kind::added)devices[e.device]=e;else if(e.kind==Kind::removed)devices.erase(e.device);
            auto clients=sessions;for(auto& [key,s]:clients)if(!s->closed)s->receive(e);
        }
        auto clients=sessions;for(auto& [key,s]:clients)if(!s->closed)s->tick(now());
        {std::lock_guard lock(mutex);diagnostics["focusedController"]=focused;}
        tick();
    });
}
WebServer::WebServer(std::string address,uint16_t port):impl(std::make_unique<Impl>(std::move(address),port)){}
WebServer::~WebServer()=default;
void WebServer::retry(){net::post(impl->io,[p=impl.get()]{p->apply(p->configuration);});}
void WebServer::configure(WebConfiguration config){
    {std::lock_guard lock(impl->mutex);if(config==impl->requested)return;impl->requested=config;}
    net::post(impl->io,[p=impl.get(),config=std::move(config)]()mutable{p->apply(std::move(config));});
}
void WebServer::receive(const Event& e){
    if(!impl->enabled&&e.kind!=Kind::added&&e.kind!=Kind::removed)return;
    std::lock_guard lock(impl->mutex);if(impl->incoming.size()>=256){impl->overflow=true;return;}impl->incoming.push_back(e);
}
std::string WebServer::status() const {std::lock_guard lock(impl->mutex);return json::serialize(impl->diagnostics);}
}
