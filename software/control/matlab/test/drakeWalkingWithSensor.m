function drakeWalking(use_mex,use_ik,use_bullet,use_angular_momentum,random_navgoal)
%NOTEST

if (nargin<1); use_mex = true; end
if (nargin<2); use_ik = false; end
if (nargin<3); use_bullet = false; end
if (nargin<4); use_angular_momentum = false; end
if (nargin<5); random_navgoal = false; end

load(strcat(getenv('DRC_PATH'),'/control/matlab/data/atlas_v4_fp.mat'));
if random_navgoal
  xstar(1) = randn();
  xstar(2) = randn();
  xstar(6) = pi*randn();
  navgoal = [xstar(1)+rand();xstar(2)+randn();0;0;0;pi*randn()];
else
  navgoal = [1;0;0;0;0;0]; % straight forward 1m
end

% silence some warnings
warning('off','Drake:RigidBodyManipulator:UnsupportedContactPoints')
warning('off','Drake:RigidBodyManipulator:UnsupportedJointLimits')
warning('off','Drake:RigidBodyManipulator:UnsupportedVelocityLimits')

% construct robot model
options.floating = true;
options.ignore_friction = true;
options.dt = 0.001;
options.atlas_version = 4;
options.hokuyo = true;
r = DRCAtlas([],options);
r = r.removeCollisionGroupsExcept({'heel','toe'});
r = compile(r);

xstar(3) = xstar(3) + 0.007; % TODO REMOVE THIS ADJUSTMENT WHEN FOOT CONTACT POINT LOCATIONS ARE FIXED
% set initial state to fixed point
r = r.setInitialState(xstar);

v = r.constructVisualizer;
v.display_dt = 0.01;

nq = getNumPositions(r);

x0 = xstar;

% create footstep and ZMP trajectories
footstep_planner = StatelessFootstepPlanner();
request = drc.footstep_plan_request_t();
request.utime = 0;
request.initial_state = r.getStateFrame().lcmcoder.encode(0, x0);
request.goal_pos = encodePosition3d(navgoal);
request.num_goal_steps = 0;
request.num_existing_steps = 0;
request.params = drc.footstep_plan_params_t();
request.params.max_num_steps = 12;
request.params.min_num_steps = 2;
request.params.min_step_width = 0.2;
request.params.nom_step_width = 0.24;
request.params.max_step_width = 0.3;
request.params.nom_forward_step = 0.5;
request.params.max_forward_step = 0.5;
request.params.nom_upward_step = 0.25;
request.params.nom_downward_step = 0.25;
request.params.planning_mode = request.params.MODE_AUTO;
request.params.behavior = request.params.BEHAVIOR_WALKING;
request.params.map_mode = drc.footstep_plan_params_t.HORIZONTAL_PLANE;
request.params.leading_foot = request.params.LEAD_AUTO;
request.default_step_params = drc.footstep_params_t();
request.default_step_params.step_speed = 0.4;
request.default_step_params.drake_min_hold_time = 0.75;
request.default_step_params.step_height = 0.05;
request.default_step_params.mu = 1.0;
request.default_step_params.drake_instep_shift = 0.0;
request.default_step_params.constrain_full_foot_pose = true;

footstep_plan = footstep_planner.plan_footsteps(r, request);

walking_planner = StatelessWalkingPlanner();
request = drc.walking_plan_request_t();
request.initial_state = r.getStateFrame().lcmcoder.encode(0, x0);
request.footstep_plan = footstep_plan.toLCM();
walking_plan = walking_planner.plan_walking(r, request, true);
walking_ctrl_data = walking_planner.plan_walking(r, request, false);

% No-op: just make sure we can cleanly encode and decode the plan as LCM
tic;
walking_ctrl_data = WalkingControllerData.from_walking_plan_t(walking_ctrl_data.toLCM());
fprintf(1, 'control data lcm code/decode time: %f\n', toc);

% plot walking traj in drake viewer
lcmgl = drake.util.BotLCMGLClient(lcm.lcm.LCM.getSingleton(),'walking-plan');
ts = walking_plan.ts;
for i=1:length(ts)
  lcmgl.glColor3f(0, 0, 1);
  lcmgl.sphere([walking_ctrl_data.comtraj.eval(ts(i));0], 0.01, 20, 20);
  lcmgl.glColor3f(0, 1, 0);
  lcmgl.sphere([walking_ctrl_data.zmptraj.eval(ts(i));0], 0.01, 20, 20);
end
lcmgl.switchBuffers();

traj = atlasUtil.simulateWalking(r, walking_ctrl_data, use_mex, use_ik, use_bullet, use_angular_momentum, true);

playback(v,traj,struct('slider',true));

[com, rms_com] = atlasUtil.plotWalkingTraj(r, traj, walking_ctrl_data);

if rms_com > length(footstep_plan.footsteps)*0.5
  error('drakeWalking unit test failed: error is too large');
  navgoal
end

end