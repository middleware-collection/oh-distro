classdef QPReactiveRecoveryPlan < QPControllerPlan
  properties
    robot
    omega;
    qtraj;
    mu = 0.5;
    V
    g
    LIP_height;
    point_mass_biped;
    lcmgl = LCMGLClient('reactive_recovery')
    last_qp_input;
    last_plan;

    % Initializes on first getQPInput
    % (setup foot contact lock and upper body state to be
    % tracked)
    initialized = 0;

    % Stateful foot contact lock
    % Used to determine how long a foot has been continuously in
    % contact (to the resolution of the rate at which this class
    % is asked for a qp input)
    l_foot_last_noncontact = 0;
    r_foot_last_noncontact = 0;
    l_foot_last_contact = 0;
    r_foot_last_contact = 0;
    l_foot_in_contact_lock = 0;
    r_foot_in_contact_lock = 0;

    % And which-foot-I'm-using-as-stance lock. Only allowed to switch this
    % slowly to prevent bouncing
    %last_used_swing = '';
    %last_swing_switch = 0;
    % debug visualization?
    DEBUG;
    SLOW_DRAW;

    last_ts = [];
    last_coefs = [];
    t_start = [];
    init_time = [];

    lc;

  end

  properties (Constant)
    OTHER_FOOT = struct('right', 'left', 'left', 'right'); % make it easy to look up the other foot's name
    TERRAIN_CONTACT_THRESH = 0.01;
    %SWING_SWITCH_MIN_TIME = 0.1;
    HYST_MIN_CONTACT_TIME = 0.005; % Foot must be solidly, continuously in contact (or out) for this long
    HYST_MIN_NONCONTACT_TIME = 0.2; % to be considered a support (or not a support).
    PLAN_FINISH_THRESHOLD = 0.0; % Duration of a plan that we'll commit to completing without updating further
    CAPTURE_SHRINK_FACTOR = 0.8; % liberal to prevent foot-roll
    FOOT_HULL_COP_SHRINK_FACTOR = 0.5; % liberal to prevent foot-roll, should be same as the capture shrin kfactor?
    MAX_CONSIDERABLE_FOOT_SWING = 0.15; % strides with extrema farther than this are ignored
    U_MAX = 5;

    MIN_STEP_DURATION = 0.4;
    DEBUG_RIGHT_FOOT_IGNORE_DURATION = -0.3;

    CAPTURE_MAX_FLYFOOT_HEIGHT = 0.025;

  end

  methods
    function obj = QPReactiveRecoveryPlan(robot, options)
      checkDependency('iris');
      if nargin < 2
        options = struct();
      end
      options = applyDefaults(options, struct('g', 9.81, 'debug', 1, 'slow_draw', 0));
      obj.lc = lcm.lcm.LCM.getSingleton();
      obj.robot = robot;
      obj.DEBUG = options.debug;
      obj.SLOW_DRAW = options.slow_draw;
      % obj.qtraj = qtraj;
      % obj.LIP_height = LIP_height;
      S = load(obj.robot.fixed_point_file);
      obj.qtraj = S.xstar(1:obj.robot.getNumPositions());
      obj.default_qp_input = atlasControllers.QPInputConstantHeight();
      obj.default_qp_input.whole_body_data.q_des = zeros(obj.robot.getNumPositions(), 1);
      obj.default_qp_input.whole_body_data.constrained_dofs = [findPositionIndices(obj.robot,'arm');findPositionIndices(obj.robot,'neck');findPositionIndices(obj.robot,'back_bkz');findPositionIndices(obj.robot,'back_bky')];
      [~, obj.V, ~, obj.LIP_height] = obj.robot.planZMPController([0;0], obj.qtraj);
      obj.g = options.g;
      obj.point_mass_biped = PointMassBiped(sqrt(options.g / obj.LIP_height));
      obj.initialized = 0;
    end

    function obj = resetInitialization(obj)
      obj.initialized = 0;
      obj.last_plan = [];
      obj.last_qp_input = [];
      obj.l_foot_last_noncontact = 0;
      obj.r_foot_last_noncontact = 0;
      obj.l_foot_last_contact = 0;
      obj.r_foot_last_contact = 0;
      obj.l_foot_in_contact_lock = 0;
      obj.r_foot_in_contact_lock = 0;
      %obj.last_used_swing = '';
      %obj.last_swing_switch = 0;
      obj.last_ts = [];
      obj.last_coefs = [];
      obj.t_start = [];
      obj.init_time = [];
    end

    function next_plan = getSuccessor(obj, t, x)
      next_plan = QPLocomotionPlan.from_standing_state(x, obj.robot);
    end

    function qp_input = getQPControllerInput(obj, t_global, x, rpc, contact_force_detected)
      DEBUG = obj.DEBUG > 0;

      q = x(1:rpc.nq);
      qd = x(rpc.nq + (1:rpc.nv));
      kinsol = doKinematics(obj.robot, q);

      [com, J] = obj.robot.getCOM(kinsol);
      comd = J * qd;


      r_ic = com(1:2) + comd(1:2) / obj.point_mass_biped.omega;


      if obj.SLOW_DRAW
        obj.lcmgl.glColor3f(0.2,0.2,1.0);
        obj.lcmgl.sphere([com(1:2); 0], 0.01, 20, 20);

        obj.lcmgl.glColor3f(0.9,0.2,0.2);
        obj.lcmgl.sphere([r_ic; 0], 0.01, 20, 20);
      end


      foot_states = struct('right', struct('xyz_quat', [], 'xyz_quatdot', [], 'contact', false),...
                          'left', struct('xyz_quat', [], 'xyz_quatdot', [], 'contact', false));
      for f = {'right', 'left'}
        foot = f{1};
        [pos, J] = obj.robot.forwardKin(kinsol, obj.robot.foot_frame_id.(foot), [0;0;0], 2);
        vel = J * qd;
        foot_states.(foot).xyz_quat = pos;
        foot_states.(foot).xyz_quatdot = vel;
        [foot_states.(foot).terrain_height, foot_states.(foot).terrain_normal] = obj.robot.getTerrainHeight(foot_states.(foot).xyz_quat(1:2));

        if contact_force_detected(obj.robot.foot_body_id.(foot))
          foot_states.(foot).contact = true;
        end
      end
      % force terrain heights to come from the foot that's in contact (if either)
      if (foot_states.right.contact)
        foot_states.right.terrain_height = foot_states.right.xyz_quat(3);
        foot_states.left.terrain_height = foot_states.right.xyz_quat(3);
      elseif (foot_states.left.contact)
        foot_states.right.terrain_height = foot_states.left.xyz_quat(3);
        foot_states.left.terrain_height = foot_states.left.xyz_quat(3);
      end
      % finally check foot contacts against the most reasonable terrain
      % heights we've been able to find
      for f = {'right', 'left'}
        foot = f{1};
        [pos, ~] = obj.robot.forwardKin(kinsol, obj.robot.foot_frame_id.(foot), [0;0;0], 2);
        if pos(3) < foot_states.(foot).terrain_height + obj.TERRAIN_CONTACT_THRESH
          foot_states.(foot).contact = true;
        end
      end
      foot_states_raw = foot_states;

      
      % Initialize if we haven't, to get foot lock into a known state
      % and capture upper body pose to hold it through the plan
      if (~obj.initialized) 
        % Take current foot state to be truth
        obj.l_foot_in_contact_lock = foot_states.left.contact;
        obj.r_foot_in_contact_lock = foot_states.right.contact;
        % Record current state of arm, neck to hold (roughly) throughout recovery
        arm_and_neck_inds = [findPositionIndices(obj.robot,'arm');findPositionIndices(obj.robot,'neck')];
        obj.qtraj(arm_and_neck_inds) = x(arm_and_neck_inds);
        %obj.last_used_swing = '';
        obj.init_time = t_global;
        obj.initialized = 1;
        replan = true;
      else
        replan = false;
      end

      % force right foot not useful for first N ms for testing purposes
      if (t_global - obj.init_time < obj.DEBUG_RIGHT_FOOT_IGNORE_DURATION)
        foot_states.right.contact = false;
        obj.r_foot_in_contact_lock = false;
        foot_states_raw.right.contact = false;
        replan = false;
        r_ic = r_ic + [0; -0.1];
      end

      % Update and check against contact locks
      if (~foot_states.left.contact)
        obj.l_foot_last_noncontact = t_global;
      else
        obj.l_foot_last_contact = t_global;
      end
      if (~foot_states.right.contact)
        obj.r_foot_last_noncontact = t_global;
      else
        obj.r_foot_last_contact = t_global;
      end
      % State switching only when hysterisis thresholds are met
      % noncontact -> contact
      if (~obj.r_foot_in_contact_lock && t_global - obj.r_foot_last_noncontact > obj.HYST_MIN_CONTACT_TIME)
        disp('r foot in contact');
        obj.l_foot_in_contact_lock
        replan = true;
        obj.r_foot_in_contact_lock = true;
      end
      if (~obj.l_foot_in_contact_lock && t_global - obj.l_foot_last_noncontact > obj.HYST_MIN_CONTACT_TIME)
        disp('l foot in contact');
        obj.r_foot_in_contact_lock
        obj.l_foot_in_contact_lock = true;
        replan = true;
      end
      % contact -> noncontact
      if (obj.r_foot_in_contact_lock && t_global - obj.r_foot_last_contact > obj.HYST_MIN_NONCONTACT_TIME)
        disp('r foot leaving contact');
        obj.l_foot_in_contact_lock
        obj.r_foot_in_contact_lock = false;
        replan = true;
      end
      if (obj.l_foot_in_contact_lock && t_global - obj.l_foot_last_contact > obj.HYST_MIN_NONCONTACT_TIME)
        disp('l foot leaving contact');
        obj.r_foot_in_contact_lock
        obj.l_foot_in_contact_lock = false;
        replan = true;
      end

      % commit contact from that filtering
      foot_states.right.contact = obj.r_foot_in_contact_lock;
      foot_states.left.contact = obj.l_foot_in_contact_lock;


      % warning('hard-coded for atlas foot shape');
      foot_vertices = struct('right', [-0.05, 0.05, 0.05, -0.05; 
                                       -0.02, -0.02, 0.02, 0.02],...
                             'left', [-0.05, 0.05, 0.05, -0.05; 
                                       -0.02, -0.02, 0.02, 0.02]);
      reachable_vertices = struct('right', [-0.4, 0.4, 0.4, -0.4;
                                     -0.2, -0.2, -0.45, -0.45],...
                            'left', [-0.4, 0.4, 0.4, -0.4;
                                     0.2, 0.2, 0.45, 0.45]);

      is_captured = obj.isICPCaptured(r_ic, foot_states, foot_vertices);
      if (t_global - obj.init_time >= obj.DEBUG_RIGHT_FOOT_IGNORE_DURATION && is_captured) % && ~(~isempty(obj.last_plan) && t_global < (obj.t_start + obj.last_plan.tf)))
        qp_input = obj.getCaptureInput(t_global, r_ic, foot_states, rpc);
        if (~isempty(obj.last_plan))
          disp('captured')
        end
        obj.last_plan = [];
        obj.last_ts = [];
        obj.last_coefs = [];
        obj.t_start = [];
      else
        % if the last plan is about to finish, just finish it first.
        % or if the current contact state equals the old contact state.
        if ((~isempty(obj.last_plan) && obj.last_plan.tf > t_global && ...
              obj.last_plan.tf - t_global < obj.PLAN_FINISH_THRESHOLD) ...
            || (~isempty(obj.last_plan) && ~replan)) % or if we're not replanning and have a plan
          qp_input = obj.getInterceptInput(t_global, obj.t_start, obj.last_ts, obj.last_coefs, foot_states, reachable_vertices, obj.last_plan, rpc);
        else
          disp('Replanning');
          U_MAX = obj.U_MAX;
          intercept_plans = obj.getInterceptPlans(foot_states, foot_vertices, reachable_vertices, r_ic, comd,  obj.point_mass_biped.omega, U_MAX);

          if isempty(intercept_plans)
            disp('recovery is not possible');
            qp_input = obj.last_qp_input;
            if (obj.SLOW_DRAW)
              obj.lcmgl.switchBuffers();
            end
            return;
          end

          % Add to the errors a new term reflecting distance of 
          % foot from down-projected com of robot
          for j=1:numel(intercept_plans)
            com_to_foot_error = norm(intercept_plans(j).r_foot_new(1:2) - com(1:2));
            intercept_plans(j).error = intercept_plans(j).error + 4*com_to_foot_error;
          end
          % Don't switch stance feet if possible
          %if t_global - obj.last_swing_switch < obj.SWING_SWITCH_MIN_TIME
          %  for j=1:numel(intercept_plans)
          %    if (~strcmp(intercept_plans(j).swing_foot, obj.last_used_swing))
          %      intercept_plans(j).error = Inf;
          %    end
          %  end
          %end

          best_plan = QPReactiveRecoveryPlan.chooseBestIntercept(intercept_plans);

          if isempty(best_plan)
            best_plan = obj.last_plan;
          else
            obj.last_plan = best_plan;
          end

          %if ~strcmp(best_plan.swing_foot, obj.last_used_swing)
          %  %fprintf('%s to %s\n', obj.last_used_swing, best_plan.swing_foot);
          %  obj.last_used_swing = best_plan.swing_foot;
          %  obj.last_swing_switch = t_global;
          %end
          [obj.last_ts, obj.last_coefs] = obj.swingTraj(best_plan, foot_states.(best_plan.swing_foot));
          obj.t_start = t_global;
          if (obj.DEBUG > 0)
            fprintf('starting publish for vis: ');
            t0 = tic();
            obj.publishForVisualization(t_global, com, r_ic, obj.last_ts, obj.last_coefs);
            toc(t0);
          end
          qp_input = obj.getInterceptInput(t_global, obj.t_start, obj.last_ts, obj.last_coefs, foot_states, reachable_vertices, best_plan, rpc);
        end
      end
      if (obj.SLOW_DRAW)
        obj.lcmgl.switchBuffers();
      end
      obj.last_qp_input = qp_input;

    end

    function draw_plan(obj, pp, foot_states, reachable_vertices, plan)
      ts = linspace(pp.breaks(1), pp.breaks(end), 50);
      obj.lcmgl.glColor3f(1.0, 0.2, 0.2);
      obj.lcmgl.glLineWidth(1);
      obj.lcmgl.glBegin(obj.lcmgl.LCMGL_LINES);
      ps = ppval(pp, ts);
      for j = 1:length(ts)-1
        obj.lcmgl.glVertex3f(ps(1,j), ps(2,j), ps(3,j));
        obj.lcmgl.glVertex3f(ps(1,j+1), ps(2,j+1), ps(3,j+1));
      end
      obj.lcmgl.glEnd();

      obj.lcmgl.glColor3f(0.2,1.0,0.2);
      obj.lcmgl.sphere([plan.r_cop; 0], 0.01, 20, 20);

      obj.lcmgl.glColor3f(0.9,0.2,0.2)
      obj.lcmgl.glBegin(obj.lcmgl.LCMGL_LINES)
      obj.lcmgl.glVertex3f(plan.r_cop(1), plan.r_cop(2), 0);
      obj.lcmgl.glVertex3f(plan.r_ic_new(1), plan.r_ic_new(2), 0);
      obj.lcmgl.glEnd();

      obj.lcmgl.glColor3f(1.0,1.0,0.3);
      stance_foot = obj.OTHER_FOOT.(plan.swing_foot);
      R = quat2rotmat(foot_states.(stance_foot).xyz_quat(4:7));
      rpy = rotmat2rpy(R);
      reachable_vertices_in_world_frame = bsxfun(@plus, rotmat(rpy(3)) * reachable_vertices.(plan.swing_foot), foot_states.(stance_foot).xyz_quat(1:2));
      obj.lcmgl.glBegin(obj.lcmgl.LCMGL_LINE_LOOP)
      for j = 1:size(reachable_vertices_in_world_frame, 2)
        obj.lcmgl.glVertex3f(reachable_vertices_in_world_frame(1,j),...
                             reachable_vertices_in_world_frame(2,j),...
                             0);
      end
      obj.lcmgl.glEnd();
    end

    function qp_input = getInterceptInput(obj, t_global, t_start, ts, coefs, foot_states, reachable_vertices, best_plan, rpc)
      DEBUG = obj.DEBUG > 0;

      pp = mkpp(ts, coefs, 6);
      if obj.SLOW_DRAW
        obj.draw_plan(pp, foot_states, reachable_vertices, best_plan);
      end
      
      qp_input = obj.default_qp_input;
      qp_input.whole_body_data.q_des = obj.qtraj;
      qp_input.zmp_data.x0 = [mean([foot_states.right.xyz_quat(1:2), foot_states.left.xyz_quat(1:2)], 2);
                              0; 0];
      qp_input.zmp_data.y0 = best_plan.r_cop;
      qp_input.zmp_data.S = obj.V.S;
      qp_input.zmp_data.D = -obj.LIP_height/obj.g * eye(2);

      if strcmp(best_plan.swing_foot, 'right')
        stance_foot = 'left';
      else
        stance_foot = 'right';
      end
      qp_input.support_data = struct('body_id', obj.robot.foot_body_id.(stance_foot),...
                                     'contact_pts', [rpc.contact_groups{obj.robot.foot_body_id.(stance_foot)}.toe,...
                                                     rpc.contact_groups{obj.robot.foot_body_id.(stance_foot)}.heel],...
                                     'support_logic_map', obj.support_logic_maps.require_support,...
                                     'mu',obj.mu,...
                                     'contact_surfaces', 0);

      % Don't allow support if we are less than halfway through the plan
      t = t_global - t_start;
      if t <= (ts(end)/2)
        support_for_swing = obj.support_logic_maps.prevent_support;
      else
        support_for_swing = obj.support_logic_maps.only_if_force_sensed;
      end
      
      qp_input.support_data(end+1) = struct('body_id', obj.robot.foot_body_id.(best_plan.swing_foot),...
                                     'contact_pts', [rpc.contact_groups{obj.robot.foot_body_id.(best_plan.swing_foot)}.toe,...
                                                     rpc.contact_groups{obj.robot.foot_body_id.(best_plan.swing_foot)}.heel],...
                                     'support_logic_map', support_for_swing,...
                                     'mu',obj.mu,...
                                     'contact_surfaces', 0);

      % swing foot
      qp_input.body_motion_data = struct('body_id', obj.robot.foot_frame_id.(best_plan.swing_foot),...
                                         'ts', t_start+ts,...
                                         'coefs', coefs,...
                                         'toe_off_allowed', false,...
                                         'in_floating_base_nullspace', true,...
                                         'control_pose_when_in_contact', false,...
                                         'quat_task_to_world', [1;0;0;0], ...
                                         'translation_task_to_world', [0;0;0], ...
                                         'xyz_kp_multiplier', [1;1;1], ...
                                         'xyz_damping_ratio_multiplier', [1;1;1], ...
                                         'expmap_kp_multiplier', 1, ...
                                         'expmap_damping_ratio_multiplier', 1, ...
                                         'weight_multiplier', [1;1;1;1;1;1]);

      pelvis_height = foot_states.(stance_foot).terrain_height + 0.84;

      foot_rpy = [quat2rpy(foot_states.right.xyz_quat(4:7)), quat2rpy(foot_states.left.xyz_quat(4:7))];
      pelvis_yaw = angleAverage(foot_rpy(3,1), foot_rpy(3,2));
      pelvis_xyz_exp = [0; 0; pelvis_height; quat2expmap(rpy2quat([0;0;pelvis_yaw]))];
      coefs_pelvis = cat(3, zeros(6,1,3), pelvis_xyz_exp);
      qp_input.body_motion_data(end+1) = struct('body_id', rpc.body_ids.pelvis,...
                                                'ts',  t_start+ts,...
                                                'coefs', repmat(coefs_pelvis, [1, length(ts)-1, 1]),...
                                                'toe_off_allowed', false,...
                                                'in_floating_base_nullspace', false,...
                                                'control_pose_when_in_contact', false,...
                                                'quat_task_to_world', [1;0;0;0], ...
                                                'translation_task_to_world', [0;0;0], ...
                                                'xyz_kp_multiplier', [1;1;1], ...
                                                'xyz_damping_ratio_multiplier', [1;1;1], ...
                                                'expmap_kp_multiplier', 1, ...
                                                'expmap_damping_ratio_multiplier', 1, ...
                                                'weight_multiplier', [1;1;1;0;0;1]);
      qp_input.param_set_name = 'recovery';
    end

    function qp_input = getCaptureInput(obj, t_global, r_ic, foot_states, rpc)
      qp_input = obj.default_qp_input;
      qp_input.whole_body_data.q_des = obj.qtraj;
      qp_input.zmp_data.x0 = [mean([foot_states.right.xyz_quat(1:2), foot_states.left.xyz_quat(1:2)], 2);
                              0; 0];
      % qp_input.zmp_data.x0 = [0;0; 0; 0];
      qp_input.zmp_data.y0 = r_ic;
      qp_input.zmp_data.S = obj.V.S;
      qp_input.zmp_data.D = -obj.LIP_height/obj.g * eye(2);

      qp_input.support_data = struct('body_id', cell(1, 2),...
                                     'contact_pts', cell(1, 2),...
                                     'support_logic_map', cell(1, 2),...
                                     'mu', {obj.mu, obj.mu},...
                                     'contact_surfaces', {0, 0});
      qp_input.body_motion_data = struct('body_id', cell(1, 3),..._
                                         'ts', cell(1, 3),...
                                         'coefs', cell(1, 3),...
                                         'toe_off_allowed', cell(1,3),...
                                         'in_floating_base_nullspace', cell(1,3),...
                                         'control_pose_when_in_contact', cell(1,3));
      feet = {'right', 'left'};
      for j = 1:2
        foot = feet{j};
        qp_input.support_data(j).body_id = obj.robot.foot_body_id.(foot);
        qp_input.support_data(j).contact_pts = [rpc.contact_groups{obj.robot.foot_body_id.(foot)}.toe,...
                                                rpc.contact_groups{obj.robot.foot_body_id.(foot)}.heel];
        qp_input.support_data(j).support_logic_map = obj.support_logic_maps.require_support;

        sole_pose_quat = foot_states.(foot).xyz_quat;
        sole_xyz_exp = [sole_pose_quat(1:3); quat2expmap(sole_pose_quat(4:7))];
        sole_xyz_exp(3) = foot_states.(foot).terrain_height;
        qp_input.body_motion_data(j).body_id = obj.robot.foot_frame_id.(foot);
        qp_input.body_motion_data(j).ts = [t_global, t_global];
        qp_input.body_motion_data(j).coefs = cat(3, zeros(6,1,3), reshape(sole_xyz_exp, [6, 1, 1]));
        qp_input.body_motion_data(j).toe_off_allowed = false;
        qp_input.body_motion_data(j).in_floating_base_nullspace = true;
        qp_input.body_motion_data(j).control_pose_when_in_contact = false;
        qp_input.body_motion_data(j).quat_task_to_world =  [1;0;0;0];
        qp_input.body_motion_data(j).translation_task_to_world =  [0;0;0];
        qp_input.body_motion_data(j).xyz_kp_multiplier =  [1;1;1];
        qp_input.body_motion_data(j).xyz_damping_ratio_multiplier =  [1;1;1];
        qp_input.body_motion_data(j).expmap_kp_multiplier =  1;
        qp_input.body_motion_data(j).expmap_damping_ratio_multiplier =  1;
        qp_input.body_motion_data(j).weight_multiplier =  [1;1;1;1;1;1];
      end
      % warning('probably not right pelvis height if feet height differ...')
      pelvis_height = 0.5 * (foot_states.left.terrain_height + foot_states.right.terrain_height) + 0.84;

      foot_rpy = [quat2rpy(foot_states.right.xyz_quat(4:7)), quat2rpy(foot_states.left.xyz_quat(4:7))];
      pelvis_yaw = angleAverage(foot_rpy(3,1), foot_rpy(3,2));
      pelvis_xyz_exp = [0; 0; pelvis_height; quat2expmap(rpy2quat([0;0;pelvis_yaw]))];
      qp_input.body_motion_data(3) = struct('body_id', rpc.body_ids.pelvis,...
                                            'ts', t_global + [0, 0],...
                                            'coefs', cat(3, zeros(6,1,3), pelvis_xyz_exp),...
                                            'toe_off_allowed', false,...
                                            'in_floating_base_nullspace', false,...
                                            'control_pose_when_in_contact', false,...
                                            'quat_task_to_world', [1;0;0;0], ...
                                            'translation_task_to_world', [0;0;0], ...
                                            'xyz_kp_multiplier', [1;1;1], ...
                                            'xyz_damping_ratio_multiplier', [1;1;1], ...
                                            'expmap_kp_multiplier', 1, ...
                                            'expmap_damping_ratio_multiplier', 1, ...
                                            'weight_multiplier', [1;1;1;0;0;1]);
      qp_input.param_set_name = 'recovery';
    end

    function intercept_plans = getInterceptPlans(obj, foot_states, foot_vertices, reach_vertices, r_ic, comd, omega, u)
      intercept_plans = struct('tf', {},...
                               'tswitch', {},...
                               'r_foot_new', {},...
                               'r_ic_new', {},...
                               'error', {},...
                               'swing_foot', {},...
                               'r_cop', {});
      if foot_states.right.contact && foot_states.left.contact
        available_feet = struct('stance', {'right', 'left'},...
                                'swing', {'left', 'right'});
      elseif ~foot_states.right.contact
        available_feet = struct('stance', {'left'},...
                                'swing', {'right'});
      else
        available_feet = struct('stance', {'right'},...
                                'swing', {'left'});
      end

      for j = 1:length(available_feet)
        swing_foot = available_feet(j).swing;
        % ignore this foot if the foot velocity is abnormally high -- 
        % given our u-limit, the foot would travel farther than
        % a threshold
        % dxdt = v - u*t
        % integrate from 0 to v/u ( v - u*t) => v*tf - 1/2*u*tf^2
        % -> v^2 / u - 1/2 * v^2 / u = 1/2 v^2 / u
        if (norm(foot_states.(swing_foot).xyz_quatdot(1:3))^2 / u / 2) < obj.MAX_CONSIDERABLE_FOOT_SWING
          new_plans = obj.getInterceptPlansForFoot(foot_states, swing_foot, foot_vertices, reach_vertices.(swing_foot), r_ic, comd, omega, u);
          if ~isempty(new_plans)
            intercept_plans = [intercept_plans, new_plans];
          end
        end
      end
    end

    function intercept_plans = getInterceptPlansForFoot(obj, foot_states, swing_foot, foot_vertices, reachable_vertices_in_stance_frame, r_ic, comd, omega, u)
      stance_foot = QPReactiveRecoveryPlan.OTHER_FOOT.(swing_foot);

      % Find the center of pressure, which we'll place as close as possible to the ICP
      rpy = quat2rpy(foot_states.(stance_foot).xyz_quat(4:7));
      R = rotmat(rpy(3));
      stance_foot_vertices_in_world = bsxfun(@plus,...
                                             R * obj.FOOT_HULL_COP_SHRINK_FACTOR * foot_vertices.(stance_foot),...
                                             foot_states.(stance_foot).xyz_quat(1:2));
      r_cop = QPReactiveRecoveryPlan.closestPointInConvexHull(r_ic, stance_foot_vertices_in_world);
      % r_ic - r_cop

      % Now transform the problem so that the x axis is aligned with (r_ic - r_cop)
      xprime = (r_ic - r_cop) / norm(r_ic - r_cop);
      yprime = [0, -1; 1, 0] * xprime;
      R = [xprime'; yprime'];
      foot_states_prime = foot_states;
      foot_vertices_prime = foot_vertices;
      for f = fieldnames(foot_states)'
        foot = f{1};
        foot_states_prime.(foot).xyz_quat(1:2) = R * (foot_states.(foot).xyz_quat(1:2) - r_cop);
        foot_states_prime.(foot).xyz_quatdot(1:2) = R * foot_states.(foot).xyz_quatdot(1:2);
        foot_vertices_prime.(foot) = R * foot_vertices_prime.(foot);
      end
      r_ic_prime = R * (r_ic - r_cop);
      assert(abs(r_ic_prime(2)) < 1e-6);


      rpy = quat2rpy(foot_states.(stance_foot).xyz_quat(4:7));
      reachable_vertices_in_world_frame = bsxfun(@plus, rotmat(rpy(3)) * reachable_vertices_in_stance_frame, foot_states.(stance_foot).xyz_quat(1:2));
      reachable_vertices_prime = R * bsxfun(@minus, reachable_vertices_in_world_frame, r_cop);
      intercept_plans = obj.getLocalFrameIntercepts(foot_states_prime, swing_foot, foot_vertices_prime, reachable_vertices_prime, r_ic_prime, u, omega);

      Ri = inv(R);
      % foot_rpy = [quat2rpy(foot_states.left.pose(4:7)), quat2rpy(foot_states.right.pose(4:7))];
      % foot_avg_direction = angleAverage(foot_rpy(3,1), foot_rpy(3,2));
      % % Desired foot direction is along direction of comd, or the opposite
      % % (so we either stumble forward along it or backward, not sideways).
      % % (strong preference for forward)
      % if (norm(comd(1:2)) > 0.25)
      %   comd = comd / norm(comd);
      %   desired_foot_direction = atan2(comd(2), comd(1));
      %   if (abs(angleDiff(desired_foot_direction, foot_avg_direction)) > 3*pi/2)
      %     desired_foot_direction = atan2(-comd(2), -comd(1));
      %   end
      % else
      %   desired_foot_direction = foot_avg_direction;
      % end
      
      for j = 1:length(intercept_plans)
        % TODO: This needs to be updated to use quaternions

        % % rotate foot to be pointing STEP degrees closer to desired foot
        % % dir
        % new_foot_dir_vec = [cos(foot_states.(stance_foot).pose(6)); sin(foot_states.(stance_foot).pose(6))];
        % err = angleDiff(foot_states.(stance_foot).pose(6), desired_foot_direction);
        % %warning('This may result in excessive inward steps. Also pull this value from obj.robot')
        % err = sign(err)*min(abs(err), pi/8);
        % new_foot_dir_vec = rotmat(err)*new_foot_dir_vec;
        % new_foot_yaw = atan2(new_foot_dir_vec(2), new_foot_dir_vec(1));

        intercept_plans(j).r_foot_new = [Ri * intercept_plans(j).r_foot_new + r_cop; 
                                         0;
                                         foot_states.(stance_foot).xyz_quat(4:7)];

        % make it conform to terrain
        intercept_plans(j).r_foot_new(3) = foot_states.(swing_foot).terrain_height;
        normal = foot_states.(swing_foot).terrain_normal;
        normal(3,normal(3,:) < 0) = -normal(3,normal(3,:) < 0);
        pose_rpy = [intercept_plans(j).r_foot_new(1:3); quat2rpy(intercept_plans(j).r_foot_new(4:7))];
        pose_rpy = fitPoseToNormal(pose_rpy, normal);
        intercept_plans(j).r_foot_new = [pose_rpy(1:3); rpy2quat(pose_rpy(4:6))];
        assert(~any(isnan(intercept_plans(j).r_foot_new)));

        intercept_plans(j).r_ic_new = Ri * intercept_plans(j).r_ic_new + r_cop;
        intercept_plans(j).swing_foot = swing_foot;
        intercept_plans(j).r_cop = r_cop;
      end
      
    end

    function [ts, coefs] = swingTraj(obj, intercept_plan, foot_state)
      DEBUG = obj.DEBUG > 1;

      %if norm(intercept_plan.r_foot_new(1:2) - foot_state.pose(1:2)) < 0.05
      %  disp('Asking for swing traj of very short step')
        %if (foot_state.pose(3) < obj.robot.getTerrainHeight(foot_state.pose(1:2)) + obj.TERRAIN_CONTACT_THRESH)
          %disp('Foot seems to be in contact. Holding pose and planting foot')
          %intercept_plan.r_foot_new = foot_state.pose;
          %intercept_plan.r_foot_new(3) = obj.robot.getTerrainHeight(foot_state.pose(1:2));
        %end
      %end

      %fprintf('0,%f,%f\n', intercept_plan.tswitch, intercept_plan.tf);
      
      % generate swing traj, which requires figuring out knot points to feed in
      % which requries knowing roughly what the long-term plan is for a swing, so we can
      % figure out what phase we're in
      % phases:
      %   last: if we can just descend to our goal point, do it, with knot points
      %     along a quadratic arc down to the goal point. "Can just descend" means
      %     "A*z^2 >= (ground distance to goal)"
      %   second-to-last: if we can't just descend to our goal point, arc to it

      dist_to_goal = norm(intercept_plan.r_foot_new(1:2) - foot_state.xyz_quat(1:2));
      descend_coeff = (1/0.15)^2;
      if norm(intercept_plan.r_foot_new(1:2) - foot_state.xyz_quat(1:2)) > 0.025 && ...
        (descend_coeff*((foot_state.xyz_quat(3) - foot_state.terrain_height)^2) >= dist_to_goal)
        disp('case1');
        % descend straight there
        sizecheck(intercept_plan.r_foot_new, [7, 1]);
        fraction_first = 0.7;
        swing_height_first = foot_state.xyz_quat(3)*(1-fraction_first^2);

        ts = [0 0 0 intercept_plan.tf];
        xs = zeros(6,3); % only plan one middle knot point
        xs(1:3,1) = foot_state.xyz_quat(1:3);
        xs(1:3,3) = intercept_plan.r_foot_new(1:3);
        [xs(4:6,1), dw0] = quat2expmap(foot_state.xyz_quat(4:7));
        xs(4:6,3) = quat2expmap(intercept_plan.r_foot_new(4:7));
        xd0 = [foot_state.xyz_quatdot(1:3); dw0 * foot_state.xyz_quatdot(4:7)];
        xdf = zeros(6,1);

        xs(4:6, 2) = xs(4:6,1);
        xs(3, 2) = xs(3, 3) + swing_height_first;
        % interp position between first and last
        xs(1:2, 2) = (1-fraction_first)*xs(1:2, 1) + fraction_first*xs(1:2, 3);

        for j = 2:3
          xs(4:6,j) = unwrapExpmap(xs(4:6,j-1), xs(4:6,j));
        end

        settings = struct('optimize_knot_times', true);
        [coefs, ts, objval] = nWaypointCubicSplineFreeKnotTimesmex(ts(1), ts(end), xs, xd0, xdf);

          tt = linspace(ts(1), ts(end));
          pp = mkpp(ts, coefs, 6);
          ps = ppval(fnder(pp, 2), tt);
          fprintf('umax x:%f y: %f z:%f\n', max(ps(1, :)), max(ps(2, :)), max(ps(3, :)));
           
        if (1 || obj.SLOW_DRAW)
          obj.lcmgl.glColor3f(0.1,0.1,1.0);
          for k=1:3
            obj.lcmgl.sphere(xs(1:3, k).', 0.01, 20, 20);
          end
        end
      else
        disp('case2');
        swing_height_first = 0.03;
        swing_height_second = 0.03;
        fraction_first = 0.15;
        fraction_second = 0.85;
        if (foot_state.xyz_quat(3) > swing_height_first+foot_state.terrain_height)
          % interpolate between current foot height and second swing height
          swing_height_first = swing_height_second*(fraction_first/fraction_second) + (foot_state.xyz_quat(3)*(1-fraction_first/fraction_second));
        end
        ts = [0 0 0 intercept_plan.tf];
        xs = zeros(6,4);
        xs(1:3,1) = foot_state.xyz_quat(1:3);
        xs(1:3,4) = intercept_plan.r_foot_new(1:3);
        [xs(4:6,1), dw0] = quat2expmap(foot_state.xyz_quat(4:7));
        xs(4:6,4) = quat2expmap(intercept_plan.r_foot_new(4:7));
        xd0 = [foot_state.xyz_quatdot(1:3); dw0 * foot_state.xyz_quatdot(4:7)];
        xdf = zeros(6,1);

        xs(4:6, 2) = xs(4:6,1);
        xs(4:6, 3) = xs(4:6,4);
        xs(3, 2) = foot_state.terrain_height + swing_height_first;
        xs(3, 3) = xs(3, 4) + swing_height_second;
        % interp position between first and last
        xs(1:2, 2) = (1-fraction_first)*xs(1:2, 1) + fraction_first*xs(1:2, 4);
        xs(1:2, 3) = (1-fraction_second)*xs(1:2, 1) + fraction_second*xs(1:2, 4);

        settings = struct('optimize_knot_times', true);
        [coefs, ts] = qpSpline(ts, xs, xd0, xdf, settings);
        
        if (1 || obj.SLOW_DRAW)
          obj.lcmgl.glColor3f(0.1,1.0,0.1);
          for k=1:4
            obj.lcmgl.sphere(xs(1:3, k).', 0.01, 20, 20);
          end
        end

          tt = linspace(ts(1), ts(end));
          pp = mkpp(ts, coefs, 6);
          ps = ppval(fnder(pp, 2), tt);
          fprintf('umax x:%f y: %f z:%f\n', max(ps(1, :)), max(ps(2, :)), max(ps(3, :)));

        if DEBUG
          tt = linspace(ts(1), ts(end));
          pp = mkpp(ts, coefs, 6);
          ps = ppval(pp, tt);
          figure(10)
          clf
          subplot(311)
          plot(tt, ps(1,:), tt, ps(2,:), tt, ps(3,:));
          subplot(312)
          ps = ppval(fnder(pp, 1), tt);
          plot(tt, ps(1,:), tt, ps(2,:), tt, ps(3,:));
          subplot(313)
          ps = ppval(fnder(pp, 2), tt);
          plot(tt, ps(1,:), tt, ps(2,:), tt, ps(3,:));
        end
      end
obj.lcmgl.switchBuffers();
      % pp = mkpp(ts, coefs, 6);

      % tt = linspace(0, intercept_plan.tf);
      % ps = ppval(pp, tt);
      % p_knot = ppval(pp, ts);
      % figure(4)
      % clf
      % hold on
      % for j = 1:6
      %   subplot(6, 1, j)
      %   hold on
      %   plot(tt, ps(j,:));
      %   plot(ts, p_knot(j,:), 'ro');
      % end
    end

    function intercept_plans = getLocalFrameIntercepts(obj, foot_states, swing_foot, foot_vertices, reachable_vertices, r_ic_prime, u_max, omega)
      OFFSET = 0.1;

      % r_ic(t) = (r_ic(0) - r_cop) e^(t*omega) + r_cop

      % figure(7)
      % clf

      r_cop_prime = [0;0];

      % subplot(212)
      xprime_axis_intercepts = QPReactiveRecoveryPlan.bangBangInterceptStruct(foot_states.(swing_foot).xyz_quat(2),...
                                                   foot_states.(swing_foot).xyz_quatdot(2),...
                                                   0,...
                                                   u_max);

      t_min = max(min([xprime_axis_intercepts.tf]), obj.MIN_STEP_DURATION);

      % subplot(211)
      % hold on
%       tt = linspace(0, 1);
      % plot(tt, QPReactiveRecoveryPlan.icpUpdate(r_ic_prime(1), r_cop_prime(1), tt, omega) + OFFSET, 'r-')

      x0 = foot_states.(swing_foot).xyz_quat(1);
      xd0 = foot_states.(swing_foot).xyz_quatdot(1);

      intercept_plans = struct('tf', {}, 'tswitch', {}, 'r_foot_new', {}, 'r_ic_new', {});

      % t_min = min_time_to_xprime_axis;
      x_ic = r_ic_prime(1);
      x_cop = r_cop_prime(1);
      % don't narrow our stance to intercept if possible 
      % x_ic_int = max(QPReactiveRecoveryPlan.icpUpdate(x_ic, x_cop, t_min, omega) + OFFSET, x0);
      x_ic_int = QPReactiveRecoveryPlan.icpUpdate(x_ic, x_cop, t_min, omega) + OFFSET;

      x_foot_int = [QPReactiveRecoveryPlan.bangBangUpdate(x0, xd0, t_min, u_max),...
                  QPReactiveRecoveryPlan.bangBangUpdate(x0, xd0, t_min, -u_max)];

      if x_ic_int >= min(x_foot_int) && x_ic_int <= max(x_foot_int)
        % The time to get onto the xprime axis dominates, and we can hit the ICP as soon as we get to that axis
        intercepts = QPReactiveRecoveryPlan.bangBangInterceptStruct(x0, xd0, x_ic_int, u_max);

        if ~isempty(intercepts)
          [~, i] = min([intercepts.tswitch]); % if there are multiple options, take the one that switches sooner
          intercept = intercepts(i);

          r_foot_int = [x_ic_int; 0];
          r_foot_reach = QPReactiveRecoveryPlan.closestPointInConvexHull(r_foot_int, reachable_vertices);
          % r_foot_reach = r_foot_int;


          intercept_plans(end+1) = struct('tf', t_min,...
                                          'tswitch', intercept.tswitch,...
                                          'r_foot_new', r_foot_reach,...
                                          'r_ic_new', [x_ic_int - OFFSET; 0]);
        end
      else
        for u = [u_max, -u_max]
          [t_int, x_int] = QPReactiveRecoveryPlan.expIntercept((x_ic - x_cop), omega, x_cop + OFFSET, x0, xd0, u, 7);
          mask = false(size(t_int));
          for j = 1:numel(t_int)
            if isreal(t_int(j)) && t_int(j) >= min_time_to_xprime_axis && t_int(j) >= abs(xd0 / u)
              mask(j) = true;
            end
          end
          t_int = t_int(mask);
          x_int = x_int(mask);
          
          % Pre-generate r_foot_reaches
          
          % If there are no intercepts, get as close to our desired capture
          % as possible in our current reachable set
          % note: this might be off of the xcop->xic line
          if isempty(t_int)
            r_foot_reaches = QPReactiveRecoveryPlan.closestPointInConvexHull([x_ic + OFFSET; 0], reachable_vertices);
            x_int = r_foot_reaches(1);
          else
            r_foot_reaches = zeros( 2, min(1, numel(x_int)) );
            for j = 1:numel(x_int)
              r_foot_int = [x_int(j); 0];
              y = iris.least_distance.cvxgen_ldp(bsxfun(@minus, reachable_vertices, r_foot_int));
              if norm(y) < 1e-3
                r_foot_reaches(:, j) = r_foot_int;
              else
                % we could theoretically catch it, but not reachably.
                % so go as close as possible.
                r_foot_reaches(:, j) = QPReactiveRecoveryPlan.closestPointInConvexHull(r_foot_int, reachable_vertices);
              end
            end
          end
         
          for j = 1:numel(x_int)
            r_foot_reach = r_foot_reaches(:, j);

            % r_foot_reach = QPReactiveRecoveryPlan.closestPointInConvexHull(r_foot_int, reachable_vertices);
            % r_foot_reach = r_foot_int;

            intercepts = QPReactiveRecoveryPlan.bangBangInterceptStruct(x0, xd0, r_foot_reach(1), u_max);
            if ~isempty(intercepts)
              [~, i] = min([intercepts.tswitch]); % if there are multiple options, take the one that switches sooner
              intercept = intercepts(i);

              if ~valuecheck(x0 + 0.5 * xd0 * intercept.tf + 0.25 * intercept.u * intercept.tf^2 - 0.25 * xd0^2 / intercept.u, r_foot_reach(1))
                warning('Unhandled bad value check')
              end

              intercept.tf = max([intercept.tf, min_time_to_xprime_axis]);
              intercept_plans(end+1) = struct('tf', intercept.tf,...
                                              'tswitch', intercept.tswitch,...
                                              'r_foot_new', r_foot_reach,...
                                              'r_ic_new', [QPReactiveRecoveryPlan.icpUpdate(x_ic, x_cop, intercept.tf, omega);
                                                           0]);
            end
          end
        end
      end


      % for u = [u_max, -u_max]
      %   tt = linspace(abs(xd0 / u), abs(xd0 / u) + 1);
      %   plot(tt, QPReactiveRecoveryPlan.bangBangUpdate(x0, xd0, tt, u), 'g-');

      % end

      % plot([min_time_to_xprime_axis,...
      %       min_time_to_xprime_axis], ...
      %      [QPReactiveRecoveryPlan.bangBangUpdate(x0, xd0, min_time_to_xprime_axis, u_max),...
      %       QPReactiveRecoveryPlan.bangBangUpdate(x0, xd0, min_time_to_xprime_axis, -u_max)], 'r-')

      % for j = 1:length(intercept_plans)
      %   plot(intercept_plans(j).tf, intercept_plans(j).r_foot_new(1), 'ro');
      %   plot(intercept_plans(j).tf, intercept_plans(j).r_ic_new(1), 'r*');
      % end

      for j = 1:length(intercept_plans)
        intercept_plans(j).error = norm(intercept_plans(j).r_foot_new - (intercept_plans(j).r_ic_new + [OFFSET; 0]));
      end
    end

    function publishForVisualization(obj, t, com, r_ic, ts, coefs)
      msg = drc.reactive_recovery_debug_t;
      msg.utime = t*1E9;
      msg.com = com;
      msg.icp = r_ic;
      msg.num_spline_ts = numel(ts);
      msg.num_spline_segments = msg.num_spline_ts - 1;
      msg.ts = ts;
      msg.coefs = coefs;
      obj.lc.publish('REACTIVE_RECOVERY_DEBUG', msg);
    end
  end

  methods(Static)
    function intercepts = bangBangInterceptStruct(x0, xd0, xf, u_max)
      [tf, tswitch, u] = QPReactiveRecoveryPlan.bangBangIntercept(x0, xd0, xf, u_max);
      intercepts = struct('tf', num2cell(tf),...
                          'tswitch', num2cell(tswitch),...
                          'u', num2cell(u));
    end

    function best_plan = chooseBestIntercept(intercept_plans)
      [min_error, idx] = min([intercept_plans.error]);
      best_plan = intercept_plans(idx);
    end
  end

  methods
    is_captured = isICPCaptured(obj, r_ic, foot_states, foot_vertices);
  end

  methods(Static)
    y = closestPointInConvexHull(x, V);
    xf = bangBangUpdate(x0, xd0, tf, u);
    x_ic_new = icpUpdate(x_ic, x_cop, dt, omega);
    [tf, tswitch, u] = bangBangIntercept(x0, xd0, xf, u_max);
    p = expTaylor(a, b, c, n);
    [t_int, l_int] = expIntercept(a, b, c, l0, ld0, u, n);

  end
end


