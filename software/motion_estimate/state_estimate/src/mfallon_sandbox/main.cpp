#include <estimate/leg_odometry.hpp>
#include <ConciseArgs>


class App{
  public:
    App(boost::shared_ptr<lcm::LCM> &lcm_subscribe_, boost::shared_ptr<lcm::LCM> &lcm_publish_, const CommandLineConfig& cl_cfg_);
    
    ~App(){
    }

  private:
    boost::shared_ptr<lcm::LCM> lcm_subscribe_, lcm_publish_;
    const CommandLineConfig cl_cfg_;
    leg_odometry* leg_odo_;
    
    void robotStateHandler(const lcm::ReceiveBuffer* rbuf, const std::string& channel, const  drc::robot_state_t* msg);
    

};
    
App::App(boost::shared_ptr<lcm::LCM> &lcm_subscribe_,  boost::shared_ptr<lcm::LCM> &lcm_publish_, const CommandLineConfig& cl_cfg_):
          lcm_subscribe_(lcm_subscribe_), lcm_publish_(lcm_publish_), cl_cfg_(cl_cfg_){

  leg_odo_ = new leg_odometry(lcm_subscribe_, lcm_publish_, cl_cfg_);
            
  lcm_subscribe_->subscribe("EST_ROBOT_STATE",&App::robotStateHandler,this);  
}

void App::robotStateHandler(const lcm::ReceiveBuffer* rbuf, const std::string& channel, const  drc::robot_state_t* msg){
  if ( cl_cfg_.begin_timestamp > -1){
    if (msg->utime <  cl_cfg_.begin_timestamp ){
      double seek_seconds = (cl_cfg_.begin_timestamp - msg->utime)*1E-6;
      std::cout << msg->utime << " too early | seeking " << seek_seconds    << "secs, to " << cl_cfg_.begin_timestamp << "\n";
      return;
    }
  }
  if ( cl_cfg_.end_timestamp > -1){
    if (msg->utime >  cl_cfg_.end_timestamp ){
      leg_odo_->terminate();
      std::cout << msg->utime << " finishing\n";
      exit(-1);
      return;
    }    
  }
  
  leg_odo_->Update(msg);
}


int main(int argc, char ** argv){
  CommandLineConfig cl_cfg;
  cl_cfg.urdf_filename = "";
  cl_cfg.config_filename = "";
  cl_cfg.lcmlog_filename = "";
  cl_cfg.read_lcmlog = false;
  cl_cfg.begin_timestamp = -1;
  cl_cfg.end_timestamp = -1;
  
  ConciseArgs opt(argc, (char**)argv);
  opt.add(cl_cfg.urdf_filename, "uf", "urdf_filename","urdf_filename");
  opt.add(cl_cfg.config_filename, "cf", "config_filename","config_filename");
  opt.add(cl_cfg.lcmlog_filename, "lf", "lcmlog_filename","lcmlog_filename");
  opt.add(cl_cfg.begin_timestamp, "bt", "begin_timestamp","Run estimation from this timestamp");
  opt.add(cl_cfg.end_timestamp, "et", "end_timestamp","End estimation at this timestamp");  
  opt.parse();
  
  std::string lcmurl = "";
  if (cl_cfg.lcmlog_filename == "" ){
    lcmurl="";
  }else{
    cl_cfg.read_lcmlog = true;
    lcmurl = "file://" + cl_cfg.lcmlog_filename + "?speed=0";// + "&start_timestamp=";// + begin_timestamp;
  }
  
  boost::shared_ptr<lcm::LCM> lcm_subscribe(new lcm::LCM(lcmurl) );
  boost::shared_ptr<lcm::LCM> lcm_publish(new lcm::LCM("") );
  
  if(!lcm_subscribe->good())
    return 1;  
  if(!lcm_publish->good())
    return 1;  
  
  App app(lcm_subscribe, lcm_publish, cl_cfg);
  while(0 == lcm_subscribe->handle());
  return 0;
}