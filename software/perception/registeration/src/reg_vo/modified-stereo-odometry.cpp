#include "modified-stereo-odometry.hpp"

#include <bot_core/bot_core.h>

#include <fovis/fovis.hpp>
#include <fovis/tictoc.hpp>
#include <lcmtypes/fovis_update_t.h>
#include <lcmtypes/fovis_tictoc_t.h>
#include <lcmtypes/fovis_param_t.h>
#include <lcmtypes/fovis_stats_t.h>

#include "jpeg-utils.h"
#ifdef USE_LCMGL
#include "visualization.hpp"
#endif

using namespace std;
using namespace cv;


namespace fovis
{

sig_atomic_t StereoOdometry::_shutdown_flag = 0;

int
StereoOdometry::init_calibration(const char * key_prefix)
{
  std::string key;
  std::string key_prefix_str;
  CameraIntrinsicsParameters * params;
  for (int i=0; i < 2; ++i) {
    if (i == 0) {
      key_prefix_str = std::string(key_prefix) + ".left";
      params = &(_stereo_params.left_parameters);
    } else {
      key_prefix_str = std::string(key_prefix) + ".right";

      params = &(_stereo_params.right_parameters);
    }
    params->width = bot_param_get_int_or_fail(_bot_param, (key_prefix_str+".width").c_str());
    params->height = bot_param_get_int_or_fail(_bot_param,(key_prefix_str+".height").c_str());
    params->fx = bot_param_get_double_or_fail(_bot_param, (key_prefix_str+".fx").c_str());
    params->fy = bot_param_get_double_or_fail(_bot_param, (key_prefix_str+".fy").c_str());
    params->cx = bot_param_get_double_or_fail(_bot_param, (key_prefix_str+".cx").c_str());
    params->cy = bot_param_get_double_or_fail(_bot_param, (key_prefix_str+".cy").c_str());
    params->k1 = bot_param_get_double_or_fail(_bot_param, (key_prefix_str+".k1").c_str());
    params->k2 = bot_param_get_double_or_fail(_bot_param, (key_prefix_str+".k2").c_str());
    params->k3 = bot_param_get_double_or_fail(_bot_param, (key_prefix_str+".k3").c_str());
    params->p1 = bot_param_get_double_or_fail(_bot_param, (key_prefix_str+".p1").c_str());
    params->p2 = bot_param_get_double_or_fail(_bot_param, (key_prefix_str+".p2").c_str());
  }

  // We assume rotation is a rotation matrix
  double rotation[9], translation[3];
  bot_param_get_double_array_or_fail(_bot_param,
                                     (key_prefix_str+".rotation").c_str(),
                                     &rotation[0],
                                     9);
  bot_param_get_double_array_or_fail(_bot_param,
                                     (key_prefix_str+".translation").c_str(),
                                     &translation[0],
                                     3);

  bot_matrix_to_quat(rotation, _stereo_params.right_to_left_rotation);
  std::copy(translation, translation+3, _stereo_params.right_to_left_translation);


  // IMU variables:
  _imu_init=false;

  return 0;
}

void
StereoOdometry::publish_tictoc_stats()
{
  std::vector<tictoc_t> tictoc_stats;
  tictoc_get_stats(&tictoc_stats);
  // publish all tictoc entries as lcm messages
  for (std::vector<tictoc_t>::iterator itr = tictoc_stats.begin();
       itr != tictoc_stats.end();
       ++itr) {
    fovis_tictoc_t tictoc_msg;
    tictoc_msg.t = itr->t;
    tictoc_msg.totalT = itr->totalT;
    tictoc_msg.ema = itr->ema;
    tictoc_msg.min = itr->min;
    tictoc_msg.max = itr->max;
    tictoc_msg.numCalls = itr->numCalls;
    tictoc_msg.description = new char[itr->description.size()+1];
    std::copy(itr->description.begin(), itr->description.end(), &tictoc_msg.description[0]);
    tictoc_msg.description[itr->description.size()] = '\0';
    //std::cerr << "tictoc_msg.description = " << tictoc_msg.description << std::endl;
    fovis_tictoc_t_publish(_publish_lcm, _tictoc_channel.c_str(), &tictoc_msg);
    delete tictoc_msg.description;
  }
}

void
StereoOdometry::decode_image(const bot_core_image_t * msg)
{
  // extract image data
  // TODO add support for raw RGB
  switch (msg->pixelformat) {
    case BOT_CORE_IMAGE_T_PIXEL_FORMAT_GRAY:
      // in stereo the two images are simply one above the other, so the pointer for
      // the right image is at the half of the images_buf
      std::copy(msg->data             , msg->data+msg->size/2 , _image_left_buf);
      std::copy(msg->data+msg->size/2 , msg->data+msg->size   , _image_right_buf);
      break;
    case BOT_CORE_IMAGE_T_PIXEL_FORMAT_MJPEG:
      // for some reason msg->row_stride is 0, so we use msg->width instead.
      jpeg_decompress_8u_gray(msg->data,
                              msg->size,
                              _images_buf,
                              msg->width,
                              msg->height,
                              msg->width);
      std::copy(_images_buf           , _images_buf+_buf_size   , _image_left_buf);
      std::copy(_images_buf+_buf_size , _images_buf+2*_buf_size , _image_right_buf);
      break;
    default:
      fprintf(stderr, "Unrecognized image format\n");
      break;
  }
}

void
StereoOdometry::publish_motion_estimation()
{
    
  
  // Pose already has look vector is +X, and up is +Z
  Eigen::Vector3d translation(_local_to_camera.translation());
  Eigen::Quaterniond rotation(_local_to_camera.rotation());

  // Output motion estimate - in CV frame:
  Eigen::Isometry3d motion_estimate = _odom->getMotionEstimate();
  fovis_update_t update_msg;
  update_msg.timestamp = _utime_cur;
  update_msg.prev_timestamp = _utime_prev;
  Eigen::Vector3d motion_T = motion_estimate.translation();
  update_msg.translation[0] = motion_T(0);
  update_msg.translation[1] = motion_T(1);
  update_msg.translation[2] = motion_T(2);
  Eigen::Quaterniond motion_R = Eigen::Quaterniond(motion_estimate.rotation());
  update_msg.rotation[0] = motion_R.w();
  update_msg.rotation[1] = motion_R.x();
  update_msg.rotation[2] = motion_R.y();
  update_msg.rotation[3] = motion_R.z();

  //zero out matrix
  const Eigen::MatrixXd & motion_cov = _odom->getMotionEstimateCov();
  for (int i=0;i<6;i++)
    for (int j=0;j<6;j++)
      update_msg.covariance[i][j] = motion_cov(i,j);

  const MotionEstimator * me = _odom->getMotionEstimator();
  MotionEstimateStatusCode estim_status = _odom->getMotionEstimateStatus();
  switch(estim_status) {
    case NO_DATA:
      break;
    case SUCCESS:
      update_msg.estimate_status = FOVIS_UPDATE_T_ESTIMATE_VALID;
      printf("Inliers: %4d  Rep. fail: %4d Matches: %4d Feats: %4d Mean err: %5.2f\n",
          me->getNumInliers(),
          me->getNumReprojectionFailures(),
          me->getNumMatches(),
          _odom->getTargetFrame()->getNumKeypoints(),
          me->getMeanInlierReprojectionError());
      break;
    case INSUFFICIENT_INLIERS:
      update_msg.estimate_status = FOVIS_UPDATE_T_ESTIMATE_INSUFFICIENT_FEATURES;
      printf("Insufficient inliers\n");
      break;
    case OPTIMIZATION_FAILURE:
      update_msg.estimate_status = FOVIS_UPDATE_T_ESTIMATE_DEGENERATE;
      printf("Unable to solve for rigid body transform\n");
      break;
    case REPROJECTION_ERROR:
      update_msg.estimate_status = FOVIS_UPDATE_T_ESTIMATE_REPROJECTION_ERROR;
      printf("Excessive reprojection error (%f).\n", me->getMeanInlierReprojectionError());
      break;
    default:
      printf("Unknown error (this should never happen)\n");
      break;
  }

  if (estim_status != NO_DATA) {
    // TODO why does this get published to odom channel?
    fovis_update_t_publish(_publish_lcm,
                           _odom_channel.c_str(),
                           &update_msg);
  }

  if (_publish_stats) {
    fovis_stats_t stats_msg;
    stats_msg.timestamp = update_msg.timestamp;
    stats_msg.num_matches = me->getNumMatches();
    stats_msg.num_inliers = me->getNumInliers();
    stats_msg.mean_reprojection_error = me->getMeanInlierReprojectionError();
    stats_msg.num_reprojection_failures = me->getNumReprojectionFailures();

    const OdometryFrame * tf(_odom->getTargetFrame());
    stats_msg.num_detected_keypoints = tf->getNumDetectedKeypoints();
    stats_msg.num_keypoints = tf->getNumKeypoints();
    stats_msg.fast_threshold = _odom->getFastThreshold();

    fovis_stats_t_publish(_publish_lcm, _stats_channel.c_str(), &stats_msg);
  }

  if (_publish_pose) {
    // Convert from camera to head frame:
    // local->head =  local->camera  * camera->head
    Eigen::Isometry3d c2h;
    _bot_frames_cpp->get_trans_with_utime( _bot_frames ,  "head", "CAMERA", _utime_cur, c2h);

    Eigen::Isometry3d l2h = _local_to_camera *c2h;
    Eigen::Vector3d l2h_trans(l2h.translation());
    Eigen::Quaterniond l2h_rot(l2h.rotation());

    // publish local to head pose
    bot_core_pose_t l2h_pose_msg;
    memset(&l2h_pose_msg, 0, sizeof(l2h_pose_msg));
    l2h_pose_msg.utime = _utime_cur;
    l2h_pose_msg.pos[0] = l2h_trans[0];
    l2h_pose_msg.pos[1] = l2h_trans[1];
    l2h_pose_msg.pos[2] = l2h_trans[2];
    l2h_pose_msg.orientation[0] = l2h_rot.w();
    l2h_pose_msg.orientation[1] = l2h_rot.x();
    l2h_pose_msg.orientation[2] = l2h_rot.y();
    l2h_pose_msg.orientation[3] = l2h_rot.z();
    bot_core_pose_t_publish(_publish_lcm, _pose_channel.c_str(),
                            &l2h_pose_msg);    
    
  }

  if (_publish_frame_update) {
    //publish the frame update message as well
    bot_core_rigid_transform_t iso_msg;
    iso_msg.utime = _utime_cur;
    for (int i = 0; i < 3; i++) {
      iso_msg.trans[i] = translation[i];
    }
    iso_msg.quat[0] = rotation.w();
    iso_msg.quat[1] = rotation.x();
    iso_msg.quat[2] = rotation.y();
    iso_msg.quat[3] = rotation.z();
    // TODO why does this get published to frame update channel?
    bot_core_rigid_transform_t_publish(_publish_lcm, _frame_update_channel.c_str(),
                                       &iso_msg);
  }
}



Eigen::Quaterniond imu2robotquat(const microstrain_ins_t *msg){

  Eigen::Quaterniond m(msg->quat[0],msg->quat[1],msg->quat[2],msg->quat[3]);

  Eigen::Isometry3d motion_estimate;
  motion_estimate.setIdentity();
  motion_estimate.translation() << 0,0,0;
  motion_estimate.rotate(m);

  // rotate coordinate frame so that look vector is +X, and up is +Z
  Eigen::Matrix3d M;

  //convert imu on bocelli cane from:
  //x+ right, z+ down, y+ back
  //to x+ forward, y+ left, z+ up (robotics)
  //M <<  0,  -1, 0,
  //    -1, 0, 0,
  //    0, 0, -1;

  //convert imu on drc rig from:
  //x+ back, z+ down, y+ left
  //to x+ forward, y+ left, z+ up (robotics)
  M <<  -1,  0, 0,
      0, 1, 0,
      0, 0, -1;

  motion_estimate= M * motion_estimate;
  Eigen::Vector3d translation(motion_estimate.translation());
  Eigen::Quaterniond rotation(motion_estimate.rotation());
  rotation = rotation * M.transpose();

  Eigen::Isometry3d motion_estimate_out;
  motion_estimate_out.setIdentity();
  motion_estimate_out.translation() << translation[0],translation[1],translation[2];
  motion_estimate_out.rotate(rotation);

  Eigen::Quaterniond r_x(motion_estimate_out.rotation());

  return r_x;
}

void print_Isometry3d(Eigen::Isometry3d pose, std::stringstream &ss){
  Eigen::Vector3d t(pose.translation());
  Eigen::Quaterniond r(pose.rotation());
  ss <<t[0]<<", "<<t[1]<<", "<<t[2]<<" | "
       <<r.w()<<", "<<r.x()<<", "<<r.y()<<", "<<r.z() ;
  //  std::cout << ss.str() << "q\n";

}


void get_descriptors(cv::Mat &image, cv::Mat &descriptors, std::vector<bool> &valid){
  // 1. Extract Descriptors:
  cv::BriefDescriptorExtractor extractor(32); // size of descriptor in bytes

  // Downsample
  cv::Mat image_small;
  cv::resize(image, image_small, cv::Size(60, 60));

  // Compute descriptor

  std::vector<cv::KeyPoint> keypoints;
  keypoints.push_back(cv::KeyPoint(cv::Point2f(30,30), 1.0));
  extractor.compute(image_small, keypoints, descriptors);

  valid.resize(descriptors.size().height);
  std::fill(valid.begin(), valid.end(), true);
}

void features_to_keypoints(const std::vector<ImageFeature> & features, std::vector<cv::KeyPoint> & kpts) {
  kpts.clear();
  for(std::vector<ImageFeature>::const_iterator it=features.begin(); it != features.end(); ++it) {
    const ImageFeature & f = *it;
    // @todo use Mei's true scale here
    //kpts.push_back(cv::KeyPoint(f.uvd(0), f.uvd(1), 1.0));
    kpts.push_back(cv::KeyPoint(f.base_uv(0), f.base_uv(1), 20.0));
  }
}


void StereoOdometry::write_images(){
  //cv::Mat img;

  cout << "images written to file @ " << _utime_cur << "\n";
  stringstream ss;
  ss << _utime_cur;
  Mat img = Mat::zeros(_stereo_params.right_parameters.height,_stereo_params.right_parameters.width,CV_8UC1);
  img.data = _image_left_buf;
  imwrite( (ss.str() + "_left_old.png"), img);

  img.data = _image_right_buf;
  imwrite( (ss.str() + "_right_old.png"), img);
}


void StereoOdometry::write_ref_images(){
  //cout << "images written to file @ " << _ref_utime << "\n";
  stringstream ss;
  char buff[10];
  sprintf(buff,"%0.4d",_output_counter);
  ss << buff << "_" << _ref_utime;
  Mat img = Mat::zeros(_stereo_params.right_parameters.height,_stereo_params.right_parameters.width,CV_8UC1);
  img.data = _image_left_buf_copy;
  imwrite( ( ss.str() + "_left.png"), img);

  Mat imgR = Mat::zeros(_stereo_params.right_parameters.height,_stereo_params.right_parameters.width,CV_8UC1);
  imgR.data = _image_right_buf_copy;
  imwrite( (ss.str() + "_right.png"), imgR);  
}


void StereoOdometry::writeFeatures(std::vector<ImageFeature> features){
  stringstream ss;
  char buff[10];
  sprintf(buff,"%0.4d",_output_counter);
  ss << buff << "_" << _ref_utime;

  std::fstream feat_file;
  string fname = string(  ss.str() + ".feat");
  feat_file.open(  fname.c_str() , std::fstream::out);
//  cout << "nmatches written to file: "<< features.size() << " @ " << _ref_utime << "\n";
  feat_file << "#i,track_id,uv,base_uv,uvd,xyz,xyzw,color\n";
  for (size_t i = 0; i < features.size(); i++) {
    ImageFeature f = features[i];
    ostringstream temp2;
    temp2 << i << ","
        << f.track_id << ","
        << f.uv[0] << "," << f.uv[1] << "," // actual pixel locations of features
        << f.base_uv[0] << "," << f.base_uv[1] << ","
        << f.uvd[0] << "," << f.uvd[1] << "," << f.uvd[2] << ","
        << f.xyz[0] << "," << f.xyz[1] << "," << f.xyz[2] << ","
        << f.xyzw[0] << "," << f.xyzw[1] << "," << f.xyzw[2] << "," << f.xyzw[3] << ","
        << (int) f.color[0] << "," << (int) f.color[1] << "," << (int) f.color[2] << "\n";
    feat_file << temp2.str() ;
  }
  feat_file.close();
}


void StereoOdometry::sendFeaturesAsCollection(std::vector<ImageFeature> features, int vs_id){
  pcl::PointCloud<pcl::PointXYZRGB>::Ptr cloud (new pcl::PointCloud<pcl::PointXYZRGB> ());
  for (size_t i = 0; i < features.size(); i++) {
    ImageFeature f = features[i];
    pcl::PointXYZRGB pt;
    pt.x = f.xyz[0];
    pt.y = f.xyz[1];
    pt.z = f.xyz[2];
    pt.r =0; pt.g =0; pt.b =255.0; // blue
    cloud->points.push_back(pt);
  }
  pc_vis_->ptcld_to_lcm_from_list(vs_id, *cloud, _ref_utime, _ref_utime);
}

void StereoOdometry::sendFeatures(std::vector<ImageFeature> features){
  reg_features_t msg;
  msg.utime = _ref_utime;
  msg.nfeatures=features.size();
  
  reg_feature_t feats[ features.size() ] ;
  for (size_t i = 0; i < features.size(); i++) {
    ImageFeature f = features[i];
    
    feats[i].track_id = f.track_id;
    feats[i].uv[0] = f.uv[0];
    feats[i].uv[1] = f.uv[1];
    feats[i].base_uv[0] = f.base_uv[0];
    feats[i].base_uv[1] = f.base_uv[1];
    feats[i].uvd[0] = f.uvd[0];
    feats[i].uvd[1] = f.uvd[1];
    feats[i].uvd[2] = f.uvd[2];
    feats[i].xyz[0] = f.xyz[0];
    feats[i].xyz[1] = f.xyz[1];
    feats[i].xyz[2] = f.xyz[2];
    feats[i].xyzw[0] = f.xyzw[0];
    feats[i].xyzw[1] = f.xyzw[1];
    feats[i].xyzw[2] = f.xyzw[2];
    feats[i].xyzw[3] = f.xyzw[3];
    // color left out for now
  }
  msg.features = feats;
  reg_features_t_publish(_publish_lcm, "FEATURES", &msg);  
}




void
StereoOdometry::image_handler(const bot_core_image_t *msg)
{
  if (_imu_attitude > 0){
    if (!_imu_init){
      cout << "no imu yet, passing\n";
      return;
    }
  }



  tictoc("image_handler");
  _utime_prev = _utime_cur;
  _utime_cur = msg->utime;

  tictoc("decode_image");
  decode_image(msg);
  tictoc("decode_image");

  tictoc("processFrame");
  _depth_producer->setRightImage(_image_right_buf);
  _odom->processFrame(_image_left_buf, _depth_producer);
  tictoc("processFrame");

  Eigen::Isometry3d delta_cam_to_local = _odom->getMotionEstimate();
  //std::stringstream ss;
  //print_Isometry3d(delta_cam_to_local,ss);
  //std::cout << "delta_cam_to_local: " << ss.str() << "\n";

  _local_to_camera = _local_to_camera*delta_cam_to_local;

  publish_motion_estimation();

  // Send vo pose:
  Isometry3dTime poseT = Isometry3dTime(msg->utime, _local_to_camera);
  pc_vis_->pose_to_lcm_from_list(60000, poseT);
  
  

  int image_width = msg->width;
  int image_height = msg->height/2;
  
  


  ////////////////// Features: ////////////////////////////////////////////
  const fovis::MotionEstimator* motion = _odom->getMotionEstimator();
  int num_matches = motion->getNumMatches();
  const fovis::FeatureMatch* matches = motion->getMatches();

  std::vector<ImageFeature> featuresA;
  std::vector<int> featuresA_indices;

  // This gets features that were matched but not necessarily inliers.
  // TODO also get features that were not even matched, if it helps.
  int feature_index = 0;

  //cout << "num_matches: " << num_matches << "\n";
  for (int i=0; i < num_matches; ++i) {
    const fovis::FeatureMatch & m(matches[i]);
    // @todo move the border removal outside, because it depends on the feature descriptor.
    //       these limits are for the BRIEF descriptor.
    int margin = 30;

    // current frame is  Ref frame and fa/dA
    //RawFrame::ConstPtr raw_ref_frame = ref_frame->raw_frame();

    int width = image_width;// raw_ref_frame->width();
    int height = image_height;//raw_ref_frame->height();
    if (   m.ref_keypoint->base_uv[0] <= margin
        || m.ref_keypoint->base_uv[0] >= (width-margin)
        || m.ref_keypoint->base_uv[1] <= margin
        || m.ref_keypoint->base_uv[1] >= (height-margin)) continue;

    //if (   m.target_keypoint->base_uv[0] <= margin
    //    || m.target_keypoint->base_uv[0] >= (width-margin)
    //    || m.target_keypoint->base_uv[1] <= margin
    //    || m.target_keypoint->base_uv[1] >= (height-margin)) continue;

    ImageFeature fA, fB;
    float dA =m.ref_keypoint->disparity; // compute_disparity_(m.ref_keypoint->disparity);
    //float dB = compute_disparity_(m.target_keypoint->disparity);

    // Workaround for the fovis DepthImage depth source
    // was: if (isnan(dA)) dA = compute_disparity_(m.ref_keypoint->xyz(2));
    if (isnan(dA)) dA = m.ref_keypoint->xyz(2); // stereo disparity is 1-to-1
    //if (isnan(dB)) dB = compute_disparity_(m.target_keypoint->xyz(2));

    //if (1==1){//was
    if(m.inlier){ // if the feature is an inlier - very important distinciton, mfallon
      fA.track_id = fB.track_id = m.track_id;

      /*
      bool use_refined = false;
      if (use_refined && m.status == fovis::MATCH_OK)
      {
        fA.xyz = m.ref_keypoint->xyz;
        fB.xyz = m.refined_target_keypoint.xyz;

        fA.xyzw = m.ref_keypoint->xyzw;
        fB.xyzw = m.refined_target_keypoint.xyzw;

        fA.uv = Eigen::Vector2d(m.ref_keypoint->kp.u, m.ref_keypoint->kp.v);
        fB.uv = Eigen::Vector2d(m.refined_target_keypoint.kp.u, m.refined_target_keypoint.kp.v);

        fA.base_uv = m.ref_keypoint->base_uv;
        fB.base_uv = m.refined_target_keypoint.base_uv;

        fA.uvd = Eigen::Vector3d(m.ref_keypoint->rect_base_uv[0], m.ref_keypoint->rect_base_uv[1], dA);
        fB.uvd = Eigen::Vector3d(m.refined_target_keypoint.rect_base_uv[0], m.refined_target_keypoint.rect_base_uv[1], dB);
      }
      else
      {*/
        fA.xyz = m.ref_keypoint->xyz;
        //fB.xyz = m.target_keypoint->xyz;

        fA.xyzw = m.ref_keypoint->xyzw;
        //fB.xyzw = m.target_keypoint->xyzw;

        fA.uv = Eigen::Vector2d(m.ref_keypoint->kp.u, m.ref_keypoint->kp.v);
        //fB.uv = Eigen::Vector2d(m.target_keypoint->kp.u, m.target_keypoint->kp.v);

        fA.base_uv = m.ref_keypoint->base_uv;
        //fB.base_uv = m.target_keypoint->base_uv;

        fA.uvd = Eigen::Vector3d(m.ref_keypoint->rect_base_uv[0], m.ref_keypoint->rect_base_uv[1], dA);
        //fB.uvd = Eigen::Vector3d(m.target_keypoint->rect_base_uv[0], m.target_keypoint->rect_base_uv[1], dB);
      //}
      featuresA.push_back(fA);
      //featuresB.push_back(fB);

      if (m.inlier) {
        featuresA_indices.push_back(feature_index);
        //frame_match_.featuresB_indices.push_back(feature_index);
      }
      feature_index++;
    }
  }
  ////////////////// Features END ////////////////////////////////////////////




  const fovis::OdometryFrame* ref_odom_frame = _odom->getReferenceFrame();
  const fovis::OdometryFrame* target_odom_frame = _odom->getTargetFrame();

  if (ref_odom_frame == target_odom_frame){
    cout << "different frames\n";
  }

  if (ref_odom_frame == NULL) {
    // The first frame is only set as reference after the second frame has been passed.
    cout << "ref_odom_frame_ null\n";
  }



  int status=0;
  if (ref_odom_frame_ == NULL) {
    // The first frame is only set as reference after the second frame has been passed.
    ref_odom_frame_ = ref_odom_frame;
  } else if (ref_odom_frame != ref_odom_frame_) {
    ref_odom_frame_ = ref_odom_frame;
    //cout << "tracking from " << _utime_prev << " at " << msg->utime <<"\n";
    status=1;

    // Write the images and features
    if (_ref_utime > 0){ // skip the first null image
      if(featuresA.size() > 50){ // if less than 50 features - dont bother writing
        write_ref_images();
        writeFeatures(featuresA);
        sendFeatures(featuresA);
        
        // Send Features paired with the pose at the ref frame:
        sendFeaturesAsCollection(featuresA, 3001); // blue, last 
        sendFeaturesAsCollection(featuresA, 3002); // red, most recent
        Isometry3dTime ref_poseT = Isometry3dTime(_ref_utime, _ref_pose);
        pc_vis_->pose_to_lcm_from_list(3000, ref_poseT);
        
        _output_counter++;
      }
    }
    
  }else {
    //cout << "other\n";  
  }

  
  /*
    pcl::PointCloud<pcl::PointXYZRGB>::Ptr scan_cloud (new pcl::PointCloud<pcl::PointXYZRGB> ());
    for (size_t i = 0; i < featuresA.size(); i++) {
      ImageFeature f = featuresA[i];
      pcl::PointXYZRGB pt;
      pt.x = f.xyz[0];
      pt.y = f.xyz[1];
      pt.z = f.xyz[2];
      if (status==0){
        pt.r = 0; pt.g = 0; pt.b = 255.0; //blue
      }else{ // status 1 when changing key frames:
        pt.r = 255; pt.g = 0; pt.b = 0.0; // red
      }
      scan_cloud->points.push_back(pt);
    }
    pc_vis_->ptcld_to_lcm_from_list(60001, *scan_cloud, msg->utime, msg->utime);  
  */
  

  #ifdef USE_LCMGL
    if(_draw_lcmgl) { _visualization->draw_reg(_odom, featuresA, status); }
  #endif

  /*
  ////////////////// DESCRIPTORS ///////////////////////////////////////////
  Mat image0 = Mat::zeros(480,640,CV_8UC1);
  cout << "blah1\n";
  image0 = imread("/home/mfallon/data/drc/registeration/0/left.png",CV_LOAD_IMAGE_GRAYSCALE);
  //image0.data = msg->data;
  cv::Mat descriptors0;
  std::vector<bool> valid0; // validity of descriptors? not sure for what
  cout << "blah2\n";
  get_descriptors(image0, descriptors0, valid0);

  cout << "num_descriptors: " << descriptors0.size().height << "\n";
  //cout << "also: " << descriptors0->descriptors.rows <<"\n";
  ////////////////// DESCRIPTORS ///////////////////////////////////////////
*/

  

  tictoc("image_handler");
#ifdef USE_LCMGL
  if(_draw_lcmgl) { _visualization->draw(_odom, _utime_cur, _ref_utime); }
#endif


  if (_odom->getChangeReferenceFrames()){
    //cout << "changed Ref frame at: "<< msg->utime<<"\n";
    _ref_utime = msg->utime;
    _ref_pose = _local_to_camera; // publish this pose when the 

   
    // Keep the image buffer to write with the features:
    //write_images(); // dont write them here any longer
    std::copy(_image_left_buf , _image_left_buf+_buf_size   , _image_left_buf_copy);
    std::copy(_image_right_buf , _image_right_buf+_buf_size   , _image_right_buf_copy);
    
    // If this is true, _cur_frame will be _ref_frame
    // on next call of processFrame.
    // TODO better name.
  }

  
}

void
StereoOdometry::imu_handler(const microstrain_ins_t *msg)
{

  if (_imu_attitude >0 ){
    if (!_imu_init){
      Eigen::Quaterniond m = imu2robotquat(msg);
      Eigen::Isometry3d init_pose;
      init_pose.setIdentity();
      init_pose.translation() << 0,0,0;
      init_pose.rotate(m);
      
      // Use head-to-camera as the required transform
      // (Multisense on its own doesnt have an imu frame)
      Eigen::Isometry3d imu2camera;
      _bot_frames_cpp->get_trans_with_utime( _bot_frames ,  "CAMERA", "head", msg->utime, imu2camera);

      _local_to_camera = init_pose *imu2camera;
      _imu_init = true;
      cout << "got first IMU measurement\n";
    }else if(_imu_attitude ==2){
      if (_imu_counter==100){
        // Every 100 frame: replace the pitch and roll with that from the IMU
        // convert the camera pose to body frame
        // extract xyz and yaw from body frame
        // extract pitch and roll from imu (in body frame)
        // combine, convert to camera frame... set as pose

        cout << "\nmore IMU measurements\n";
        std::stringstream ss3;
        print_Isometry3d(_local_to_camera, ss3);
        std::cout << "_local_to_camera: " << ss3.str() << "\n";        
        
        Eigen::Isometry3d cam2head;
        _bot_frames_cpp->get_trans_with_utime( _bot_frames ,  "head", "CAMERA", msg->utime, cam2head);        
        std::stringstream ss;
        print_Isometry3d(cam2head,ss);
        std::cout << "cam2head: " << ss.str() << "\n";        
        
        Eigen::Isometry3d local_to_head = _local_to_camera *cam2head;
        std::stringstream ss2;
        print_Isometry3d(local_to_head, ss2);
        double ypr[3];
        quat_to_euler(  Eigen::Quaterniond(local_to_head.rotation()) , ypr[0], ypr[1], ypr[2]);
        std::cout << "_local_to_head: " << ss2.str() << " | "<< 
          ypr[0]*180/M_PI << " " << ypr[1]*180/M_PI << " " << ypr[2]*180/M_PI << "\n";        

        double xyz[3];
        xyz[0] = local_to_head.translation().x();
        xyz[1] = local_to_head.translation().y();
        xyz[2] = local_to_head.translation().z();
        std::cout << xyz[0] << " " << xyz[1] << " " << xyz[2] << " pose xyz\n";
          
        double ypr_imu[3];
        quat_to_euler( imu2robotquat(msg) , 
                        ypr_imu[0], ypr_imu[1], ypr_imu[2]);
        std::cout <<  ypr_imu[0]*180/M_PI << " " << ypr_imu[1]*180/M_PI << " " << ypr_imu[2]*180/M_PI << " imuypr\n";        
        
        Eigen::Quaterniond revised_local_to_head_quat = euler_to_quat( ypr[0], ypr_imu[1], ypr_imu[2]);             
        Eigen::Isometry3d revised_local_to_head;
        revised_local_to_head.setIdentity();
        revised_local_to_head.translation() = local_to_head.translation();
        revised_local_to_head.rotate(revised_local_to_head_quat);        
        std::stringstream ss4;
        print_Isometry3d(revised_local_to_head, ss4);
        quat_to_euler(  Eigen::Quaterniond(revised_local_to_head.rotation()) , ypr[0], ypr[1], ypr[2]);
        std::cout << "_local_revhead: " << ss4.str() << " | "<< 
          ypr[0]*180/M_PI << " " << ypr[1]*180/M_PI << " " << ypr[2]*180/M_PI << "\n";        
        
        Eigen::Isometry3d revised_local_to_camera = revised_local_to_head *cam2head.inverse();
        std::stringstream ss5;
        print_Isometry3d(revised_local_to_camera,ss5);
        std::cout << "revised_local_to_camera: " << ss5.str() << "\n";        
        _local_to_camera = revised_local_to_camera;
        
      }
      if (_imu_counter > 100) { _imu_counter =0; }
      _imu_counter++;
    }
  }else{
//    cout << "got IMU measurement - not incorporating them\n";
  }


}

void
StereoOdometry::usage(const char* progname)
{
  fprintf(stderr, "Usage: %s [options]\n"
      "\n"
      "Options:\n"
      "  -p, --pose [CHAN]             Publish pose messages on specified channel.\n"
      "  -u, --update-channel [CHAN]   Publish frame updates on specified channel.\n"
      "                                  Default channel is BODY_TO_LOCAL.\n"
      "  -o, --odometry-channel [CHAN] Publish relative odometry messages on specified channel.\n"
      "                                  Default channel is STEREO_REL_ODOMETRY  \n"
      "  -s, --stats-channel [CHAN]    Publish extra statistics on specified channel.\n"
      "                                  Default channel is FOVIS_STATS.\n"
      "  -t, --tictoc-channel [CHAN]   Publish timing info on specified channel.\n"
      "                                  Default channel is FOVIS_TICTOC.\n"
      "  -i, --input-log FILE          Process a log file.\n"
      "  -w, --output-log FILE         Write output directly to a log file.\n"
      "  -c, --camera-file FILE        File with camera calibration information in bot_param format.\n"
      "                                  By default this information is read from bot_param server.\n"
      "  -b, --camera-block [STRING]   Which camera block in the cfg file to use.\n"
      "  -a, --param-file FILE         File with VO parameters in bot_param format. May be same file\n"
      "                                  as camera file.\n"
#ifdef USE_LCMGL
      "  -l, --lcmgl                   Render debugging information with LCMGL\n"
#endif
      "  -m, --mode                    IMU integration mode\n",
      "  -h, --help                    Shows this help text and exits\n",
      progname);
}

int
StereoOdometry::parse_command_line_options(int argc, char **argv) {
  // TODO parse options
  const char *optstring = "hp::u::s::t::o::i:w:c:b:a:l:m:";
  int c;
  struct option long_opts[] = {
    { "help", no_argument, 0, 'h' },
    { "pose", optional_argument, 0, 'p' },
    { "update-channel", optional_argument, 0, 'u' },
    { "odometry-channel", required_argument, 0, 'o' },
    { "stats-channel", required_argument, 0, 's' },
    { "tictoc-channel", required_argument, 0, 't' },
    { "input-log", required_argument, 0, 'i' },
    { "output-log", required_argument, 0, 'w'},
    { "camera-file", required_argument, 0, 'c' },
    { "camera-block", required_argument, 0, 'b' },
    { "param-file", required_argument, 0, 'a'},
    { "lcmgl", no_argument, 0, 'l' },
    { "mode", required_argument, 0, 'm' },
    {0, 0, 0, 0}
  };

  while ((c = getopt_long(argc, argv, optstring, long_opts, 0)) >= 0) {
    switch(c) {
      case 'p':
        _publish_pose = true;
        if(optarg)
          _pose_channel = optarg;
        break;
      case 'u':
        _publish_frame_update = true;
        if (optarg)
          _frame_update_channel = optarg;
        break;
      case 'o':
        _publish_odometry = true;
        if (optarg)
          _odom_channel = optarg;
        break;
      case 'i':
        _input_log_fname = optarg;
        break;
      case 'w':
        _output_log_fname = optarg;
        break;
      case 'c':
        _camera_parameters_fname = optarg;
        break;
      case 'b':
        _camera_block = optarg; // mfallon
        break;
      case 'a':
        _vo_parameters_fname = optarg;
        break;
      case 's':
        _publish_stats = true;
        if (optarg)
          _stats_channel = optarg;
        break;
      case 't':
        _publish_tictoc = true;
        if (optarg)
          _tictoc_channel = optarg;
        break;
#if USE_LCMGL
      case 'l':
        _draw_lcmgl = true;
        break;
#endif
      case 'm':
        _imu_attitude = atoi(optarg);
        break;
      case 'h':
      default:
        usage(argv[0]);
        return 1;
    }
  }
  return 0;
}

StereoOdometry::StereoOdometry() :
    _publish_lcm(NULL),
    _subscribe_lcm(NULL),
    _bot_param_lcm(NULL),
    _odom_channel("STEREO_REL_ODOMETRY"),
    _pose_channel("POSE_HEAD"),
    _frame_update_channel("BODY_TO_LOCAL"),
    _stats_channel("FOVIS_STATS"),
    _tictoc_channel("FOVIS_TICTOC"),
    _bot_param(NULL),
    _odom(NULL),
    _depth_producer(NULL),
    _publish_pose(false),
    _publish_odometry(false),
    _publish_frame_update(false),
    _publish_stats(false),
    _publish_tictoc(false),
    _imu_attitude(0), // mfallon
    _imu_counter(0),
    _utime_cur(0),
    _utime_prev(0),
    _ref_utime(0), //mfallon
    _output_counter(0), // mfallon
    _image_left_buf(NULL),
    _image_right_buf(NULL),
    _images_buf(NULL),
    _buf_size(0)
{
#ifdef USE_LCMGL
  _draw_lcmgl = false;
  _visualization = NULL;
#endif
}

int
StereoOdometry::init_lcm()
{
  // four cases on whether we are using logfiles for input and output.
  // TODO better error checking
  std::string in_url = std::string("file://") + _input_log_fname + "?speed=0";
  std::string out_url = std::string("file://") + _output_log_fname + "?mode=w";
  if (_input_log_fname.size() &&
      _output_log_fname.size()) {
    // both.
    // avoid getting bot_param from lcm handles on logfiles.
    _subscribe_lcm = lcm_create(in_url.c_str());
    _publish_lcm = lcm_create(out_url.c_str());
    _bot_param_lcm = lcm_create(NULL);
  } else if (_input_log_fname.size()) {
    // only input.
    _subscribe_lcm = lcm_create(in_url.c_str());
    _publish_lcm = lcm_create(NULL);
    _bot_param_lcm = _publish_lcm;
  } else if (_output_log_fname.size()) {
    // only output.
    _subscribe_lcm = lcm_create(NULL);
    _publish_lcm = lcm_create(out_url.c_str());
    _bot_param_lcm = _subscribe_lcm;
  } else {
    // neither.
    _subscribe_lcm = lcm_create(NULL);
    _publish_lcm = _subscribe_lcm;
    _bot_param_lcm = _subscribe_lcm;
  }
  if (_subscribe_lcm==NULL ||
      _publish_lcm==NULL ||
      _bot_param_lcm==NULL) {
    fprintf(stderr, "LCM initialization failed.\n");
    return 1;
  }
  return 0;
}

int
StereoOdometry::initialize(int argc, char **argv)
{
  if (parse_command_line_options(argc, argv)) { return 1; }

  VisualOdometryOptions vo_opts = StereoOdometry::getDefaultOptions();

  if (init_lcm()) { return 1; }

  if (_camera_parameters_fname.size()) {
    _bot_param = bot_param_new_from_file(_camera_parameters_fname.c_str());
    if (_bot_param == NULL) {
      fprintf(stderr, "Couldn't get bot param from file %s\n",
              _camera_parameters_fname.c_str());
      return 1;
    }
  } else {
    _bot_param = bot_param_new_from_server(_bot_param_lcm, 0);
    if (_bot_param == NULL) {
      fprintf(stderr, "Couldn't get bot param from server.\n");
      return 1;
    }
  }

  std::string calib_block = "cameras." + _camera_block; //added mfallon
  if (init_calibration(calib_block.c_str())) { return 1; }

  // TODO at some point publish camera calib on lcm
  // TODO integrate camera parameter reading and bot param reading in a sane
  // way.
  if (_vo_parameters_fname.size()) {
    BotParam * vo_bot_param = bot_param_new_from_file(_vo_parameters_fname.c_str());
    if (vo_bot_param == NULL) {
      fprintf(stderr, "Couldn't get bot param from file %s",
          _camera_parameters_fname.c_str());
      return 1;
    }

    fprintf(stderr, "VO options from file:\n");
    for (VisualOdometryOptions::iterator itr = vo_opts.begin();
         itr != vo_opts.end();
         ++itr) {
      std::string key(itr->first);
      std::replace(key.begin(), key.end(), '-', '_');
      char * new_val = bot_param_get_str_or_fail(vo_bot_param,
                                                 ("VisualOdometryOptions."+key).c_str());
      itr->second = new_val;
      free(new_val);
      fprintf(stderr, "%s : %s\n", itr->first.c_str(), itr->second.c_str());
    }
    fprintf(stderr, "\n");
  }

  // Note VisualOdometry is borrowing the rectification pointer
  StereoCalibration *calib = new StereoCalibration(_stereo_params);
  _odom = new VisualOdometry(calib->getLeftRectification(), vo_opts);
  _depth_producer = new StereoDepth(calib, vo_opts);

#ifdef USE_LCMGL
  // use bot_param_lcm because it doesn't come from logfile
  bot_lcmgl_t* lcmgl = bot_lcmgl_init(_bot_param_lcm, "stereo-odometry");
  _visualization = new Visualization(lcmgl, calib);
#endif

  // init buffers
  _buf_size = _stereo_params.left_parameters.width*_stereo_params.left_parameters.height;
  _image_left_buf = new uint8_t[_buf_size];
  _image_right_buf = new uint8_t[_buf_size];
  _images_buf = new uint8_t[2*_buf_size];
  
  // mfallon - copy of ref image:
  _image_left_buf_copy = new uint8_t[_buf_size];
  _image_right_buf_copy = new uint8_t[_buf_size];


  // catch signals
  struct sigaction new_action;
  new_action.sa_sigaction = sig_handler_aux;
  sigemptyset(&new_action.sa_mask);
  new_action.sa_flags = 0;
  sigaction(SIGINT, &new_action, NULL);
  sigaction(SIGTERM, &new_action, NULL);
  sigaction(SIGHUP, &new_action, NULL);

  // subscribe to image events
  //std::string image_channel(bot_param_get_camera_lcm_channel(_bot_param, "stereo")); 
  std::string image_channel(bot_param_get_camera_lcm_channel(_bot_param, _camera_block.c_str())); // added mfallon
  bot_core_image_t_subscribe(_subscribe_lcm, image_channel.c_str(),
                             StereoOdometry::image_handler_aux, this);

  _bot_frames= bot_frames_get_global(_publish_lcm, _bot_param);
  
  /// IMU:
  microstrain_ins_t_subscribe(_subscribe_lcm, "MICROSTRAIN_INS",
                             StereoOdometry::imu_handler_aux, this);
  _local_to_camera.setIdentity();

// Apply in initial local-to-camera pose transform
  Eigen::Matrix3d m;
  m = Eigen::AngleAxisd ( 0*M_PI/180 , Eigen::Vector3d::UnitZ ())
    * Eigen::AngleAxisd ( 180*M_PI/180 , Eigen::Vector3d::UnitY ())
    * Eigen::AngleAxisd ( 90*M_PI/180  , Eigen::Vector3d::UnitX ());
  _local_to_camera.setIdentity ();
  _local_to_camera *= m;
  
  _local_to_camera.translation().x() =10;
  
  
  // Vis Config:
  // mfallon:
  pc_vis_ = new pointcloud_vis(_publish_lcm);
  float colors_r[] ={1.0,0.0,0.0};
  vector <float> colors_v_r;
  colors_v_r.assign(colors_r,colors_r+4*sizeof(float));
  float colors_b[] ={0.0,0.0,1.0};
  vector <float> colors_v_b;
  colors_v_b.assign(colors_b,colors_b+4*sizeof(float));
  int reset =0;
  // obj: id name type reset
  // pts: id name type reset objcoll usergb rgb
  pc_vis_->obj_cfg_list.push_back( obj_cfg(3000,"Pose - Feats",5,reset) );
  pc_vis_->ptcld_cfg_list.push_back( ptcld_cfg(3001,"Feats - Current",1,1, 3000,1,colors_v_r));
  pc_vis_->ptcld_cfg_list.push_back( ptcld_cfg(3002,"Feats - All",1,reset, 3000,1,colors_v_b));
  
  pc_vis_->obj_cfg_list.push_back( obj_cfg(60000,"Pose - All",5,0) );
  //pc_vis_->ptcld_cfg_list.push_back( ptcld_cfg(60001,"Cloud - Laser"         ,1,0, 60000,0, colors_v ));
  
  
  return 0;
}

StereoOdometry::~StereoOdometry()
{
  delete[] _image_left_buf;
  delete[] _image_right_buf;
  delete[] _images_buf;

  // mfallon:
  delete[] _image_left_buf_copy;
  delete[] _image_right_buf_copy;

  delete _depth_producer;
  delete _odom;
  delete _visualization;

  if (_subscribe_lcm) {
    lcm_destroy(_subscribe_lcm);
  }
  if (_publish_lcm && (_publish_lcm != _subscribe_lcm)) {
    lcm_destroy(_publish_lcm);
  }
  // avoid double destruction. A case for smart pointers?
  if (_bot_param_lcm &&
      (_bot_param_lcm != _subscribe_lcm) &&
      (_bot_param_lcm != _publish_lcm)) {
    lcm_destroy(_bot_param_lcm);
  }
  // TODO delete bot param if it is from file
}

VisualOdometryOptions
StereoOdometry::getDefaultOptions()
{
  VisualOdometryOptions vo_opts = VisualOdometry::getDefaultOptions();

  // change to stereo 'defaults'
  vo_opts["use-adaptive-threshold"] = "false"; // hordur: use now not very useful - adds noisy features
  vo_opts["fast-threshold"] = "15";
  // hordur: use not and set fast-threshold as 10-15

  // options if uat is true
  vo_opts["feature-window-size"] = "9";
  vo_opts["max-pyramid-level"] = "3";
  vo_opts["min-pyramid-level"] = "0";
  vo_opts["target-pixels-per-feature"] = "250"; 
  //width*height/250 = target number of features for fast detector
  // - related to fast-threshold-adaptive-gain
  // 640x480 pr2 ---> 307200/tppf = nfeatures = 400 (typically for pr2)
  // 1024x620 (1088)> 634880/tppf = nfeatures
  vo_opts["fast-threshold-adaptive-gain"] = "0.002";
  vo_opts["use-homography-initialization"] = "true";
  vo_opts["ref-frame-change-threshold"] = "100"; // hordur: lowering this is a good idea. down to 100 is good. results in tracking to poses much further appart


  // OdometryFrame
  vo_opts["use-bucketing"] = "true"; // dependent on resolution: bucketing of features. might want to increase this...
  vo_opts["bucket-width"] = "50";
  vo_opts["bucket-height"] = "50";
  vo_opts["max-keypoints-per-bucket"] = "10";
  vo_opts["use-image-normalization"] = "true"; //hordur: not of major importance, can turn off, extra computation

  // MotionEstimator
  vo_opts["inlier-max-reprojection-error"] = "1.0"; // putting this down to 1.0 is good - give better alignment
  vo_opts["clique-inlier-threshold"] = "0.1";
  vo_opts["min-features-for-estimate"] = "10";
  vo_opts["max-mean-reprojection-error"] = "8.0";
  vo_opts["use-subpixel-refinement"] = "true"; // hordur: v.important to use
  vo_opts["feature-search-window"] = "25"; // for rapid motion this should be higher - size of area to search for new features
  vo_opts["update-target-features-with-refined"] = "false";

  // StereoDepth
  vo_opts["stereo-require-mutual-match"] = "true";
  vo_opts["stereo-max-dist-epipolar-line"] = "2.0";
  vo_opts["stereo-max-refinement-displacement"] = "2.0";
  vo_opts["stereo-max-disparity"] = "128";


/* Original:

  // change to stereo 'defaults'
  vo_opts["use-adaptive-threshold"] = "true"; // hordur: use now not very useful - adds noisy features
  vo_opts["fast-threshold"] = "10";
  // hordur: use not and set fast-threshold as 10-15

  // options if uat is true
  vo_opts["feature-window-size"] = "9";
  vo_opts["max-pyramid-level"] = "3";
  vo_opts["min-pyramid-level"] = "0";
  vo_opts["target-pixels-per-feature"] = "250"; 
  //width*height/250 = target number of features for fast detector
  // - related to fast-threshold-adaptive-gain
  // 640x480 pr2 ---> 307200/tppf = nfeatures = 400 (typically for pr2)
  // 1024x620 (1088)> 634880/tppf = nfeatures
  vo_opts["fast-threshold-adaptive-gain"] = "0.002";
  vo_opts["use-homography-initialization"] = "true";
  vo_opts["ref-frame-change-threshold"] = "150"; // hordur: lowering this is a good idea. down to 100 is good. results in tracking to poses much further appart


  // OdometryFrame
  vo_opts["use-bucketing"] = "true"; // dependent on resolution: bucketing of features. might want to increase this...
  vo_opts["bucket-width"] = "50";
  vo_opts["bucket-height"] = "50";
  vo_opts["max-keypoints-per-bucket"] = "10";
  vo_opts["use-image-normalization"] = "true"; //hordur: not of major importance, can turn off, extra computation

  // MotionEstimator
  vo_opts["inlier-max-reprojection-error"] = "2.0"; // putting this down to 1.0 is good - give better alignment
  vo_opts["clique-inlier-threshold"] = "0.1";
  vo_opts["min-features-for-estimate"] = "10";
  vo_opts["max-mean-reprojection-error"] = "8.0";
  vo_opts["use-subpixel-refinement"] = "true"; // hordur: v.important to use
  vo_opts["feature-search-window"] = "25"; // for rapid motion this should be higher - size of area to search for new features
  vo_opts["update-target-features-with-refined"] = "false";

  // StereoDepth
  vo_opts["stereo-require-mutual-match"] = "true";
  vo_opts["stereo-max-dist-epipolar-line"] = "2.0";
  vo_opts["stereo-max-refinement-displacement"] = "2.0";
  vo_opts["stereo-max-disparity"] = "128";
*/

  return vo_opts;
}

}
