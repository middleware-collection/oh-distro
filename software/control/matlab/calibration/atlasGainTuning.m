function atlasGainTuning
%NOTEST

% simple function for tuning position and torque control gains
% joint-by-joint

% gain spec: 
% q, qd, f are sensed position, velocity, torque, from AtlasJointState
%
% q_d, qd_d, f_d are desired position, velocity, torque, from
% AtlasJointDesired
%
% The final joint command will be:
%
%  k_q_p   * ( q_d - q ) +
%  k_q_i   * 1/s * ( q_d - q ) +
%  k_qd_p  * ( qd_d - qd ) +
%  k_f_p   * ( f_d - f ) +
%  ff_qd   * qd +
%  ff_qd_d * qd_d +
%  ff_f_d  * f_d +
%  ff_const


% load robot model
options.floating = true;
r = Atlas(strcat(getenv('DRC_PATH'),'/models/mit_gazebo_models/mit_robot_drake/model_minimal_contact_point_hands.urdf'),options);

% setup frames
state_frame = getStateFrame(r);
state_frame.subscribe('EST_ROBOT_STATE');
input_frame = getInputFrame(r);
ref_frame = AtlasPosTorqueRef(r);

nu = getNumInputs(r);
nq = getNumDOF(r);

joint_index_map = struct(); % maps joint names to indices
joint_offset_map = struct(); % maps joint names to nominal angle offsets
joint_sign_map = struct(); % maps joint names to signs in the direction of desired motion
for i=1:nq
  joint_index_map.(state_frame.coordinates{i}) = i;
  joint_offset_map.(state_frame.coordinates{i}) = 0;
  joint_sign_map.(state_frame.coordinates{i}) = 1;
end

act_idx = getActuatedJoints(r);

gains = getAtlasGains(input_frame); 


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% SET JOINT PARAMETERS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
joint = 'back_bky';% <---- 
control_mode = 'position';% <----  force, position
signal = 'foh';% <----  zoh, foh, chirp

% GAINS %%%%%%%%%%%%%%%%%%%%%
ff_const = gains.ff_const(act_idx==joint_index_map.(joint));% -0.16;% <----
if strcmp(control_mode,'force')
  % force gains: only have an effect if control_mode==force
  k_f_p = gains.k_f_p(act_idx==joint_index_map.(joint));%0.125;% <----
  ff_f_d = gains.ff_f_d(act_idx==joint_index_map.(joint));%0.01;% <----
  ff_qd = gains.ff_qd(act_idx==joint_index_map.(joint));% <----
elseif strcmp(control_mode,'position')  
  % position gains: only have an effect if control_mode==position
  k_q_p = gains.k_q_p(act_idx==joint_index_map.(joint));%0.125;% <----
  k_q_i = gains.k_q_i(act_idx==joint_index_map.(joint));%0.01;% <----
  k_qd_p = gains.k_qd_p(act_idx==joint_index_map.(joint));% <----
else
  error('unknown control mode');
end

% SIGNAL PARAMS %%%%%%%%%%%%%
if strcmp( signal, 'chirp' )
  zero_crossing = true;
  ts = linspace(0,40,800);% <----
  amp = 0.3;% <----  Nm or radians
  freq = linspace(0.04,0.2,800);% <----  cycles per second
else
%   vals = 1.6*[0 1 1 .5 .5 0 0];% <----  Nm or radians
  vals = 0.4*[0 1 1 -1 -1 0 0];% <----  Nm or radians
  ts = linspace(0,15,length(vals));% <----
end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
T=ts(end);

% check gain ranges --- TODO: make this more conservative
rangecheck(ff_const,-10,10);
if strcmp(control_mode,'force')
%   rangecheck(k_f_p,0,1);
%   rangecheck(ff_f_d,0,1);
%   rangecheck(ff_qd,0,1.5);
elseif strcmp(control_mode,'position')  
  rangecheck(k_q_p,0,60);
  rangecheck(k_q_i,0,0.5);
  rangecheck(k_qd_p,0,60);
end

% check value ranges --- TODO: should be joint specific
if ~exist('vals','var')
  vals=amp;
end
if strcmp(control_mode,'force')
%   rangecheck(vals,-70,70);
%   if ~rangecheck(vals,-50,50)
%     disp('Warning: about to command relatively high torque. Shift+F5 to cancel.');
%     keyboard;
%   end
elseif strcmp(control_mode,'position')  
  rangecheck(vals,-pi,pi);
  if ~rangecheck(vals,-1,1)
    disp('Warning: about to command relatively large position change. Shift+F5 to cancel.');
    keyboard;
  end
end

% set nonzero offsets
joint_offset_map.l_arm_shx = -1.45;
joint_offset_map.l_arm_ely = 1.57;
joint_offset_map.r_arm_ely = 1.57;
joint_offset_map.l_leg_kny = 1.57;
joint_offset_map.r_leg_kny = 1.57;

