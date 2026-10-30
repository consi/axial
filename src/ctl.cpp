#include "axial/transport.hpp"
#include <cstdio>
#include <iostream>
#include <string>
int main(int argc,char** argv) {
    std::string command=argc>1?argv[1]:"status";
    if(command=="monitor") {
        int fd=sn::openEvents(sn::Flags::monitor);if(fd<0){perror("Axial");return 1;}
        sn::Event e;
        while(sn::readAll(fd,&e,sizeof(e))&&sn::valid(e)){
            printf("%llu %u device=%u %04x:%04x axes=[%d,%d,%d,%d,%d,%d] buttons=%08x\n",e.received,unsigned(e.kind),e.device,e.vendor,e.product,e.axes[0],e.axes[1],e.axes[2],e.axes[3],e.axes[4],e.axes[5],e.buttons);fflush(stdout);
        }close(fd);return 0;
    }
    std::string request;
    if(command=="status")request="{\"op\":\"status\"}";
    else if(command=="stop")request="{\"op\":\"stop\"}";
    else if(command=="config")request="{\"op\":\"getConfig\"}";
    else if(command=="commands")request="{\"op\":\"getCommands\"}";
    else if(command=="calibrate")request="{\"op\":\"calibrate\"}";
    else if(command=="set-config"){
        std::string data((std::istreambuf_iterator<char>(std::cin)),{});
        request="{\"op\":\"setConfig\",\"config\":"+data+"}";
    } else {fprintf(stderr,"usage: axialctl [status|stop|monitor|config|commands|calibrate|set-config < settings.json]\n");return 2;}
    auto response=sn::request(request);std::cout<<response<<std::endl;
    // Service failures are top-level error objects. Status also contains a
    // nested web.error field, which must not turn a successful query into failure.
    return response.starts_with("{\"error\":")?1:0;
}
