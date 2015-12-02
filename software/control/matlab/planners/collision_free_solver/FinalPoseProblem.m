classdef FinalPoseProblem
  
  properties
    robot
    end_effector_id
    q_start
    x_goal
    additional_constraints
    goal_constraints
    q_nom
    end_effector_point
    min_distance
    capability_map
    ikoptions
    grasping_hand
    active_collision_options
    debug
  end
  
  properties (Constant)
    SUCCESS = 1
    FAIL_NO_FINAL_POSE = 12
  end  
  
  methods
    
    function obj = FinalPoseProblem(robot, end_effector_id,...
         q_start, x_goal, additional_constraints, q_nom, capabilty_map, ikoptions, varargin)
      
      opt.graspinghand =  'right';
      opt.mindistance = 0.005;
      opt.activecollisionoptions = struct();
      opt.endeffectorpoint = [0; 0; 0]';
      opt.debug = false;
      
      optNames = fieldnames(opt);
      nArgs = length(varargin);
      if round(nArgs/2)~=nArgs/2
        error('Needs propertyName/propertyValue pairs')
      end
      for pair = reshape(varargin,2,[])
        inpName = lower(pair{1});
        if any(strcmp(inpName,optNames))
          opt.(inpName) = pair{2};
        else
          error('%s is not a recognized parameter name',inpName)
        end
      end
      
      obj.robot = robot;
      obj.end_effector_id = end_effector_id;
      obj.q_start = q_start;
      obj.x_goal = x_goal;
      obj.additional_constraints = additional_constraints;
      obj.q_nom = q_nom;
      obj.capability_map = capabilty_map;
      obj.ikoptions = ikoptions;
      obj.end_effector_point = opt.endeffectorpoint;
      obj.min_distance = opt.mindistance;
      obj.grasping_hand = opt.graspinghand;
      obj.active_collision_options = opt.activecollisionoptions;
      obj.goal_constraints = obj.generateGoalConstraints();
      obj.debug = opt.debug;

    end

    function [x_goal, info, debug_vars] = findFinalPose(obj, point_cloud)
      
      info = obj.SUCCESS;
      if obj.debug
        debug_vars = obj.initDebugVars();
      else
        debug_vars = struct();
      end
      
      %compute final pose
      tic
      if length(obj.x_goal) == 7
        disp('Searching for a feasible final configuration...')
        if obj.debug
          timer = tic();
        end
        [qGoal, debug_vars] = obj.searchFinalPose(point_cloud, debug_vars);
        if isempty(qGoal)
          info = obj.FAIL_NO_FINAL_POSE;
          x_goal = obj.x_goal;
          disp('Failed to find a feasible final configuration')
          return
        else
          kinsol = obj.robot.doKinematics(qGoal);
          obj.x_goal = obj.robot.forwardKin(kinsol, obj.end_effector_id, obj.end_effector_point, 2);
          obj.x_goal = [obj.x_goal; qGoal];
          disp('Final configuration found')
        end
      elseif length(obj.x_goal) == 7 + obj.robot.num_positions
        disp('Final configuration input found A')
      elseif length(obj.x_goal) == obj.robot.num_positions
        kinsol = obj.robot.doKinematics(obj.x_goal);
        obj.x_goal = [obj.robot.forwardKin(kinsol, obj.end_effector_id, obj.end_effector_point, 2); obj.x_goal];
        disp('Final configuration input found B')
      else
        error('Bad final configuration input')
      end
      
      x_goal = obj.x_goal;
      if obj.debug
        debug_vars.info = info;
        debug_vars.computation_time = toc(timer);
        fprintf('Computation Time: %.2f s', debug_vars.computation_time)
      end
    end
    
    function [qOpt, debug_vars] = searchFinalPose(obj, point_cloud, debug_vars)
      setupTimer = tic;
      
      kinSol = obj.robot.doKinematics(obj.q_start);
      options.rotation_type = 2;
      options.compute_gradients = true;
      options.rotation_type = 1;
      
      root = obj.capability_map.root_link.(obj.grasping_hand);
      endEffector = obj.capability_map.end_effector_link.(obj.grasping_hand);
      rootPoint = obj.capability_map.root_point.(obj.grasping_hand);
      EEPoint = obj.capability_map.end_effector_point.(obj.grasping_hand);
      base = obj.capability_map.base_link;
      
      rootPose = obj.robot.forwardKin(kinSol, root, rootPoint, 2);
      trPose = obj.robot.forwardKin(kinSol, base, [0;0;0], 2);
      tr2root = quat2rotmat(trPose(4:end))\(rootPose(1:3)-trPose(1:3));
      np = obj.robot.num_positions;
      
      ee_rotmat = quat2rotmat(obj.x_goal(4:7));
      ee_direction = ee_rotmat(:,2);
      obj.capability_map = obj.capability_map.setEEPose(obj.x_goal);
      reduceTimer = tic;
      obj.capability_map = obj.capability_map.reduceActiveSet(ee_direction, 1000, true, point_cloud, 0, 0, 2, 1.5);
      fprintf('reduce Time: %.4f s\n', toc(reduceTimer))
      vox_centers = obj.capability_map.getActiveVoxelCentres();
      n_vox = obj.capability_map.n_active_voxels;
      iter = 0;
      qOpt = [];
      cost = [];
      validConfs =  double.empty(np+1, 0);
      fprintf('Setup time: %.2f s\n', toc(setupTimer))
      iterationTimer = tic;
      
      for vox = randperm(n_vox)
        iter = iter + 1;
        dist = norm(vox_centers(:,vox));
        axis = -vox_centers(:,vox)/dist;