joint_offset_map.l_arm_uwy = 1.57;
joint_offset_map.r_arm_uwy = 1.57;
joint_offset_map.l_arm_elx = 1.57;
joint_offset_map.r_arm_elx = -1.57;
joint_offset_map.r_arm_shx = 1.45;

% set negative joints
joint_sign_map.l_arm_ely = -1;
joint_sign_map.l_arm_usy = -1;
joint_sign_map.r_arm_usy = -1;
joint_sign_map.r_arm_shx = -1;
joint_sign_map.r_arm_ely = -1;
joint_sign_map.r_arm_elx = -1;
joint_sign_map.r_arm_mwx = -1;

joint_sign_map.l_leg_hpy = -1;
joint_sign_map.r_leg_hpy = -1;

joint_sign_map.r_leg_hpx = -1;
joint_sign_map.r_leg_hpz = -1;

if ~isfield(joint_index_map,joint)
  error ('unknown joint name');
end

gains = getAtlasGains(input_frame); 

% zero out force gains to start --- move to nominal joint position
gains.k_f_p = zeros(nu,1);
gains.ff_f_d = zeros(nu,1);
gains.ff_qd = zeros(nu,1);
ref_frame.updateGains(gains);

% setup desired pose based on joint being tuned
qdes = zeros(nq,1);

if strcmp(joint,'l_leg_hpy') 
  
  qdes(joint_index_map.r_arm_shx) = 1.25;
  qdes(joint_index_map.l_arm_shx) = -1.25;
%   qdes(joint_index_map.r_leg_hpx) = -0.25;

elseif strcmp(joint,'r_leg_hpy') 

  qdes(joint_index_map.r_arm_shx) = 1.25;
  qdes(joint_index_map.l_arm_shx) = -1.25;
%   qdes(joint_index_map.l_leg_hpx) = 0.25;

elseif strcmp(joint,'l_leg_hpz') 

  qdes(joint_index_map.r_arm_shx) = 1.25;
  qdes(joint_index_map.l_arm_shx) = -1.25;
%   qdes(joint_index_map.r_arm_shx) = 1.0;
%   qdes(joint_index_map.l_arm_shx) = -1.0;
%   qdes(joint_index_map.r_leg_hpx) = -0.4;
%   qdes(joint_index_map.l_leg_kny) = 1.57;

elseif strcmp(joint,'r_leg_hpz') 

  qdes(joint_index_map.r_arm_shx) = 1.25;
  qdes(joint_index_map.l_arm_shx) = -1.25;
%   qdes(joint_index_map.r_arm_shx) = 1.0;
%   qdes(joint_index_map.l_arm_shx) = -1.0;
%   qdes(joint_index_map.l_leg_hpx) = 0.4;
%   qdes(joint_index_map.r_leg_kny) = 1.57;

elseif strcmp(joint,'l_leg_hpx') 

  qdes(joint_index_map.r_arm_shx) = 0.7;
  qdes(joint_index_map.l_arm_shx) = -0.7;
  qdes(joint_index_map.r_leg_hpx) = -0.5;

elseif strcmp(joint,'r_leg_hpx') 

  qdes(joint_index_map.r_arm_shx) = 0.7;
  qdes(joint_index_map.l_arm_shx) = -0.7;
  qdes(joint_index_map.l_leg_hpx) = 0.5;

elseif strcmp(joint,'r_leg_kny') 

  qdes(joint_index_map.r_arm_shx) = 1.0;
  qdes(joint_index_map.l_arm_shx) = -1.0;
  qdes(joint_index_map.r_leg_hpy) = -pi/2;
  qdes(joint_index_map.r_leg_kny) = pi/2;  

elseif strcmp(joint,'l_arm_usy') || strcmp(joint,'r_arm_usy') || ...
    strcmp(joint,'l_arm_shx') || strcmp(joint,'r_arm_shx') 
  
  qdes(joint_index_map.r_arm_shx) = 1.45;
  qdes(joint_index_map.l_arm_shx) = -1.45;

  qdes(joint_index_map.l_arm_uwy) = 1.57;
  qdes(joint_index_map.r_arm_uwy) = 1.57;

  qdes(joint_index_map.r_arm_ely) = joint_offset_map.r_arm_ely;
  qdes(joint_index_map.l_arm_ely) = joint_offset_map.l_arm_ely;

elseif strcmp(joint,'l_arm_ely') || strcmp(joint,'l_arm_mwx') || strcmp(joint,'l_arm_elx')
  
  qdes(joint_index_map.r_arm_shx) = 1.45;
  qdes(joint_index_map.l_arm_elx) = 1.57;
  qdes(joint_index_map.l_arm_ely) = 3.14;

