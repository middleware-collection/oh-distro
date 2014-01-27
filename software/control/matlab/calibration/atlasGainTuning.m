function atlasGainTuning
%NOTEST

% simple function for tuning position and torque control gains joint-by-joint

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


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% SET JOINT PARAMETERS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
joint = 'r_leg_hpz';% <---- joint name 
input_mode = 'position';% <---- force, position
control_mode = 'force';% <---- force, position
signal = 'chirp';% <----  zoh, foh, chirp

% INPUT SIGNAL PARAMS %%%%%%%%%%%%%
T = 30;% <--- signal duration (sec)

% chirp specific
amp = 2;% <----  Nm or radians
chirp_f0 = 0.25;% <--- chirp starting frequency
chirp_fT = 1.00;% <--- chirp ending frequency
chirp_sign = 0;% <--- -1: below offset, 1: above offset, 0: centered about offset 

% z/foh
vals = 20*[0 1 1 -1 -1 0 0];% <----  Nm or radians
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


if strcmp(signal, 'chirp')
  ts = linspace(0,T,800);
  freq = linspace(chirp_f0,chirp_fT,800);
else
  ts = linspace(0,T,length(vals));
end

% load robot model
options.floating = true;
r = Atlas(strcat(getenv('DRC_PATH'),'/models/mit_gazebo_models/mit_robot_drake/model_minimal_contact_point_hands.urdf'),options);

% load fixed-base model
options.floating = false;
r_fixed = RigidBodyManipulator(strcat(getenv('DRC_PATH'),'/models/mit_gazebo_models/mit_robot_drake/model_minimal_contact_point_hands.urdf'));
fixed_joint_idx = find(strcmp(r_fixed.getStateFrame.coordinates,joint));

% setup frames
state_frame = getStateFrame(r);
state_frame.subscribe('EST_ROBOT_STATE');
input_frame = getInputFrame(r);
ref_frame = AtlasPosTorqueRef(r);

nq = getNumDOF(r);
nu = getNumInputs(r);

joint_index_map = cell2struct(num2cell(1:nq),state_frame.coordinates(1:nq),2);

act_idx = getActuatedJoints(r);

% check value ranges --- TODO: should be joint specific
if ~exist('vals','var')
  vals=amp;
end
if strcmp(control_mode,'force')
  rangecheck(vals,-200,200);
  if ~rangecheck(vals,-50,50)
    resp = input('Warning: about to command relatively high torque. OK? (y/n): ','s');
    if ~strcmp(resp,{'y','yes'})
      return;
    end
  end
elseif strcmp(control_mode,'position')  
  rangecheck(vals,-3.2,3.2);
  if ~rangecheck(vals,-1,1)
    resp = input('Warning: about to command relatively large position change. OK? (y/n): ','s');
    if ~strcmp(resp,{'y','yes'})
      return;
    end
  end
end

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
[qdes,motion_sign] = getAtlasJointMotionConfig(r,joint_name);

% move to desired pos
atlasLinearMoveToPos(qdes,state_frame,ref_frame,act_idx,3);

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

vals = motion_sign * vals;
if strcmp(input_mode,'position')
  offset = qdes(joint_index_map.(joint));
  vals = offset + vals;  
end
if strcmp(signal,'zoh')
  input_traj = PPTrajectory(zoh(ts,vals));
elseif strcmp(signal,'foh')
  input_traj = PPTrajectory(foh(ts,vals));
elseif strcmp(signal,'chirp')
  if strcmp(input_mode,'force')
    offset = 0;
  end
  if chirp_sign==0
  	input_traj = PPTrajectory(foh(ts, offset + amp*sin(ts.*freq*2*pi)));
  else
    input_traj = PPTrajectory(foh(ts, offset + chirp_sign*motion_sign*(0.5*amp - 0.5*amp*cos(ts.*freq*2*pi))));
  end
else
  error('unknown signal');
end

qdes=qdes(act_idx); % convert to input frame
toffset = -1;
tt=-1;
while tt<T
  [x,t] = getNextMessage(state_frame,1);
  if ~isempty(x)
    if toffset==-1
      toffset=t;
    end
    tt=t-toffset;
    if strcmp(input_mode,'force')
      udes(act_idx==joint_index_map.(joint)) = input_traj.eval(tt);
    elseif strcmp(input_mode,'position')
      qdes(act_idx==joint_index_map.(joint)) = input_traj.eval(tt);
    end
    ref_frame.publish(t,[qdes;udes],'ATLAS_COMMAND');
  end
end

end