%         drawTreePoints([[0;0;0] vox_centers(1:3,vox)], 'lines', true, 'text', 'cm_point')
%         drawTreePoints([obj.x_goal(1:3) - vox_centers(1:3,vox), obj.x_goal(1:3)], 'lines', true)
        shDistance = Point2PointDistanceConstraint(obj.robot, root, obj.robot.findLinkId('world'), [0;0;0], obj.x_goal(1:3), dist, dist);
        shGaze = WorldGazeTargetConstraint(obj.robot, base, axis, obj.x_goal(1:3), tr2root, 0);
%         shConstraint = WorldPositionConstraint(obj.robot, root, [0;0;0], obj.x_goal(1:3) - vox_centers(1:3,vox), obj.x_goal(1:3) - vox_centers(1:3,vox));
        shOrient = WorldEulerConstraint(obj.robot, base, [-pi/50;-pi/20; -pi/20], [pi/50; pi/20; pi/20]);
        constraints = [{shDistance, shGaze, shOrient}, obj.goal_constraints, obj.additional_constraints];
        [q, info] = inverseKin(obj.robot, obj.q_nom, obj.q_nom, constraints{:}, obj.ikoptions);
        valid = (info < 10);
        kinSol = obj.robot.doKinematics(q, ones(obj.robot.num_positions, 1), options);
        if valid
          valid = ~obj.robot.collidingPointsCheckOnly(kinSol, point_cloud, obj.min_distance);
          if valid
            cost = (obj.q_nom - q)'*obj.ikoptions.Q*(obj.q_nom - q);
            validConfs(:,vox) = [cost; q];
            if cost < 20
              if obj.debug
                debug_vars.cost_below_threshold = true;
              end
              break
            end
          else
          end
        end
      end
      if ~isempty(validConfs)
        validConfs = validConfs(:, validConfs(1,:) > 0);
        [cost, qOptIdx] =  min(validConfs(1,:));
        qOpt = validConfs(2:end, qOptIdx);
      end
      fprintf('iteration Time: %.4f\n', toc(iterationTimer))
      
      debug_vars.n_capability_map_samples = iter;
      debug_vars.cost = cost;
      
    end
    
    function constraints = generateGoalConstraints(obj)
%       !!!!!!WARNING:This works for val2 only!!!!!!!!!
      end_effector = obj.capability_map.end_effector_link.(obj.grasping_hand);
      goalDistConstraint = Point2PointDistanceConstraint(obj.robot, end_effector, obj.robot.findLinkId('world'), obj.end_effector_point, obj.x_goal(1:3), -0.001, 0.001);
      goalQuatConstraint = WorldQuatConstraint(obj.robot, end_effector, obj.x_goal(4:7), 1/180*pi);
      constraints = {goalDistConstraint, goalQuatConstraint};
%       !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    end
    
  end
  
  methods (Static)    
    
    function debug_vars = initDebugVars()
      debug_vars = struct(...
        'n_capability_map_samples', [], ...
        'cost', [], ...
        'info', [], ...
        'cost_below_threshold', [], ...
        'n_body_collision_iter', 0, ...
        'n_arm_collision_iter', 0, ...
        'n_nullspace_iter', 0, ...
        'n_accepted_after_armcollision', 0, ...
        'n_accepted_after_nullspace', 0, ...
        'nullspace_iter', struct('success', [], 'nIter', []), ...
        'computation_time', []...
        );
    end
    
  end
  
end