elseif strcmp(joint,'r_arm_ely') || strcmp(joint,'r_arm_mwx') || strcmp(joint,'r_arm_elx')
  
  qdes(joint_index_map.l_arm_shx) = -1.45;
  qdes(joint_index_map.r_arm_elx) = -1.57;
%   qdes(joint_index_map.r_arm_uwy) = 1.57;
  qdes(joint_index_map.r_arm_ely) = 3.14;

elseif strcmp(joint,'r_arm_uwy')
  
  qdes(joint_index_map.l_arm_shx) = -1.45;
  qdes(joint_index_map.r_arm_ely) = 1.57;
  qdes(joint_index_map.r_arm_elx) = -1.57;
  qdes(joint_index_map.r_arm_uwy) = 1.57;
  qdes(joint_index_map.r_arm_mwx) = 1.15;
  
elseif strcmp(joint,'l_arm_uwy')
  
  qdes(joint_index_map.r_arm_shx) = 1.45;
  qdes(joint_index_map.l_arm_ely) = 1.57;
  qdes(joint_index_map.l_arm_elx) = 1.57;
  qdes(joint_index_map.l_arm_uwy) = 1.57;
  qdes(joint_index_map.l_arm_mwx) = -1.15;
  
elseif strcmp(joint,'back_bkx') || strcmp(joint,'back_bky') || strcmp(joint,'back_bkz')  
  qdes(joint_index_map.r_arm_shx) = 0.7;
  qdes(joint_index_map.l_arm_shx) = -0.7;
  
else
  error ('that joint isnt supported yet');
end

qdes(joint_index_map.(joint)) = joint_offset_map.(joint);

% move to desired pos
atlasLinearMoveToPos(qdes,state_frame,ref_frame,act_idx,3);

disp('Ready to send input signal.');
%keyboard;

% set gains to user specified values
gains.ff_const(act_idx==joint_index_map.(joint)) = ff_const;
if strcmp(control_mode,'force')
  % set force gains
  gains.k_f_p(act_idx==joint_index_map.(joint)) = k_f_p; 
  gains.ff_f_d(act_idx==joint_index_map.(joint)) = ff_f_d;
  gains.ff_qd(act_idx==joint_index_map.(joint)) = ff_qd;
  % set joint position gains to 0
  gains.k_q_p(act_idx==joint_index_map.(joint)) = 0;
  gains.k_q_i(act_idx==joint_index_map.(joint)) = 0;
  gains.k_qd_p(act_idx==joint_index_map.(joint)) = 0;
elseif strcmp(control_mode,'position')  
  % set force gains to 0
  gains.k_f_p(act_idx==joint_index_map.(joint)) = 0; 
  gains.ff_f_d(act_idx==joint_index_map.(joint)) = 0;
  gains.ff_qd(act_idx==joint_index_map.(joint)) = 0;
  % set joint position gains 
  gains.k_q_p(act_idx==joint_index_map.(joint)) = k_q_p;
  gains.k_q_i(act_idx==joint_index_map.(joint)) = k_q_i;
  gains.k_qd_p(act_idx==joint_index_map.(joint)) = k_qd_p;
else
  error('unknown control mode');
end 

ref_frame.updateGains(gains);
udes = zeros(nu,1);

vals = joint_sign_map.(joint) * vals;
if strcmp(control_mode,'position')
  vals = joint_offset_map.(joint) + vals;
end
if strcmp(signal,'zoh')
  input_traj = PPTrajectory(zoh(ts,vals));
elseif strcmp(signal,'foh')
  input_traj = PPTrajectory(foh(ts,vals));
elseif strcmp(signal,'chirp')
  offset = 0;
  if strcmp(control_mode,'position')
    offset=joint_offset_map.(joint);
  end
  if zero_crossing
  	input_traj = PPTrajectory(foh(ts, offset + amp*sin(ts.*freq*2*pi)));
  else
    input_traj = PPTrajectory(foh(ts, offset + joint_sign_map.(joint)*(0.5*amp - 0.5*amp*cos(ts.*freq*2*pi))));
  end
else
  error('unknown signal');
end

qdes=qdes(act_idx);
toffset = -1;
tt=-1;
while tt<T
  [x,t] = getNextMessage(state_frame,1);
  if ~isempty(x)
    if toffset==-1
      toffset=t;
    end
    tt=t-toffset;
    if strcmp(control_mode,'force')
      udes(act_idx==joint_index_map.(joint)) = input_traj.eval(tt);
    elseif strcmp(control_mode,'position')
      qdes(act_idx==joint_index_map.(joint)) = input_traj.eval(tt);
    end
    ref_frame.publish(t,[qdes;udes],'ATLAS_COMMAND');
  end
end

end