// file: robot_model_publisher.cpp
// Broadcasts an URDF only once. 

#include <stdio.h>
#include <iostream>
#include <fstream>
#include <sys/time.h>
#include <time.h>

#include "urdf/model.h"
#include <lcm/lcm-cpp.hpp>
#include "lcmtypes/drc_lcmtypes.hpp"
#include <ConciseArgs>

using namespace std;

int main(int argc, char ** argv)
{
  string urdf_file = "path_to_your.urdf";
  string role = "robot";
  ConciseArgs opt(argc, (char**)argv);
  opt.add(urdf_file, "u", "urdf_file","Robot URDF file");
  opt.add(role, "r", "role","Role - robot or base");
  opt.parse();
  std::cout << "urdf_file: " << urdf_file << "\n";
  std::cout << "role: " << role << "\n";

  string lcm_url="";
  if(role.compare("robot") == 0){
     lcm_url = "";
  }else if(role.compare("base") == 0){
     lcm_url = "udpm://239.255.12.68:1268?ttl=1";
  }else{
    std::cout << "Role not understood, choose: robot or base\n";
    return 1;
  }

  // get the entire file
  std::string xml_string;
  std::fstream xml_file(urdf_file.c_str(), std::fstream::in);
  if (xml_file.is_open())
  {
    while ( xml_file.good() )
    {
      std::string line;
      std::getline( xml_file, line);     
      xml_string += (line + "\n");
    }
    xml_file.close();
    std::cout << "File ["<< urdf_file << "]  parsed successfully.\n";    
  }
  else
  {
    std::cout << "ERROR: Could not open file ["<< urdf_file << "] for parsing.\n";
    return false;
  }
  
  
  urdf::Model robot;
  if (!robot.initFile(urdf_file)){
    std::cerr << "ERROR: Model Parsing the xml failed" << std::endl;
    return -1;
  }

    lcm::LCM lcm(lcm_url);
    if(!lcm.good())
        return 1;
    

    
    drc::robot_urdf_t message;
    message.robot_name =robot.getName();
    message.urdf_xml_string = xml_string;
    std::cout << "Broadcasting urdf of robot [" << robot.getName() << "] as a string at 1Hz\n";
   struct timeval tv;
  while(true)
  {
    gettimeofday (&tv, NULL);
    message.utime = (int64_t) tv.tv_sec * 1000000 + tv.tv_usec; // TODO: replace with bot_timestamp_now() from bot_core
    lcm.publish("ROBOT_MODEL", &message);
    usleep(1000000);
  }
    

    return 0;
}
