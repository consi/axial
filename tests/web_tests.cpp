#include "web_client.hpp"

void onshapeInitialization(sn::WebServer& server,unsigned port,const std::string& directory){
    Client client(port,directory+"/root.crt");client.connect();
    client.send(json::array{1,"3dx_rpc","wss://127.51.68.120/3dconnexion#"});
    client.send(json::array{1,"3dconnexion","wss://127.51.68.120/3dconnexion"});
    client.send(json::array{1,"self","https://cad.onshape.com/"});
    auto mouse=client.call({2,"mouse","3dx_rpc:create","3dconnexion:3dmouse","0.6.0"}).as_object()["connexion"];
    auto controller=client.call({2,"controller","3dx_rpc:create","3dconnexion:3dcontroller",mouse,json::object{{"name","Onshape"},{"version",0.6},{"rowMajorOrder",false}}}).as_object()["instance"];
    auto target="3dconnexion:3dcontroller/"+text(controller);
    client.send(json::array{5,target});
    client.call({2,"focus","3dx_rpc:update",target,json::object{{"focus",true}}});
    client.call({2,"frame","3dx_rpc:update",target,json::object{{"frame",json::object{{"timingSource",1}}}}});
    auto commands=json::parse(R"({"activeSet":"Default","tree":{"nodes":[{"id":"Part Studio","label":"Part Studio","type":0,"nodes":[{"id":"Commands","label":"Commands","type":1,"nodes":[{"id":"extrude","label":"Extrude","type":2,"description":""}]}]},{"id":"Default","label":"Default","type":0,"nodes":[]}]}})");
    client.call({2,"commands","3dx_rpc:update",target,json::object{{"commands",commands}}});
    // Match the captured upload's byte count with a synthetic base64 SVG:
    // <svg > followed by spaces and </svg>. No vendor images or document IDs.
    json::array images{json::object{{"id","extrude"},{"type",3},{"index",0},{"data","PHN2ZyA+PC9zdmc+"}}};
    json::array upload{2,"images","3dx_rpc:update",target,json::object{{"images",images}}};
    constexpr size_t capturedBytes=372217;
    while((capturedBytes-json::serialize(upload).size())%4)upload[1].as_string().push_back('x');
    auto paddingBytes=capturedBytes-json::serialize(upload).size();
    std::string svg="PHN2ZyA+";svg.reserve(paddingBytes+16);
    for(size_t i=0;i<paddingBytes;i+=4)svg+="ICAg";
    svg+="PC9zdmc+";images[0].as_object()["data"]=svg;
    upload[4].as_object()["images"]=images;
    CHECK(json::serialize(upload).size()==capturedBytes);
    CHECK(client.call(upload).is_null());
    CHECK(client.call({2,"images-read","rpc:read",target,"images"})==images);
    CHECK(client.call({2,"commands-read","rpc:read",target,"commands"})==commands);

    // Each update fits individually, but the merged properties exceed 1 MiB.
    // A rejected update must not overwrite commands or release navigation focus.
    client.send(json::array{2,"overflow","rpc:update",target,json::object{{"padding",std::string(700*1024,'x')},{"focus",false},{"commands",json::object{}}}});
    auto error=client.read();
    CHECK(error==json::array({4,"overflow","wamp.error.invalid_argument","Controller properties exceed 1 MiB limit"}));
    CHECK(client.call({2,"focused","rpc:read",target,"focus"})==true);
    CHECK(client.call({2,"commands-read","rpc:read",target,"commands"})==commands);
    CHECK(client.call({2,"images-read","rpc:read",target,"images"})==images);
    CHECK(client.call({2,"recovery","rpc:update",target,json::object{{"padding","accepted"}}}).is_null());
    CHECK(client.call({2,"padding-read","rpc:read",target,"padding"})=="accepted");

    sn::Event e;e.device=1;e.vendor=0x046d;e.product=0xc627;e.kind=sn::Kind::added;server.receive(e);
    e.kind=sn::Kind::motion;e.axes[0]=350;e.flags=sn::Flags::orbit;server.receive(e);
    while(client.matrices<2||client.transaction)client.callback(client.read());
    CHECK(client.matrix[12].to_number<double>()>0);CHECK(client.moving);
    e.axes={};server.receive(e);while(client.moving)client.callback(client.read());
    client.call({2,"blur","rpc:update",target,json::object{{"focus",false}}});

    // At the storage boundary, the read response plus its call ID exceeds 1 MiB.
    auto boundary=client.call({2,"boundary","rpc:create","3dconnexion:3dcontroller",mouse,json::object{{"name","Storage limit"}}}).as_object()["instance"];
    json::object properties{{"images",""}};
    properties["images"]=std::string(1024*1024-json::serialize(properties).size(),'x');
    CHECK(json::serialize(properties).size()==1024*1024);
    CHECK(client.call({2,"boundary-update","rpc:update",boundary,properties}).is_null());
    CHECK(client.call({2,std::string(64,'r'),"rpc:read",boundary,"images"})==properties["images"]);
    client.send(json::array{2,"boundary-overflow","rpc:update",boundary,json::object{{"extra",true}}});
    error=client.read();CHECK(error[0]==4&&error[1]=="boundary-overflow");
    CHECK(client.call({2,"boundary-read","rpc:read",boundary,"images"})==properties["images"]);

    // A transport overflow closes only the offending connection.
    {
        Client oversized(port,directory+"/root.crt");oversized.connect();
        // A masked text frame declares 2 MiB + 1 bytes. Send only the header:
        // the server must reject the length before waiting for the payload.
        const unsigned char header[]{0x81,0xff,0,0,0,0,0,0x20,0,1,0,0,0,0};
        net::write(oversized.socket.next_layer(),net::buffer(header));
        beast::flat_buffer buffer;boost::system::error_code ec;
        oversized.socket.read(buffer,ec);
        CHECK(ec==ws::error::closed);
        CHECK(oversized.socket.reason().code==ws::close_code::too_big);
    }
    auto diagnosed=[&]{
        auto error=text(json::parse(server.status()).as_object()["error"]);
        return error=="Web client message exceeds 2 MiB limit"||error.starts_with("Web client TLS read failed: ");
    };
    for(int i=0;i<100;++i){
        if(diagnosed())break;
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    CHECK(diagnosed());
    CHECK(client.call({2,"still-connected","rpc:read",target,"images"})==images);
    Client fresh(port,directory+"/root.crt");fresh.connect();
    CHECK(fresh.call({2,"fresh-mouse","rpc:create","3dconnexion:3dmouse","0.6.0"}).as_object().contains("connexion"));
}

// driftlock.online replays: the page answers reads, but ignores self:update for
// view.affine and motion, and rejects "transaction" as an unknown property. Its
// matrices are row-major without declaring rowMajorOrder. 3DxWare keeps
// navigating; Axial must not time the session out, stop motion or mix layouts.
void unansweredUpdates(sn::WebServer& server,unsigned port,const std::string& directory){
    Client client(port,directory+"/root.crt");client.connect();
    client.send(json::array{1,"3dx_rpc","wss://127.51.68.120/3dconnexion#"});
    client.send(json::array{1,"3dconnexion","wss://127.51.68.120/3dconnexion"});
    client.send(json::array{1,"self","https://driftlock.online/"});
    auto mouse=client.call({2,"mouse","3dx_rpc:create","3dconnexion:3dmouse","0.7.0"}).as_object()["connexion"];
    auto controller=client.call({2,"controller","3dx_rpc:create","3dconnexion:3dcontroller",mouse,json::object{{"name","DRIFT//LOCK"},{"version",0.7},{"rowMajorOrder",false}}}).as_object()["instance"];
    auto target="3dconnexion:3dcontroller/"+text(controller);
    client.send(json::array{5,target});
    client.call({2,"focus","3dx_rpc:update",target,json::object{{"focus",true}}});
    int matrices=0,motionOff=0;json::array rowMajor{1,0,0,0,0,1,0,0,0,0,1,10,0,0,0,1};
    auto driftlock=[&](const json::array& event){
        CHECK(event[0]==8);const auto& call=event[2].as_array();CHECK(call[0]==2);
        auto property=text(call[4]);
        if(call[2]=="self:read"){
            json::value value;
            if(property=="view.affine")value=rowMajor;
            else if(property=="view.perspective"||property=="view.rotatable")value=true;
            else if(property=="view.extents"||property=="model.extents")value=json::array{-1,-1,-1,1,1,1};
            else if(property=="pivot.position")value=json::array{0,0,0};
            else {client.send(json::array{4,call[1],"self:read#generic","unknown property"});return;}
            client.send(json::array{3,call[1],value});return;
        }
        CHECK(call[2]=="self:update");
        if(property=="view.affine"){rowMajor=call[5].as_array();++matrices;auto n=[&](int i){return rowMajor[i].to_number<double>();};CHECK(n(12)==0&&n(13)==0&&n(14)==0&&n(15)==1);}
        else if(property=="motion"){if(!call[5].as_bool())++motionOff;}
        else if(property=="transaction")client.send(json::array{4,call[1],"self:update#generic","transaction unknown property"});
    };
    sn::Event e;e.device=1;e.vendor=0x046d;e.product=0xc629;e.kind=sn::Kind::motion;e.axes[0]=350;e.flags=sn::Flags::orbit;server.receive(e);
    auto started=std::chrono::steady_clock::now(),sent=started;int early=0;
    while(std::chrono::steady_clock::now()-started<std::chrono::milliseconds(2600)){
        driftlock(client.read());
        auto now=std::chrono::steady_clock::now();
        // The cap keeps reporting while held; idle input stops motion after 250 ms.
        if(now-sent>std::chrono::milliseconds(100)){server.receive(e);sent=now;}
        if(now-started<std::chrono::milliseconds(2100))early=matrices;
    }
    // Navigation survived the two-second callback deadline.
    CHECK(early>10);CHECK(matrices>early);
    CHECK(rowMajor[3].to_number<double>()>0);
    auto error=text(json::parse(server.status()).as_object()["error"]);
    CHECK(!error.starts_with("Web callback timed out")&&!error.starts_with("Client did not supply"));
    e.axes={};server.receive(e);while(!motionOff)driftlock(client.read());
    CHECK(client.call({2,"alive","rpc:read",target,"focus"})==true);
    client.call({2,"blur","rpc:update",target,json::object{{"focus",false}}});
}

int main(int argc,char** argv){try{
    CHECK(argc==2);std::string directory=argv[1];
    sn::WebServer server("127.0.0.1",0);sn::WebConfiguration config;
    config.certificate=directory+"/server.crt";config.key=directory+"/server.key";server.configure(config);
    json::object status;
    for(int i=0;i<300;++i){status=json::parse(server.status()).as_object();if(status["listening"]==true)break;std::this_thread::sleep_for(std::chrono::milliseconds(10));}
    CHECK(status["listening"]==true);unsigned port=status["port"].to_number<unsigned>();
    for(const auto& origin:{"https://unlisted.example","http://untrusted.example"}){
        Client client(port,directory+"/root.crt");http::request<http::empty_body> request{http::verb::get,"/3dconnexion/nlproxy",11};
        request.set(http::field::host,client.host);request.set(http::field::origin,origin);
        http::write(client.socket.next_layer(),request);http::response<http::string_body> response;beast::flat_buffer buffer;http::read(client.socket.next_layer(),buffer,response);
        CHECK(response.result()==(std::string(origin).starts_with("https:")?http::status::ok:http::status::forbidden));
        if(response.result()==http::status::ok)CHECK(json::parse(response.body()).as_object()["port"].to_number<unsigned>()==port);
    }
    Client client(port,directory+"/root.crt");client.connect();
    // Replay the browser's 0.7.0 handshake: RPC targets are controller CURIEs,
    // not the bare instance IDs returned by create.
    client.send(json::array{1,"3dx_rpc","wss://127.51.68.120/3dconnexion#"});
    client.send(json::array{1,"3dconnexion","wss://127.51.68.120/3dconnexion"});
    client.send(json::array{1,"self","https://3dconnexion.com/technical_support/web_threejs.html"});
    auto mouse=client.call({2,"mouse","3dx_rpc:create","3dconnexion:3dmouse","0.7.0"}).as_object()["connexion"];
    auto controller=client.call({2,"controller","3dx_rpc:create","3dconnexion:3dcontroller",mouse,json::object{{"name","WebThreeJS Sample"},{"version",0.7},{"rowMajorOrder",false}}}).as_object()["instance"];
    auto compact="3dconnexion:3dcontroller/"+text(controller);
    auto full="wss://127.51.68.120/3dconnexion3dcontroller/"+text(controller);
    client.send(json::array{5,compact});
    client.call({2,"focus","3dx_rpc:update",compact,json::object{{"focus",true}}});
    client.call({2,"frame","3dx_rpc:update",compact,json::object{{"frame",json::object{{"timingSource",1}}}}});
    auto commands=json::parse(R"({"activeSet":"Default","tree":{"nodes":[{"id":"Default","label":"Custom action set","type":0,"nodes":[{"id":"CAT_ID_FILE","label":"File","type":1,"nodes":[{"id":"ID_OPEN","label":"Open","type":2,"description":"Open file"}]}]}]}})");
    client.call({2,"commands","3dx_rpc:update",compact,json::object{{"commands",commands}}});
    CHECK(client.call({2,"commands-read","rpc:read",full,"commands"})==commands);
    CHECK(client.call({2,"focused","rpc:read",compact,"focus"})==true);
    sn::Event e;e.device=1;e.vendor=0x046d;e.product=0xc627;e.kind=sn::Kind::added;server.receive(e);
    e.kind=sn::Kind::motion;e.axes[0]=350;e.flags=sn::Flags::orbit;server.receive(e);
    while(client.matrices<2||client.transaction)client.callback(client.read());
    CHECK(client.matrix[12].to_number<double>()>0);CHECK(client.moving);
    e.axes={};server.receive(e);while(client.moving)client.callback(client.read());
    client.call({2,"blur","rpc:update",controller,json::object{{"focus",false}}});
    CHECK(client.call({2,"focused","rpc:read",controller,"focus"})==false);
    // Bare IDs, declared prefixes and full URIs address the same session-local
    // controller; unrelated namespaces and other sessions cannot alias it.
    client.send(json::array{1,"alias","wss://127.51.68.120/3dconnexion"});
    for(const auto& reference:{text(controller),compact,full,"alias:3dcontroller/"+text(controller)}){
        client.send(json::array{5,reference});
        client.call({2,"refocus","rpc:update",reference,json::object{{"focus",true}}});
        CHECK(client.call({2,"focused","rpc:read",reference,"focus"})==true);
        client.send(json::array{6,reference});
        CHECK(client.call({2,"unsubscribed","rpc:read",reference,"focus"})==false);
    }
    CHECK(json::parse(server.status()).as_object()["unsupported"]==0);
    client.unknownController("wss://unrelated.example/3dconnexion3dcontroller/"+text(controller));
    client.unknownController("undeclared:3dcontroller/"+text(controller));
    {Client other(port,directory+"/root.crt");other.connect();other.unknownController(full);}
    client.send(json::array{2,"unknown","rpc:unsupported"});
    auto error=client.read();CHECK(error[0]==4&&error[1]=="unknown");
    for(const auto& prefix:{"","3dconnexion:3dcontroller/","wss://127.51.68.120/3dconnexion3dcontroller/"}){
        auto second=client.call({2,"controller2","rpc:create","3dconnexion:3dcontroller",mouse,json::object{{"name","Second view"}}}).as_object()["instance"];
        CHECK(second!=controller);client.call({2,"delete","rpc:delete",prefix+text(second)});
        client.unknownController(text(second));
    }
    unansweredUpdates(server,port,directory);
    onshapeInitialization(server,port,directory);
    sn::WebServer conflict("127.0.0.1",port);conflict.configure(config);
    std::this_thread::sleep_for(std::chrono::milliseconds(100));CHECK(json::parse(conflict.status()).as_object()["listening"]==false);
    config.enabled=false;server.configure(config);
    for(int i=0;i<100;++i){status=json::parse(server.status()).as_object();if(status["listening"]==false)break;std::this_thread::sleep_for(std::chrono::milliseconds(10));}
    CHECK(status["listening"]==false);
    // An explicit retry must preserve the enabled preference.
    server.retry();std::this_thread::sleep_for(std::chrono::milliseconds(30));
    CHECK(json::parse(server.status()).as_object()["listening"]==false);
    // Destroying a live server closes both active WebSockets and its listener.
    config.enabled=true;auto lifetime=std::make_unique<sn::WebServer>("127.0.0.1",0);lifetime->configure(config);
    for(int i=0;i<300;++i){status=json::parse(lifetime->status()).as_object();if(status["listening"]==true)break;std::this_thread::sleep_for(std::chrono::milliseconds(10));}
    CHECK(status["listening"]==true);auto lifetimePort=status["port"].to_number<unsigned>();
    Client connected(lifetimePort,directory+"/root.crt");connected.connect();lifetime.reset();
    bool closed=false;try{connected.read();}catch(const boost::system::system_error&){closed=true;}CHECK(closed);
    net::io_context probeIO;tcp::socket probe(probeIO);boost::system::error_code connectError;
    probe.connect(tcp::endpoint(net::ip::make_address("127.0.0.1"),lifetimePort),connectError);CHECK(bool(connectError));
    std::cout<<"TLS, discovery, origins, WAMP lifecycle, unanswered updates, Onshape initialization, size limits, camera callbacks, neutral, focus and port conflict passed\n";
    return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<"\n";return 1;}}
